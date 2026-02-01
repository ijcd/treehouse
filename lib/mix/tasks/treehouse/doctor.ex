defmodule Mix.Tasks.Treehouse.Doctor do
  @shortdoc "Check Treehouse setup and diagnose issues"
  @moduledoc """
  Diagnoses Treehouse setup and shows helpful information.

      $ mix treehouse.doctor

  Shows:
  - Available loopback aliases
  - Current allocations
  - Setup commands if needed

  ## Options

    * `--ping` - Ping a sample of loopback IPs to verify connectivity
    * `--ping-all` - Ping all available loopback IPs (slower)

  """

  use Mix.Task

  alias Treehouse.Config
  alias Treehouse.Loopback
  alias Treehouse.Registry

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [ping: :boolean, ping_all: :boolean]
      )

    Mix.Task.run("app.start", ["--no-start"])
    Application.ensure_all_started(:treehouse)

    IO.puts("")
    available = check_loopback_aliases()
    IO.puts("")

    if opts[:ping] || opts[:ping_all] do
      check_connectivity(available, opts[:ping_all])
      IO.puts("")
    end

    check_registry()
    IO.puts("")
    show_allocations()
    IO.puts("")
  end

  defp check_loopback_aliases do
    IO.puts("=== Loopback Aliases ===")

    available = Loopback.available_ips()
    count = length(available)

    if count == 0 do
      IO.puts("Status: NOT CONFIGURED")
      IO.puts("")
      IO.puts("No loopback aliases found. Treehouse needs these to work.")
      IO.puts("")
      IO.puts("Quick setup (temporary, until reboot):")
      IO.puts("  #{Loopback.setup_script()}")
      IO.puts("")
      IO.puts("Or run each command:")

      Loopback.setup_commands()
      |> Enum.take(3)
      |> Enum.each(&IO.puts("  #{&1}"))

      IO.puts("  ... (run `mix treehouse.loopback` for full list)")
    else
      IO.puts("Status: OK (#{count} IPs available)")

      if count <= 10 do
        ips_str = available |> Enum.map(&"127.0.0.#{&1}") |> Enum.join(", ")
        IO.puts("IPs: #{ips_str}")
      else
        first = List.first(available)
        last = List.last(available)
        IO.puts("Range: 127.0.0.#{first} - 127.0.0.#{last}")
      end
    end

    available
  end

  defp check_connectivity([], _all) do
    IO.puts("=== Connectivity Check ===")
    IO.puts("Status: SKIPPED (no loopback aliases to check)")
  end

  defp check_connectivity(available, ping_all) do
    IO.puts("=== Connectivity Check ===")

    # Sample IPs: first, middle, last (or all if requested)
    ips_to_check =
      if ping_all do
        available
      else
        sample_ips(available)
      end

    total = length(ips_to_check)
    IO.puts("Pinging #{total} IP#{if total == 1, do: "", else: "s"}...")
    IO.puts("")

    results =
      Enum.map(ips_to_check, fn suffix ->
        ip = "127.0.0.#{suffix}"
        result = ping_ip(ip)
        status = if result == :ok, do: "✓", else: "✗"
        IO.puts("  #{status} #{ip}")
        {ip, result}
      end)

    ok_count = Enum.count(results, fn {_, r} -> r == :ok end)
    fail_count = total - ok_count

    IO.puts("")

    if fail_count == 0 do
      IO.puts("Status: OK (#{ok_count}/#{total} reachable)")
    else
      IO.puts("Status: ISSUES (#{fail_count}/#{total} unreachable)")
      IO.puts("")
      IO.puts("Some IPs failed ping. This may indicate:")
      IO.puts("  - Loopback aliases not properly configured")
      IO.puts("  - Firewall blocking ICMP on loopback")
    end
  end

  # Note: sample_ips is only called when available is non-empty
  # (check_connectivity short-circuits when available is [])
  defp sample_ips([single]), do: [single]
  defp sample_ips([first, last]), do: [first, last]

  defp sample_ips(available) when length(available) >= 3 do
    first = List.first(available)
    last = List.last(available)
    middle_idx = div(length(available), 2)
    middle = Enum.at(available, middle_idx)
    Enum.uniq([first, middle, last])
  end

  @doc false
  def ping_args(ip, os_type \\ :os.type())

  def ping_args(ip, {:unix, :darwin}), do: ["-c", "1", "-t", "1", ip]
  def ping_args(ip, {:unix, _linux}), do: ["-c", "1", "-W", "1", ip]
  def ping_args(ip, _other), do: ["-n", "1", "-w", "1000", ip]

  defp ping_ip(ip) do
    args = ping_args(ip)

    case System.cmd("ping", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, _} -> :error
    end
  end

  defp check_registry do
    IO.puts("=== Registry ===")

    path = Config.registry_path() |> Path.expand()
    exists = File.exists?(path)

    IO.puts("Path: #{path}")
    IO.puts("Status: #{if exists, do: "OK", else: "Will be created on first use"}")
  end

  defp show_allocations do
    IO.puts("=== Current Allocations ===")

    case Registry.list_allocations() do
      {:ok, []} ->
        IO.puts("No allocations yet.")

      {:ok, allocations} ->
        IO.puts("")

        # Header
        IO.puts(
          String.pad_trailing("PROJECT", 15) <>
            String.pad_trailing("BRANCH", 20) <>
            String.pad_trailing("IP", 15) <>
            "HOSTNAME"
        )

        IO.puts(String.duplicate("-", 75))

        # Rows
        Enum.each(allocations, fn alloc ->
          ip = Config.format_ip(alloc.ip_suffix)

          hostname =
            "#{Treehouse.Branch.sanitize(alloc.branch)}.#{Treehouse.Project.sanitize(alloc.project)}.#{Config.domain()}"

          IO.puts(
            String.pad_trailing(alloc.project, 15) <>
              String.pad_trailing(alloc.branch, 20) <>
              String.pad_trailing(ip, 15) <>
              hostname
          )
        end)

      {:error, reason} ->
        IO.puts("Error reading registry: #{inspect(reason)}")
    end
  end
end
