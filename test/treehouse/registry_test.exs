defmodule Treehouse.RegistryTest do
  use ExUnit.Case, async: false

  alias Treehouse.Registry

  setup do
    db_path = Path.join(System.tmp_dir!(), "treehouse_registry_test_#{:rand.uniform(100_000)}.db")
    {:ok, conn} = Registry.open(db_path)
    :ok = Registry.init_schema(conn)

    on_exit(fn -> File.rm(db_path) end)

    {:ok, conn: conn}
  end

  describe "allocate/3" do
    test "creates new allocation", %{conn: conn} do
      {:ok, alloc} = Registry.allocate(conn, "main", 10)
      assert alloc.branch == "main"
      assert alloc.ip_suffix == 10
      assert alloc.sanitized_name == "main"
      assert alloc.allocated_at != nil
      assert alloc.last_seen_at != nil
    end

    test "sanitizes branch name", %{conn: conn} do
      {:ok, alloc} = Registry.allocate(conn, "feature/new-thing", 11)
      assert alloc.sanitized_name == "feature-new-thing"
    end

    test "returns existing allocation if branch already exists", %{conn: conn} do
      {:ok, first} = Registry.allocate(conn, "main", 10)
      {:ok, second} = Registry.allocate(conn, "main", 20)
      assert first.id == second.id
      assert first.ip_suffix == second.ip_suffix
    end
  end

  describe "find_by_branch/2" do
    test "returns allocation for branch", %{conn: conn} do
      {:ok, _} = Registry.allocate(conn, "main", 10)
      {:ok, found} = Registry.find_by_branch(conn, "main")
      assert found.branch == "main"
    end

    test "returns nil for unknown branch", %{conn: conn} do
      assert {:ok, nil} = Registry.find_by_branch(conn, "unknown")
    end
  end

  describe "find_by_ip/2" do
    test "returns allocation for IP suffix", %{conn: conn} do
      {:ok, _} = Registry.allocate(conn, "main", 42)
      {:ok, found} = Registry.find_by_ip(conn, 42)
      assert found.branch == "main"
    end

    test "returns nil for unused IP", %{conn: conn} do
      assert {:ok, nil} = Registry.find_by_ip(conn, 99)
    end
  end

  describe "list_allocations/1" do
    test "returns all allocations", %{conn: conn} do
      {:ok, _} = Registry.allocate(conn, "main", 10)
      {:ok, _} = Registry.allocate(conn, "develop", 11)
      {:ok, list} = Registry.list_allocations(conn)
      assert length(list) == 2
    end

    test "returns empty list when none", %{conn: conn} do
      {:ok, list} = Registry.list_allocations(conn)
      assert list == []
    end
  end

  describe "touch/2" do
    test "updates last_seen_at timestamp", %{conn: conn} do
      {:ok, alloc} = Registry.allocate(conn, "main", 10)
      :timer.sleep(10)
      :ok = Registry.touch(conn, alloc.id)
      {:ok, updated} = Registry.find_by_branch(conn, "main")
      assert updated.last_seen_at > alloc.last_seen_at
    end
  end

  describe "release/2" do
    test "deletes allocation", %{conn: conn} do
      {:ok, alloc} = Registry.allocate(conn, "main", 10)
      :ok = Registry.release(conn, alloc.id)
      {:ok, found} = Registry.find_by_branch(conn, "main")
      assert found == nil
    end
  end

  describe "stale_allocations/2" do
    test "returns allocations older than threshold", %{conn: conn} do
      # Create with old timestamp (simulate 8 days ago)
      {:ok, _old} = Registry.allocate(conn, "old-branch", 10)
      eight_days_ago = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.to_iso8601()

      Exqlite.Sqlite3.execute(
        conn,
        "UPDATE allocations SET last_seen_at = '#{eight_days_ago}' WHERE branch = 'old-branch'"
      )

      {:ok, _new} = Registry.allocate(conn, "new-branch", 11)

      {:ok, stale} = Registry.stale_allocations(conn, 7)
      assert length(stale) == 1
      assert hd(stale).branch == "old-branch"
    end
  end

  describe "used_ips/1" do
    test "returns list of used IP suffixes", %{conn: conn} do
      {:ok, _} = Registry.allocate(conn, "main", 10)
      {:ok, _} = Registry.allocate(conn, "develop", 20)
      {:ok, ips} = Registry.used_ips(conn)
      assert Enum.sort(ips) == [10, 20]
    end
  end

  describe "error handling with closed connection" do
    test "init_schema returns error when connection closed", %{conn: conn} do
      Exqlite.Sqlite3.close(conn)
      assert {:error, _} = Registry.init_schema(conn)
    end

    test "allocate returns error when connection closed", %{conn: conn} do
      Exqlite.Sqlite3.close(conn)
      assert {:error, _} = Registry.allocate(conn, "test", 10)
    end

    test "find_by_branch returns error when connection closed", %{conn: conn} do
      Exqlite.Sqlite3.close(conn)
      assert {:error, _} = Registry.find_by_branch(conn, "test")
    end

    test "find_by_ip returns error when connection closed", %{conn: conn} do
      Exqlite.Sqlite3.close(conn)
      assert {:error, _} = Registry.find_by_ip(conn, 10)
    end

    test "list_allocations returns error when connection closed", %{conn: conn} do
      Exqlite.Sqlite3.close(conn)
      assert {:error, _} = Registry.list_allocations(conn)
    end

    test "stale_allocations returns error when connection closed", %{conn: conn} do
      Exqlite.Sqlite3.close(conn)
      assert {:error, _} = Registry.stale_allocations(conn, 7)
    end

    test "used_ips returns error when connection closed", %{conn: conn} do
      Exqlite.Sqlite3.close(conn)
      assert {:error, _} = Registry.used_ips(conn)
    end
  end
end
