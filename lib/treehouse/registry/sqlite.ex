defmodule Treehouse.Registry.Sqlite do
  @moduledoc """
  SQLite-backed registry implementation.

  This is a GenServer that manages its own database connection internally.
  """

  use GenServer

  @behaviour Treehouse.Registry

  alias Treehouse.Branch
  alias Treehouse.Config

  # Client API

  @impl Treehouse.Registry
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Treehouse.Registry
  def init_schema do
    GenServer.call(__MODULE__, :init_schema)
  end

  @impl Treehouse.Registry
  def allocate(branch, ip_suffix) do
    GenServer.call(__MODULE__, {:allocate, branch, ip_suffix})
  end

  @impl Treehouse.Registry
  def find_by_branch(branch) do
    GenServer.call(__MODULE__, {:find_by_branch, branch})
  end

  @impl Treehouse.Registry
  def find_by_ip(ip_suffix) do
    GenServer.call(__MODULE__, {:find_by_ip, ip_suffix})
  end

  @impl Treehouse.Registry
  def list_allocations do
    GenServer.call(__MODULE__, :list_allocations)
  end

  @impl Treehouse.Registry
  def touch(id) do
    GenServer.call(__MODULE__, {:touch, id})
  end

  @impl Treehouse.Registry
  def release(id) do
    GenServer.call(__MODULE__, {:release, id})
  end

  @impl Treehouse.Registry
  def stale_allocations(days) do
    GenServer.call(__MODULE__, {:stale_allocations, days})
  end

  @impl Treehouse.Registry
  def used_ips do
    GenServer.call(__MODULE__, :used_ips)
  end

  # Server callbacks

  @impl GenServer
  def init(opts) do
    path = Config.registry_path(opts)
    full_path = Path.expand(path)
    dir_name = Path.dirname(full_path)
    File.mkdir_p!(dir_name)

    case Exqlite.Sqlite3.open(full_path) do
      {:ok, conn} ->
        # WAL mode for concurrent readers/writers across VMs
        :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
        # 5 second timeout when DB is locked by another VM
        :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
        {:ok, %{conn: conn}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:init_schema, _from, %{conn: conn} = state) do
    result = do_init_schema(conn)
    {:reply, result, state}
  end

  def handle_call({:allocate, branch, ip_suffix}, _from, %{conn: conn} = state) do
    result =
      case do_find_by_branch(conn, branch) do
        {:ok, nil} -> do_insert_allocation(conn, branch, ip_suffix)
        {:ok, existing} -> {:ok, existing}
        error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:find_by_branch, branch}, _from, %{conn: conn} = state) do
    result = do_find_by_branch(conn, branch)
    {:reply, result, state}
  end

  def handle_call({:find_by_ip, ip_suffix}, _from, %{conn: conn} = state) do
    result = do_find_by_ip(conn, ip_suffix)
    {:reply, result, state}
  end

  def handle_call(:list_allocations, _from, %{conn: conn} = state) do
    result = do_list_allocations(conn)
    {:reply, result, state}
  end

  def handle_call({:touch, id}, _from, %{conn: conn} = state) do
    result = do_touch(conn, id)
    {:reply, result, state}
  end

  def handle_call({:release, id}, _from, %{conn: conn} = state) do
    result = do_release(conn, id)
    {:reply, result, state}
  end

  def handle_call({:stale_allocations, days}, _from, %{conn: conn} = state) do
    result = do_stale_allocations(conn, days)
    {:reply, result, state}
  end

  def handle_call(:used_ips, _from, %{conn: conn} = state) do
    result = do_used_ips(conn)
    {:reply, result, state}
  end

  # Private implementation functions

  defp do_init_schema(conn) do
    sql = """
    CREATE TABLE IF NOT EXISTS allocations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      branch TEXT NOT NULL UNIQUE,
      sanitized_name TEXT NOT NULL,
      ip_suffix INTEGER NOT NULL UNIQUE,
      allocated_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_allocations_branch ON allocations(branch);
    CREATE INDEX IF NOT EXISTS idx_allocations_ip ON allocations(ip_suffix);
    """

    case Exqlite.Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp do_insert_allocation(conn, branch, ip_suffix) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    sanitized = Branch.sanitize(branch)

    sql = """
    INSERT INTO allocations (branch, sanitized_name, ip_suffix, allocated_at, last_seen_at)
    VALUES (?1, ?2, ?3, ?4, ?5)
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [branch, sanitized, ip_suffix, now, now]),
         :done <- Exqlite.Sqlite3.step(conn, stmt),
         :ok <- Exqlite.Sqlite3.release(conn, stmt) do
      {:ok, id} = last_insert_id(conn)

      {:ok,
       %{
         id: id,
         branch: branch,
         sanitized_name: sanitized,
         ip_suffix: ip_suffix,
         allocated_at: now,
         last_seen_at: now
       }}
    end
  end

  defp last_insert_id(conn) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT last_insert_rowid()")

    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [id]} ->
        Exqlite.Sqlite3.release(conn, stmt)
        {:ok, id}

      _ ->
        Exqlite.Sqlite3.release(conn, stmt)
        {:error, :no_id}
    end
  end

  defp do_find_by_branch(conn, branch) do
    sql =
      "SELECT id, branch, sanitized_name, ip_suffix, allocated_at, last_seen_at FROM allocations WHERE branch = ?1"

    query_one(conn, sql, [branch])
  end

  defp do_find_by_ip(conn, ip_suffix) do
    sql =
      "SELECT id, branch, sanitized_name, ip_suffix, allocated_at, last_seen_at FROM allocations WHERE ip_suffix = ?1"

    query_one(conn, sql, [ip_suffix])
  end

  defp do_list_allocations(conn) do
    sql =
      "SELECT id, branch, sanitized_name, ip_suffix, allocated_at, last_seen_at FROM allocations ORDER BY last_seen_at DESC"

    query_all(conn, sql, [])
  end

  defp do_touch(conn, id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    sql = "UPDATE allocations SET last_seen_at = ?1 WHERE id = ?2"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [now, id]),
         :done <- Exqlite.Sqlite3.step(conn, stmt) do
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp do_release(conn, id) do
    sql = "DELETE FROM allocations WHERE id = ?1"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [id]),
         :done <- Exqlite.Sqlite3.step(conn, stmt) do
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp do_stale_allocations(conn, days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.to_iso8601()

    sql =
      "SELECT id, branch, sanitized_name, ip_suffix, allocated_at, last_seen_at FROM allocations WHERE last_seen_at < ?1 ORDER BY last_seen_at ASC"

    query_all(conn, sql, [cutoff])
  end

  defp do_used_ips(conn) do
    sql = "SELECT ip_suffix FROM allocations"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql) do
      ips = fetch_all_rows(conn, stmt, []) |> Enum.map(fn [ip] -> ip end)
      Exqlite.Sqlite3.release(conn, stmt)
      {:ok, ips}
    end
  end

  # Query helpers

  defp query_one(conn, sql, params) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, params) do
      result =
        case Exqlite.Sqlite3.step(conn, stmt) do
          {:row, row} -> {:ok, row_to_map(row)}
          :done -> {:ok, nil}
        end

      Exqlite.Sqlite3.release(conn, stmt)
      result
    end
  end

  defp query_all(conn, sql, params) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, params) do
      rows = fetch_all_rows(conn, stmt, [])
      Exqlite.Sqlite3.release(conn, stmt)
      {:ok, Enum.map(rows, &row_to_map/1)}
    end
  end

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp row_to_map([id, branch, sanitized_name, ip_suffix, allocated_at, last_seen_at]) do
    %{
      id: id,
      branch: branch,
      sanitized_name: sanitized_name,
      ip_suffix: ip_suffix,
      allocated_at: allocated_at,
      last_seen_at: last_seen_at
    }
  end
end
