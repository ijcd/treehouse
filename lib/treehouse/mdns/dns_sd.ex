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
    domain = Keyword.get(opts, :domain) || Application.get_env(:treehouse, :domain, "local")
    hostname = "#{name}.#{domain}"

    Logger.info("[treehouse] Registering mDNS: #{hostname} -> #{ip}:#{port}")

    port_ref =
      Port.open({:spawn_executable, System.find_executable(cmd)}, [
        :binary,
        :exit_status,
        args: args
      ])

    {:ok, spawn(fn -> monitor_port(port_ref, hostname) end)}
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
    domain = Keyword.get(opts, :domain) || Application.get_env(:treehouse, :domain, "local")
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
