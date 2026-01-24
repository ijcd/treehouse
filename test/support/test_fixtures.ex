defmodule Treehouse.TestFixtures do
  @moduledoc """
  ExUnit setup fixtures for Treehouse tests.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  require ExUnit.Assertions

  @doc """
  Sets up Registry.Sqlite and Allocator with a temporary database.

  Returns `{:ok, allocator: pid, registry: pid, db_path: path}`.

  ## Options
    - `:name` - Allocator GenServer name (default: nil for anonymous)
    - `:prefix` - temp file prefix (default: "treehouse_test")
    - `:ip_range_start` - first IP suffix (default: 10)
    - `:ip_range_end` - last IP suffix (default: 99)
    - `:stale_threshold_days` - days before stale (default: 7)
  """
  def setup_allocator(opts) do
    prefix = Keyword.get(opts, :prefix, "treehouse_test")
    db_path = temp_db_path(prefix)

    # Start Registry.Sqlite GenServer with default name (required by client API)
    {:ok, registry_pid} = Treehouse.Registry.Sqlite.start_link(db_path: db_path)

    allocator_opts =
      opts
      |> Keyword.put_new(:name, nil)
      |> Keyword.put(:db_path, db_path)

    {:ok, allocator_pid} = Treehouse.Allocator.start_link(allocator_opts)

    on_exit(fn ->
      if Process.alive?(allocator_pid), do: GenServer.stop(allocator_pid)
      if Process.alive?(registry_pid), do: GenServer.stop(registry_pid)
      File.rm(db_path)
    end)

    {:ok, allocator: allocator_pid, registry: registry_pid, db_path: db_path}
  end

  @doc """
  Sets up an Allocator registered as Treehouse.Allocator (for facade tests).
  """
  def setup_named_allocator(opts) do
    opts
    |> Keyword.put(:name, Treehouse.Allocator)
    |> setup_allocator()
  end

  @doc """
  Sets up Registry.Sqlite GenServer with temp database.

  Returns `{:ok, registry: pid, db_path: path}`.
  """
  def setup_registry(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "treehouse_registry_test")
    db_path = temp_db_path(prefix)

    # Use default name since client API uses __MODULE__
    {:ok, registry_pid} = Treehouse.Registry.Sqlite.start_link(db_path: db_path)
    :ok = Treehouse.Registry.init_schema()

    on_exit(fn ->
      if Process.alive?(registry_pid), do: GenServer.stop(registry_pid)
      File.rm(db_path)
    end)

    {:ok, registry: registry_pid, db_path: db_path}
  end

  @doc """
  Generates a unique temp database path.
  """
  def temp_db_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{:rand.uniform(100_000)}.db")
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
