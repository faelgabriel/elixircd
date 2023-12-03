defmodule ElixIRCd.Supervisors.TcpSupervisor do
  @moduledoc """
  Module for the TCP listener.
  """

  require Logger

  @doc """
  Starts the TCP server supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Logger.info("Starting TCP server on port #{Keyword.get(opts, :port)}...")

    :ranch.child_spec(__MODULE__, :ranch_tcp, opts, ElixIRCd.Protocols.TcpServer, [])
    |> tap(fn _ ->
      Logger.info("TCP server started on port #{Keyword.get(opts, :port)}.")
    end)
  end
end
