defmodule Treehouse.Registry.SqliteTest do
  use ExUnit.Case, async: false

  alias Treehouse.Registry
  alias Treehouse.Registry.Sqlite

  import Treehouse.TestHelpers

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
      # The GenServer.call raises an exit with the error details
      exit_reason = catch_exit(Registry.allocate("meck-test-branch", 50))

      # Verify we got the expected exit reason containing the :no_id error
      # Exit reason format: {{{:badmatch, {:error, :no_id}}, stacktrace}, {GenServer, :call, args}}
      assert {{{:badmatch, {:error, :no_id}}, _stacktrace}, {GenServer, :call, _args}} =
               exit_reason
    end
  end
end
