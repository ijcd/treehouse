defmodule Treehouse.Registry.SqliteTest do
  use ExUnit.Case, async: false

  alias Treehouse.Registry.Sqlite

  import Treehouse.TestFixtures

  describe "start_link/0" do
    test "starts with default options (no args)" do
      db_path = temp_db_path("sqlite_defaults_test")
      Application.put_env(:treehouse, :registry_path, db_path)

      on_exit(fn ->
        Application.delete_env(:treehouse, :registry_path)
        File.rm(db_path)
      end)

      # Exercise the default args clause: start_link()
      {:ok, pid} = Sqlite.start_link()
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  # NOTE: These tests use meck to simulate Exqlite errors that are hard to trigger
  # in practice (disk full, corrupt DB, etc). They test defensive error handling.
  # Consider these integration tests of error paths rather than unit tests.
  describe "init/1 error path" do
    test "returns stop when database open fails" do
      # Use a temp path so mkdir_p succeeds
      db_path = temp_db_path("sqlite_open_fail_test")

      # Simulates: disk full, permission denied, etc.
      :meck.new(Exqlite.Sqlite3, [:passthrough, :unstick, :no_passthrough_cover])

      :meck.expect(Exqlite.Sqlite3, :open, fn _path ->
        {:error, :mock_open_error}
      end)

      on_exit(fn ->
        try do
          :meck.unload(Exqlite.Sqlite3)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        File.rm(db_path)
      end)

      # Trap exits since GenServer sends EXIT when init returns {:stop, reason}
      Process.flag(:trap_exit, true)

      assert {:error, :mock_open_error} =
               Sqlite.start_link(db_path: db_path, name: nil)
    end
  end

  describe "init_schema paths" do
    test "init_schema returns :ok on success" do
      db_path = temp_db_path("sqlite_init_schema_test")
      {:ok, pid} = Sqlite.start_link(db_path: db_path, name: nil)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db_path)
      end)

      # This exercises the :ok -> :ok path in do_init_schema (line 159)
      assert :ok = GenServer.call(pid, :init_schema)
      # Call again to verify idempotency
      assert :ok = GenServer.call(pid, :init_schema)
    end

    test "init_schema returns error when execute fails" do
      db_path = temp_db_path("sqlite_init_schema_error_test")
      {:ok, pid} = Sqlite.start_link(db_path: db_path, name: nil)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db_path)

        try do
          :meck.unload(Exqlite.Sqlite3)
        catch
          _, _ -> :ok
        end
      end)

      # Mock execute to return error for init_schema
      :meck.new(Exqlite.Sqlite3, [:passthrough, :unstick, :no_passthrough_cover])

      :meck.expect(Exqlite.Sqlite3, :execute, fn _conn, _sql ->
        {:error, :mock_execute_error}
      end)

      # This exercises the {:error, _} = err -> err path (line 160)
      assert {:error, :mock_execute_error} = GenServer.call(pid, :init_schema)
    end
  end

  describe "allocate paths" do
    test "allocate returns existing allocation without inserting" do
      db_path = temp_db_path("sqlite_existing_test")
      {:ok, pid} = Sqlite.start_link(db_path: db_path, name: nil)
      :ok = GenServer.call(pid, :init_schema)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db_path)
      end)

      # First allocation creates new record
      {:ok, first} = GenServer.call(pid, {:allocate, "testapp", "test-branch", 10})
      assert first.project == "testapp"
      assert first.branch == "test-branch"
      assert first.ip_suffix == 10

      # Second allocation with same project/branch returns existing (line 100)
      {:ok, second} = GenServer.call(pid, {:allocate, "testapp", "test-branch", 99})
      assert second.id == first.id
      assert second.ip_suffix == 10
    end

    test "allocate returns error when find_by_branch fails" do
      db_path = temp_db_path("sqlite_allocate_error_test")
      {:ok, pid} = Sqlite.start_link(db_path: db_path, name: nil)
      :ok = GenServer.call(pid, :init_schema)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db_path)

        try do
          :meck.unload(Exqlite.Sqlite3)
        catch
          _, _ -> :ok
        end
      end)

      # Mock prepare to return error (which will make do_find_by_branch fail)
      :meck.new(Exqlite.Sqlite3, [:passthrough, :unstick, :no_passthrough_cover])

      :meck.expect(Exqlite.Sqlite3, :prepare, fn _conn, _sql ->
        {:error, :mock_prepare_error}
      end)

      # This exercises the error -> error path (line 101)
      assert {:error, :mock_prepare_error} =
               GenServer.call(pid, {:allocate, "testapp", "test", 10})
    end
  end

  describe "config get/set" do
    test "get_config returns nil for unknown key" do
      db_path = temp_db_path("sqlite_config_get_unknown_test")
      {:ok, pid} = Sqlite.start_link(db_path: db_path, name: nil)
      :ok = GenServer.call(pid, :init_schema)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db_path)
      end)

      assert {:ok, nil} = GenServer.call(pid, {:get_config, "unknown_key"})
    end

    test "get_config returns default values after init_schema" do
      db_path = temp_db_path("sqlite_config_defaults_test")
      {:ok, pid} = Sqlite.start_link(db_path: db_path, name: nil)
      :ok = GenServer.call(pid, :init_schema)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db_path)
      end)

      assert {:ok, "10"} = GenServer.call(pid, {:get_config, "ip_range_start"})
      assert {:ok, "99"} = GenServer.call(pid, {:get_config, "ip_range_end"})
    end

    test "set_config creates new value" do
      db_path = temp_db_path("sqlite_config_set_test")
      {:ok, pid} = Sqlite.start_link(db_path: db_path, name: nil)
      :ok = GenServer.call(pid, :init_schema)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db_path)
      end)

      assert :ok = GenServer.call(pid, {:set_config, "custom_key", "custom_value"})
      assert {:ok, "custom_value"} = GenServer.call(pid, {:get_config, "custom_key"})
    end

    test "set_config updates existing value" do
      db_path = temp_db_path("sqlite_config_update_test")
      {:ok, pid} = Sqlite.start_link(db_path: db_path, name: nil)
      :ok = GenServer.call(pid, :init_schema)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db_path)
      end)

      # Default is 10
      assert {:ok, "10"} = GenServer.call(pid, {:get_config, "ip_range_start"})

      # Update it
      assert :ok = GenServer.call(pid, {:set_config, "ip_range_start", "20"})
      assert {:ok, "20"} = GenServer.call(pid, {:get_config, "ip_range_start"})
    end

    test "init_schema preserves existing config values" do
      db_path = temp_db_path("sqlite_config_preserve_test")
      {:ok, pid} = Sqlite.start_link(db_path: db_path, name: nil)
      :ok = GenServer.call(pid, :init_schema)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        File.rm(db_path)
      end)

      # Modify the default
      assert :ok = GenServer.call(pid, {:set_config, "ip_range_start", "50"})

      # Call init_schema again (should not overwrite)
      :ok = GenServer.call(pid, :init_schema)

      # Value should be preserved
      assert {:ok, "50"} = GenServer.call(pid, {:get_config, "ip_range_start"})
    end
  end
end
