defmodule ElixIRCd.Listeners.SslListener do
  @moduledoc """
  Module for the SSL listener.
  """

  @doc """
  Starts the SSL server supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    :ranch.child_spec(__MODULE__, :ranch_ssl, opts, ElixIRCd.Protocols.SslServer, [])
  end
end
