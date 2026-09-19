defmodule ElixIRCd.Utils.Monitor do
  @moduledoc """
  Utility functions for MONITOR notifications.
  """

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserMonitors
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

  @doc """
  Returns whether nickname monitoring is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.fetch!(Application.fetch_env!(:elixircd, :monitor), :enabled)

  @doc """
  Returns users that should receive a supported presence notification.

  Shared-channel visibility and extended MONITOR subscriptions are merged and
  clients that qualify through both paths are de-duplicated.
  """
  @spec notification_watchers(User.t(), String.t(), boolean()) :: [User.t()]
  def notification_watchers(user, capability, include_self \\ false) do
    shared_watchers = Users.get_in_shared_channels_with_capability(user, capability, include_self)

    extended_watchers =
      if enabled?() and extended_monitor_enabled?() and is_binary(user.nick) and :mnesia.is_transaction() do
        user.nick
        |> CaseMapping.normalize()
        |> UserMonitors.get_by_target_nick_key()
        |> Enum.map(& &1.user_pid)
        |> Users.get_by_pids()
        |> Enum.filter(&(capability in &1.capabilities and "extended-monitor" in &1.capabilities))
      else
        []
      end

    self_watchers =
      if include_self and capability in user.capabilities do
        [user]
      else
        []
      end

    (shared_watchers ++ extended_watchers ++ self_watchers)
    |> Enum.uniq_by(& &1.pid)
  end

  @spec extended_monitor_enabled?() :: boolean()
  defp extended_monitor_enabled? do
    Application.fetch_env!(:elixircd, :capabilities)
    |> Keyword.get(:extended_monitor, false)
  end

  @doc """
  Notifies all users monitoring this nick that the user is now online.
  """
  @spec notify_online(User.t()) :: :ok
  def notify_online(user) do
    if enabled?() do
      nick_key = CaseMapping.normalize(user.nick)
      monitors = UserMonitors.get_by_target_nick_key(nick_key)
      monitoring_users = Users.get_by_pids(Enum.map(monitors, & &1.user_pid))

      user_mask_str = user_mask(user)

      Enum.each(monitoring_users, fn monitoring_user ->
        %Message{command: :rpl_mononline, params: [monitoring_user.nick], trailing: user_mask_str}
        |> Dispatcher.broadcast(:server, monitoring_user)
      end)
    end

    :ok
  end

  @doc """
  Notifies all users monitoring this nick that the user is now offline.
  """
  @spec notify_offline(User.t()) :: :ok
  def notify_offline(user) do
    if enabled?() do
      nick_key = CaseMapping.normalize(user.nick)
      monitors = UserMonitors.get_by_target_nick_key(nick_key)
      monitoring_users = Users.get_by_pids(Enum.map(monitors, & &1.user_pid))

      Enum.each(monitoring_users, fn monitoring_user ->
        %Message{command: :rpl_monoffline, params: [monitoring_user.nick], trailing: user.nick}
        |> Dispatcher.broadcast(:server, monitoring_user)
      end)
    end

    :ok
  end
end
