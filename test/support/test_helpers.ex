defmodule Treehouse.TestHelpers do
  @moduledoc """
  Shared test utilities for Treehouse tests.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  require ExUnit.Assertions

  @doc """
  Sets up an Allocator with a temporary database.

  Returns `{:ok, allocator: pid, db_path: path}`.

  ## Options
    - `:name` - GenServer name (default: nil for anonymous)
    - `:prefix` - temp file prefix (default: "treehouse_test")
    - `:ip_range_start` - first IP suffix (default: 10)
    - `:ip_range_end` - last IP suffix (default: 99)
    - `:stale_threshold_days` - days before stale (default: 7)
  """
  def setup_allocator(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "treehouse_test")
    db_path = temp_db_path(prefix)

    allocator_opts =
      opts
      |> Keyword.put_new(:name, nil)
      |> Keyword.put(:db_path, db_path)

    {:ok, pid} = Treehouse.Allocator.start_link(allocator_opts)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(db_path)
    end)

    {:ok, allocator: pid, db_path: db_path}
  end

  @doc """
  Sets up an Allocator registered as Treehouse.Allocator (for facade tests).
  """
  def setup_named_allocator(opts \\ []) do
    opts
    |> Keyword.put(:name, Treehouse.Allocator)
    |> setup_allocator()
  end

  @doc """
  Sets up a raw Registry connection with temp database.

  Returns `{:ok, conn: conn, db_path: path}`.
  """
  def setup_registry(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "treehouse_registry_test")
    db_path = temp_db_path(prefix)

    {:ok, conn} = Treehouse.Registry.open(db_path)
    :ok = Treehouse.Registry.init_schema(conn)

    on_exit(fn ->
      # Silently close - may already be closed by test
      try do
        Exqlite.Sqlite3.close(conn)
      catch
        _, _ -> :ok
      end

      File.rm(db_path)
    end)

    {:ok, conn: conn, db_path: db_path}
  end

  @doc """
  Generates a unique temp database path.
  """
  def temp_db_path(prefix \\ "treehouse") do
    Path.join(System.tmp_dir!(), "#{prefix}_#{:rand.uniform(100_000)}.db")
  end

  @doc """
  Asserts that a function returns an error when given a closed connection.

  ## Example

      assert_error_when_closed(conn, Treehouse.Registry, :find_by_branch, ["main"])
  """
  def assert_error_when_closed(conn, module, function, args) do
    Exqlite.Sqlite3.close(conn)
    result = apply(module, function, [conn | args])
    ExUnit.Assertions.assert({:error, _} = result)
    result
  end

  @doc """
  Cleans up application env settings for adapter overrides.
  """
  def cleanup_adapter_env do
    Application.delete_env(:treehouse, :registry_adapter)
    Application.delete_env(:treehouse, :branch_adapter)
    Application.delete_env(:treehouse, :mdns_adapter)
    Application.delete_env(:treehouse, :system_adapter)
  end
end
