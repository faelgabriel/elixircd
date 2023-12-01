defmodule ElixIRCd.Commands.Nick do
  @moduledoc """
  This module defines the NICK command.

  Future:: broadcast nick change for other users
  Future:: issue on changing nick twice
  """

  alias Ecto.Changeset
  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Handshake
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.MessageBuilder

  require Logger

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "NICK", params: [nick]}) do
    if nick_in_use?(nick) do
      MessageBuilder.server_message(:err_nicknameinuse, ["*", nick], "Nickname is already in use")
      |> Messaging.send_message(user)
    else
      handle_nick(user, nick)
    end
  end

  @impl true
  def handle(user, %{command: "NICK"}) when user.identity != nil do
    MessageBuilder.server_message(:rpl_needmoreparams, [user.nick, "NICK"], "Not enough parameters")
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: "NICK"}) do
    MessageBuilder.server_message(:rpl_needmoreparams, ["*", "NICK"], "Not enough parameters")
    |> Messaging.send_message(user)
  end

  @spec handle_nick(Schemas.User.t(), String.t()) :: :ok
  defp handle_nick(user, nick) do
    case Contexts.User.update(user, %{nick: nick}) do
      {:ok, user} -> handle_identity(user, nick)
      {:error, %Changeset{errors: errors}} -> handle_error(user, nick, errors)
    end
  end

  @spec handle_identity(Schemas.User.t(), String.t()) :: :ok
  defp handle_identity(user, nick) do
    case user.identity do
      nil ->
        Handshake.handshake(user)

      _ ->
        MessageBuilder.user_message(user.identity, "NICK", [nick])
        |> Messaging.send_message(user)
    end
  end

  @spec handle_error(Schemas.User.t(), String.t(), list()) :: :ok
  defp handle_error(user, nick, errors) do
    error_message = Enum.map_join(errors, ", ", fn {_, {message, _}} -> message end)

    MessageBuilder.server_message(:err_erroneusnickname, ["*", nick], ":Nickname is unavailable: #{error_message}")
    |> Messaging.send_message(user)
  end

  @spec nick_in_use?(String.t()) :: boolean()
  defp nick_in_use?(nick) do
    case Contexts.User.get_by_nick(nick) do
      nil -> false
      _ -> true
    end
  end
end
