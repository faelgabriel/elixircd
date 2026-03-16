defmodule ElixIRCd.Services.Chanserv.Topic do
  @moduledoc """
  This module defines the ChanServ TOPIC command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Services.Chanserv.Channel.Context, as: ChannelContext
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags

  @command_name "TOPIC"
  @chanserv_mask "ChanServ!service@irc.test"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]),
    do: notify(user, "You must be identified with NickServ to use this command.")

  def handle(user, [@command_name, channel_name]) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_use_topic(registered_channel, user.identified_as, access_entries) do
      show_topic(user, registered_channel)
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name, channel_name | topic_parts]) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_use_topic(registered_channel, user.identified_as, access_entries),
         updated_topic <- normalize_topic(topic_parts),
         updated_registered_channel <- RegisteredChannels.update(registered_channel, %{topic: updated_topic}) do
      sync_live_channel(updated_registered_channel.name, updated_topic)
      notify_topic_change(user, updated_registered_channel.name, updated_topic)
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name | _]), do: notify(user, "Syntax: \x02TOPIC <channel> [topic|OFF]\x02")

  @spec show_topic(User.t(), RegisteredChannel.t()) :: :ok
  defp show_topic(user, %{name: channel_name, topic: nil}),
    do: notify(user, "No topic is set for \x02#{channel_name}\x02.")

  defp show_topic(user, %{name: channel_name, topic: %{text: text}}),
    do: notify(user, "Topic for \x02#{channel_name}\x02: \x02#{text}\x02")

  @spec normalize_topic([String.t()]) :: Channel.Topic.t() | nil
  defp normalize_topic(["OFF"]), do: nil

  defp normalize_topic(topic_parts) do
    %Channel.Topic{
      text: Enum.join(topic_parts, " "),
      setter: @chanserv_mask,
      set_at: DateTime.utc_now()
    }
  end

  @spec sync_live_channel(String.t(), Channel.Topic.t() | nil) :: :ok
  defp sync_live_channel(channel_name, topic) do
    case Channels.get_by_name(channel_name) do
      {:ok, channel} ->
        updated_channel = Channels.update(channel, %{topic: topic})

        users =
          updated_channel.name
          |> UserChannels.get_by_channel_name()
          |> Enum.map(& &1.user_pid)
          |> Users.get_by_pids()

        %Message{command: "TOPIC", params: [updated_channel.name], trailing: topic_text(topic)}
        |> Dispatcher.broadcast(:chanserv, users)

        :ok

      {:error, :channel_not_found} ->
        :ok
    end
  end

  @spec notify_topic_change(User.t(), String.t(), Channel.Topic.t() | nil) :: :ok
  defp notify_topic_change(user, channel_name, nil),
    do: notify(user, "The topic for \x02#{channel_name}\x02 has been cleared.")

  defp notify_topic_change(user, channel_name, _topic),
    do: notify(user, "The topic for \x02#{channel_name}\x02 has been updated.")

  @spec topic_text(Channel.Topic.t() | nil) :: String.t()
  defp topic_text(nil), do: ""
  defp topic_text(%{text: text}), do: text
end
