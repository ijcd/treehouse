defmodule Treehouse.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:treehouse, :start_allocator, true) do
        # Registry must start before Allocator (Allocator calls Registry.init_schema)
        [Treehouse.Registry.Sqlite, Treehouse.Allocator]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Treehouse.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
