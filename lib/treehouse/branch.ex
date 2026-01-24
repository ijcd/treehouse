defmodule Treehouse.Branch do
  @moduledoc """
  Branch/context detection and name sanitization.

  Default implementation uses git. Could also be static, env var, etc.
  """

  @doc """
  Returns the current branch/context name.
  """
  @callback current(path :: String.t() | nil) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Returns the configured adapter module.
  """
  def adapter do
    Application.get_env(:treehouse, :branch_adapter, __MODULE__.Git)
  end

  @doc """
  Returns the current branch name.
  Uses cwd if no path specified.

  Delegates to configured adapter (default: git).
  """
  @spec current(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def current(path \\ nil) do
    adapter().current(path)
  end

  @max_label_length 63

  @doc """
  Sanitizes a branch name for use in hostnames.

  - Lowercases everything
  - Replaces slashes and underscores with dashes
  - Removes non-alphanumeric characters (except dashes)
  - Collapses multiple dashes
  - Trims leading/trailing dashes
  - Truncates to 63 chars (DNS label limit), adding hash suffix if needed
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(branch) do
    clean =
      branch
      |> String.downcase()
      |> String.replace(~r"[/_]", "-")
      |> String.replace(~r"[^a-z0-9-]", "")
      |> String.replace(~r"-+", "-")
      |> String.trim("-")

    truncate_with_hash(clean)
  end

  defp truncate_with_hash(name) when byte_size(name) <= @max_label_length, do: name

  defp truncate_with_hash(name) do
    # 8 char hash suffix + dash = 9 chars reserved
    prefix_len = @max_label_length - 9
    prefix = name |> String.slice(0, prefix_len) |> String.trim_trailing("-")
    hash = :crypto.hash(:md5, name) |> Base.encode16(case: :lower) |> String.slice(0, 8)
    "#{prefix}-#{hash}"
  end

  @doc """
  Creates a hostname from a branch name.

  ## Options
    - `:domain` - domain suffix (default: from config or "local")
  """
  @spec hostname(String.t(), keyword()) :: String.t()
  def hostname(branch, opts \\ []) do
    domain = opts[:domain] || Application.get_env(:treehouse, :domain, "local")
    "#{branch}.#{domain}"
  end
end
