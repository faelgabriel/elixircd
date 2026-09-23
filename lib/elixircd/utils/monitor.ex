defmodule ElixIRCd.Utils.Monitor do
  @moduledoc """
  Utility functions for MONITOR notifications.
  """

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserMonitors
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.ServiceEndpoint
  alias ElixIRCd.Server.S2S.View
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
      monitoring_users = monitoring_users(user.nick)

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
      monitoring_users = monitoring_users(user.nick)

      Enum.each(monitoring_users, fn monitoring_user ->
        %Message{command: :rpl_monoffline, params: [monitoring_user.nick], trailing: user.nick}
        |> Dispatcher.broadcast(:server, monitoring_user)
      end)
    end

    :ok
  end

  @doc "Notifies local MONITOR subscribers for a user present only in S2S state."
  @spec notify_online_projection(map(), map()) :: :ok
  def notify_online_projection(projection, runtime) when is_map(projection) and is_map(runtime) do
    if enabled?() do
      case ServiceEndpoint.caller_user(runtime, projection["uid"]) do
        {:ok, user} -> notify_online(user)
        _ -> :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  @doc "Notifies local MONITOR subscribers for a user leaving S2S state."
  @spec notify_offline_projection(map(), map()) :: :ok
  def notify_offline_projection(projection, runtime) when is_map(projection) and is_map(runtime) do
    if enabled?() do
      user = ServiceEndpoint.user_from_projection(projection, runtime)
      notify_offline(user)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  @doc "Notifies local MONITOR subscribers when the logical ChanServ endpoint changes reachability."
  @spec notify_service_presence_change(map(), map()) :: :ok
  def notify_service_presence_change(previous_runtime, runtime)
      when is_map(previous_runtime) and is_map(runtime) do
    if enabled?(), do: service_presence_transition(previous_runtime, runtime), else: :ok
  rescue
    _ -> :ok
  end

  defp service_presence_transition(previous_runtime, runtime) do
    case {View.services_ready?(previous_runtime), View.services_ready?(runtime)} do
      {false, true} -> notify_service_online(runtime)
      {true, false} -> notify_service_offline(previous_runtime)
      _ -> :ok
    end
  end

  defp notify_service_online(runtime) do
    case View.chanserv_user(runtime) do
      {:ok, service} -> notify_online(service)
      _ -> :ok
    end
  end

  defp notify_service_offline(runtime) do
    case View.chanserv_user(runtime) do
      {:ok, service} -> notify_offline(service)
      _ -> :ok
    end
  end

  defp monitoring_users(nick) when is_binary(nick) do
    read_monitoring_users(CaseMapping.normalize(nick))
  end

  defp monitoring_users(_nick), do: []

  defp read_monitoring_users(nick_key) do
    load = fn ->
      nick_key
      |> UserMonitors.get_by_target_nick_key()
      |> Enum.map(& &1.user_pid)
      |> Users.get_by_pids()
    end

    if :mnesia.is_transaction(), do: load.(), else: Memento.transaction!(load)
  rescue
    _ -> []
  end
end
