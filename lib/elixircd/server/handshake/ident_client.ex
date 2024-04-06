defmodule ElixIRCd.Server.Handshake.IdentClient do
  @moduledoc """
  Module for querying the userid from an Ident server.
  """

  # Since Mimic library does not support mocking of sticky modules (:gen_tcp, for this case),
  # we need to ignore this module from the test coverage.
  # coveralls-ignore-start

  @doc """
  Retrieves the user identifier from an Ident server.
  """
  @spec query_userid(tuple(), integer()) :: {:ok, String.t()} | {:error, String.t()}
  def query_userid(ip, server_port_query) do
    timeout = Application.get_env(:elixircd, :ident_service)[:timeout]

    with {:ok, socket} <- :gen_tcp.connect(ip, 113, [:binary, {:active, false}]),
         :ok <- :gen_tcp.send(socket, "#{server_port_query}, 113\r\n"),
         {:ok, data} <- :gen_tcp.recv(socket, 0, timeout),
         :ok <- :gen_tcp.close(socket),
         [_port_info, "USERID", _os, user_id] <- String.split(data, " : ", trim: true) do
      {:ok, user_id}
    else
      reason -> {:error, "Failed to retrieve Ident response: #{inspect(reason)}"}
    end
  end

  # coveralls-ignore-stop
end
