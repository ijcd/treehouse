defmodule Treehouse.Registry do
  @moduledoc """
  Registry for IP allocations.

  Adapters are GenServers that manage their own connections internally.
  Default implementation uses SQLite via exqlite.
  """

  @type allocation :: %{
          id: integer(),
          branch: String.t(),
          sanitized_name: String.t(),
          ip_suffix: integer(),
          allocated_at: String.t(),
          last_seen_at: String.t()
        }

  @doc "Starts the registry adapter"
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc "Initializes the schema if not present"
  @callback init_schema() :: :ok | {:error, term()}

  @doc "Allocates an IP suffix for a branch"
  @callback allocate(branch :: String.t(), ip_suffix :: integer()) ::
              {:ok, allocation()} | {:error, term()}

  @doc "Finds allocation by branch name"
  @callback find_by_branch(branch :: String.t()) ::
              {:ok, allocation() | nil} | {:error, term()}

  @doc "Finds allocation by IP suffix"
  @callback find_by_ip(ip_suffix :: integer()) ::
              {:ok, allocation() | nil} | {:error, term()}

  @doc "Lists all allocations"
  @callback list_allocations() :: {:ok, [allocation()]} | {:error, term()}

  @doc "Updates last_seen_at timestamp"
  @callback touch(id :: integer()) :: :ok | {:error, term()}

  @doc "Deletes an allocation"
  @callback release(id :: integer()) :: :ok | {:error, term()}

  @doc "Returns allocations not seen in the given number of days"
  @callback stale_allocations(days :: integer()) ::
              {:ok, [allocation()]} | {:error, term()}

  @doc "Returns list of IP suffixes currently in use"
  @callback used_ips() :: {:ok, [integer()]} | {:error, term()}

  @doc """
  Returns the configured adapter module.
  """
  def adapter do
    Application.get_env(:treehouse, :registry_adapter, __MODULE__.Sqlite)
  end

  # Delegated functions - no conn parameter needed

  @doc "Initializes the schema if not present."
  def init_schema, do: adapter().init_schema()

  @doc "Allocates an IP suffix for a branch. Returns existing allocation if branch already has one."
  def allocate(branch, ip_suffix), do: adapter().allocate(branch, ip_suffix)

  @doc "Finds allocation by branch name."
  def find_by_branch(branch), do: adapter().find_by_branch(branch)

  @doc "Finds allocation by IP suffix."
  def find_by_ip(ip_suffix), do: adapter().find_by_ip(ip_suffix)

  @doc "Lists all allocations."
  def list_allocations, do: adapter().list_allocations()

  @doc "Updates last_seen_at timestamp."
  def touch(id), do: adapter().touch(id)

  @doc "Deletes an allocation."
  def release(id), do: adapter().release(id)

  @doc "Returns allocations not seen in the given number of days."
  def stale_allocations(days), do: adapter().stale_allocations(days)

  @doc "Returns list of IP suffixes currently in use."
  def used_ips, do: adapter().used_ips()
end
