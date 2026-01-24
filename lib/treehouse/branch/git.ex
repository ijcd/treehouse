defmodule Treehouse.Branch.Git do
  @moduledoc """
  Branch adapter that uses system git command.
  """

  @behaviour Treehouse.Branch

  @impl true
  def current(path \\ nil) do
    dir = path || File.cwd!()

    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: dir, stderr_to_stdout: true) do
      {branch, 0} -> {:ok, String.trim(branch)}
      {error, _} -> {:error, String.trim(error)}
    end
  end
end
