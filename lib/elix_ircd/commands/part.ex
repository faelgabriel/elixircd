defmodule ElixIRCd.Commands.Part do
  @moduledoc """
  This module defines the PART command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageBuilder

  require Logger

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "PART"}) do
    MessageBuilder.server_message(:rpl_notregistered, ["*"], "You have not registered")
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PART", params: [channel_name], body: part_message}) do
    with {:ok, channel} <- Contexts.Channel.get_by_name(channel_name),
         {:ok, user_channel} <- Contexts.UserChannel.get_by_user_and_channel(user, channel) do
      part_message(user_channel.user, user_channel.channel, part_message)
      {:ok, _deleted_user_channel} = Contexts.UserChannel.delete(user_channel)
    else
      {:error, "UserChannel not found"} ->
        MessageBuilder.server_message(:err_notonchannel, [user.nick, channel_name], "You're not on that channel")
        |> Messaging.send_message(user)

      {:error, "Channel not found"} ->
        MessageBuilder.server_message(:err_nosuchchannel, [user.nick, channel_name], "No such channel")
        |> Messaging.send_message(user)

      error ->
        Logger.error("Error leaving channel #{channel_name}: #{inspect(error)}")
    end

    :ok
  end

  @impl true
  def handle(user, %{command: "PART"}) do
    MessageBuilder.server_message(:rpl_needmoreparams, [user.nick, "PART"], "Not enough parameters")
    |> Messaging.send_message(user)
  end

  @doc """
  Sends a message to all users in the channel that the user has left.
  """
  @spec part_message(Schemas.User.t(), Schemas.Channel.t(), String.t()) :: :ok
  def part_message(user, channel, part_message) do
    channel_users = Contexts.UserChannel.get_by_channel(channel) |> Enum.map(& &1.user)

    MessageBuilder.user_message(user.identity, "PART", [channel.name], part_message)
    |> Messaging.send_message(channel_users)
  end
end
