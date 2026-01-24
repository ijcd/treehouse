defmodule Mix.Tasks.Treehouse.Helpers do
  @moduledoc false

  @doc """
  Gets branch from args or current git branch.

  Returns the branch name string, or `{:error, reason}` if detection fails.
  """
  def branch_from_args(args) do
    case args do
      [branch | _] -> branch
      [] -> get_current_branch()
    end
  end

  @doc """
  Gets the current git branch.

  Returns the branch name or `{:error, reason}`.
  """
  def get_current_branch do
    case Treehouse.Branch.current() do
      {:ok, branch} -> branch
      error -> error
    end
  end

  @doc """
  Executes a callback with the branch, handling errors.

  If branch is an error tuple, prints error to stderr.
  Otherwise, calls the callback with the branch name.
  """
  def with_branch(branch, callback) do
    case branch do
      {:error, reason} ->
        Mix.shell().error("Error getting branch: #{reason}")

      branch when is_binary(branch) ->
        callback.(branch)
    end
  end

  @doc """
  Prints a Treehouse error to stderr.
  """
  def print_error(reason) do
    Mix.shell().error("Error: #{inspect(reason)}")
  end
end
