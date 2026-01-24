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
  @moduledoc """
  Lists all current IP allocations.

      mix treehouse.list

  Shows branch name, sanitized name, IP, and last seen time.
  """

  use Mix.Task

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
          ip = "127.0.0.#{alloc.ip_suffix}"
          branch = String.pad_trailing(alloc.branch, 32)
          ip_str = String.pad_trailing(ip, 15)
          Mix.shell().info("#{branch} #{ip_str} #{alloc.last_seen_at}")
        end

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
    end
  end
end

defmodule Mix.Tasks.Treehouse.Info do
  @shortdoc "Show current branch allocation"
  @moduledoc """
  Shows allocation info for the current git branch.

      mix treehouse.info

  Or for a specific branch:

      mix treehouse.info BRANCH
  """

  use Mix.Task

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    branch =
      case args do
        [b | _] -> b
        [] -> get_current_branch()
      end

    case branch do
      {:error, reason} ->
        Mix.shell().error("Error getting branch: #{reason}")

      branch ->
        case Treehouse.info(branch) do
          {:ok, nil} ->
            Mix.shell().info("No allocation for branch: #{branch}")

          {:ok, alloc} ->
            Mix.shell().info("Branch:     #{alloc.branch}")
            Mix.shell().info("Hostname:   #{alloc.sanitized_name}.local")
            Mix.shell().info("IP:         127.0.0.#{alloc.ip_suffix}")
            Mix.shell().info("Allocated:  #{alloc.allocated_at}")
            Mix.shell().info("Last seen:  #{alloc.last_seen_at}")

          {:error, reason} ->
            Mix.shell().error("Error: #{inspect(reason)}")
        end
    end
  end

  defp get_current_branch do
    case Treehouse.Branch.current() do
      {:ok, branch} -> branch
      error -> error
    end
  end
end

defmodule Mix.Tasks.Treehouse.Release do
  @shortdoc "Release current branch allocation"
  @moduledoc """
  Releases the IP allocation for the current git branch.

      mix treehouse.release

  Or for a specific branch:

      mix treehouse.release BRANCH
  """

  use Mix.Task

  @impl true
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:treehouse)

    branch =
      case args do
        [b | _] -> b
        [] -> get_current_branch()
      end

    case branch do
      {:error, reason} ->
        Mix.shell().error("Error getting branch: #{reason}")

      branch ->
        case Treehouse.release(branch) do
          :ok ->
            Mix.shell().info("Released allocation for: #{branch}")

          {:error, reason} ->
            Mix.shell().error("Error: #{inspect(reason)}")
        end
    end
  end

  defp get_current_branch do
    case Treehouse.Branch.current() do
      {:ok, branch} -> branch
      error -> error
    end
  end
end
