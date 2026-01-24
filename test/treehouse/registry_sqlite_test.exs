defmodule Treehouse.Registry.SqliteTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Treehouse.Registry
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

  describe "init/1 error path" do
    test "returns stop when database open fails" do
      # Use a temp path so mkdir_p succeeds
      db_path = temp_db_path("sqlite_open_fail_test")

      # Meck the Exqlite.Sqlite3.open to return error
      :meck.new(Exqlite.Sqlite3, [:passthrough, :unstick])

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
      :meck.new(Exqlite.Sqlite3, [:passthrough, :unstick])

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
      {:ok, first} = GenServer.call(pid, {:allocate, "test-branch", 10})
      assert first.branch == "test-branch"
      assert first.ip_suffix == 10

      # Second allocation with same branch returns existing (line 100)
      {:ok, second} = GenServer.call(pid, {:allocate, "test-branch", 99})
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
      :meck.new(Exqlite.Sqlite3, [:passthrough, :unstick])

      :meck.expect(Exqlite.Sqlite3, :prepare, fn _conn, _sql ->
        {:error, :mock_prepare_error}
      end)

      # This exercises the error -> error path (line 101)
      assert {:error, :mock_prepare_error} = GenServer.call(pid, {:allocate, "test", 10})
    end
  end

  describe "last_insert_id edge case" do
    setup do
      setup_registry(prefix: "sqlite_edge_test")
    end

    test "allocate returns error when last_insert_rowid returns no rows" do
      # Use meck to mock step to return :done for last_insert_rowid query only
      # This exercises the defensive error path that SQLite never actually hits
      :meck.new(Exqlite.Sqlite3, [:passthrough, :unstick])

      # Use process dictionary to track INSERT completion
      Process.put(:insert_done, false)

      :meck.expect(Exqlite.Sqlite3, :step, fn conn_ref, stmt ->
        result = :meck.passthrough([conn_ref, stmt])

        case result do
          :done ->
            # INSERT completed, next step call will be last_insert_rowid
            Process.put(:insert_done, true)
            :done

          {:row, [_id]} ->
            # Check if INSERT was done (meaning this is last_insert_rowid)
            if Process.get(:insert_done, false) do
              # Sabotage the last_insert_rowid query!
              :done
            else
              result
            end

          other ->
            other
        end
      end)

      on_exit(fn ->
        try do
          :meck.unload(Exqlite.Sqlite3)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

      # Trap exits so the GenServer crash doesn't kill the test
      Process.flag(:trap_exit, true)

      # The error happens in the GenServer, which crashes.
      # Capture the log to avoid noisy output
      {exit_reason, log} =
        with_log(fn ->
          catch_exit(Registry.allocate("meck-test-branch", 50))
        end)

      # Verify we got the expected exit reason containing the :no_id error
      # Exit reason format: {{{:badmatch, {:error, :no_id}}, stacktrace}, {GenServer, :call, args}}
      assert {{{:badmatch, {:error, :no_id}}, _stacktrace}, {GenServer, :call, _args}} =
               exit_reason

      assert log =~ "GenServer Treehouse.Registry.Sqlite terminating"
    end
  end
end
