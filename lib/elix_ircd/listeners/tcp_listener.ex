defmodule ElixIRCd.Listeners.TcpListener do
  @moduledoc """
  Module for the TCP listener.
  """

  @doc """
  Starts the TCP server supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    :ranch.child_spec(__MODULE__, :ranch_tcp, opts, ElixIRCd.Protocols.TcpServer, [])
  end
end
