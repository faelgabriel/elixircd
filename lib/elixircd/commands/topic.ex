defmodule ElixIRCd.Commands.Topic do
  @moduledoc """
  This module defines the TOPIC command.

  TOPIC displays or changes the topic of a channel.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.Chanserv.Flags, as: ChannelFlags

  @type topic_errors ::
          :channel_not_found
          | :topic_locked
          | :user_channel_not_found
          | :user_is_not_operator
          | :topic_too_long

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "TOPIC"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "TOPIC", params: []}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "TOPIC"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "TOPIC", params: [channel_name | _rest], trailing: nil}) do
    Channels.get_by_name(channel_name)
    |> case do
      {:ok, channel} ->
        send_channel_topic(channel, user)

      {:error, :channel_not_found} ->
        %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
        |> Dispatcher.broadcast(:server, user)
    end
  end

  @impl true
  def handle(user, %{command: "TOPIC", params: [channel_name | _rest], trailing: new_topic_text}) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         :ok <- check_user_permission(channel, user, user_channel),
         :ok <- check_topic_length(new_topic_text) do
      updated_topic = normalize_topic(new_topic_text, user)
      updated_channel = Channels.update(channel, %{topic: updated_topic})
      sync_registered_channel_topic(channel.name, updated_topic)
      user_channels = UserChannels.get_by_channel_name(channel.name)

      send_channel_topic_change(updated_channel, user, user_channels)
    else
      {:error, error} -> send_channel_topic_error(error, user, channel_name)
    end
  end

  @spec check_user_permission(Channel.t(), User.t(), UserChannel.t()) ::
          :ok | {:error, :topic_locked | :user_is_not_operator}
  defp check_user_permission(channel, user, user_channel) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, registered_channel} ->
        check_registered_channel_permission(channel, user, user_channel, registered_channel)

      {:error, :registered_channel_not_found} ->
        check_channel_operator_permission(channel, user_channel)
    end
  end

  @spec check_registered_channel_permission(Channel.t(), User.t(), UserChannel.t(), RegisteredChannel.t()) ::
          :ok | {:error, :topic_locked | :user_is_not_operator}
  defp check_registered_channel_permission(
         _channel,
         user,
         _user_channel,
         %{settings: %{topiclock: true}} = registered_channel
       ),
       do: check_topiclock_permission(registered_channel, user)

  defp check_registered_channel_permission(channel, _user, user_channel, _registered_channel),
    do: check_channel_operator_permission(channel, user_channel)

  @spec check_topiclock_permission(RegisteredChannel.t(), User.t()) :: :ok | {:error, :topic_locked}
  defp check_topiclock_permission(registered_channel, user) do
    access_entries =
      registered_channel.name
      |> RegisteredChannelAccesses.get_flags_map_by_channel_name()
      |> ChannelFlags.normalize_access_entries()

    case ChannelFlags.can_use_topic(registered_channel, user.identified_as, access_entries) do
      :ok -> :ok
      {:error, :access_denied} -> {:error, :topic_locked}
    end
  end

  @spec check_channel_operator_permission(Channel.t(), UserChannel.t()) :: :ok | {:error, :user_is_not_operator}
  defp check_channel_operator_permission(channel, user_channel) do
    case {"t" in channel.modes, "o" in user_channel.modes} do
      {true, false} -> {:error, :user_is_not_operator}
      _modes -> :ok
    end
  end

  @spec check_topic_length(String.t()) :: :ok | {:error, :topic_too_long}
  defp check_topic_length(""), do: :ok

  defp check_topic_length(topic_text) do
    max_topic_length = Application.get_env(:elixircd, :channel)[:max_topic_length]

    case String.length(topic_text) > max_topic_length do
      true -> {:error, :topic_too_long}
      false -> :ok
    end
  end

  @spec normalize_topic(String.t(), User.t()) :: Channel.Topic.t() | nil
  defp normalize_topic("", _user), do: nil

  defp normalize_topic(new_topic_text, user) do
    %Channel.Topic{
      text: new_topic_text,
      setter: user_mask(user),
      set_at: DateTime.utc_now()
    }
  end

  @spec send_channel_topic(Channel.t(), User.t()) :: :ok
  defp send_channel_topic(%{topic: topic} = channel, user) when topic == nil do
    %Message{command: :rpl_notopic, params: [user.nick, channel.name], trailing: "No topic is set"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_topic(%{topic: %{text: topic_text}} = channel, user) do
    [
      %Message{command: :rpl_topic, params: [user.nick, channel.name], trailing: topic_text},
      %Message{
        command: :rpl_topicwhotime,
        params: [user.nick, channel.name, channel.topic.setter, DateTime.to_unix(channel.topic.set_at)]
      }
    ]
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_channel_topic_change(Channel.t(), User.t(), [UserChannel.t()]) :: :ok
  defp send_channel_topic_change(%{topic: topic} = channel, user, to_user_channels) do
    user_pids = Enum.map(to_user_channels, & &1.user_pid)
    users = Users.get_by_pids(user_pids)

    %Message{command: "TOPIC", params: [channel.name], trailing: topic_text(topic)}
    |> Dispatcher.broadcast(user, users)
  end

  @spec send_channel_topic_error(topic_errors(), User.t(), String.t()) :: :ok
  defp send_channel_topic_error(:channel_not_found, user, channel_name) do
    %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_topic_error(:user_channel_not_found, user, channel_name) do
    %Message{command: :err_notonchannel, params: [user.nick, channel_name], trailing: "You're not on that channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_topic_error(:topic_locked, user, channel_name) do
    %Message{
      command: :err_chanoprivsneeded,
      params: [user.nick, channel_name],
      trailing: "Topic changes are restricted by ChanServ"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_topic_error(:user_is_not_operator, user, channel_name) do
    %Message{
      command: :err_chanoprivsneeded,
      params: [user.nick, channel_name],
      trailing: "You're not a channel operator"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_topic_error(:topic_too_long, user, _channel_name) do
    max_topic_length = Application.get_env(:elixircd, :channel)[:max_topic_length]

    %Message{
      command: :err_inputtoolong,
      params: [user.nick],
      trailing: "Topic too long (maximum length: #{max_topic_length} characters)"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec sync_registered_channel_topic(String.t(), Channel.Topic.t() | nil) :: :ok
  defp sync_registered_channel_topic(channel_name, topic) do
    case RegisteredChannels.get_by_name(channel_name) do
      {:ok, registered_channel} ->
        RegisteredChannels.update(registered_channel, %{topic: topic})
        :ok

      {:error, :registered_channel_not_found} ->
        :ok
    end
  end

  @spec topic_text(Channel.Topic.t() | nil) :: String.t()
  defp topic_text(nil), do: ""
  defp topic_text(%{text: text}), do: text
end
