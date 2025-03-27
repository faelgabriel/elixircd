defmodule ElixIRCd.Command.Join do
  @moduledoc """
  This module defines the JOIN command.
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, channel_name?: 1, channel_operator?: 1, match_user_mask?: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.ChannelBans
  alias ElixIRCd.Repository.ChannelInvites
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @type channel_states :: :created | :existing
  @type mode_error :: :channel_key_invalid | :channel_limit_reached | :user_banned | :user_not_invited

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "JOIN"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "JOIN", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "JOIN"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "JOIN", params: [channel_names | values]}) do
    channel_names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.with_index()
    |> Enum.each(fn {channel_name, index} ->
      join_value = Enum.at(values, index, nil)
      handle_join_channel(user, channel_name, join_value)
    end)
  end

  @spec handle_join_channel(User.t(), String.t(), String.t() | nil) :: :ok
  defp handle_join_channel(user, channel_name, join_value) do
    with :ok <- validate_channel_name(channel_name),
         {channel_state, channel} <- get_or_create_channel(channel_name),
         :ok <- check_modes(channel_state, channel, user, join_value) do
      user_channel =
        UserChannels.create(%{
          user_pid: user.pid,
          user_transport: user.transport,
          channel_name: channel.name,
          modes: determine_user_channel_modes(channel_state)
        })

      send_join_channel(user, channel, user_channel)
    else
      {:error, error} -> send_join_channel_error(error, user, channel_name)
    end
  end

  @spec get_or_create_channel(String.t()) :: {channel_states(), Channel.t()}
  defp get_or_create_channel(channel_name) do
    Channels.get_by_name(channel_name)
    |> case do
      {:ok, channel} ->
        {:existing, channel}

      _ ->
        channel = Channels.create(%{name: channel_name, topic: nil})
        {:created, channel}
    end
  end

  @spec determine_user_channel_modes(channel_states()) :: [String.t()]
  defp determine_user_channel_modes(:created), do: ["o"]
  defp determine_user_channel_modes(:existing), do: []

  @spec send_join_channel(User.t(), Channel.t(), UserChannel.t()) :: :ok
  defp send_join_channel(user, channel, user_channel) do
    user_channels = UserChannels.get_by_channel_name(channel.name)

    Message.build(%{
      prefix: user_mask(user),
      command: "JOIN",
      params: [channel.name]
    })
    |> Dispatcher.broadcast(user_channels)

    if channel_operator?(user_channel) do
      Message.build(%{
        prefix: :server,
        command: "MODE",
        params: [channel.name, "+o", user.nick]
      })
      |> Dispatcher.broadcast(user_channels)
    end

    {topic_reply, topic_trailing} =
      case channel.topic do
        nil -> {:rpl_notopic, "No topic is set"}
        %{text: topic_text} -> {:rpl_topic, topic_text}
      end

    [
      Message.build(%{
        prefix: :server,
        command: topic_reply,
        params: [user.nick, channel.name],
        trailing: topic_trailing
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_namreply,
        params: ["=", user.nick, channel.name],
        trailing: get_user_channels_nicks(user_channels)
      }),
      Message.build(%{
        prefix: :server,
        command: :rpl_endofnames,
        params: [user.nick, channel.name],
        trailing: "End of NAMES list."
      })
    ]
    |> Dispatcher.broadcast(user)
  end

  @spec send_join_channel_error(mode_error() | String.t(), User.t(), String.t()) :: :ok
  defp send_join_channel_error(:channel_key_invalid, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_badchannelkey,
      params: [user.nick, channel_name],
      trailing: "Cannot join channel (+k) - bad key"
    })
    |> Dispatcher.broadcast(user)
  end

  defp send_join_channel_error(:channel_limit_reached, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_channelisfull,
      params: [user.nick, channel_name],
      trailing: "Cannot join channel (+l) - channel is full"
    })
    |> Dispatcher.broadcast(user)
  end

  defp send_join_channel_error(:user_banned, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_bannedfromchan,
      params: [user.nick, channel_name],
      trailing: "Cannot join channel (+b) - you are banned"
    })
    |> Dispatcher.broadcast(user)
  end

  defp send_join_channel_error(:user_not_invited, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_inviteonlychan,
      params: [user.nick, channel_name],
      trailing: "Cannot join channel (+i) - you are not invited"
    })
    |> Dispatcher.broadcast(user)
  end

  defp send_join_channel_error(error, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_badchanmask,
      params: [user.nick, channel_name],
      trailing: "Cannot join channel - #{error}"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec validate_channel_name(String.t()) :: :ok | {:error, String.t()}
  defp validate_channel_name(channel_name) do
    cond do
      !channel_name?(channel_name) -> {:error, "channel name must start with a hash mark (#)"}
      !Regex.match?(~r/^#[a-zA-Z0-9_\-]{1,49}$/, channel_name) -> {:error, "invalid channel name format"}
      true -> :ok
    end
  end

  @spec check_modes(channel_states(), Channel.t(), User.t(), String.t() | nil) :: :ok | {:error, mode_error()}
  defp check_modes(:created, _channel, _user, _join_value), do: :ok

  defp check_modes(:existing, channel, user, join_value) do
    with :ok <- check_user_banned(channel, user),
         :ok <- check_user_invited(channel, user),
         :ok <- check_channel_key(channel, user, join_value) do
      check_channel_limit(channel, user)
    end
  end

  @spec check_user_banned(Channel.t(), User.t()) :: :ok | {:error, :user_banned}
  defp check_user_banned(channel, user) do
    ChannelBans.get_by_channel_name(channel.name)
    |> Enum.any?(&match_user_mask?(user, &1.mask))
    |> case do
      true -> {:error, :user_banned}
      false -> :ok
    end
  end

  @spec check_user_invited(Channel.t(), User.t()) :: :ok | {:error, :user_not_invited}
  defp check_user_invited(channel, user) do
    if "i" in channel.modes do
      ChannelInvites.get_by_user_pid_and_channel_name(user.pid, channel.name)
      |> case do
        {:ok, _channel_invite} -> :ok
        {:error, :channel_invite_not_found} -> {:error, :user_not_invited}
      end
    else
      :ok
    end
  end

  @spec check_channel_key(Channel.t(), User.t(), String.t()) :: :ok | {:error, :channel_key_invalid}
  defp check_channel_key(channel, _user, key) do
    channel.modes
    |> Enum.find_value(fn
      {"k", value} -> value
      _ -> nil
    end)
    |> case do
      nil -> :ok
      channel_key when channel_key == key -> :ok
      _ -> {:error, :channel_key_invalid}
    end
  end

  @spec check_channel_limit(Channel.t(), User.t()) :: :ok | {:error, :channel_limit_reached}
  defp check_channel_limit(channel, _user) do
    channel.modes
    |> Enum.find_value(fn
      {"l", value} -> String.to_integer(value)
      _ -> nil
    end)
    |> case do
      nil ->
        :ok

      channel_limit ->
        case UserChannels.count_users_by_channel_name(channel.name) do
          channel_count when channel_count >= channel_limit -> {:error, :channel_limit_reached}
          _ -> :ok
        end
    end
  end

  @spec get_user_channels_nicks([UserChannel.t()]) :: String.t()
  defp get_user_channels_nicks(user_channels) do
    users_by_pid =
      Enum.map(user_channels, & &1.user_pid)
      |> Users.get_by_pids()
      |> Map.new(fn user -> {user.pid, user} end)

    user_channels
    |> Enum.map(fn user_channel ->
      user = Map.get(users_by_pid, user_channel.user_pid)
      {user, user_channel}
    end)
    |> Enum.sort_by(fn {_user, user_channel} -> user_channel.created_at end, :desc)
    |> Enum.map_join(" ", fn {user, user_channel} ->
      user_mode_symbol(user_channel) <> user.nick
    end)
  end

  @spec user_mode_symbol(UserChannel.t()) :: String.t()
  defp user_mode_symbol(%UserChannel{modes: modes}) do
    cond do
      Enum.member?(modes, "o") -> "@"
      Enum.member?(modes, "v") -> "+"
      true -> ""
    end
  end
end
