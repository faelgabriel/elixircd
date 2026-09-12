defmodule ElixIRCd.Commands.Rehash do
  @moduledoc """
  This module defines the REHASH command.

  REHASH reloads the server configuration. Only IRC operators can use this command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1, user_reply: 1]
  import ElixIRCd.Utils.System, only: [load_configurations: 0]

  alias ElixIRCd.Commands.Cap
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserMonitors
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Isupport
  alias ElixIRCd.Utils.Monitor

  @cap_mappings [
    {:account_tag, "account-tag"},
    {:account_notify, "account-notify"},
    {:away_notify, "away-notify"},
    {:batch, "batch"},
    {:cap_notify, "cap-notify"},
    {:chghost, "chghost"},
    {:echo_message, "echo-message"},
    {:extended_join, "extended-join"},
    {:invite_notify, "invite-notify"},
    {:labeled_response, "labeled-response"},
    {:multi_prefix, "multi-prefix"},
    {:sasl, "sasl"},
    {:setname, "setname"},
    {:extended_names, "userhost-in-names"},
    {:message_tags, "message-tags"},
    {:server_time, "server-time"},
    {:sts, "sts"}
  ]

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "REHASH"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
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
    old_caps = Application.get_env(:elixircd, :capabilities, [])
    load_configurations()
    new_caps = Application.get_env(:elixircd, :capabilities, [])

    %Message{command: "NOTICE", params: [user.nick], trailing: "Rehashing completed"}
    |> Dispatcher.broadcast(:server, user)

    # Finish the logical response under the negotiated capabilities before
    # announcing their removal. CAP DEL must never interrupt an open batch.
    ResponseContext.flush(user)
    notify_config_changes(old_caps, new_caps)
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

  @spec notify_config_changes(keyword(), keyword()) :: :ok
  defp notify_config_changes(old_caps, new_caps) do
    enabled_keys =
      @cap_mappings
      |> Enum.filter(fn {key, _name} ->
        old_value = capability_enabled?(old_caps, key)
        new_value = capability_enabled?(new_caps, key)
        !old_value and new_value
      end)
      |> Enum.map(fn {key, _name} -> key end)

    disabled_caps =
      @cap_mappings
      |> Enum.filter(fn {key, _name} ->
        old_value = capability_enabled?(old_caps, key)
        new_value = capability_enabled?(new_caps, key)
        old_value and !new_value
      end)
      |> Enum.map(fn {_key, name} -> name end)
      |> Enum.reject(&(&1 in @del_excluded_capabilities))

    if enabled_keys != [] do
      notify_new(enabled_keys)
    end

    if disabled_caps != [] do
      notify_del(Enum.join(disabled_caps, " "))
    end

    :ok
  end

  @spec capability_enabled?(keyword(), atom()) :: boolean()
  defp capability_enabled?(config, :labeled_response) do
    Keyword.get(config, :batch, false) and Keyword.get(config, :labeled_response, false)
  end

  defp capability_enabled?(config, key), do: Keyword.get(config, key, false)

  @spec notify_new([atom()]) :: :ok
  defp notify_new(enabled_keys) when is_list(enabled_keys) do
    Users.get_all()
    |> Enum.filter(&has_cap_notify?/1)
    |> Enum.each(fn user ->
      user_caps =
        enabled_keys
        |> Enum.map(&capability_value_for_user(&1, user))
        |> Enum.reject(&is_nil/1)

      if user_caps != [] do
        %Message{
          command: "CAP",
          params: [user_reply(user), "NEW"],
          trailing: Enum.join(user_caps, " ")
        }
        |> Dispatcher.broadcast(:server, user)
      end
    end)
  end

  @spec capability_value_for_user(atom(), User.t()) :: String.t() | nil
  defp capability_value_for_user(:sts, user), do: Cap.build_sts_capability_value(user)

  defp capability_value_for_user(key, _user) do
    Enum.find_value(@cap_mappings, fn {k, name} -> if k == key, do: name end)
  end

  @spec notify_del(String.t()) :: :ok
  defp notify_del(capabilities) when is_binary(capabilities) do
    Users.get_all()
    |> Enum.each(fn user ->
      if has_cap_notify?(user) do
        %Message{
          command: "CAP",
          params: [user_reply(user), "DEL"],
          trailing: capabilities
        }
        |> Dispatcher.broadcast(:server, user)
      end

      remove_deleted_capabilities(user, capabilities)
    end)
  end

  @spec has_cap_notify?(User.t()) :: boolean()
  defp has_cap_notify?(user) do
    "cap-notify" in user.capabilities
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
