defmodule ElixIRCd.Command.Notice do
  @moduledoc """
  This module defines the NOTICE command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [build_user_mask: 1, channel_name?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "NOTICE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "NOTICE", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "NOTICE"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "NOTICE", trailing: nil}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "NOTICE"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "NOTICE", params: [receiver], trailing: message}) do
    if channel_name?(receiver),
      do: handle_channel_message(user, receiver, message),
      else: handle_user_message(user, receiver, message)
  end

  defp handle_channel_message(user, channel_name, message) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, _user_channel} <- UserChannels.get_by_user_port_and_channel_name(user.port, channel.name) do
      channel_users_without_user =
        UserChannels.get_by_channel_name(channel.name)
        |> Enum.reject(&(&1.user_port == user.port))

      Message.build(%{
        prefix: build_user_mask(user),
        command: "NOTICE",
        params: [channel.name],
        trailing: message
      })
      |> Messaging.broadcast(channel_users_without_user)
    else
      {:error, :user_channel_not_found} ->
        Message.build(%{
          prefix: :server,
          command: :err_cannotsendtochan,
          params: [user.nick, channel_name],
          trailing: "Cannot send to channel"
        })
        |> Messaging.broadcast(user)

      {:error, :channel_not_found} ->
        Message.build(%{
          prefix: :server,
          command: :err_nosuchchannel,
          params: [user.nick, channel_name],
          trailing: "No such channel"
        })
        |> Messaging.broadcast(user)
    end
  end

  defp handle_user_message(user, receiver_nick, message) do
    case Users.get_by_nick(receiver_nick) do
      {:ok, receiver_user} ->
        Message.build(%{
          prefix: build_user_mask(user),
          command: "NOTICE",
          params: [receiver_nick],
          trailing: message
        })
        |> Messaging.broadcast(receiver_user)

      {:error, _} ->
        Message.build(%{
          prefix: :server,
          command: :err_nosuchnick,
          params: [user.nick, receiver_nick],
          trailing: "No such nick"
        })
        |> Messaging.broadcast(user)
    end
  end
end
