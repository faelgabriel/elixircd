defmodule ElixIRCd.Command.Nick do
  @moduledoc """
  This module defines the NICK command.

  Future:: broadcast nick change for other users
  Future:: issue on changing nick twice
  """

  alias Ecto.Changeset
  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server
  alias ElixIRCd.Server.Handshake

  require Logger

  @behaviour ElixIRCd.Command

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(user, %{command: "NICK", params: [], body: nil}) do
    user_reply = Helper.get_user_reply(user)

    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user_reply, "NICK"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "NICK", params: [], body: nick}) do
    handle(user, %Message{command: "NICK", params: [nick]})
  end

  @impl true
  def handle(user, %{command: "NICK", params: [nick]}) do
    if nick_in_use?(nick) do
      user_reply = Helper.get_user_reply(user)

      Message.new(%{
        source: :server,
        command: :err_nicknameinuse,
        params: [user_reply, nick],
        body: "Nickname is already in use"
      })
      |> Server.send_message(user)
    else
      handle_nick(user, nick)
    end
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
        Handshake.handle(user)

      _ ->
        Message.new(%{
          source: user.identity,
          command: "NICK",
          params: [nick]
        })
        |> Server.send_message(user)
    end
  end

  @spec handle_error(Schemas.User.t(), String.t(), list()) :: :ok
  defp handle_error(user, nick, errors) do
    error_message = Enum.map_join(errors, ", ", fn {_, {message, _}} -> message end)

    Message.new(%{
      source: :server,
      command: :err_erroneusnickname,
      params: ["*", nick],
      body: "Nickname is unavailable: #{error_message}"
    })
    |> Server.send_message(user)
  end

  @spec nick_in_use?(String.t()) :: boolean()
  defp nick_in_use?(nick) do
    case Contexts.User.get_by_nick(nick) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
