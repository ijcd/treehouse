defmodule Mix.Tasks.Treehouse.Loopback do
  @shortdoc "Show commands to set up loopback aliases"
  @moduledoc """
  Prints shell commands to configure loopback aliases.

      $ mix treehouse.loopback

  The output can be piped to `sudo sh`:

      $ mix treehouse.loopback | sudo sh

  ## Options

    * `--start` - First IP suffix (default: 10)
    * `--end` - Last IP suffix (default: 99)
    * `--script` - Output as single script line instead of individual commands
    * `--pf` - Also output PF (packet filter) rules for hairpin NAT

  ## Hairpin NAT

  If your server needs to connect to itself via the loopback IP (e.g., making
  HTTP requests to itself), you need PF NAT rules:

      $ mix treehouse.loopback --pf > /tmp/loopback-setup.sh
      $ sudo sh /tmp/loopback-setup.sh

  """

  use Mix.Task

  alias Treehouse.Loopback

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [start: :integer, end: :integer, script: :boolean, pf: :boolean]
      )

    range_start = opts[:start] || 10
    range_end = opts[:end] || 99
    script_mode = opts[:script] || false
    include_pf = opts[:pf] || false

    if script_mode do
      IO.puts("#!/bin/sh")
      IO.puts("# Treehouse loopback setup")
      IO.puts("")
      IO.puts("# Create loopback aliases")
      IO.puts(Loopback.setup_script(range_start, range_end))
    else
      IO.puts("# Loopback aliases for 127.0.0.#{range_start} - 127.0.0.#{range_end}")
      IO.puts("# Run with: mix treehouse.loopback | sudo sh")
      IO.puts("")

      Loopback.setup_commands(range_start, range_end)
      |> Enum.each(&IO.puts/1)
    end

    if include_pf do
      IO.puts("")
      output_pf_rules(range_start, range_end)
    end
  end

  defp output_pf_rules(range_start, range_end) do
    case :os.type() do
      {:unix, :darwin} ->
        IO.puts("# PF NAT rules for hairpin routing (macOS)")
        IO.puts("# This allows servers to connect to themselves via loopback IPs")
        IO.puts("")
        IO.puts("cat > /tmp/loopback_nat.conf << 'EOF'")

        for i <- range_start..range_end do
          IO.puts("nat on lo0 from 127.0.0.#{i} to 127.0.0.#{i} -> 127.0.0.1")
        end

        IO.puts("EOF")
        IO.puts("")
        IO.puts("# Add anchor to pf.conf if not present")
        IO.puts("grep -q 'loopback_treehouse' /etc/pf.conf || {")
        IO.puts("  sudo cp /etc/pf.conf /etc/pf.conf.backup")
        IO.puts("  echo 'nat-anchor \"loopback_treehouse\"' | sudo tee -a /etc/pf.conf")

        IO.puts(
          "  echo 'load anchor \"loopback_treehouse\" from \"/etc/pf.anchors/loopback_treehouse\"' | sudo tee -a /etc/pf.conf"
        )

        IO.puts("}")
        IO.puts("")
        IO.puts("sudo cp /tmp/loopback_nat.conf /etc/pf.anchors/loopback_treehouse")
        IO.puts("sudo pfctl -f /etc/pf.conf")
        IO.puts("sudo pfctl -e 2>/dev/null || true")

      {:unix, _linux} ->
        IO.puts("# Linux typically doesn't need hairpin NAT for loopback")
        IO.puts("# If you do need it, use iptables DNAT rules")

      _ ->
        IO.puts("# PF rules not available on this platform")
    end
  end
end
