defmodule ElixIRCd.Command.Privmsg do
  @moduledoc """
  This module defines the PRIVMSG command.
  """

  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  @behaviour ElixIRCd.Command

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "PRIVMSG"}) do
    Message.new(%{source: :server, command: :err_notregistered, params: ["*"], body: "You have not registered"})
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG", params: []}) do
    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user.nick, "PRIVMSG"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG", body: nil}) do
    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user.nick, "PRIVMSG"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG", params: [receiver], body: message}) do
    if Helper.channel_name?(receiver),
      do: handle_channel_message(user, receiver, message),
      else: handle_user_message(user, receiver, message)
  end

  defp handle_channel_message(user, channel_name, message) do
    with {:ok, channel} <- Contexts.Channel.get_by_name(channel_name),
         {:ok, _user_channel} <- Contexts.UserChannel.get_by_user_and_channel(user, channel) do
      channel_users = Contexts.UserChannel.get_by_channel(channel) |> Enum.map(& &1.user)
      channel_users_without_user = Enum.reject(channel_users, &(&1 == user))

      Message.new(%{
        source: user.identity,
        command: "PRIVMSG",
        params: [channel.name],
        body: message
      })
      |> Server.send_message(channel_users_without_user)
    else
      {:error, "UserChannel not found"} ->
        Message.new(%{
          source: :server,
          command: :err_cannotsendtochan,
          params: [user.nick, channel_name],
          body: "Cannot send to channel"
        })
        |> Server.send_message(user)

      {:error, "Channel not found"} ->
        Message.new(%{
          source: :server,
          command: :err_nosuchchannel,
          params: [user.nick, channel_name],
          body: "No such channel"
        })
        |> Server.send_message(user)
    end
  end

  defp handle_user_message(user, receiver_nick, message) do
    case Contexts.User.get_by_nick(receiver_nick) do
      {:ok, receiver_user} ->
        Message.new(%{
          source: user.identity,
          command: "PRIVMSG",
          params: [receiver_nick],
          body: message
        })
        |> Server.send_message(receiver_user)

      {:error, _} ->
        Message.new(%{
          source: :server,
          command: :err_nosuchnick,
          params: [user.nick, receiver_nick],
          body: "No such nick"
        })
        |> Server.send_message(user)
    end
  end
end
