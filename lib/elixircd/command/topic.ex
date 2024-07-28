defmodule ElixIRCd.Command.Topic do
  @moduledoc """
  This module defines the TOPIC command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [get_user_mask: 1]

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @type topic_errors :: :channel_not_found | :user_channel_not_found | :user_is_not_operator

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "TOPIC"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "TOPIC", params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "TOPIC"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "TOPIC", params: [channel_name | _rest], trailing: nil}) do
    Channels.get_by_name(channel_name)
    |> case do
      {:ok, channel} ->
        send_channel_topic(channel, user)

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

  @impl true
  def handle(user, %{command: "TOPIC", params: [channel_name | _rest], trailing: new_topic_text}) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_port_and_channel_name(user.port, channel.name),
         :ok <- check_user_permission(channel, user_channel) do
      updated_channel = Channels.update(channel, %{topic: normalize_topic(new_topic_text, user)})
      user_channels = UserChannels.get_by_channel_name(channel.name)

      send_channel_topic_change(updated_channel, user, user_channels)
    else
      {:error, error} -> send_channel_topic_error(error, user, channel_name)
    end
  end

  @spec check_user_permission(Channel.t(), UserChannel.t()) :: :ok | {:error, :user_is_not_operator}
  defp check_user_permission(channel, user_channel) do
    if "t" in channel.modes and "o" not in user_channel.modes do
      {:error, :user_is_not_operator}
    else
      :ok
    end
  end

  @spec normalize_topic(String.t(), User.t()) :: Channel.Topic.t() | nil
  defp normalize_topic("", _user), do: nil

  defp normalize_topic(new_topic_text, user) do
    %Channel.Topic{
      text: new_topic_text,
      setter: get_user_mask(user),
      set_at: DateTime.utc_now()
    }
  end

  @spec send_channel_topic(Channel.t(), User.t()) :: :ok
  defp send_channel_topic(%{topic: topic} = channel, user) when topic == nil do
    Message.build(%{
      prefix: :server,
      command: :rpl_notopic,
      params: [user.nick, channel.name],
      trailing: "No topic is set"
    })
    |> Messaging.broadcast(user)
  end

  defp send_channel_topic(%{topic: %{text: topic_text}} = channel, user) do
    [
      Message.build(%{
        prefix: :server,
        command: :rpl_topic,
        params: [user.nick, channel.name],
        trailing: topic_text
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_topicwhotime,
        params: [user.nick, channel.name, channel.topic.setter, DateTime.to_unix(channel.topic.set_at)]
      })
    ]
    |> Messaging.broadcast(user)
  end

  @spec send_channel_topic_change(Channel.t(), User.t(), [UserChannel.t()]) :: :ok
  defp send_channel_topic_change(%{topic: topic} = channel, user, to_user_channels) do
    topic_text =
      case topic do
        nil -> ""
        %{text: topic_text} -> topic_text
      end

    Message.build(%{
      prefix: get_user_mask(user),
      command: "TOPIC",
      params: [channel.name],
      trailing: topic_text
    })
    |> Messaging.broadcast(to_user_channels)
  end

  @spec send_channel_topic_error(topic_errors(), User.t(), String.t()) :: :ok
  defp send_channel_topic_error(:channel_not_found, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchchannel,
      params: [user.nick, channel_name],
      trailing: "No such channel"
    })
    |> Messaging.broadcast(user)
  end

  defp send_channel_topic_error(:user_channel_not_found, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_notonchannel,
      params: [user.nick, channel_name],
      trailing: "You're not on that channel"
    })
    |> Messaging.broadcast(user)
  end

  defp send_channel_topic_error(:user_is_not_operator, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_chanoprivsneeded,
      params: [user.nick, channel_name],
      trailing: "You're not a channel operator"
    })
    |> Messaging.broadcast(user)
  end
end
