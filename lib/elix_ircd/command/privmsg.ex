defmodule ElixIRCd.Command.Privmsg do
  @moduledoc """
  This module defines the PRIVMSG command.
  """

  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  @behaviour ElixIRCd.Command.Behavior

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "PRIVMSG"}) do
    Message.new(%{source: :server, command: :err_notregistered, params: ["*"], body: "You have not registered"})
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG", params: [receiver], body: message}) do
    if String.starts_with?(receiver, "#"),
      do: handle_channel_message(user, receiver, message),
      else: handle_user_message(user, receiver, message)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG"}) do
    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user.nick, "PRIVMSG"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end

  defp handle_channel_message(user, channel_name, message) do
    with {:ok, channel} <- Contexts.Channel.get_by_name(channel_name),
         user_channels <- Contexts.UserChannel.get_by_channel(channel),
         channel_users = Enum.map(user_channels, & &1.user),
         true <- Enum.member?(channel_users, user) do
      channel_users_without_user = Enum.reject(channel_users, &(&1 == user))

      Message.new(%{
        source: user.identity,
        command: "PRIVMSG",
        params: [channel.name],
        body: message
      })
      |> Server.send_message(channel_users_without_user)
    else
      _ ->
        Message.new(%{
          source: :server,
          command: :rpl_cannotsendtochan,
          params: [user.nick, channel_name],
          body: "Cannot send to channel"
        })
        |> Server.send_message(user)
    end
  end

  defp handle_user_message(user, receiver_nick, message) do
    case Contexts.User.get_by_nick(receiver_nick) do
      {:ok, receiver_user} ->
        Message.new(%{source: receiver_user.identity, command: "PRIVMSG", params: [user.nick], body: message})
        |> Server.send_message(receiver_user)

      {:error, _} ->
        Message.new(%{source: :server, command: :rpl_nouser, params: [user.nick, receiver_nick], body: "No such nick"})
        |> Server.send_message(user)
    end
  end
end
