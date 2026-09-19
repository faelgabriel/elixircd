defmodule ElixIRCd.Commands.Rehash do
  @moduledoc """
  This module defines the REHASH command.

  REHASH reloads the server configuration. Only IRC operators can use this command.
  """

  @behaviour ElixIRCd.Command

  require Logger

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1, user_reply: 1]
  import ElixIRCd.Utils.System, only: [load_configurations: 0]

  alias ElixIRCd.Commands.Cap
  alias ElixIRCd.Config.Error
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserMonitors
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Isupport
  alias ElixIRCd.Utils.Monitor

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "REHASH"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "REHASH", params: [server_name | _]}) do
    local_hostname = Application.fetch_env!(:elixircd, :server)[:hostname]

    cond do
      not irc_operator?(user) ->
        noprivileges_message(user)

      String.downcase(server_name) == String.downcase(local_hostname) ->
        process_rehashing(user)

      true ->
        %Message{command: :err_nosuchserver, params: [user.nick, server_name], trailing: "No such server"}
        |> Dispatcher.broadcast(:server, user)
    end
  end

  @impl true
  def handle(user, %{command: "REHASH"}) do
    case irc_operator?(user) do
      true -> process_rehashing(user)
      false -> noprivileges_message(user)
    end
  end

  @spec process_rehashing(User.t()) :: :ok
  defp process_rehashing(user) do
    %Message{command: :rpl_rehashing, params: [user.nick, "elixircd.exs"], trailing: "Rehashing"}
    |> Dispatcher.broadcast(:server, user)

    old_features = Isupport.feature_tokens()
    monitor_was_enabled = Monitor.enabled?()
    old_caps = Application.fetch_env!(:elixircd, :capabilities)
    old_sts = Application.fetch_env!(:elixircd, :sts)
    old_capability_maps = Map.new(Users.get_all(), &{&1.pid, Cap.capability_map(&1)})

    case reload_configurations() do
      :ok -> complete_rehashing(user, old_features, monitor_was_enabled, old_caps, old_sts, old_capability_maps)
      :error -> configuration_error(user)
      {:error, error} -> configuration_error(user, error)
    end
  end

  @spec reload_configurations() :: :ok | :error | {:error, Error.t()}
  defp reload_configurations do
    load_configurations()
  rescue
    error in Error ->
      Logger.error("Failed to reload configuration during REHASH:\n" <> Exception.message(error))
      {:error, error}

    # Configuration evaluation can fail with file, syntax or runtime errors. Keep this boundary around loading, without
    # masking notification failures.
    error ->
      Logger.error("Failed to reload configuration during REHASH:\n" <> Exception.format(:error, error, __STACKTRACE__))
      :error
  end

  @spec configuration_error(User.t()) :: :ok
  defp configuration_error(user) do
    description = "Could not reload configuration. Check config/elixircd.exs and try again."

    reply = %StandardReply{type: :fail, command: "REHASH", code: "CONFIG_BAD", description: description}
    fallback = %Message{command: "NOTICE", params: [user.nick], trailing: description}

    Dispatcher.broadcast_standard_reply(reply, :server, user, fallback)
  end

  @spec configuration_error(User.t(), Error.t()) :: :ok
  defp configuration_error(user, error) do
    configuration_error(user)

    error.errors
    |> Enum.take(5)
    |> Enum.each(fn detail ->
      description = detail |> String.replace(~r/[\r\n\x00]/, " ") |> String.slice(0, 300)

      %Message{command: "NOTICE", params: [user.nick], trailing: description}
      |> Dispatcher.broadcast(:server, user)
    end)
  end

  @spec complete_rehashing(User.t(), [String.t()], boolean(), keyword(), keyword(), map()) :: :ok
  defp complete_rehashing(user, old_features, monitor_was_enabled, old_caps, old_sts, old_capability_maps) do
    description = "Rehashing completed"
    reply = %StandardReply{type: :note, command: "REHASH", code: "REHASH_COMPLETE", description: description}
    fallback = %Message{command: "NOTICE", params: [user.nick], trailing: description}

    Dispatcher.broadcast_standard_reply(reply, :server, user, fallback)

    # Finish the logical response under the negotiated capabilities before
    # announcing their removal. CAP DEL must never interrupt an open batch.
    ResponseContext.flush(user)
    notify_sts_changes(old_caps, old_sts)
    notify_capability_changes(old_capability_maps)
    clear_disabled_monitor_lists(monitor_was_enabled)
    Isupport.notify_changes(old_features)
  end

  @spec clear_disabled_monitor_lists(boolean()) :: :ok
  defp clear_disabled_monitor_lists(was_enabled) do
    if was_enabled and not Monitor.enabled?() do
      Users.get_all()
      |> Enum.each(&UserMonitors.delete_by_user_pid(&1.pid))
    end

    :ok
  end

  @spec noprivileges_message(User.t()) :: :ok
  defp noprivileges_message(user) do
    %Message{command: :err_noprivileges, params: [user.nick], trailing: "Permission Denied- You're not an IRC operator"}
    |> Dispatcher.broadcast(:server, user)
  end

  # Per the IRCv3 STS spec, servers MAY announce STS policy changes with CAP
  # NEW but MUST NOT send CAP DEL for sts (policy removal is communicated via
  # the duration key instead, and clients must ignore such DEL attempts).
  @del_excluded_capabilities ["sts"]

  @spec notify_capability_changes(map()) :: :ok
  defp notify_capability_changes(old_capability_maps) do
    Users.get_all()
    |> Enum.each(fn user ->
      old_map = Map.get(old_capability_maps, user.pid, %{})
      new_map = Cap.capability_map(user)

      changed =
        new_map
        |> Enum.filter(fn {name, value} -> name not in @del_excluded_capabilities and old_map[name] != value end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      removed =
        old_map
        |> Map.keys()
        |> Enum.reject(&(Map.has_key?(new_map, &1) or &1 in @del_excluded_capabilities))

      removed = if user.cap_version >= 302, do: List.delete(removed, "cap-notify"), else: removed

      removed =
        removed
        |> Enum.sort()

      if has_cap_notify?(user) and changed != [] do
        %Message{command: "CAP", params: [user_reply(user), "NEW"], trailing: Enum.join(changed, " ")}
        |> Dispatcher.broadcast(:server, user)
      end

      if has_cap_notify?(user) and removed != [] do
        %Message{command: "CAP", params: [user_reply(user), "DEL"], trailing: Enum.join(removed, " ")}
        |> Dispatcher.broadcast(:server, user)
      end

      removed_from_session = if has_cap_notify?(user), do: removed, else: List.delete(removed, "account-notify")
      remove_deleted_capabilities(user, Enum.join(removed_from_session, " "))
    end)

    :ok
  end

  @spec notify_sts_changes(keyword(), keyword()) :: :ok
  defp notify_sts_changes(old_caps, old_sts) do
    new_caps = Application.fetch_env!(:elixircd, :capabilities)
    new_sts = Application.fetch_env!(:elixircd, :sts)

    Users.get_all()
    |> Enum.filter(&(has_cap_notify?(&1) and &1.cap_version >= 302))
    |> Enum.each(&notify_sts_change(&1, old_caps, old_sts, new_caps, new_sts))
  end

  @spec notify_sts_change(User.t(), keyword(), keyword(), keyword(), keyword()) :: :ok
  defp notify_sts_change(user, old_caps, old_sts, new_caps, new_sts) do
    old_value = sts_value(user, old_caps, old_sts)
    new_value = sts_value(user, new_caps, new_sts)

    value =
      cond do
        old_value == new_value -> nil
        new_value != nil -> new_value
        old_value != nil and user.transport in [:tls, :wss] -> "sts=duration=0"
        true -> nil
      end

    if value != nil do
      %Message{command: "CAP", params: [user_reply(user), "NEW"], trailing: value}
      |> Dispatcher.broadcast(:server, user)
    end

    :ok
  end

  @spec sts_value(User.t(), keyword(), keyword()) :: String.t() | nil
  defp sts_value(user, capabilities, config) do
    if capability_enabled?(capabilities, :sts), do: Cap.build_sts_capability_value(user, config)
  end

  defp capability_enabled?(config, key), do: Keyword.fetch!(config, key)

  @spec has_cap_notify?(User.t()) :: boolean()
  defp has_cap_notify?(user) do
    "cap-notify" in user.capabilities or user.cap_version >= 302
  end

  @spec remove_deleted_capabilities(User.t(), String.t()) :: User.t()
  defp remove_deleted_capabilities(user, capabilities_string) do
    capabilities_to_remove = String.split(capabilities_string)

    new_capabilities =
      user.capabilities
      |> Enum.reject(&(&1 in capabilities_to_remove))

    Users.update(user, %{capabilities: new_capabilities})
  end
end
