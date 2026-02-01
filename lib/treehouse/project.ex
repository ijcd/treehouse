defmodule Treehouse.Project do
  @moduledoc """
  Project name detection for unique allocation keys.

  Detection order:
  1. Explicit config: `config :treehouse, project: "myapp"`
  2. Mix project app name
  3. Current directory name (fallback)
  """

  @doc """
  Returns the current project name.

  ## Examples

      iex> Treehouse.Project.current()
      {:ok, "treehouse"}
  """
  def current do
    {:ok, detect()}
  end

  @doc """
  Returns the project name, raising on failure.
  """
  def current! do
    detect()
  end

  defp detect do
    from_config() || from_mix() || from_directory()
  end

  defp from_config do
    case Application.get_env(:treehouse, :project) do
      nil -> nil
      name when is_atom(name) -> Atom.to_string(name)
      name when is_binary(name) -> name
    end
  end

  defp from_mix do
    if Code.ensure_loaded?(Mix.Project) and function_exported?(Mix.Project, :config, 0) do
      case Mix.Project.config()[:app] do
        nil -> nil
        app -> Atom.to_string(app)
      end
    else
      nil
    end
  end

  defp from_directory do
    File.cwd!() |> Path.basename()
  end

  @doc """
  Sanitizes a project name for use in hostnames.
  Same rules as branch sanitization.
  """
  def sanitize(project) do
    project
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> truncate(20)
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max) |> String.trim("-")
end
