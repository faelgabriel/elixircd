defmodule ElixIRCd.Command.Part do
  @moduledoc """
  This module defines the PART command.
  """

  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  require Logger

  @behaviour ElixIRCd.Command.Behavior

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "PART"}) do
    Message.new(%{source: :server, command: :rpl_notregistered, params: ["*"], body: "You have not registered"})
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PART", params: [channel_name], body: part_message}) do
    with {:ok, channel} <- Contexts.Channel.get_by_name(channel_name),
         {:ok, user_channel} <- Contexts.UserChannel.get_by_user_and_channel(user, channel) do
      part_message(user_channel.user, user_channel.channel, part_message)
      {:ok, _deleted_user_channel} = Contexts.UserChannel.delete(user_channel)
    else
      {:error, "UserChannel not found"} ->
        Message.new(%{
          source: :server,
          command: :err_notonchannel,
          params: [user.nick, channel_name],
          body: "You're not on that channel"
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

      error ->
        Logger.error("Error leaving channel #{channel_name}: #{inspect(error)}")
    end

    :ok
  end

  @impl true
  def handle(user, %{command: "PART"}) do
    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user.nick, "PART"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end

  @doc """
  Sends a message to all users in the channel that the user has left.
  """
  @spec part_message(Schemas.User.t(), Schemas.Channel.t(), String.t()) :: :ok
  def part_message(user, channel, part_message) do
    channel_users = Contexts.UserChannel.get_by_channel(channel) |> Enum.map(& &1.user)

    Message.new(%{
      source: user.identity,
      command: "PART",
      params: [channel.name],
      body: part_message
    })
    |> Server.send_message(channel_users)
  end
end
