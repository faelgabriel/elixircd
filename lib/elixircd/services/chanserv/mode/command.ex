defmodule ElixIRCd.Services.Chanserv.Mode.Command do
  @moduledoc """
  Shared implementation for ChanServ user mode commands.
  """

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.Chanserv.Flags

  @type permission_kind :: :op | :voice
  @type action :: :add | :remove

  @doc false
  @spec handle(User.t(), String.t(), [String.t()], permission_kind(), action()) :: :ok
  def handle(%{identified_as: nil} = user, _command_name, _args, _permission_kind, _action) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, command_name, [channel_name], permission_kind, action) do
    handle(user, command_name, [channel_name, user.nick], permission_kind, action)
  end

  def handle(user, _command_name, [channel_name, target_nick], permission_kind, action) do
    with {:ok, registered_channel} <- RegisteredChannels.get_by_name(channel_name),
         {:ok, channel_users} <- get_channel_users(registered_channel.name),
         access_entries = get_access_entries(registered_channel.name),
         :ok <- check_permission(registered_channel, user.identified_as, access_entries, permission_kind),
         {:ok, target_user} <- Users.get_by_nick(target_nick),
         {:ok, target_user_channel} <-
           UserChannels.get_by_user_pid_and_channel_name(target_user.pid, registered_channel.name),
         :ok <- check_secure_setting(registered_channel, target_user, action),
         :ok <- check_peace_setting(registered_channel, user, target_user, action, access_entries),
         result <- apply_mode(target_user_channel, mode_flag(permission_kind), action) do
      handle_mode_result(user, registered_channel, target_user, channel_users, permission_kind, action, result)
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :channel_not_in_use} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not currently in use.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")

      {:error, :user_not_found} ->
        notify(user, "The nickname \x02#{target_nick}\x02 is not online.")

      {:error, :user_channel_not_found} ->
        notify(user, "\x02#{target_nick}\x02 is not on \x02#{channel_name}\x02.")

      {:error, :target_must_be_identified} ->
        notify(
          user,
          "Channel \x02#{channel_name}\x02 has \x02SECURE\x02 enabled; \x02#{target_nick}\x02 must be identified to receive privileges."
        )

      {:error, :peace_denied} ->
        notify(
          user,
          "Channel \x02#{channel_name}\x02 has \x02PEACE\x02 enabled; you cannot change privileges for that target."
        )
    end
  end

  def handle(user, command_name, _args, _permission_kind, _action) do
    notify(user, "Syntax: \x02#{command_name} <channel> [nickname]\x02")
  end

  @spec get_channel_users(String.t()) :: {:ok, [User.t()]} | {:error, :channel_not_in_use}
  defp get_channel_users(channel_name) do
    case Channels.get_by_name(channel_name) do
      {:ok, channel} ->
        user_pids =
          channel.name
          |> UserChannels.get_by_channel_name()
          |> Enum.map(& &1.user_pid)

        {:ok, Users.get_by_pids(user_pids)}

      {:error, :channel_not_found} ->
        {:error, :channel_not_in_use}
    end
  end

  @spec get_access_entries(String.t()) :: %{optional(String.t()) => String.t()}
  defp get_access_entries(channel_name) do
    channel_name
    |> RegisteredChannelAccesses.get_flags_map_by_channel_name()
    |> Flags.normalize_access_entries()
  end

  @spec check_permission(RegisteredChannel.t(), String.t(), map(), permission_kind()) ::
          :ok | {:error, :access_denied}
  defp check_permission(channel, account_name, access_entries, :op),
    do: Flags.can_use_op(channel, account_name, access_entries)

  defp check_permission(channel, account_name, access_entries, :voice),
    do: Flags.can_use_voice(channel, account_name, access_entries)

  @spec check_secure_setting(RegisteredChannel.t(), User.t(), action()) :: :ok | {:error, :target_must_be_identified}
  defp check_secure_setting(_registered_channel, _target_user, :remove), do: :ok

  defp check_secure_setting(registered_channel, target_user, :add) do
    if registered_channel.settings.secure and is_nil(target_user.identified_as) do
      {:error, :target_must_be_identified}
    else
      :ok
    end
  end

  @spec check_peace_setting(RegisteredChannel.t(), User.t(), User.t(), action(), map()) ::
          :ok | {:error, :peace_denied}
  defp check_peace_setting(_registered_channel, _user, _target_user, :add, _access_entries), do: :ok

  defp check_peace_setting(registered_channel, user, target_user, :remove, access_entries) do
    if peace_denied?(registered_channel, user, target_user, access_entries) do
      {:error, :peace_denied}
    else
      :ok
    end
  end

  @spec peace_denied?(RegisteredChannel.t(), User.t(), User.t(), map()) :: boolean()
  defp peace_denied?(registered_channel, user, target_user, access_entries) do
    registered_channel.settings.peace and
      not is_nil(target_user.identified_as) and
      user.identified_as != target_user.identified_as and
      not Flags.founder?(registered_channel, user.identified_as) and
      Flags.access_rank(registered_channel, target_user.identified_as, access_entries) >=
        Flags.access_rank(registered_channel, user.identified_as, access_entries)
  end

  @spec mode_flag(permission_kind()) :: ModeRegistry.membership_mode()
  defp mode_flag(:op), do: :o
  defp mode_flag(:voice), do: :v

  @spec apply_mode(UserChannel.t(), ModeRegistry.membership_mode(), action()) :: :changed | :unchanged
  defp apply_mode(target_user_channel, mode_flag, :add) do
    if mode_flag in target_user_channel.modes do
      :unchanged
    else
      UserChannels.update(target_user_channel, %{modes: [mode_flag | target_user_channel.modes]})
      :changed
    end
  end

  defp apply_mode(target_user_channel, mode_flag, :remove) do
    if mode_flag in target_user_channel.modes do
      UserChannels.update(target_user_channel, %{modes: List.delete(target_user_channel.modes, mode_flag)})
      :changed
    else
      :unchanged
    end
  end

  @spec handle_mode_result(
          User.t(),
          RegisteredChannel.t(),
          User.t(),
          [User.t()],
          permission_kind(),
          action(),
          :changed | :unchanged
        ) :: :ok
  defp handle_mode_result(user, registered_channel, target_user, channel_users, permission_kind, action, :changed) do
    %Message{
      command: "MODE",
      params: [registered_channel.name, "#{mode_prefix(action)}#{mode_flag(permission_kind)}", target_user.nick]
    }
    |> Dispatcher.broadcast(:chanserv, channel_users)

    notify(user, success_message(target_user.nick, registered_channel.name, permission_kind, action))
  end

  defp handle_mode_result(user, registered_channel, target_user, _channel_users, permission_kind, action, :unchanged) do
    notify(user, unchanged_message(target_user.nick, registered_channel.name, permission_kind, action))
  end

  @spec mode_prefix(action()) :: String.t()
  defp mode_prefix(:add), do: "+"
  defp mode_prefix(:remove), do: "-"

  @spec success_message(String.t(), String.t(), permission_kind(), action()) :: String.t()
  defp success_message(target_nick, channel_name, :op, :add),
    do: "Operator status granted to \x02#{target_nick}\x02 on \x02#{channel_name}\x02."

  defp success_message(target_nick, channel_name, :op, :remove),
    do: "Operator status removed from \x02#{target_nick}\x02 on \x02#{channel_name}\x02."

  defp success_message(target_nick, channel_name, :voice, :add),
    do: "Voice status granted to \x02#{target_nick}\x02 on \x02#{channel_name}\x02."

  defp success_message(target_nick, channel_name, :voice, :remove),
    do: "Voice status removed from \x02#{target_nick}\x02 on \x02#{channel_name}\x02."

  @spec unchanged_message(String.t(), String.t(), permission_kind(), action()) :: String.t()
  defp unchanged_message(target_nick, channel_name, :op, :add),
    do: "\x02#{target_nick}\x02 is already opped on \x02#{channel_name}\x02."

  defp unchanged_message(target_nick, channel_name, :op, :remove),
    do: "\x02#{target_nick}\x02 is not opped on \x02#{channel_name}\x02."

  defp unchanged_message(target_nick, channel_name, :voice, :add),
    do: "\x02#{target_nick}\x02 is already voiced on \x02#{channel_name}\x02."

  defp unchanged_message(target_nick, channel_name, :voice, :remove),
    do: "\x02#{target_nick}\x02 is not voiced on \x02#{channel_name}\x02."
end
