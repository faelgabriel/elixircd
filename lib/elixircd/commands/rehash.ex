defmodule ElixIRCd.Commands.Rehash do
  @moduledoc """
  This module defines the REHASH command.

  REHASH reloads the server configuration. Only IRC operators can use this command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1, user_reply: 1]
  import ElixIRCd.Utils.System, only: [load_configurations: 0]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @cap_mappings [
    {:account_tag, "account-tag"},
    {:account_notify, "account-notify"},
    {:away_notify, "away-notify"},
    {:cap_notify, "cap-notify"},
    {:chghost, "chghost"},
    {:echo_message, "echo-message"},
    {:extended_join, "extended-join"},
    {:invite_extended, "invite-extended"},
    {:invite_notify, "invite-notify"},
    {:multi_prefix, "multi-prefix"},
    {:sasl, "sasl"},
    {:setname, "setname"},
    {:extended_names, "uhnames"},
    {:extended_uhlist, "extended-uhlist"},
    {:message_tags, "message-tags"},
    {:server_time, "server-time"},
    {:msgid, "msgid"}
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

    old_caps = Application.get_env(:elixircd, :capabilities, [])
    load_configurations()
    new_caps = Application.get_env(:elixircd, :capabilities, [])

    notify_config_changes(old_caps, new_caps)

    %Message{command: "NOTICE", params: [user.nick], trailing: "Rehashing completed"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec noprivileges_message(User.t()) :: :ok
  defp noprivileges_message(user) do
    %Message{command: :err_noprivileges, params: [user.nick], trailing: "Permission Denied- You're not an IRC operator"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec notify_config_changes(keyword(), keyword()) :: :ok
  defp notify_config_changes(old_caps, new_caps) do
    enabled_caps =
      @cap_mappings
      |> Enum.filter(fn {key, _name} ->
        old_value = Keyword.get(old_caps, key, false)
        new_value = Keyword.get(new_caps, key, false)
        !old_value and new_value
      end)
      |> Enum.map(fn {_key, name} -> name end)

    disabled_caps =
      @cap_mappings
      |> Enum.filter(fn {key, _name} ->
        old_value = Keyword.get(old_caps, key, false)
        new_value = Keyword.get(new_caps, key, false)
        old_value and !new_value
      end)
      |> Enum.map(fn {_key, name} -> name end)

    if enabled_caps != [] do
      notify_new(Enum.join(enabled_caps, " "))
    end

    if disabled_caps != [] do
      notify_del(Enum.join(disabled_caps, " "))
    end

    :ok
  end

  @spec notify_new(String.t()) :: :ok
  defp notify_new(capabilities) when is_binary(capabilities) do
    Users.get_all()
    |> Enum.filter(&has_cap_notify?/1)
    |> Enum.each(fn user ->
      %Message{
        command: "CAP",
        params: [user_reply(user), "NEW"],
        trailing: capabilities
      }
      |> Dispatcher.broadcast(:server, user)
    end)
  end

  @spec notify_del(String.t()) :: :ok
  defp notify_del(capabilities) when is_binary(capabilities) do
    Users.get_all()
    |> Enum.filter(&has_cap_notify?/1)
    |> Enum.each(fn user ->
      %Message{
        command: "CAP",
        params: [user_reply(user), "DEL"],
        trailing: capabilities
      }
      |> Dispatcher.broadcast(:server, user)

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
