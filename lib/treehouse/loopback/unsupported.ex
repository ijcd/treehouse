defmodule Treehouse.Loopback.Unsupported do
  @moduledoc """
  Fallback adapter for unsupported operating systems.
  """

  @behaviour Treehouse.Loopback

  @impl true
  def available_ips do
    []
  end

  @impl true
  def setup_commands(_range_start, _range_end) do
    ["# Unsupported platform"]
  end

  @impl true
  def setup_script(_range_start, _range_end) do
    "# Unsupported platform"
  end
end
