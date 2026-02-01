defmodule Mix.Tasks.Treehouse.Config do
  @shortdoc "View or set Treehouse configuration"
  @moduledoc """
  Manages Treehouse configuration stored in the registry database.

      $ mix treehouse.config

  Shows current configuration values.

  ## Options

    * `--start N` - Set IP range start (e.g., --start 10)
    * `--end N` - Set IP range end (e.g., --end 99)

  ## Examples

      # Show current config
      $ mix treehouse.config

      # Set IP range to 20-80
      $ mix treehouse.config --start 20 --end 80

      # Set just the start
      $ mix treehouse.config --start 30

  """

  use Mix.Task

  alias Treehouse.Registry

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [start: :integer, end: :integer]
      )

    # Handle setting values
    if opts[:start] do
      set_config("ip_range_start", opts[:start])
    end

    if opts[:end] do
      set_config("ip_range_end", opts[:end])
    end

    # Always show current config
    show_config()
  end

  defp set_config(key, value) do
    case Registry.set_config(key, to_string(value)) do
      :ok ->
        IO.puts("Set #{key} = #{value}")

      {:error, reason} ->
        Mix.shell().error("Error setting #{key}: #{inspect(reason)}")
    end
  end

  defp show_config do
    IO.puts("")
    IO.puts("=== Treehouse Configuration ===")
    IO.puts("")

    case {Registry.get_config("ip_range_start"), Registry.get_config("ip_range_end")} do
      {{:ok, start_val}, {:ok, end_val}} ->
        start_ip = start_val || "10"
        end_ip = end_val || "99"
        IO.puts("IP Range: 127.0.0.#{start_ip} - 127.0.0.#{end_ip}")

      {{:error, reason}, _} ->
        Mix.shell().error("Error reading config: #{inspect(reason)}")

      {_, {:error, reason}} ->
        Mix.shell().error("Error reading config: #{inspect(reason)}")
    end

    IO.puts("")
  end
end
