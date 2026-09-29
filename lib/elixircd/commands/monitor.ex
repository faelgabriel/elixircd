defmodule ElixIRCd.Commands.Monitor do
  @moduledoc """
  This module defines the MONITOR command.

  MONITOR allows clients to track when specific nicknames go online or offline.

  Subcommands:
  - `MONITOR + target[,target2]*` - Add targets to monitor list
  - `MONITOR - target[,target2]*` - Remove targets from list
  - `MONITOR C` - Clear entire monitor list
  - `MONITOR L` - List all monitored targets
  - `MONITOR S` - Show current status of all monitored targets
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1, user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserMonitors
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Monitor, as: MonitorUtils

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "MONITOR"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, message) do
    if MonitorUtils.enabled?() do
      handle_enabled(user, message)
    else
      %Message{command: :err_unknowncommand, params: [user_reply(user), "MONITOR"], trailing: "Unknown command"}
      |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec handle_enabled(User.t(), Message.t()) :: :ok
  defp handle_enabled(user, %{command: "MONITOR", params: []}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "MONITOR"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp handle_enabled(user, %{command: "MONITOR", params: ["+" | targets]}) do
    handle_add(user, targets)
  end

  defp handle_enabled(user, %{command: "MONITOR", params: ["-" | targets]}) do
    handle_remove(user, targets)
  end

  defp handle_enabled(user, %{command: "MONITOR", params: ["+" <> targets_str]}) do
    targets = String.split(targets_str, ",", trim: true)
    handle_add(user, targets)
  end

  defp handle_enabled(user, %{command: "MONITOR", params: ["-" <> targets_str]}) do
    targets = String.split(targets_str, ",", trim: true)
    handle_remove(user, targets)
  end

  defp handle_enabled(user, %{command: "MONITOR", params: [subcommand]}) when subcommand in ["C", "c"] do
    handle_clear(user)
  end

  defp handle_enabled(user, %{command: "MONITOR", params: [subcommand]}) when subcommand in ["L", "l"] do
    handle_list(user)
  end

  defp handle_enabled(user, %{command: "MONITOR", params: [subcommand]}) when subcommand in ["S", "s"] do
    handle_status(user)
  end

  defp handle_enabled(user, %{command: "MONITOR", params: _}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "MONITOR"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_add(User.t(), [String.t()]) :: :ok
  defp handle_add(user, targets) when is_list(targets) do
    # Duplicates still get status replies but consume no slots and never trigger a false 734.
    deduped_targets =
      targets
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.uniq_by(&CaseMapping.normalize/1)

    fresh_targets = Enum.reject(deduped_targets, &UserMonitors.exists?(user.pid, CaseMapping.normalize(&1)))
    duplicate_targets = deduped_targets -- fresh_targets

    max_targets = get_max_targets()
    current_count = UserMonitors.count_by_user_pid(user.pid)

    {to_add, overflow} =
      if max_targets > 0 do
        available = max(0, max_targets - current_count)
        Enum.split(fresh_targets, available)
      else
        {fresh_targets, []}
      end

    {online_targets, offline_targets} = add_targets(user, to_add ++ duplicate_targets)

    if online_targets != [] do
      online_str = Enum.join(online_targets, ",")

      %Message{command: :rpl_mononline, params: [user.nick], trailing: online_str}
      |> Dispatcher.broadcast(:server, user)
    end

    if offline_targets != [] do
      offline_str = Enum.join(offline_targets, ",")

      %Message{command: :rpl_monoffline, params: [user.nick], trailing: offline_str}
      |> Dispatcher.broadcast(:server, user)
    end

    if overflow != [] do
      overflow_str = Enum.join(overflow, ",")

      %Message{
        command: :err_monlistfull,
        params: [user.nick, "#{max_targets}", overflow_str],
        trailing: "Monitor list is full."
      }
      |> Dispatcher.broadcast(:server, user)
    end

    :ok
  end

  @spec add_targets(User.t(), [String.t()]) :: {[String.t()], [String.t()]}
  defp add_targets(user, targets) do
    Enum.reduce(targets, {[], []}, fn target, acc ->
      process_target_addition(user, target, acc)
    end)
  end

  defp process_target_addition(user, target, {online_acc, offline_acc}) do
    target_nick_key = CaseMapping.normalize(target)

    unless UserMonitors.exists?(user.pid, target_nick_key) do
      UserMonitors.create(%{user_pid: user.pid, target_nick_key: target_nick_key, target_nick: target})
    end

    case target_mask(target) do
      {:ok, mask} -> {[mask | online_acc], offline_acc}
      :error -> {online_acc, [target | offline_acc]}
    end
  end

  @spec handle_remove(User.t(), [String.t()]) :: :ok
  defp handle_remove(user, targets) when is_list(targets) do
    targets_list =
      targets
      |> Enum.flat_map(&String.split(&1, ",", trim: true))

    Enum.each(targets_list, fn target ->
      target_nick_key = CaseMapping.normalize(target)
      UserMonitors.delete(user.pid, target_nick_key)
    end)

    :ok
  end

  @spec handle_clear(User.t()) :: :ok
  defp handle_clear(user) do
    UserMonitors.delete_by_user_pid(user.pid)
    :ok
  end

  @spec handle_list(User.t()) :: :ok
  defp handle_list(user) do
    monitors = UserMonitors.get_by_user_pid(user.pid)

    if monitors != [] do
      targets_str =
        monitors
        |> Enum.map_join(",", & &1.target_nick)

      %Message{command: :rpl_monlist, params: [user.nick], trailing: targets_str}
      |> Dispatcher.broadcast(:server, user)
    end

    %Message{command: :rpl_endofmonlist, params: [user.nick], trailing: "End of MONITOR list"}
    |> Dispatcher.broadcast(:server, user)

    :ok
  end

  @spec handle_status(User.t()) :: :ok
  defp handle_status(user) do
    monitors = UserMonitors.get_by_user_pid(user.pid)

    {online, offline} =
      Enum.reduce(monitors, {[], []}, fn monitor, {online_acc, offline_acc} ->
        case target_mask(monitor.target_nick_key) do
          {:ok, mask} -> {[mask | online_acc], offline_acc}
          :error -> {online_acc, [monitor.target_nick | offline_acc]}
        end
      end)

    if online != [] do
      online_str = Enum.join(online, ",")

      %Message{command: :rpl_mononline, params: [user.nick], trailing: online_str}
      |> Dispatcher.broadcast(:server, user)
    end

    if offline != [] do
      offline_str = Enum.join(offline, ",")

      %Message{command: :rpl_monoffline, params: [user.nick], trailing: offline_str}
      |> Dispatcher.broadcast(:server, user)
    end

    :ok
  end

  defp target_mask(nick) do
    case Users.get_by_nick(nick) do
      {:ok, user} ->
        {:ok, user_mask(user)}

      {:error, :user_not_found} ->
        case Directory.get_by_nick(nick) do
          {:ok, remote} -> {:ok, remote.user |> UserPayload.public_view() |> user_mask()}
          :error -> :error
        end
    end
  end

  @spec get_max_targets() :: non_neg_integer()
  defp get_max_targets do
    Application.fetch_env!(:elixircd, :monitor)
    |> Keyword.fetch!(:max_targets)
  end
end
