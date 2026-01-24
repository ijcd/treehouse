defmodule Mix.Tasks.Treehouse do
  @shortdoc "Treehouse IP allocation commands"
  @moduledoc """
  Commands for managing Treehouse IP allocations.

  ## Available commands

      mix treehouse.list     # List all allocations
      mix treehouse.info     # Show current branch allocation
      mix treehouse.release  # Release current branch allocation
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info(@moduledoc)
  end
end

defmodule Mix.Tasks.Treehouse.List do
  @shortdoc "List all IP allocations"
  @moduledoc "Lists all current IP allocations with branch, IP, and last seen time."

  use Mix.Task

  alias Mix.Tasks.Treehouse.Helpers

  @impl true
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    case Treehouse.list() do
      {:ok, []} ->
        Mix.shell().info("No allocations")

      {:ok, allocations} ->
        Mix.shell().info("Branch                           IP              Last Seen")
        Mix.shell().info(String.duplicate("-", 70))

        for alloc <- allocations do
          ip = Treehouse.format_ip(alloc.ip_suffix)
          branch = String.pad_trailing(alloc.branch, 32)
          ip_str = String.pad_trailing(ip, 15)
          Mix.shell().info("#{branch} #{ip_str} #{alloc.last_seen_at}")
        end

      {:error, reason} ->
        Helpers.print_error(reason)
    end
  end
end

defmodule Mix.Tasks.Treehouse.Info do
  @shortdoc "Show allocation info for a branch"
  @moduledoc "Shows allocation info for the current git branch or a specified branch."

  use Mix.Task

  alias Mix.Tasks.Treehouse.Helpers

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    args
    |> Helpers.branch_from_args()
    |> Helpers.with_branch(fn branch ->
      case Treehouse.info(branch) do
        {:ok, nil} ->
          Mix.shell().info("No allocation for branch: #{branch}")

        {:ok, alloc} ->
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

defmodule Mix.Tasks.Treehouse.Release do
  @shortdoc "Release allocation for a branch"
  @moduledoc "Releases the IP allocation for the current git branch or a specified branch."

  use Mix.Task

  alias Mix.Tasks.Treehouse.Helpers

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    args
    |> Helpers.branch_from_args()
    |> Helpers.with_branch(fn branch ->
      case Treehouse.release(branch) do
        :ok ->
          Mix.shell().info("Released allocation for: #{branch}")

        {:error, reason} ->
          Helpers.print_error(reason)
      end
    end)
  end
end
