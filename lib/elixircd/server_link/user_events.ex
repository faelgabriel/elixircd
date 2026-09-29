defmodule ElixIRCd.ServerLink.UserEvents do
  @moduledoc "Delivers committed remote nickname, away and disconnect events to local clients."

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserAcceptRemotes
  alias ElixIRCd.Repositories.UserMonitors
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelEvents
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Monitor
  alias ElixIRCd.Utils.Protocol

  @doc "Emits visible NICK, AWAY or QUIT messages after a remote user event commits."
  @spec deliver(map(), map(), map(), map()) :: :ok
  def deliver(%{"type" => "user_upsert", "origin" => origin, "user" => %{"uid" => uid}}, previous, current, views) do
    with {:ok, new_user} <- Map.fetch(current.users, {origin, uid}) do
      case Map.fetch(previous.users, {origin, uid}) do
        {:ok, old_user} ->
          deliver_nick(old_user, new_user, origin, uid, views)
          deliver_away(old_user, new_user, origin, uid, views)

        :error ->
          notify_monitor_online(new_user)
      end
    end

    :ok
  end

  def deliver(%{"type" => "snapshot_end", "origin" => origin}, previous, current, views) do
    Enum.each(previous.users, fn
      {{^origin, uid} = identity, old_user} ->
        with {:ok, new_user} <- Map.fetch(current.users, identity) do
          deliver_nick(old_user, new_user, origin, uid, views)
          deliver_away(old_user, new_user, origin, uid, views)
        end

      _other ->
        :ok
    end)

    Enum.each(current.users, fn
      {{^origin, _uid} = identity, new_user} ->
        unless Map.has_key?(previous.users, identity), do: notify_monitor_online(new_user)

      _other ->
        :ok
    end)

    :ok
  end

  def deliver(%{"type" => "user_remove", "origin" => origin, "uid" => uid}, previous, _current, views) do
    with {:ok, old_user} <- Map.fetch(previous.users, {origin, uid}) do
      deliver_quit(old_user, origin, uid, views, "Client Quit")
    end

    :ok
  end

  def deliver(_frame, _previous, _current, _views), do: :ok

  @doc "Emits QUIT for users removed by a resynchronized snapshot or lost route."
  @spec deliver_departures(map(), map(), map(), String.t()) :: :ok
  def deliver_departures(previous, current, views, reason) do
    Enum.each(previous.users, fn {{origin, uid} = identity, old_user} ->
      unless Map.has_key?(current.users, identity),
        do: deliver_quit(old_user, origin, uid, views, reason)
    end)

    :ok
  end

  defp deliver_quit(old_user, origin, uid, views, reason) do
    Memento.transaction!(fn -> UserAcceptRemotes.delete_by_identity({origin, uid}) end)
    recipients = ChannelEvents.local_audience(views, origin, uid)

    %Message{command: "QUIT", params: [], trailing: reason, prefix: mask(old_user)}
    |> Dispatcher.broadcast_without_history(nil, recipients)

    notify_monitor_offline(old_user)
  end

  defp deliver_nick(old_user, new_user, origin, uid, views) do
    if old_user["nick"] != new_user["nick"] do
      recipients = ChannelEvents.local_audience(views, origin, uid)

      %Message{command: "NICK", params: [new_user["nick"]], prefix: mask(old_user)}
      |> Dispatcher.broadcast_without_history(nil, recipients)

      if CaseMapping.normalize(old_user["nick"]) != CaseMapping.normalize(new_user["nick"]) do
        notify_monitor_offline(old_user)
        notify_monitor_online(new_user)
      end
    end
  end

  defp deliver_away(old_user, new_user, origin, uid, views) do
    if old_user["away"] != new_user["away"] and Application.fetch_env!(:elixircd, :capabilities)[:away_notify] do
      shared = ChannelEvents.local_audience(views, origin, uid)
      monitored = extended_monitor_watchers(new_user["nick"])

      recipients =
        (shared ++ monitored)
        |> Enum.filter(&("away-notify" in &1.capabilities))
        |> Enum.uniq_by(& &1.pid)

      %Message{command: "AWAY", params: [], trailing: new_user["away"], prefix: mask(new_user)}
      |> Dispatcher.broadcast_without_history(nil, recipients)
    end
  end

  defp extended_monitor_watchers(nick) do
    if Application.fetch_env!(:elixircd, :capabilities)[:extended_monitor] do
      Enum.filter(monitor_watchers(nick), &("extended-monitor" in &1.capabilities))
    else
      []
    end
  end

  defp monitor_watchers(nick) do
    if Monitor.enabled?() do
      Memento.transaction!(fn ->
        nick
        |> CaseMapping.normalize()
        |> UserMonitors.get_by_target_nick_key()
        |> Enum.map(& &1.user_pid)
        |> Users.get_by_pids()
      end)
    else
      []
    end
  end

  defp notify_monitor_online(user) do
    Enum.each(monitor_watchers(user["nick"]), fn watcher ->
      %Message{command: :rpl_mononline, params: [watcher.nick], trailing: mask(user)}
      |> Dispatcher.broadcast_without_history(:server, watcher)
    end)
  end

  defp notify_monitor_offline(user) do
    Enum.each(monitor_watchers(user["nick"]), fn watcher ->
      %Message{command: :rpl_monoffline, params: [watcher.nick], trailing: user["nick"]}
      |> Dispatcher.broadcast_without_history(:server, watcher)
    end)
  end

  defp mask(user), do: user |> UserPayload.public_view() |> Protocol.user_mask()
end
