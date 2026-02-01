defmodule Treehouse.Loopback.Darwin do
  @moduledoc """
  macOS loopback adapter. Discovers aliases via `ifconfig lo0`.
  """

  @behaviour Treehouse.Loopback

  require Logger

  @impl true
  def available_ips do
    case System.cmd("ifconfig", ["lo0"], stderr_to_stdout: true) do
      {output, 0} ->
        parse_ifconfig(output)

      {error, _} ->
        Logger.warning("[treehouse] Failed to query loopback interfaces: #{error}")
        []
    end
  end

  @impl true
  def setup_commands(range_start, range_end) do
    for i <- range_start..range_end do
      "sudo ifconfig lo0 alias 127.0.0.#{i} up"
    end
  end

  @impl true
  def setup_script(range_start, range_end) do
    "for i in $(seq #{range_start} #{range_end}); do sudo ifconfig lo0 alias 127.0.0.$i up; done"
  end

  # Parse macOS ifconfig output like:
  #   inet 127.0.0.1 netmask 0xff000000
  #   inet 127.0.0.10 netmask 0xff000000
  defp parse_ifconfig(output) do
    ~r/inet 127\.0\.0\.(\d+)/
    |> Regex.scan(output)
    |> Enum.map(fn [_, suffix] -> String.to_integer(suffix) end)
    |> Enum.filter(&(&1 > 1))
    |> Enum.sort()
  end
end
