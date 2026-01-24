defmodule Treehouse do
  @moduledoc """
  Local development IP manager - a home for your worktrees.

  Allocates unique IPs from 127.0.0.10-99 per git branch,
  persists in SQLite, and announces via mDNS.

  ## Usage

      {:ok, ip} = Treehouse.allocate("my-branch")
      # => {:ok, "127.0.0.10"}

  The IP is yours to use. Bind your server to it, configure mDNS, etc.

  ## Phoenix Integration

      # In config/dev.exs:
      {:ok, branch} = Treehouse.Branch.current()
      {:ok, ip} = Treehouse.allocate(branch)

      config :my_app, MyAppWeb.Endpoint,
        http: [ip: Treehouse.parse_ip(ip), port: 4000],
        url: [host: Treehouse.Branch.sanitize(branch) <> ".local"]
  """

  @doc """
  Allocates an IP for the given branch, or returns existing allocation.
  Updates last_seen_at timestamp on each call.

  Returns `{:ok, ip_string}` or `{:error, reason}`.
  """
  def allocate(branch) do
    Treehouse.Allocator.get_or_allocate(branch)
  end

  @doc """
  Releases the allocation for a branch.
  """
  def release(branch) do
    Treehouse.Allocator.release(branch)
  end

  @doc """
  Lists all current allocations.
  """
  def list do
    Treehouse.Allocator.list()
  end

  @doc """
  Gets allocation info for a specific branch.
  """
  def info(branch) do
    Treehouse.Allocator.info(branch)
  end

  @doc """
  Parses an IP string like "127.0.0.10" into a tuple {127, 0, 0, 10}.
  Useful for Phoenix endpoint config.

  ## Example

      Treehouse.parse_ip("127.0.0.42")
      # => {127, 0, 0, 42}
  """
  @spec parse_ip(String.t()) :: {integer(), integer(), integer(), integer()}
  def parse_ip(ip) when is_binary(ip) do
    ip
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end
end
