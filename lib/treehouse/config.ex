defmodule Treehouse.Config do
  @moduledoc """
  Centralized configuration access for Treehouse.

  All configuration can be set in config files or at runtime:

      config :treehouse,
        domain: "local",
        ip_prefix: "127.0.0",
        ip_range_start: 10,
        ip_range_end: 99,
        stale_threshold_days: 7,
        registry_path: "~/.local/share/treehouse/registry.db"
  """

  @doc "Domain for mDNS hostnames (default: \"local\")"
  def domain(opts \\ []) do
    opts[:domain] || Application.get_env(:treehouse, :domain, "local")
  end

  @doc "IP prefix for allocations (default: \"127.0.0\")"
  def ip_prefix do
    Application.get_env(:treehouse, :ip_prefix, "127.0.0")
  end

  @doc "First IP suffix in allocation range (default: 10)"
  def ip_range_start(opts \\ []) do
    opts[:ip_range_start] || Application.get_env(:treehouse, :ip_range_start, 10)
  end

  @doc "Last IP suffix in allocation range (default: 99)"
  def ip_range_end(opts \\ []) do
    opts[:ip_range_end] || Application.get_env(:treehouse, :ip_range_end, 99)
  end

  @doc "Days before an allocation is considered stale (default: 7)"
  def stale_threshold_days(opts \\ []) do
    opts[:stale_threshold_days] || Application.get_env(:treehouse, :stale_threshold_days, 7)
  end

  @doc "Path to SQLite registry database"
  def registry_path(opts \\ []) do
    opts[:db_path] ||
      Application.get_env(:treehouse, :registry_path, "~/.local/share/treehouse/registry.db")
  end

  @doc "Formats an IP suffix to full IP string using configured prefix"
  def format_ip(suffix) when is_integer(suffix) do
    "#{ip_prefix()}.#{suffix}"
  end
end
