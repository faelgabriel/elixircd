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
  def enabled?, do: Keyword.get(Application.get_env(:elixircd, :monitor, []), :enabled, false)

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
