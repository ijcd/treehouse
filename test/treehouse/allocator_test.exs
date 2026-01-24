defmodule Treehouse.AllocatorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Hammox

  alias Treehouse.Allocator

  setup :verify_on_exit!

  setup do
    db_path =
      Path.join(System.tmp_dir!(), "treehouse_allocator_test_#{:rand.uniform(100_000)}.db")

    {:ok, pid} = Allocator.start_link(db_path: db_path, name: nil)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(db_path)
      Application.delete_env(:treehouse, :registry_adapter)
    end)

    {:ok, allocator: pid, db_path: db_path}
  end

  describe "start_link/1" do
    test "starts with default options" do
      # This exercises the default args clause
      db = Path.join(System.tmp_dir!(), "treehouse_defaults_test_#{:rand.uniform(100_000)}.db")
      Application.put_env(:treehouse, :registry_path, db)

      on_exit(fn ->
        Application.delete_env(:treehouse, :registry_path)
        File.rm(db)
      end)

      # start_link/0 uses default empty list
      {:ok, pid} = Allocator.start_link()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "returns error when registry open fails" do
      # Use global mode since GenServer spawns a new process
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :open, fn _path ->
        {:error, :database_open_failed}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)

      # Trap exits since GenServer sends EXIT when init returns {:stop, reason}
      Process.flag(:trap_exit, true)

      assert {:error, :database_open_failed} =
               Allocator.start_link(db_path: "/any/path", name: nil)
    end
  end

  describe "get_or_allocate/2" do
    test "allocates IP for new branch", %{allocator: pid} do
      {:ok, ip} = Allocator.get_or_allocate(pid, "main")
      assert ip =~ ~r/^127\.0\.0\.\d+$/
    end

    test "returns same IP for same branch", %{allocator: pid} do
      {:ok, ip1} = Allocator.get_or_allocate(pid, "main")
      {:ok, ip2} = Allocator.get_or_allocate(pid, "main")
      assert ip1 == ip2
    end

    test "allocates different IPs for different branches", %{allocator: pid} do
      {:ok, ip1} = Allocator.get_or_allocate(pid, "main")
      {:ok, ip2} = Allocator.get_or_allocate(pid, "develop")
      assert ip1 != ip2
    end

    test "allocates IPs in configured range", %{allocator: pid} do
      {:ok, ip} = Allocator.get_or_allocate(pid, "main")
      [_, _, _, suffix] = ip |> String.split(".") |> Enum.map(&String.to_integer/1)
      assert suffix >= 10 and suffix <= 99
    end
  end

  describe "release/2" do
    test "releases allocated IP", %{allocator: pid} do
      {:ok, _ip} = Allocator.get_or_allocate(pid, "main")
      :ok = Allocator.release(pid, "main")
      {:ok, ip2} = Allocator.get_or_allocate(pid, "other-branch")
      assert ip2 =~ ~r/^127\.0\.0\.\d+$/
    end

    test "release unknown branch is ok", %{allocator: pid} do
      assert :ok = Allocator.release(pid, "nonexistent")
    end
  end

  describe "list/1" do
    test "returns empty list initially", %{allocator: pid} do
      assert {:ok, []} = Allocator.list(pid)
    end

    test "returns all allocations", %{allocator: pid} do
      {:ok, _} = Allocator.get_or_allocate(pid, "main")
      {:ok, _} = Allocator.get_or_allocate(pid, "develop")
      {:ok, list} = Allocator.list(pid)
      assert length(list) == 2
    end
  end

  describe "info/2" do
    test "returns allocation info for branch", %{allocator: pid} do
      {:ok, ip} = Allocator.get_or_allocate(pid, "main")
      {:ok, info} = Allocator.info(pid, "main")
      assert info.branch == "main"
      assert info.ip_suffix != nil
      assert "127.0.0.#{info.ip_suffix}" == ip
    end

    test "returns nil for unknown branch", %{allocator: pid} do
      assert {:ok, nil} = Allocator.info(pid, "unknown")
    end
  end

  describe "lazy reclamation" do
    test "reclaims stale IP when pool exhausted" do
      # Start with tiny pool (only 2 IPs)
      db = Path.join(System.tmp_dir!(), "treehouse_reclaim_test_#{:rand.uniform(100_000)}.db")

      {:ok, pid} =
        Allocator.start_link(
          db_path: db,
          name: nil,
          ip_range_start: 10,
          ip_range_end: 11,
          # Immediate staleness for testing
          stale_threshold_days: 0
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db)
      end)

      # Allocate both IPs
      {:ok, _} = Allocator.get_or_allocate(pid, "branch1")
      {:ok, _} = Allocator.get_or_allocate(pid, "branch2")

      # Make branch1 stale
      :timer.sleep(10)

      # Third allocation should reclaim stale one
      {:ok, ip3} = Allocator.get_or_allocate(pid, "branch3")
      assert ip3 =~ ~r/^127\.0\.0\.(10|11)$/
    end

    test "returns error when pool exhausted and no stale IPs" do
      # Start with tiny pool (only 2 IPs) and long stale threshold
      db = Path.join(System.tmp_dir!(), "treehouse_exhausted_test_#{:rand.uniform(100_000)}.db")

      {:ok, pid} =
        Allocator.start_link(
          db_path: db,
          name: nil,
          ip_range_start: 10,
          ip_range_end: 11,
          # Nothing will be stale
          stale_threshold_days: 365
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db)
      end)

      # Allocate both IPs
      {:ok, _} = Allocator.get_or_allocate(pid, "branch1")
      {:ok, _} = Allocator.get_or_allocate(pid, "branch2")

      # Third allocation should fail - pool exhausted, nothing stale
      log =
        capture_log(fn ->
          assert {:error, :pool_exhausted} = Allocator.get_or_allocate(pid, "branch3")
        end)

      assert log =~ "Failed to allocate IP"
    end
  end

  describe "error handling with closed connection" do
    test "get_or_allocate returns error when connection closed", %{allocator: pid} do
      state = :sys.get_state(pid)
      Exqlite.Sqlite3.close(state.conn)

      assert {:error, _} = Allocator.get_or_allocate(pid, "test")
    end

    test "release returns error when connection closed", %{allocator: pid} do
      state = :sys.get_state(pid)
      Exqlite.Sqlite3.close(state.conn)

      assert {:error, _} = Allocator.release(pid, "test")
    end

    test "list returns error when connection closed", %{allocator: pid} do
      state = :sys.get_state(pid)
      Exqlite.Sqlite3.close(state.conn)

      assert {:error, _} = Allocator.list(pid)
    end

    test "info returns error when connection closed", %{allocator: pid} do
      state = :sys.get_state(pid)
      Exqlite.Sqlite3.close(state.conn)

      assert {:error, _} = Allocator.info(pid, "test")
    end

    test "reclaim_stale_ip handles stale_allocations error" do
      # Use mock registry to simulate specific failure scenario
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :open, fn _path ->
        {:ok, :mock_conn}
      end)

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn :mock_conn ->
        :ok
      end)

      # find_by_branch returns nil (branch not found)
      Hammox.stub(Treehouse.MockRegistry, :find_by_branch, fn :mock_conn, _branch ->
        {:ok, nil}
      end)

      # used_ips returns all IPs used (pool exhausted)
      Hammox.stub(Treehouse.MockRegistry, :used_ips, fn :mock_conn ->
        {:ok, [10, 11]}
      end)

      # stale_allocations returns error (triggers the error path we want to test)
      Hammox.stub(Treehouse.MockRegistry, :stale_allocations, fn :mock_conn, _days ->
        {:error, :mock_stale_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)

      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Allocator.start_link(
          db_path: "/mock/path",
          name: nil,
          ip_range_start: 10,
          ip_range_end: 11,
          stale_threshold_days: 0
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      # This should hit: find_by_branch -> nil, find_free_ip -> exhausted,
      # reclaim_stale_ip -> {:error, _} -> :none_reclaimable -> pool_exhausted
      log =
        capture_log(fn ->
          assert {:error, :pool_exhausted} = Allocator.get_or_allocate(pid, "branch3")
        end)

      assert log =~ "Failed to allocate IP"
    end
  end
end
