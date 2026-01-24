defmodule Treehouse.Registry.Sqlite do
  @moduledoc """
  SQLite-backed registry implementation.
  """

  @behaviour Treehouse.Registry

  alias Treehouse.Branch

  @impl true
  def open(path) do
    full_path = Path.expand(path)
    dir_name = Path.dirname(full_path)
    File.mkdir_p!(dir_name)

    with {:ok, conn} <- Exqlite.Sqlite3.open(full_path) do
      # WAL mode for concurrent readers/writers across VMs
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
      # 5 second timeout when DB is locked by another VM
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
      {:ok, conn}
    end
  end

  @impl true
  def init_schema(conn) do
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

  @impl true
  def allocate(conn, branch, ip_suffix) do
    case find_by_branch(conn, branch) do
      {:ok, nil} -> insert_allocation(conn, branch, ip_suffix)
      {:ok, existing} -> {:ok, existing}
      error -> error
    end
  end

  defp insert_allocation(conn, branch, ip_suffix) do
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

  @impl true
  def find_by_branch(conn, branch) do
    sql =
      "SELECT id, branch, sanitized_name, ip_suffix, allocated_at, last_seen_at FROM allocations WHERE branch = ?1"

    query_one(conn, sql, [branch])
  end

  @impl true
  def find_by_ip(conn, ip_suffix) do
    sql =
      "SELECT id, branch, sanitized_name, ip_suffix, allocated_at, last_seen_at FROM allocations WHERE ip_suffix = ?1"

    query_one(conn, sql, [ip_suffix])
  end

  @impl true
  def list_allocations(conn) do
    sql =
      "SELECT id, branch, sanitized_name, ip_suffix, allocated_at, last_seen_at FROM allocations ORDER BY last_seen_at DESC"

    query_all(conn, sql, [])
  end

  @impl true
  def touch(conn, id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    sql = "UPDATE allocations SET last_seen_at = ?1 WHERE id = ?2"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [now, id]),
         :done <- Exqlite.Sqlite3.step(conn, stmt) do
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  @impl true
  def release(conn, id) do
    sql = "DELETE FROM allocations WHERE id = ?1"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [id]),
         :done <- Exqlite.Sqlite3.step(conn, stmt) do
      Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  @impl true
  def stale_allocations(conn, days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.to_iso8601()

    sql =
      "SELECT id, branch, sanitized_name, ip_suffix, allocated_at, last_seen_at FROM allocations WHERE last_seen_at < ?1 ORDER BY last_seen_at ASC"

    query_all(conn, sql, [cutoff])
  end

  @impl true
  def used_ips(conn) do
    sql = "SELECT ip_suffix FROM allocations"

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql) do
      ips = fetch_all_rows(conn, stmt, []) |> Enum.map(fn [ip] -> ip end)
      Exqlite.Sqlite3.release(conn, stmt)
      {:ok, ips}
    end
  end

  # Helpers

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
