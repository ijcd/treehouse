defmodule Mix.Tasks.Treehouse do
  @shortdoc "Treehouse IP allocation commands"
  @moduledoc """
  Commands for managing Treehouse IP allocations.

  ## Available commands

      mix treehouse.list      # List all allocations
      mix treehouse.info      # Show current branch allocation
      mix treehouse.allocate  # Allocate IP for current/specified branch
      mix treehouse.release   # Release current branch allocation
      mix treehouse.doctor    # Check setup and diagnose issues
      mix treehouse.loopback  # Show loopback alias setup commands
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info(@moduledoc)
  end
end

defmodule Mix.Tasks.Treehouse.List do
  @shortdoc "List all IP allocations"
  @moduledoc "Lists all current IP allocations with project, branch, IP, hostname, and last seen time."

  use Mix.Task

  alias Mix.Tasks.Treehouse.Helpers
  alias Treehouse.Config

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    case Treehouse.list() do
      {:ok, []} ->
        Mix.shell().info("No allocations")

      {:ok, allocations} ->
        Mix.shell().info("")
        Mix.shell().info("PROJECT         BRANCH               IP             HOSTNAME")
        Mix.shell().info(String.duplicate("-", 80))

        for alloc <- allocations do
          ip = Treehouse.format_ip(alloc.ip_suffix)
          hostname = "#{alloc.sanitized_name}.#{Config.domain()}"

          project = String.pad_trailing(alloc.project, 15)
          branch = String.pad_trailing(truncate(alloc.branch, 20), 20)
          ip_str = String.pad_trailing(ip, 14)

          Mix.shell().info("#{project} #{branch} #{ip_str} #{hostname}")
        end

        Mix.shell().info("")

      {:error, reason} ->
        Helpers.print_error(reason)
    end
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 2) <> ".."
end

defmodule Mix.Tasks.Treehouse.Info do
  @shortdoc "Show allocation info for a branch"
  @moduledoc "Shows allocation info for the current project/branch or a specified branch."

  use Mix.Task

  alias Mix.Tasks.Treehouse.Helpers

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    args
    |> Helpers.branch_from_args()
    |> Helpers.with_project_branch(fn project, branch ->
      case Treehouse.info(project, branch) do
        {:ok, nil} ->
          Mix.shell().info("No allocation for #{project}:#{branch}")

        {:ok, alloc} ->
          Mix.shell().info("Project:    #{alloc.project}")
          Mix.shell().info("Branch:     #{alloc.branch}")
          Mix.shell().info("Hostname:   #{alloc.sanitized_name}.local")
          Mix.shell().info("IP:         #{Treehouse.format_ip(alloc.ip_suffix)}")
          Mix.shell().info("Allocated:  #{alloc.allocated_at}")
          Mix.shell().info("Last seen:  #{alloc.last_seen_at}")

        {:error, reason} ->
          Helpers.print_error(reason)
      end
    end)
  end
end

defmodule Mix.Tasks.Treehouse.Allocate do
  @shortdoc "Allocate an IP for a branch"
  @moduledoc "Allocates an IP for the current project/branch or a specified branch."

  use Mix.Task

  alias Mix.Tasks.Treehouse.Helpers

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    args
    |> Helpers.branch_from_args()
    |> Helpers.with_project_branch(fn project, branch ->
      case Treehouse.allocate(project, branch) do
        {:ok, ip} ->
          hostname = Treehouse.Branch.hostname(project, branch)
          Mix.shell().info("")
          Mix.shell().info("Allocated IP for #{project}:#{branch}")
          Mix.shell().info("")
          Mix.shell().info("  IP:       #{ip}")
          Mix.shell().info("  Hostname: #{hostname}")
          Mix.shell().info("")

        {:error, :no_loopback_aliases} ->
          Mix.shell().error("No loopback aliases configured!")
          Mix.shell().info("Run: mix treehouse.doctor")

        {:error, :pool_exhausted} ->
          Mix.shell().error("IP pool exhausted!")
          Mix.shell().info("Run: mix treehouse.doctor")

        {:error, reason} ->
          Helpers.print_error(reason)
      end
    end)
  end
end

defmodule Mix.Tasks.Treehouse.Release do
  @shortdoc "Release allocation for a branch"
  @moduledoc "Releases the IP allocation for the current project/branch or a specified branch."

  use Mix.Task

  alias Mix.Tasks.Treehouse.Helpers

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    args
    |> Helpers.branch_from_args()
    |> Helpers.with_project_branch(fn project, branch ->
      case Treehouse.release(project, branch) do
        :ok ->
          Mix.shell().info("Released allocation for: #{project}:#{branch}")

        {:error, reason} ->
          Helpers.print_error(reason)
      end
    end)
  end
end
