defmodule ElixIRCd.Commands.Part do
  @moduledoc """
  This module defines the PART command.

  PART allows users to leave one or more channels.
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Utils.MessageFilter, only: [filter_auditorium_users: 3]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "PART"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "PART", params: []}) do
    %Message{command: :err_needmoreparams, params: [user.nick, "PART"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
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
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name) do
      user_channels =
        UserChannels.get_by_channel_name(channel.name)
        |> filter_auditorium_users(user_channel, channel.modes)

      UserChannels.delete(user_channel)

      # Delete the channel if there are no other users
      if user_channels == [user_channel] do
        ChannelInvites.delete_by_channel_name(channel_name)
        Channels.delete(channel)
      end

      user_pids = Enum.map(user_channels, & &1.user_pid)
      users = Users.get_by_pids(user_pids)

      %Message{command: "PART", params: [channel.name], trailing: part_message}
      |> Dispatcher.broadcast(user, users)
    else
      {:error, :user_channel_not_found} ->
        %Message{command: :err_notonchannel, params: [user.nick, channel_name], trailing: "You're not on that channel"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :channel_not_found} ->
        %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
        |> Dispatcher.broadcast(:server, user)
    end
  end
end
