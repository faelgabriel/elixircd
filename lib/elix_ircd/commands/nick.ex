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

  require Logger

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "NICK", params: [nick]}) do
    if nick_in_use?(nick) do
      Messaging.send_message(user, :server, "433 * #{nick} :Nickname is already in use")
    else
      handle_nick(user, nick)
    end
  end

  @impl true
  def handle(user, %{command: "NICK"}) do
    Messaging.message_not_enough_params(user, "NICK")
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
      nil -> Handshake.handshake(user)
      _ -> Messaging.send_message(user, :user, "NICK #{nick}")
    end
  end

  @spec handle_error(Schemas.User.t(), String.t(), list()) :: :ok
  defp handle_error(user, nick, errors) do
    error_message = Enum.map_join(errors, ", ", fn {_, {message, _}} -> message end)

    Messaging.send_message(
      user,
      :server,
      "432 #{user.nick} #{nick} :Nickname is unavailable: #{error_message}"
    )
  end

  @spec nick_in_use?(String.t()) :: boolean()
  defp nick_in_use?(nick) do
    case Contexts.User.get_by_nick(nick) do
      nil -> false
      _ -> true
    end
  end
end
