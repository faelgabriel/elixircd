defmodule ElixIRCd.Commands.Part do
  @moduledoc """
  This module defines the PART command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(%{identity: nil} = user, %{command: "PART"}) do
    MessageBuilder.server_message(:rpl_notregistered, ["*"], "You have not registered")
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PART", body: part_message, params: [channel_name]}) do
    %Schemas.Channel{} = channel = Contexts.Channel.get_by_name(channel_name)
    %Schemas.UserChannel{} = user_channel = Contexts.UserChannel.get_by_user_and_channel(user, channel)

    part_message(user_channel.user, user_channel.channel, part_message)

    {:ok, _deleted_user_channel} = Contexts.UserChannel.delete(user_channel)

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
    channel = channel |> Repo.preload(user_channels: :user)
    channel_users = channel.user_channels |> Enum.map(& &1.user)

    MessageBuilder.user_message(user.identity, "PART", [channel.name], part_message)
    |> Messaging.send_message(channel_users)
  end
end
