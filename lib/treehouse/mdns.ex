defmodule Treehouse.Mdns do
  @moduledoc """
  mDNS hostname resolution.

  Default implementation uses macOS dns-sd command.
  """

  @doc """
  Registers an mDNS hostname→IP mapping.
  Returns {:ok, reference} that can be used to unregister.
  """
  @callback register(name :: String.t(), ip :: String.t(), port :: integer(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Unregisters an mDNS mapping.
  """
  @callback unregister(reference :: term()) :: :ok

  @doc """
  Returns the configured adapter module.
  """
  def adapter do
    Application.get_env(:treehouse, :mdns_adapter, __MODULE__.DnsSd)
  end

  @doc """
  Registers an mDNS hostname→IP mapping.
  Returns {:ok, reference} that can be used to unregister.
  """
  def register(name, ip, port, opts \\ []) do
    adapter().register(name, ip, port, opts)
  end

  @doc """
  Unregisters an mDNS mapping.
  """
  def unregister(reference) do
    adapter().unregister(reference)
  end

  @doc """
  Builds the dns-sd command and arguments.
  Delegates to the dns-sd adapter for the command format.
  """
  @spec build_command(String.t(), String.t(), integer(), keyword()) :: {String.t(), [String.t()]}
  def build_command(name, ip, port, opts \\ []) do
    __MODULE__.DnsSd.build_command(name, ip, port, opts)
  end
end
