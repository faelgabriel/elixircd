defmodule ElixIRCd.Commands.Nick do
  @moduledoc """
  This module defines the NICK command.

  Future:: broadcast nick change for other users
  Future:: issue on changing nick twice
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Handshake
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Tables
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageBuilder

  require Logger

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  @spec handle(Tables.User.t(), Message.t()) :: :ok
  def handle(user, %{command: "NICK", params: [], body: nick}) do
    handle(user, %Message{command: "NICK", params: [nick]})
  end

  def handle(user, %{command: "NICK", params: [nick]}) do
    if nick_in_use?(nick) do
      user_reply = MessageBuilder.get_user_reply(user)

      MessageBuilder.server_message(:err_nicknameinuse, [user_reply, nick], "Nickname is already in use")
      |> Messaging.send_message(user)
    else
      handle_nick(user, nick)
    end
  end

  @impl true
  def handle(user, %{command: "NICK"}) do
    user_reply = MessageBuilder.get_user_reply(user)

    MessageBuilder.server_message(:rpl_needmoreparams, [user_reply, "NICK"], "Not enough parameters")
    |> Messaging.send_message(user)
  end

  @spec handle_nick(Tables.User.t(), String.t()) :: :ok
  defp handle_nick(user, nick) do
    case Contexts.User.update(user, %{nick: nick}) do
      {:ok, user} -> handle_identity(user, nick)
      {:error, error} -> handle_error(user, nick, error)
    end
  end

  @spec handle_identity(Tables.User.t(), String.t()) :: :ok
  defp handle_identity(user, nick) do
    case user.identity do
      nil ->
        Handshake.handshake(user)

      _ ->
        MessageBuilder.user_message(user.identity, "NICK", [nick])
        |> Messaging.send_message(user)
    end
  end

  @spec handle_error(Tables.User.t(), String.t(), String.t()) :: :ok
  defp handle_error(user, nick, error) do
    MessageBuilder.server_message(:err_erroneusnickname, ["*", nick], ":Nickname is unavailable: #{error}")
    |> Messaging.send_message(user)
  end

  @spec nick_in_use?(String.t()) :: boolean()
  defp nick_in_use?(nick) do
    case Contexts.User.get_by_nick(nick) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
