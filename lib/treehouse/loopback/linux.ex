defmodule Treehouse.Loopback.Linux do
  @moduledoc """
  Linux loopback adapter. Discovers aliases via `ip addr show lo`.
  """

  @behaviour Treehouse.Loopback

  require Logger

  @impl true
  def available_ips do
    case System.cmd("ip", ["addr", "show", "lo"], stderr_to_stdout: true) do
      {output, 0} ->
        parse_ip_addr(output)

      {error, _} ->
        Logger.warning("[treehouse] Failed to query loopback interfaces: #{error}")
        []
    end
  end

  @impl true
  def setup_commands(range_start, range_end) do
    for i <- range_start..range_end do
      "sudo ip addr add 127.0.0.#{i}/8 dev lo"
    end
  end

  @impl true
  def setup_script(range_start, range_end) do
    "for i in $(seq #{range_start} #{range_end}); do sudo ip addr add 127.0.0.$i/8 dev lo 2>/dev/null; done"
  end

  # Parse Linux ip addr output like:
  #   inet 127.0.0.1/8 scope host lo
  #   inet 127.0.0.10/8 scope host secondary lo
  defp parse_ip_addr(output) do
    ~r/inet 127\.0\.0\.(\d+)/
    |> Regex.scan(output)
    |> Enum.map(fn [_, suffix] -> String.to_integer(suffix) end)
    |> Enum.filter(&(&1 > 1))
    |> Enum.sort()
  end
end
