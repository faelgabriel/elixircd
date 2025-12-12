defmodule ElixIRCd.Commands.Cap do
  @moduledoc """
  This module defines the CAP command.

  CAP handles IRCv3 capability negotiation between client and server.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
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
    "MULTI-PREFIX" => %{
      name: "MULTI-PREFIX",
      description: "Display multiple status prefixes for users in channel responses"
    },
    "SASL" => %{
      name: "SASL",
      description: "SASL authentication before registration"
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

  @sasl_mechanism_order ["PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512", "EXTERNAL", "OAUTHBEARER"]

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
  defp handle_cap_ls(user) do
    capabilities_list = get_capabilities_list()

    %Message{command: "CAP", params: [user_reply(user), "LS"], trailing: capabilities_list}
    |> Dispatcher.broadcast(:server, user)
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

    if length(nacked) > 0 do
      %Message{command: "CAP", params: [user_reply(user), "NAK"], trailing: capabilities_string}
      |> Dispatcher.broadcast(:server, user)
    else
      updated_user = apply_capability_changes(user, acked)

      %Message{command: "CAP", params: [user_reply(user), "ACK"], trailing: capabilities_string}
      |> Dispatcher.broadcast(:server, updated_user)
    end
  end

  @spec handle_cap_end(User.t()) :: :ok
  defp handle_cap_end(_user) do
    :ok
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
            {:multi_prefix, "MULTI-PREFIX"},
            {:sasl, build_sasl_capability_value()},
            {:setname, "SETNAME"},
            {:msgid, "MSGID"},
            {:server_time, "SERVER-TIME"},
            {:message_tags, "MESSAGE-TAGS"},
            {:extended_uhlist, "EXTENDED-UHLIST"},
            {:extended_names, "UHNAMES"}
          ],
          Keyword.get(capabilities_config, config_key, false) do
        name
      end

    Enum.join(capabilities, " ")
  end

  @spec build_sasl_capability_value() :: String.t()
  defp build_sasl_capability_value do
    sasl_config = Application.get_env(:elixircd, :sasl, [])

    mechanisms =
      []
      |> add_plain_mechanism(sasl_config)
      |> add_scram_mechanisms(sasl_config)
      |> add_external_mechanism(sasl_config)
      |> add_oauthbearer_mechanism(sasl_config)

    format_sasl_capability(mechanisms)
  end

  defp add_plain_mechanism(mechanisms, sasl_config) do
    if Keyword.get(sasl_config[:plain] || [], :enabled, true) do
      ["PLAIN" | mechanisms]
    else
      mechanisms
    end
  end

  defp add_scram_mechanisms(mechanisms, sasl_config) do
    if Keyword.get(sasl_config[:scram] || [], :enabled, true) do
      scram_algos = Keyword.get(sasl_config[:scram] || [], :algorithms, ["SHA-256", "SHA-512"])
      scram_mechs = Enum.map(scram_algos, fn algo -> "SCRAM-#{algo}" end)
      scram_mechs ++ mechanisms
    else
      mechanisms
    end
  end

  defp add_external_mechanism(mechanisms, sasl_config) do
    if Keyword.get(sasl_config[:external] || [], :enabled, false) do
      ["EXTERNAL" | mechanisms]
    else
      mechanisms
    end
  end

  defp add_oauthbearer_mechanism(mechanisms, sasl_config) do
    if Keyword.get(sasl_config[:oauthbearer] || [], :enabled, false) do
      ["OAUTHBEARER" | mechanisms]
    else
      mechanisms
    end
  end

  defp format_sasl_capability([]), do: "SASL"

  defp format_sasl_capability(mechanisms) do
    mechanisms_str =
      mechanisms
      |> Enum.uniq()
      |> Enum.sort_by(&mechanism_order/1)
      |> Enum.join(",")

    "SASL=#{mechanisms_str}"
  end

  defp mechanism_order(mechanism) do
    Enum.find_index(@sasl_mechanism_order, &(&1 == mechanism)) || 999
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
