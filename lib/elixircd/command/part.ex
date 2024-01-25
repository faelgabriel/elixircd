defmodule ElixIRCd.Command.Part do
  @moduledoc """
  This module defines the PART command.
  """

  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  require Logger

  @behaviour ElixIRCd.Command

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "PART"}) do
    Message.new(%{source: :server, command: :err_notregistered, params: ["*"], body: "You have not registered"})
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PART", params: []}) do
    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user.nick, "PART"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PART", params: [channel_names], body: part_message}) do
    channel_names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.each(&handle_channel(user, &1, part_message))
  end

  @spec handle_channel(Schemas.User.t(), String.t(), String.t()) :: :ok
  defp handle_channel(user, channel_name, part_message) do
    with {:ok, channel} <- Contexts.Channel.get_by_name(channel_name),
         {:ok, user_channel} <- Contexts.UserChannel.get_by_user_and_channel(user, channel) do
      part_message(user_channel.user, user_channel.channel, part_message)
      Contexts.UserChannel.delete(user_channel)
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
    end

    :ok
  end

  @spec part_message(Schemas.User.t(), Schemas.Channel.t(), String.t()) :: :ok
  defp part_message(user, channel, part_message) do
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
