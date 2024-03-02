defmodule ElixIRCd.Command.Join do
  @moduledoc """
  This module defines the JOIN command.
  """

  @behaviour ElixIRCd.Command

  require Logger

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @type channel_states :: :created | :existing

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "JOIN"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "JOIN", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "JOIN"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "JOIN", params: [channel_names]}) do
    channel_names
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.each(&handle_channel(user, &1))
  end

  @spec handle_channel(User.t(), String.t()) :: :ok
  defp handle_channel(user, channel_name) do
    with :ok <- validate_channel_name(channel_name),
         {channel_state, channel} <- get_or_create_channel(channel_name) do
      user_channel =
        UserChannels.create(%{
          user_port: user.port,
          user_socket: user.socket,
          user_transport: user.transport,
          channel_name: channel.name,
          modes: determine_user_channel_modes(channel_state)
        })

      join_channel(user, channel, user_channel)
    else
      {:error, error} ->
        Message.build(%{
          prefix: :server,
          command: :err_cannotjoinchannel,
          params: [user.nick, channel_name],
          trailing: "Cannot join channel: #{error}"
        })
        |> Messaging.broadcast(user)
    end
  end

  @spec get_or_create_channel(String.t()) :: {channel_states(), Channel.t()}
  defp get_or_create_channel(channel_name) do
    Channels.get_by_name(channel_name)
    |> case do
      {:ok, channel} ->
        {:existing, channel}

      _ ->
        # TODO: create without topic set, or put it in a config;
        channel = Channels.create(%{name: channel_name, topic: "Welcome to #{channel_name}."})
        {:created, channel}
    end
  end

  @spec determine_user_channel_modes(channel_states()) :: [tuple()]
  defp determine_user_channel_modes(:created), do: [{:operator, true}]
  defp determine_user_channel_modes(_), do: []

  @spec join_channel(User.t(), Channel.t(), UserChannel.t()) :: :ok
  defp join_channel(user, channel, user_channel) do
    user_channels = UserChannels.get_by_channel_name(channel.name)

    Message.build(%{
      prefix: user.identity,
      command: "JOIN",
      params: [channel.name]
    })
    |> Messaging.broadcast(user_channels)

    if Enum.find(user_channel.modes, fn {mode, _} -> mode == :operator end) do
      Message.build(%{
        prefix: :server,
        command: "MODE",
        params: [channel.name, "+o", user.nick]
      })
      |> Messaging.broadcast(user_channels)
    end

    # TODO: if topic is nil, then the command code should be 331, otherwise 332
    [
      Message.build(%{prefix: :server, command: :rpl_topic, params: [user.nick, channel.name], trailing: channel.topic}),
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
    |> Messaging.broadcast(user)
  end

  @spec validate_channel_name(String.t()) :: :ok | {:error, String.t()}
  defp validate_channel_name(channel_name) do
    name_pattern = ~r/^#[a-zA-Z0-9_\-]{1,49}$/

    cond do
      !String.starts_with?(channel_name, "#") -> {:error, "Channel name must start with a hash mark (#)"}
      !Regex.match?(name_pattern, channel_name) -> {:error, "Invalid channel name format"}
      true -> :ok
    end
  end

  @spec get_user_channels_nicks([UserChannel.t()]) :: String.t()
  defp get_user_channels_nicks(user_channels) do
    users = user_channels |> Enum.map(& &1.user_port) |> Users.get_by_ports()
    users_by_port = Map.new(users, fn user -> {user.port, user} end)

    user_channels
    |> Enum.map(fn user_channel ->
      user = Map.get(users_by_port, user_channel.user_port)
      {user, user_channel.created_at}
    end)
    |> Enum.sort_by(fn {_user, created_at} -> created_at end, :desc)
    |> Enum.map_join(" ", fn {user, _created_at} -> user.nick end)
  end
end
