defmodule ElixIRCd.Listeners.TcpListener do
  @moduledoc """
  Module for the TCP listener.
  """

  def child_spec(opts) do
    :ranch.child_spec(__MODULE__, :ranch_tcp, opts, ElixIRCd.Protocols.TcpServer, [])
  end
end
