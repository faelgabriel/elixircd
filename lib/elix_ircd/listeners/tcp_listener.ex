defmodule ElixIRCd.Listeners.TcpListener do
  @moduledoc """
  Module for the TCP listener.
  """

  require Logger

  @doc """
  Starts the TCP server supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Logger.info("Starting TCP server on port #{Keyword.get(opts, :port)}")
    :ranch.child_spec(__MODULE__, :ranch_tcp, opts, ElixIRCd.Protocols.TcpServer, [])
  end
end
