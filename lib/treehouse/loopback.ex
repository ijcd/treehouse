defmodule Treehouse.Loopback do
  @moduledoc """
  Discovers available loopback IP aliases on the system.

  Instead of configuring an IP range and hoping the user set up matching
  aliases, we discover what's actually available and use that as the pool.

  Uses OS-specific adapters:
  - `Treehouse.Loopback.Darwin` for macOS (parses `ifconfig lo0`)
  - `Treehouse.Loopback.Linux` for Linux (parses `ip addr show lo`)

  The adapter is auto-detected based on OS, or can be overridden via config:

      config :treehouse, :loopback_adapter, MyCustomAdapter
  """

  @doc """
  Returns list of available loopback IPs (127.0.0.x where x > 1).

  Returns IPs as integers (the suffix, e.g., 10 for 127.0.0.10).
  """
  @callback available_ips() :: [integer()]

  @doc """
  Returns shell commands to create loopback aliases for a given range.
  """
  @callback setup_commands(range_start :: integer(), range_end :: integer()) :: [String.t()]

  @doc """
  Returns a single shell command that sets up all aliases.
  """
  @callback setup_script(range_start :: integer(), range_end :: integer()) :: String.t()

  # Delegate to adapter

  @spec available_ips() :: [integer()]
  def available_ips do
    adapter().available_ips()
  end

  @spec available_count() :: non_neg_integer()
  def available_count do
    length(available_ips())
  end

  @spec available?(integer()) :: boolean()
  def available?(ip_suffix) when is_integer(ip_suffix) do
    ip_suffix in available_ips()
  end

  @spec setup_commands(integer(), integer()) :: [String.t()]
  def setup_commands(range_start \\ 10, range_end \\ 99) do
    adapter().setup_commands(range_start, range_end)
  end

  @spec setup_script(integer(), integer()) :: String.t()
  def setup_script(range_start \\ 10, range_end \\ 99) do
    adapter().setup_script(range_start, range_end)
  end

  # Adapter resolution

  defp adapter do
    Application.get_env(:treehouse, :loopback_adapter) || default_adapter()
  end

  defp default_adapter do
    case :os.type() do
      {:unix, :darwin} -> Treehouse.Loopback.Darwin
      {:unix, _linux} -> Treehouse.Loopback.Linux
      _ -> Treehouse.Loopback.Unsupported
    end
  end
end
