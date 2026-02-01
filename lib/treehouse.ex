defmodule Treehouse do
  @moduledoc """
  Local development IP manager - a home for your worktrees.

  Allocates unique IPs from 127.0.0.10-99 per project/branch combination,
  persists in SQLite, and announces via mDNS.

  ## Phoenix Integration (Recommended)

      # In config/dev.exs:
      {:ok, treehouse} = Treehouse.setup(port: 4000)

      config :my_app, MyAppWeb.Endpoint,
        http: [ip: treehouse.ip_tuple, port: 4000],
        url: [host: treehouse.hostname]
        # => hostname: "main.myapp.local"

  ## Manual Usage

      {:ok, ip} = Treehouse.allocate("my-branch")
      # => {:ok, "127.0.0.10"}

  Project is auto-detected from Mix app name or can be explicit:

      {:ok, ip} = Treehouse.allocate("myapp", "my-branch")
  """

  alias Treehouse.Config
  alias Treehouse.Project

  @doc """
  Allocates an IP for the given project/branch, or returns existing allocation.
  Updates last_seen_at timestamp on each call.

  Project is auto-detected from Mix app name if not specified.

  Returns `{:ok, ip_string}` or `{:error, reason}`.
  """
  @spec allocate(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def allocate(project \\ Project.current!(), branch) do
    Treehouse.Allocator.get_or_allocate(project, branch)
  end

  @doc """
  Releases the allocation for a project/branch.

  Project is auto-detected from Mix app name if not specified.
  """
  @spec release(String.t(), String.t()) :: :ok | {:error, term()}
  def release(project \\ Project.current!(), branch) do
    Treehouse.Allocator.release(project, branch)
  end

  @doc """
  Lists all current allocations.
  """
  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list do
    Treehouse.Allocator.list()
  end

  @doc """
  Gets allocation info for a specific project/branch.

  Project is auto-detected from Mix app name if not specified.
  """
  @spec info(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def info(project \\ Project.current!(), branch) do
    Treehouse.Allocator.info(project, branch)
  end

  @doc """
  Formats an IP suffix to a full IP string.

  ## Example

      Treehouse.format_ip(42)
      # => "127.0.0.42"
  """
  @spec format_ip(integer()) :: String.t()
  defdelegate format_ip(suffix), to: Config

  @doc """
  Parses an IP string like "127.0.0.10" into a tuple {127, 0, 0, 10}.
  Useful for Phoenix endpoint config.

  ## Example

      Treehouse.parse_ip("127.0.0.42")
      # => {127, 0, 0, 42}
  """
  @spec parse_ip(String.t()) :: {integer(), integer(), integer(), integer()}
  def parse_ip(ip) when is_binary(ip) do
    ip
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  @doc """
  One-call setup for Phoenix integration.

  Detects project/branch, allocates IP, registers mDNS, returns config.

  ## Options
    - `:port` - Port to register with mDNS (required)
    - `:project` - Override auto-detected project
    - `:branch` - Override auto-detected branch
    - `:mdns` - Set to false to skip mDNS registration (default: true)

  ## Example

      # In config/dev.exs
      {:ok, treehouse} = Treehouse.setup(port: 4000)

      config :my_app, MyAppWeb.Endpoint,
        http: [ip: treehouse.ip_tuple, port: 4000],
        url: [host: treehouse.hostname]

  ## Returns

      {:ok, %{
        project: "myapp",
        branch: "main",
        ip: "127.0.0.10",
        ip_tuple: {127, 0, 0, 10},
        hostname: "main.myapp.local",
        mdns_pid: pid | nil
      }}
  """
  @spec setup(keyword()) :: {:ok, map()} | {:error, term()}
  def setup(opts) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    port = Keyword.fetch!(opts, :port)
    project = Keyword.get_lazy(opts, :project, &Project.current!/0)
    register_mdns? = Keyword.get(opts, :mdns, true)

    with {:ok, branch} <- get_branch(opts),
         {:ok, ip} <- allocate(project, branch) do
      hostname = Treehouse.Branch.hostname(project, branch)
      # Strip the domain suffix for the service name
      service_name = "#{Treehouse.Branch.sanitize(branch)}.#{Project.sanitize(project)}"

      mdns_pid =
        if register_mdns? do
          case Treehouse.Mdns.register(service_name, ip, port) do
            {:ok, pid} -> pid
            {:error, _} -> nil
          end
        end

      {:ok,
       %{
         project: project,
         branch: branch,
         ip: ip,
         ip_tuple: parse_ip(ip),
         hostname: hostname,
         mdns_pid: mdns_pid
       }}
    end
  end

  defp get_branch(opts) do
    case Keyword.fetch(opts, :branch) do
      {:ok, branch} -> {:ok, branch}
      :error -> Treehouse.Branch.current()
    end
  end
end
