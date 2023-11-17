defmodule ElixIRCd.Commands.Nick do
  @moduledoc """
  This module defines the NICK command.

  TODO: broadcast nick change for other users
  TODO: issue on changing nick twice
  """

  alias Ecto.Changeset
  alias ElixIRCd.Contexts
  alias ElixIRCd.Handlers.HandshakeHandler
  alias ElixIRCd.Handlers.MessageHandler

  require Logger

  @behaviour ElixIRCd.Behaviors.Command
  @command "NICK"

  @impl true
  def handle(user, [nick]) do
    case nick_in_use?(nick) do
      true ->
        MessageHandler.send_message(user, :server, "433 * #{nick} :Nickname is already in use")

      false ->
        Contexts.User.update(user, %{nick: nick})
        |> case do
          {:ok, user} ->
            case user.identity do
              nil -> HandshakeHandler.handshake(user)
              _ -> MessageHandler.send_message(user, :user, "#{@command} #{nick}")
            end

          {:error, %Changeset{errors: errors}} ->
            error_message = Enum.map_join(errors, ", ", fn {_, {message, _}} -> message end)

            MessageHandler.send_message(
              user,
              :server,
              "432 #{user.nick} #{nick} :Nickname is unavailable: #{error_message}"
            )
        end
    end
  end

  @impl true
  def handle(user, []) do
    MessageHandler.message_not_enough_params(user, @command)
  end

  @spec nick_in_use?(String.t()) :: boolean()
  defp nick_in_use?(nick) do
    case Contexts.User.get_by_nick(nick) do
      nil -> false
      _ -> true
    end
  end
end
