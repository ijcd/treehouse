defmodule Treehouse.System.Native do
  @moduledoc """
  Native System adapter using Elixir's System module.
  """

  @behaviour Treehouse.System

  @impl true
  def find_executable(cmd) do
    System.find_executable(cmd)
  end
end
