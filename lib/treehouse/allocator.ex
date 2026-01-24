defmodule Treehouse.Allocator do
  @moduledoc """
  GenServer that manages IP allocations.

  Implements lazy reclamation - only reclaims stale IPs when the pool is exhausted.
  """

  use GenServer
  require Logger

  alias Treehouse.Config
  alias Treehouse.Registry

  defstruct [:ip_range_start, :ip_range_end, :stale_threshold_days]

  # Client API

  @doc """
  Starts the allocator.

  ## Options
    - `:db_path` - path to SQLite database
    - `:name` - GenServer name (default: __MODULE__)
    - `:ip_range_start` - first IP suffix (default: from config or 10)
    - `:ip_range_end` - last IP suffix (default: from config or 99)
    - `:stale_threshold_days` - days before an allocation is stale (default: from config or 7)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets existing IP for branch or allocates a new one.
  """
  def get_or_allocate(server \\ __MODULE__, branch) do
    GenServer.call(server, {:get_or_allocate, branch})
  end

  @doc """
  Releases the IP allocation for a branch.
  """
  def release(server \\ __MODULE__, branch) do
    GenServer.call(server, {:release, branch})
  end

  @doc """
  Lists all current allocations.
  """
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc """
  Gets allocation info for a branch.
  """
  def info(server \\ __MODULE__, branch) do
    GenServer.call(server, {:info, branch})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    :ok = Registry.init_schema()

    state = %__MODULE__{
      ip_range_start: Config.ip_range_start(opts),
      ip_range_end: Config.ip_range_end(opts),
      stale_threshold_days: Config.stale_threshold_days(opts)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get_or_allocate, branch}, _from, state) do
    case Registry.find_by_branch(branch) do
      {:ok, nil} ->
        case allocate_new_ip(state, branch) do
          {:ok, alloc} ->
            ip = Config.format_ip(alloc.ip_suffix)
            Logger.info("[treehouse] Allocated #{ip} for branch '#{branch}'")
            touch_allocation(alloc.id)
            {:reply, {:ok, ip}, state}

          {:error, reason} ->
            Logger.error("[treehouse] Failed to allocate IP for '#{branch}': #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end

      {:ok, existing} ->
        ip = Config.format_ip(existing.ip_suffix)
        Logger.debug("[treehouse] Reusing #{ip} for branch '#{branch}'")
        touch_allocation(existing.id)
        {:reply, {:ok, ip}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:release, branch}, _from, state) do
    case Registry.find_by_branch(branch) do
      {:ok, nil} ->
        {:reply, :ok, state}

      {:ok, alloc} ->
        ip = Config.format_ip(alloc.ip_suffix)
        Logger.info("[treehouse] Released #{ip} for branch '#{branch}'")
        Registry.release(alloc.id)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    result = Registry.list_allocations()
    {:reply, result, state}
  end

  @impl true
  def handle_call({:info, branch}, _from, state) do
    result = Registry.find_by_branch(branch)
    {:reply, result, state}
  end

  # Private

  defp allocate_new_ip(state, branch) do
    with :pool_exhausted <- find_free_ip(state),
         :none_reclaimable <- reclaim_stale_ip(state) do
      {:error, :pool_exhausted}
    else
      {:ok, ip_suffix} -> Registry.allocate(branch, ip_suffix)
    end
  end

  defp find_free_ip(state) do
    {:ok, used} = Registry.used_ips()
    used_set = MapSet.new(used)

    free =
      Enum.find(state.ip_range_start..state.ip_range_end, fn ip ->
        not MapSet.member?(used_set, ip)
      end)

    case free do
      nil -> :pool_exhausted
      ip -> {:ok, ip}
    end
  end

  defp reclaim_stale_ip(state) do
    case Registry.stale_allocations(state.stale_threshold_days) do
      {:ok, [oldest | _]} ->
        ip = Config.format_ip(oldest.ip_suffix)
        Logger.info("[treehouse] Reclaiming stale IP #{ip} from branch '#{oldest.branch}'")
        Registry.release(oldest.id)
        {:ok, oldest.ip_suffix}

      {:ok, []} ->
        :none_reclaimable

      {:error, _} ->
        :none_reclaimable
    end
  end

  defp touch_allocation(id) do
    case Registry.touch(id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[treehouse] Failed to update last_seen: #{inspect(reason)}")
    end
  end
end
