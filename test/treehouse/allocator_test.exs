defmodule Treehouse.AllocatorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Hammox
  import Treehouse.TestHelpers

  alias Treehouse.Allocator

  # Default IP range for tests (matches Allocator defaults)
  @default_ip_start 10
  @default_ip_end 99

  setup :verify_on_exit!

  setup do
    on_exit(&cleanup_adapter_env/0)
    setup_allocator(prefix: "treehouse_allocator_test")
  end

  describe "struct" do
    test "defstruct creates valid struct" do
      # Explicitly exercise defstruct-generated functions for coverage
      struct = Allocator.__struct__()
      assert %Allocator{} = struct
      assert struct.ip_range_start == nil

      struct2 = Allocator.__struct__(ip_range_start: 10)
      assert struct2.ip_range_start == 10
    end
  end

  describe "start_link/1" do
    test "starts with default options", %{registry: _registry_pid} do
      # This exercises the default args clause
      db = temp_db_path("treehouse_defaults_test")
      Application.put_env(:treehouse, :registry_path, db)

      on_exit(fn ->
        Application.delete_env(:treehouse, :registry_path)
        File.rm(db)
      end)

      # start_link/0 uses default empty list (Registry already running from setup)
      {:ok, pid} = Allocator.start_link()
      assert Process.alive?(pid)
      GenServer.stop(pid)
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
      assert suffix >= @default_ip_start and suffix <= @default_ip_end
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
      db = temp_db_path("treehouse_reclaim_test")

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
      db = temp_db_path("treehouse_exhausted_test")

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

  describe "error handling with mocked registry" do
    # Mock tests need to stop the setup-started allocator and registry
    # to avoid conflicts with the mock configuration
    setup %{allocator: allocator_pid, registry: registry_pid} do
      GenServer.stop(allocator_pid)
      GenServer.stop(registry_pid)
      :ok
    end

    test "get_or_allocate returns error when registry fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)

      Hammox.stub(Treehouse.MockRegistry, :find_by_branch, fn _branch ->
        {:error, :mock_db_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} = Allocator.start_link(db_path: "/mock/path", name: nil)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:error, :mock_db_error} = Allocator.get_or_allocate(pid, "test")
    end

    test "release returns error when registry fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)

      Hammox.stub(Treehouse.MockRegistry, :find_by_branch, fn _branch ->
        {:error, :mock_db_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} = Allocator.start_link(db_path: "/mock/path", name: nil)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:error, :mock_db_error} = Allocator.release(pid, "test")
    end

    test "list returns error when registry fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)

      Hammox.stub(Treehouse.MockRegistry, :list_allocations, fn ->
        {:error, :mock_db_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} = Allocator.start_link(db_path: "/mock/path", name: nil)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:error, :mock_db_error} = Allocator.list(pid)
    end

    test "info returns error when registry fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)

      Hammox.stub(Treehouse.MockRegistry, :find_by_branch, fn _branch ->
        {:error, :mock_db_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} = Allocator.start_link(db_path: "/mock/path", name: nil)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert {:error, :mock_db_error} = Allocator.info(pid, "test")
    end

    test "reclaim_stale_ip handles stale_allocations error" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)

      # find_by_branch returns nil (branch not found)
      Hammox.stub(Treehouse.MockRegistry, :find_by_branch, fn _branch ->
        {:ok, nil}
      end)

      # used_ips returns all IPs used (pool exhausted)
      Hammox.stub(Treehouse.MockRegistry, :used_ips, fn -> {:ok, [10, 11]} end)

      # stale_allocations returns error (triggers the error path we want to test)
      Hammox.stub(Treehouse.MockRegistry, :stale_allocations, fn _days ->
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

    test "touch_allocation logs warning when touch fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)

      Hammox.stub(Treehouse.MockRegistry, :find_by_branch, fn _branch ->
        {:ok, nil}
      end)

      Hammox.stub(Treehouse.MockRegistry, :used_ips, fn -> {:ok, []} end)

      Hammox.stub(Treehouse.MockRegistry, :allocate, fn branch, ip_suffix ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        {:ok,
         %{
           id: 1,
           branch: branch,
           ip_suffix: ip_suffix,
           sanitized_name: branch,
           allocated_at: now,
           last_seen_at: now
         }}
      end)

      # touch returns error to trigger warning log
      Hammox.stub(Treehouse.MockRegistry, :touch, fn _id ->
        {:error, :mock_touch_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} = Allocator.start_link(db_path: "/mock/path", name: nil)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      # Allocation succeeds but touch fails - should log warning
      log =
        capture_log(fn ->
          {:ok, ip} = Allocator.get_or_allocate(pid, "test-branch")
          assert ip == "127.0.0.10"
        end)

      assert log =~ "Failed to update last_seen"
    end
  end
end
