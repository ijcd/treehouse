defmodule Treehouse.System do
  @moduledoc """
  System utilities behaviour for dependency injection.

  Wraps System module functions to allow mocking in tests.
  """

  @doc """
  Finds the path to an executable.
  """
  @callback find_executable(String.t()) :: String.t() | nil

  @doc """
  Returns the configured adapter module.
  """
  def adapter do
    Application.get_env(:treehouse, :system_adapter, __MODULE__.Native)
  end

  @doc """
  Finds the path to an executable.

  Delegates to configured adapter (default: Native).
  """
  @spec find_executable(String.t()) :: String.t() | nil
  def find_executable(cmd) do
    adapter().find_executable(cmd)
  end
end
