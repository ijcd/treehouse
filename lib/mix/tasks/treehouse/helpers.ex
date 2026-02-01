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
  Gets the current project name.

  Returns the project name string.
  """
  def get_current_project do
    Treehouse.Project.current!()
  end

  @doc """
  Executes a callback with project and branch, handling errors.

  If branch is an error tuple, prints error to stderr.
  Otherwise, calls the callback with project and branch.
  """
  def with_project_branch(branch, callback) do
    case branch do
      {:error, reason} ->
        Mix.shell().error("Error getting branch: #{reason}")

      branch when is_binary(branch) ->
        project = get_current_project()
        callback.(project, branch)
    end
  end

  @doc """
  Prints a Treehouse error to stderr.
  """
  def print_error(reason) do
    Mix.shell().error("Error: #{inspect(reason)}")
  end
end
