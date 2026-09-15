defmodule ElixIRCd.Commands.Ping do
  @moduledoc """
  This module defines the PING command.

  PING tests the connection between client and server, expecting a PONG response.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "PING", params: [token | _]}) do
    send_pong(user, token)
  end

  def handle(user, %{command: "PING", trailing: token}) when is_binary(token) do
    send_pong(user, token)
  end

  @impl true
  def handle(user, %{command: "PING"}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "PING"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_pong(User.t(), String.t()) :: :ok
  defp send_pong(user, token) do
    hostname = Application.fetch_env!(:elixircd, :server)[:hostname]

    %Message{command: "PONG", params: [hostname], trailing: token}
    |> Dispatcher.broadcast(:server, user)
  end
end
