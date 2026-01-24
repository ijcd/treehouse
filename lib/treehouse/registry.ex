defmodule Treehouse.Registry do
  @moduledoc """
  Registry for IP allocations.

  Default implementation uses SQLite via exqlite.
  """

  @type conn :: term()
  @type allocation :: %{
          id: integer(),
          branch: String.t(),
          sanitized_name: String.t(),
          ip_suffix: integer(),
          allocated_at: String.t(),
          last_seen_at: String.t()
        }

  @callback open(path :: String.t()) :: {:ok, conn()} | {:error, term()}
  @callback init_schema(conn()) :: :ok | {:error, term()}
  @callback allocate(conn(), branch :: String.t(), ip_suffix :: integer()) ::
              {:ok, allocation()} | {:error, term()}
  @callback find_by_branch(conn(), branch :: String.t()) ::
              {:ok, allocation() | nil} | {:error, term()}
  @callback find_by_ip(conn(), ip_suffix :: integer()) ::
              {:ok, allocation() | nil} | {:error, term()}
  @callback list_allocations(conn()) :: {:ok, [allocation()]} | {:error, term()}
  @callback touch(conn(), id :: integer()) :: :ok | {:error, term()}
  @callback release(conn(), id :: integer()) :: :ok | {:error, term()}
  @callback stale_allocations(conn(), days :: integer()) ::
              {:ok, [allocation()]} | {:error, term()}
  @callback used_ips(conn()) :: {:ok, [integer()]} | {:error, term()}

  @doc """
  Returns the configured adapter module.
  """
  def adapter do
    Application.get_env(:treehouse, :registry_adapter, __MODULE__.Sqlite)
  end

  @doc """
  Opens a connection to the registry.
  """
  def open(path), do: adapter().open(path)

  @doc """
  Initializes the schema if not present.
  """
  def init_schema(conn), do: adapter().init_schema(conn)

  @doc """
  Allocates an IP suffix for a branch.
  Returns existing allocation if branch already has one.
  """
  def allocate(conn, branch, ip_suffix), do: adapter().allocate(conn, branch, ip_suffix)

  @doc """
  Finds allocation by branch name.
  """
  def find_by_branch(conn, branch), do: adapter().find_by_branch(conn, branch)

  @doc """
  Finds allocation by IP suffix.
  """
  def find_by_ip(conn, ip_suffix), do: adapter().find_by_ip(conn, ip_suffix)

  @doc """
  Lists all allocations.
  """
  def list_allocations(conn), do: adapter().list_allocations(conn)

  @doc """
  Updates last_seen_at timestamp.
  """
  def touch(conn, id), do: adapter().touch(conn, id)

  @doc """
  Deletes an allocation.
  """
  def release(conn, id), do: adapter().release(conn, id)

  @doc """
  Returns allocations not seen in the given number of days.
  """
  def stale_allocations(conn, days), do: adapter().stale_allocations(conn, days)

  @doc """
  Returns list of IP suffixes currently in use.
  """
  def used_ips(conn), do: adapter().used_ips(conn)
end
