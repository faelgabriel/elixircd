defmodule ElixIRCd.Commands.Part do
  @moduledoc """
  This module defines the PART command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Handlers.MessageHandler
  alias ElixIRCd.Repo
  alias ElixIRCd.Schemas

  @behaviour ElixIRCd.Behaviors.Command

  @impl true
  def handle(user, %{command: "PART", body: part_message, params: [channel_name]}) when user.identity != nil do
    %Schemas.Channel{} = channel = Contexts.Channel.get_by_name(channel_name)
    %Schemas.UserChannel{} = user_channel = Contexts.UserChannel.get_by_user_and_channel(user, channel)

    part_message(user_channel.user, user_channel.channel, part_message)

    {:ok, _deleted_user_channel} = Contexts.UserChannel.delete(user_channel)

    :ok
  end

  @impl true
  def handle(user, %{command: "PART"}) when user.identity != nil do
    MessageHandler.message_not_enough_params(user, "PART")
  end

  @impl true
  def handle(user, %{command: "PART"}) do
    MessageHandler.message_not_registered(user)
  end

  @doc """
  Sends a message to all users in the channel that the user has left.
  """
  @spec part_message(Schemas.User.t(), Schemas.Channel.t(), String.t()) :: :ok
  def part_message(user, channel, part_message) do
    channel = channel |> Repo.preload(user_channels: :user)
    channel_users = channel.user_channels |> Enum.map(& &1.user)

    MessageHandler.broadcast(channel_users, "#{user.identity} PART #{channel.name} #{part_message}")
    MessageHandler.send_message(user, :server, "PART :#{channel.name}")
  end
end
