defmodule ElixIRCd.Commands.Cap do
  @moduledoc """
  This module defines the CAP command.

  CAP handles IRCv3 capability negotiation between client and server.

  - `CAP LS`: Initiates negotiation, blocks registration until `CAP END`
  - `CAP REQ`: Requests specific capabilities
  - `CAP END`: Finalizes negotiation, allows registration to complete

  During CAP negotiation, the server blocks registration (001) even if NICK and USER
  are provided. This allows SASL authentication before registration completes.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Tables.User

  @supported_capabilities %{
    "ACCOUNT-TAG" => %{
      name: "ACCOUNT-TAG",
      description: "Attach authenticated account name via message tags"
    },
    "ACCOUNT-NOTIFY" => %{
      name: "ACCOUNT-NOTIFY",
      description: "Notify when users identify or logout"
    },
    "AWAY-NOTIFY" => %{
      name: "AWAY-NOTIFY",
      description: "Notify when users set or remove away status"
    },
    "CHGHOST" => %{
      name: "CHGHOST",
      description: "Notify when a user's ident or hostname changes"
    },
    "CLIENT-TAGS" => %{
      name: "CLIENT-TAGS",
      description: "Allow vendor-specific client-only tags from clients"
    },
    "EXTENDED-JOIN" => %{
      name: "EXTENDED-JOIN",
      description: "Extended JOIN messages including account name and real name"
    },
    "INVITE-EXTENDED" => %{
      name: "INVITE-EXTENDED",
      description: "Extended INVITE messages including account information"
    },
    "INVITE-NOTIFY" => %{
      name: "INVITE-NOTIFY",
      description: "Notify channel members when users are invited"
    },
    "MULTI-PREFIX" => %{
      name: "MULTI-PREFIX",
      description: "Display multiple status prefixes for users in channel responses"
    },
    "SASL" => %{
      name: "SASL",
      description: "Display multiple status prefixes for users in channel responses"
    },
    "SETNAME" => %{
      name: "SETNAME",
      description: "Allow clients to change their real name during the session"
    },
    "UHNAMES" => %{
      name: "UHNAMES",
      description: "Extended NAMES reply with full user@host format"
    },
    "EXTENDED-UHLIST" => %{
      name: "EXTENDED-UHLIST",
      description: "Extended user modes in WHO replies"
    },
    "MESSAGE-TAGS" => %{
      name: "MESSAGE-TAGS",
      description: "Support for IRCv3 message tags including bot tag"
    },
    "SERVER-TIME" => %{
      name: "SERVER-TIME",
      description: "Attach server-generated time= message tags"
    },
    "MSGID" => %{
      name: "MSGID",
      description: "Attach unique msgid= message tags"
    }
  }

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "CAP", params: params, trailing: trailing}) do
    handle_cap_command(user, params, trailing)
  end

  @spec handle_cap_command(User.t(), [String.t()], String.t() | nil) :: :ok
  defp handle_cap_command(user, ["LS"], _trailing), do: handle_cap_ls(user)
  defp handle_cap_command(user, ["LS", _version], _trailing), do: handle_cap_ls(user)
  defp handle_cap_command(user, ["LIST"], _trailing), do: handle_cap_list(user)
  defp handle_cap_command(user, ["REQ", capabilities_string], _trailing), do: handle_cap_req(user, capabilities_string)
  defp handle_cap_command(user, ["REQ"], capabilities_string), do: handle_cap_req(user, capabilities_string)
  defp handle_cap_command(user, ["END"], _trailing), do: handle_cap_end(user)

  defp handle_cap_command(user, params, _trailing) do
    %Message{
      command: "CAP",
      params: [user_reply(user), "NAK"],
      trailing: "Unsupported CAP command: #{Enum.join(params, " ")}"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_cap_ls(User.t()) :: :ok
  defp handle_cap_ls(%{cap_negotiating: true} = user) do
    capabilities_list = get_capabilities_list()

    %Message{command: "CAP", params: [user_reply(user), "LS"], trailing: capabilities_list}
    |> Dispatcher.broadcast(:server, user)
  end

  defp handle_cap_ls(user) do
    updated_user = Users.update(user, %{cap_negotiating: true})
    capabilities_list = get_capabilities_list()

    %Message{command: "CAP", params: [user_reply(updated_user), "LS"], trailing: capabilities_list}
    |> Dispatcher.broadcast(:server, updated_user)
  end

  @spec handle_cap_list(User.t()) :: :ok
  defp handle_cap_list(user) do
    enabled_caps = Enum.join(user.capabilities, " ")

    %Message{command: "CAP", params: [user_reply(user), "LIST"], trailing: enabled_caps}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_cap_req(User.t(), String.t()) :: :ok
  defp handle_cap_req(user, capabilities_string) do
    capabilities = parse_capabilities_request(capabilities_string)
    {acked, nacked} = validate_capabilities(capabilities)

    case nacked do
      [] ->
        updated_user = apply_capability_changes(user, acked)

        %Message{command: "CAP", params: [user_reply(user), "ACK"], trailing: capabilities_string}
        |> Dispatcher.broadcast(:server, updated_user)

      _ ->
        %Message{command: "CAP", params: [user_reply(user), "NAK"], trailing: capabilities_string}
        |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec handle_cap_end(User.t()) :: :ok
  defp handle_cap_end(user) do
    updated_user = Users.update(user, %{cap_negotiating: false})
    Handshake.handle(updated_user)
  end

  @spec get_capabilities_list() :: String.t()
  defp get_capabilities_list do
    capabilities_config = Application.get_env(:elixircd, :capabilities, [])

    capabilities =
      for {config_key, name} <- [
            {:account_tag, "ACCOUNT-TAG"},
            {:account_notify, "ACCOUNT-NOTIFY"},
            {:away_notify, "AWAY-NOTIFY"},
            {:chghost, "CHGHOST"},
            {:client_tags, "CLIENT-TAGS"},
            {:extended_join, "EXTENDED-JOIN"},
            {:invite_extended, "INVITE-EXTENDED"},
            {:invite_notify, "INVITE-NOTIFY"},
            {:multi_prefix, "MULTI-PREFIX"},
            {:sasl, build_sasl_capability_value()},
            {:setname, "SETNAME"},
            {:msgid, "MSGID"},
            {:server_time, "SERVER-TIME"},
            {:message_tags, "MESSAGE-TAGS"},
            {:extended_uhlist, "EXTENDED-UHLIST"},
            {:extended_names, "UHNAMES"}
          ],
          Keyword.get(capabilities_config, config_key, false) and name != nil do
        name
      end

    Enum.join(capabilities, " ")
  end

  @spec build_sasl_capability_value() :: String.t() | nil
  defp build_sasl_capability_value do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    mechanisms = get_enabled_sasl_mechanisms(sasl_config)

    case mechanisms do
      [] -> nil
      mechs -> "SASL=#{Enum.join(mechs, ",")}"
    end
  end

  @spec get_enabled_sasl_mechanisms(keyword()) :: [String.t()]
  defp get_enabled_sasl_mechanisms(sasl_config) do
    []
    |> maybe_add_mechanism(sasl_config[:plain], "PLAIN")
  end

  @spec maybe_add_mechanism([String.t()], keyword() | nil, String.t()) :: [String.t()]
  defp maybe_add_mechanism(mechanisms, nil, mechanism_name) do
    mechanisms ++ [mechanism_name]
  end

  defp maybe_add_mechanism(mechanisms, config, mechanism_name) do
    if Keyword.get(config, :enabled, true) do
      mechanisms ++ [mechanism_name]
    else
      mechanisms
    end
  end

  @spec parse_capabilities_request(String.t()) :: [%{action: :enable | :disable, name: String.t()}]
  defp parse_capabilities_request(capabilities_string) do
    capabilities_string
    |> String.split()
    |> Enum.map(&parse_single_capability/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec parse_single_capability(String.t()) :: %{action: :enable | :disable, name: String.t()} | nil
  defp parse_single_capability("-" <> capability) do
    %{action: :disable, name: String.upcase(capability)}
  end

  defp parse_single_capability(capability) do
    %{action: :enable, name: String.upcase(capability)}
  end

  @spec validate_capabilities([%{action: :enable | :disable, name: String.t()}]) ::
          {[%{action: :enable | :disable, name: String.t()}], [String.t()]}
  defp validate_capabilities(capabilities) do
    Enum.split_with(capabilities, fn cap ->
      Map.has_key?(@supported_capabilities, cap.name)
    end)
  end

  @spec apply_capability_changes(User.t(), [%{action: :enable | :disable, name: String.t()}]) :: User.t()
  defp apply_capability_changes(user, capabilities) do
    new_capabilities =
      Enum.reduce(capabilities, user.capabilities, fn cap, acc ->
        apply_capability_change(cap, acc)
      end)

    Users.update(user, %{capabilities: new_capabilities})
  end

  @spec apply_capability_change(%{action: :enable | :disable, name: String.t()}, [String.t()]) :: [String.t()]
  defp apply_capability_change(%{action: :enable, name: name}, acc) do
    if name in acc, do: acc, else: [name | acc]
  end

  defp apply_capability_change(%{action: :disable, name: name}, acc) do
    List.delete(acc, name)
  end
end
