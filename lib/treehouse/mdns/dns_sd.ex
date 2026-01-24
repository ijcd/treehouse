defmodule Treehouse.Mdns.DnsSd do
  @moduledoc """
  mDNS adapter using macOS dns-sd command.

  Uses proxy mode (-P) to create actual A record resolution,
  so `<hostname>.local` resolves to the allocated IP.
  """

  @behaviour Treehouse.Mdns

  require Logger

  @impl true
  def register(name, ip, port, opts \\ []) do
    {cmd, args} = build_command(name, ip, port, opts)
    hostname = "#{name}.#{Treehouse.Config.domain(opts)}"

    Logger.info("[treehouse] Registering mDNS: #{hostname} -> #{ip}:#{port}")

    # Spawn process that opens AND owns the port so it receives messages
    pid =
      spawn(fn ->
        port_ref =
          Port.open({:spawn_executable, Treehouse.System.find_executable(cmd)}, [
            :binary,
            :exit_status,
            args: args
          ])

        monitor_port(port_ref, hostname)
      end)

    {:ok, pid}
  end

  @impl true
  def unregister(pid) when is_pid(pid) do
    Logger.info("[treehouse] Unregistering mDNS service")
    Process.exit(pid, :kill)
    :ok
  end

  @doc """
  Builds the dns-sd command and arguments for proxy registration.
  """
  def build_command(name, ip, port, opts \\ []) do
    service_type = Keyword.get(opts, :service_type, "_http._tcp")
    domain = Treehouse.Config.domain(opts)
    hostname = "#{name}.#{domain}"

    args = [
      # Proxy mode - creates A record
      "-P",
      # Service name
      name,
      # Service type
      service_type,
      # Domain
      domain,
      # Port
      to_string(port),
      # Target hostname
      hostname,
      # IP address to resolve to
      ip
    ]

    {"dns-sd", args}
  end

  defp monitor_port(port_ref, hostname) do
    receive do
      {^port_ref, {:exit_status, status}} ->
        Logger.debug("[treehouse] mDNS for #{hostname} exited with status #{status}")
        :ok

      {^port_ref, {:data, _data}} ->
        monitor_port(port_ref, hostname)
    end
  end
end
