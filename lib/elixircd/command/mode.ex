defmodule ElixIRCd.Command.Mode do
  @moduledoc """
  This module defines the Mode command.


  User Modes:
  i - Invisible mode. The user does not appear in the channel lists of channels they are in.
    Set: MODE <nick> +i
    Unset: MODE <nick> -i
  w - Wallops. Allows the user to receive "wallops" messages (global messages from IRC operators).
    Set: MODE <nick> +w
    Unset: MODE <nick> -w
  o - IRC operator. Indicates that the user is a server operator.
    Granted by the server to IRC operators and cannot be set by users themselves.
  Z - Secure connection. Indicates the user is connected via SSL.
    Granted by the server to users connected via SSL and cannot be set by users themselves.

  User Channel Modes:
  o - Operator. The user has operator privileges in the channel.
    Set: MODE <channel> +o <nick>
    Unset: MODE <channel> -o <nick>
  v - Voice. The user can speak in moderated channels.
    Set: MODE <channel> +v <nick>
    Unset: MODE <channel> -v <nick>

  Channel Modes:
  n - No external messages. Prevents users who are not in the channel from sending messages to it.
    Set: MODE <channel> +n
    Unset: MODE <channel> -n
  t - Topic settable by channel operator only. Restricts the ability to change the channel topic to operators.
    Set: MODE <channel> +t
    Unset: MODE <channel> -t
  s - Secret. The channel won't appear in the channel listing.
    Set: MODE <channel> +s
    Unset: MODE <channel> -s
  i - Invite only. Users must be invited to join the channel.
    Set: MODE <channel> +i
    Unset: MODE <channel> -i
  m - Moderated channel. Only users with voice or higher privileges can speak.
    Set: MODE <channel> +m
    Unset: MODE <channel> -m
  p - Private. Similar to secret but may appear differently in different IRC implementations.
    Set: MODE <channel> +p
    Unset: MODE <channel> -p
  k - Key (password) protected. Users must enter the correct key to join.
    Set: MODE <channel> +k <key>
    Unset: MODE <channel> -k
  l - User limit. Sets a limit on the number of users who can join the channel.
    Set: MODE <channel> +l <limit>
    Unset: MODE <channel> -l
  b - Ban mask. Prevents users matching the mask from joining.
    List: MODE <channel> +b
    Set: MODE <channel> +b <mask>
    Unset: MODE <channel> -b <mask>
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [build_user_mask: 1]

  alias ElixIRCd.Command.Mode.ChannelModes
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "MODE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "MODE", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "MODE"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "MODE", params: [target, mode_string | values]}) do
    case Helper.channel_name?(target) do
      true -> handle_channel_mode(user, target, mode_string, values)
      false -> handle_user_mode(user, target, mode_string)
    end
  end

  @impl true
  def handle(user, %{command: "MODE", params: [target]}) do
    case Helper.channel_name?(target) do
      true -> handle_channel_mode(user, target)
      false -> handle_user_mode(user, target)
    end
  end

  @spec handle_channel_mode(User.t(), String.t(), String.t(), list(String.t())) :: :ok
  defp handle_channel_mode(user, channel_name, mode_string, values) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, _user_channel} <- UserChannels.get_by_user_port_and_channel_name(user.port, channel.name) do
      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)
      {applied_modes, updated_channel} = ChannelModes.apply_mode_changes(channel, validated_modes)

      channel_users = UserChannels.get_by_channel_name(updated_channel.name)

      Message.build(%{
        prefix: build_user_mask(user),
        command: "MODE",
        params: [updated_channel.name, ChannelModes.display_mode_changes(applied_modes)]
      })
      |> Messaging.broadcast(channel_users)

      invalid_modes
      |> Enum.each(fn mode ->
        Message.build(%{
          prefix: :server,
          command: :err_unknownmode,
          params: [user.nick, mode],
          trailing: "is unknown mode char to me"
        })
        |> Messaging.broadcast(user)
      end)
    else
      {:error, "UserChannel not found"} ->
        Message.build(%{
          prefix: :server,
          command: :err_notonchannel,
          params: [user.nick, channel_name],
          trailing: "You're not on that channel"
        })
        |> Messaging.broadcast(user)

      {:error, "Channel not found"} ->
        Message.build(%{
          prefix: :server,
          command: :err_nosuchchannel,
          params: [user.nick, channel_name],
          trailing: "No such channel"
        })
        |> Messaging.broadcast(user)
    end
  end

  @spec handle_channel_mode(User.t(), String.t()) :: :ok
  defp handle_channel_mode(user, channel_name) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, _user_channel} <- UserChannels.get_by_user_port_and_channel_name(user.port, channel.name) do
      Message.build(%{
        prefix: build_user_mask(user),
        command: "MODE",
        params: [channel.name, ChannelModes.display_modes(channel.modes)]
      })
      |> Messaging.broadcast(user)
    else
      {:error, "UserChannel not found"} ->
        Message.build(%{
          prefix: :server,
          command: :err_notonchannel,
          params: [user.nick, channel_name],
          trailing: "You're not on that channel"
        })
        |> Messaging.broadcast(user)

      {:error, "Channel not found"} ->
        Message.build(%{
          prefix: :server,
          command: :err_nosuchchannel,
          params: [user.nick, channel_name],
          trailing: "No such channel"
        })
        |> Messaging.broadcast(user)
    end
  end

  defp handle_user_mode(_user, _receiver_nick, _mode_string) do
    # Future
    :ok
  end

  defp handle_user_mode(_user, _receiver_nick) do
    # Future
    :ok
  end
end
