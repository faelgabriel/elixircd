defmodule ElixIRCd.Command.Part do
  @moduledoc """
  This module defines the PART command.
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Helper, only: [build_user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "PART"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "PART", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "PART"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "PART", params: [channel_names], trailing: part_message}) do
    channel_names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.each(&handle_channel(user, &1, part_message))
  end

  @spec handle_channel(User.t(), String.t(), String.t()) :: :ok
  defp handle_channel(user, channel_name, part_message) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_port_and_channel_name(user.port, channel.name) do
      channel_users = UserChannels.get_by_channel_name(channel.name)
      UserChannels.delete(user_channel)
      # Future: Delete channel if the channel is not registered and has no users

      Message.build(%{
        prefix: build_user_mask(user),
        command: "PART",
        params: [channel.name],
        trailing: part_message
      })
      |> Messaging.broadcast(channel_users)
    else
      {:error, :user_channel_not_found} ->
        Message.build(%{
          prefix: :server,
          command: :err_notonchannel,
          params: [user.nick, channel_name],
          trailing: "You're not on that channel"
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
end
