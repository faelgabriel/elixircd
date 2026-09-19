defmodule ElixIRCd.Server.NickChange do
  @moduledoc """
  Applies an already-authorized nickname change to a registered connection.

  Validation and policy belong to the caller. This module owns the shared
  protocol-visible transition: persistence, channel broadcast, registered-mode
  synchronization, operator notices, and MONITOR notifications.
  """

  import ElixIRCd.Utils.Nickserv, only: [sync_registered_mode: 1]

  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.Snotice
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Monitor

  @doc "Applies an authorized nickname change and returns the updated user."
  @spec change(User.t(), String.t()) :: User.t()
  def change(user, input_nick) do
    old_nick = user.nick
    updated_user = Users.update(user, %{nick: input_nick})

    channel_name_keys = UserChannels.get_by_user_pid(user.pid) |> Enum.map(& &1.channel_name_key)

    Enum.each(channel_name_keys, fn channel_name ->
      History.record_channel_event(%Message{command: "NICK", params: [input_nick]}, user, channel_name)
    end)

    all_channel_user_pids =
      channel_name_keys
      |> UserChannels.get_by_channel_names()
      |> Enum.reject(fn user_channel -> user_channel.user_pid == updated_user.pid end)
      |> Enum.group_by(& &1.user_pid)
      |> Enum.map(fn {_key, user_channels} -> hd(user_channels) end)
      |> Enum.map(& &1.user_pid)

    all_users = Users.get_by_pids(all_channel_user_pids)

    %Message{command: "NICK", params: [input_nick]}
    |> Dispatcher.broadcast(user, [updated_user | all_users])

    updated_user = sync_registered_mode(updated_user)
    send_nick_change_snotice(old_nick, updated_user)

    if CaseMapping.normalize(old_nick) != updated_user.nick_key do
      Monitor.notify_offline(user)
      Monitor.notify_online(updated_user)
    end

    updated_user
  end

  @spec send_nick_change_snotice(String.t(), User.t()) :: :ok
  defp send_nick_change_snotice(old_nick, user) do
    user_info = Snotice.format_user_info(user)
    Snotice.broadcast(:nick, "Nick change: #{old_nick} -> #{user.nick} (#{user_info})")
  end
end
