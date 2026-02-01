defmodule Treehouse.Allocator do
  @moduledoc """
  GenServer that manages IP allocations.

  Discovers available loopback IPs from the system and allocates from that pool.
  Implements lazy reclamation - only reclaims stale IPs when the pool is exhausted.
  """

  use GenServer
  require Logger

  alias Treehouse.Config
  alias Treehouse.Loopback
  alias Treehouse.Registry

  defstruct [:available_ips, :stale_threshold_days]

  # Client API

  @doc """
  Starts the allocator.

  ## Options
    - `:db_path` - path to SQLite database
    - `:name` - GenServer name (default: __MODULE__)
    - `:ip_range_start` - first IP suffix for pool (default: discover from system)
    - `:ip_range_end` - last IP suffix for pool (default: discover from system)
    - `:stale_threshold_days` - days before an allocation is stale (default: from config or 7)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets existing IP for project/branch or allocates a new one.
  """
  def get_or_allocate(server \\ __MODULE__, project, branch) do
    GenServer.call(server, {:get_or_allocate, project, branch})
  end

  @doc """
  Releases the IP allocation for a project/branch.
  """
  def release(server \\ __MODULE__, project, branch) do
    GenServer.call(server, {:release, project, branch})
  end

  @doc """
  Lists all current allocations.
  """
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc """
  Gets allocation info for a project/branch.
  """
  def info(server \\ __MODULE__, project, branch) do
    GenServer.call(server, {:info, project, branch})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    :ok = Registry.init_schema()

    available_ips = discover_pool(opts)
    stale_threshold_days = Config.stale_threshold_days(opts)

    log_pool_status(available_ips)

    state = %__MODULE__{
      available_ips: available_ips,
      stale_threshold_days: stale_threshold_days
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get_or_allocate, project, branch}, _from, state) do
    case Registry.find_by_branch(project, branch) do
      {:ok, nil} ->
        case allocate_new_ip(state, project, branch) do
          {:ok, alloc} ->
            ip = Config.format_ip(alloc.ip_suffix)
            Logger.info("[treehouse] Allocated #{ip} for #{project}:#{branch}")
            touch_allocation(alloc.id)
            {:reply, {:ok, ip}, state}

          {:error, :no_loopback_aliases} = error ->
            Logger.error("[treehouse] No loopback aliases configured! Run: mix treehouse.doctor")
            {:reply, error, state}

          {:error, :pool_exhausted} = error ->
            Logger.error(
              "[treehouse] IP pool exhausted for #{project}:#{branch}. Run: mix treehouse.doctor"
            )

            {:reply, error, state}

          {:error, reason} ->
            Logger.error(
              "[treehouse] Failed to allocate IP for #{project}:#{branch}: #{inspect(reason)}"
            )

            {:reply, {:error, reason}, state}
        end

      {:ok, existing} ->
        ip = Config.format_ip(existing.ip_suffix)
        Logger.debug("[treehouse] Reusing #{ip} for #{project}:#{branch}")
        touch_allocation(existing.id)
        {:reply, {:ok, ip}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:release, project, branch}, _from, state) do
    case Registry.find_by_branch(project, branch) do
      {:ok, nil} ->
        {:reply, :ok, state}

      {:ok, alloc} ->
        ip = Config.format_ip(alloc.ip_suffix)
        Logger.info("[treehouse] Released #{ip} for #{project}:#{branch}")
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
  def handle_call({:info, project, branch}, _from, state) do
    result = Registry.find_by_branch(project, branch)
    {:reply, result, state}
  end

  # Private

  defp discover_pool(opts) do
    # Allow explicit range override (for testing), otherwise discover from system
    case {opts[:ip_range_start], opts[:ip_range_end]} do
      {nil, nil} ->
        # Get configured range from DB (defaults set in init_schema)
        {range_start, range_end} = get_configured_range()
        # Discover actual loopback aliases from system
        available = Loopback.available_ips()
        # Filter to intersection: available IPs within configured range
        Enum.filter(available, fn ip -> ip >= range_start and ip <= range_end end)

      {start_ip, end_ip} ->
        # Explicit range provided (e.g., for testing)
        range_start = start_ip || Config.ip_range_start(opts)
        range_end = end_ip || Config.ip_range_end(opts)
        Enum.to_list(range_start..range_end)
    end
  end

  defp get_configured_range do
    # Read from DB, fall back to defaults if somehow missing
    range_start =
      case Registry.get_config("ip_range_start") do
        {:ok, val} when is_binary(val) -> String.to_integer(val)
        _ -> 10
      end

    range_end =
      case Registry.get_config("ip_range_end") do
        {:ok, val} when is_binary(val) -> String.to_integer(val)
        _ -> 99
      end

    {range_start, range_end}
  end

  defp log_pool_status(available_ips) do
    count = length(available_ips)

    cond do
      count == 0 ->
        Logger.warning("[treehouse] No loopback aliases found! Run: mix treehouse.doctor")

      count < 10 ->
        ips_str = available_ips |> Enum.map(&"127.0.0.#{&1}") |> Enum.join(", ")
        Logger.info("[treehouse] Available IPs (#{count}): #{ips_str}")

      true ->
        first_3 = available_ips |> Enum.take(3) |> Enum.map(&"127.0.0.#{&1}") |> Enum.join(", ")
        last = List.last(available_ips)
        Logger.info("[treehouse] Available IPs: #{first_3} ... 127.0.0.#{last} (#{count} total)")
    end
  end

  defp allocate_new_ip(state, project, branch) do
    if state.available_ips == [] do
      {:error, :no_loopback_aliases}
    else
      with :pool_exhausted <- find_free_ip(state),
           :none_reclaimable <- reclaim_stale_ip(state) do
        {:error, :pool_exhausted}
      else
        {:ok, ip_suffix} -> Registry.allocate(project, branch, ip_suffix)
      end
    end
  end

  defp find_free_ip(state) do
    {:ok, used} = Registry.used_ips()
    used_set = MapSet.new(used)

    free =
      Enum.find(state.available_ips, fn ip ->
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
        # Only reclaim if the IP is in our available pool
        if oldest.ip_suffix in state.available_ips do
          ip = Config.format_ip(oldest.ip_suffix)

          Logger.info(
            "[treehouse] Reclaiming stale IP #{ip} from #{oldest.project}:#{oldest.branch}"
          )

          Registry.release(oldest.id)
          {:ok, oldest.ip_suffix}
        else
          :none_reclaimable
        end

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
