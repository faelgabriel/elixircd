defmodule ElixIRCd.Supervisors.SslSupervisor do
  @moduledoc """
  Module for the SSL listener.
  """

  require Logger

  @doc """
  Starts the SSL server supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Logger.info("Starting SSL server on port #{Keyword.get(opts, :port)}...")

    :ranch.child_spec(__MODULE__, :ranch_ssl, opts, ElixIRCd.Protocols.SslServer, [])
    |> tap(fn _ ->
      Logger.info("SSL server started on port #{Keyword.get(opts, :port)}.")
    end)
  end
end
