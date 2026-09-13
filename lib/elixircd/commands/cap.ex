defmodule ElixIRCd.Commands.Cap do
  @moduledoc """
  This module defines the CAP command.

  CAP handles IRCv3 capability negotiation between client and server.

  - `CAP LS`: Initiates negotiation, blocks registration until `CAP END`
  - `CAP REQ`: Requests specific capabilities
  - `CAP END`: Finalizes negotiation, allows registration to complete

  During CAP negotiation, the server blocks registration (001) even if NICK and USER
  are provided. This allows SASL authentication before registration completes.

  Capability identifiers are case-sensitive opaque strings. Standard capabilities
  are advertised and stored using their canonical lowercase names.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.Tables.User

  @supported_capabilities %{
    "account-tag" => %{
      name: "account-tag",
      description: "Attach authenticated account name via message tags"
    },
    "account-notify" => %{
      name: "account-notify",
      description: "Notify when users identify or logout"
    },
    "away-notify" => %{
      name: "away-notify",
      description: "Notify when users set or remove away status"
    },
    "batch" => %{
      name: "batch",
      description: "Group related server messages using BATCH and batch tags"
    },
    "cap-notify" => %{
      name: "cap-notify",
      description: "Notify clients when server capabilities change dynamically"
    },
    "chghost" => %{
      name: "chghost",
      description: "Notify when a user's ident or hostname changes"
    },
    "echo-message" => %{
      name: "echo-message",
      description: "Echo accepted PRIVMSG, NOTICE, and TAGMSG commands back to the sender"
    },
    "extended-join" => %{
      name: "extended-join",
      description: "Extended JOIN messages including account name and real name"
    },
    "invite-notify" => %{
      name: "invite-notify",
      description: "Notify channel members when users are invited"
    },
    "multi-prefix" => %{
      name: "multi-prefix",
      description: "Display multiple status prefixes for users in channel responses"
    },
    "sasl" => %{
      name: "sasl",
      description: "Authenticate to services using SASL"
    },
    "setname" => %{
      name: "setname",
      description: "Allow clients to change their real name during the session"
    },
    "standard-replies" => %{
      name: "standard-replies",
      description: "Structured server errors, warnings and informational replies"
    },
    "sts" => %{
      name: "sts",
      description: "Strict Transport Security - automatic TLS upgrade and policy persistence"
    },
    "userhost-in-names" => %{
      name: "userhost-in-names",
      description: "Extended NAMES reply with full nick!user@host masks"
    },
    "message-tags" => %{
      name: "message-tags",
      description: "Support for IRCv3 message tags including bot tag"
    },
    "server-time" => %{
      name: "server-time",
      description: "Attach server-generated time= message tags"
    },
    "labeled-response" => %{
      name: "labeled-response",
      description: "Associate command responses with a client-provided label"
    }
  }

  # Capabilities that are announced via CAP LS but cannot be requested via CAP REQ
  # As per IRCv3 specifications, these capabilities are informational only
  @non_requestable_capabilities ["sts"]

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "CAP", params: params, trailing: trailing}) do
    handle_cap_command(user, params, trailing)
  end

  @spec handle_cap_command(User.t(), [String.t()], String.t() | nil) :: :ok
  defp handle_cap_command(user, ["LS"], _trailing), do: handle_cap_ls(user, 301)

  defp handle_cap_command(user, ["LS", version], _trailing) do
    version =
      case Integer.parse(version) do
        {number, ""} when number >= 302 -> number
        _ -> 301
      end

    handle_cap_ls(user, version)
  end

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

  @spec handle_cap_ls(User.t(), pos_integer()) :: :ok
  defp handle_cap_ls(user, requested_version) do
    version = max(user.cap_version || 301, requested_version)
    capabilities = if version >= 302, do: Enum.uniq(user.capabilities ++ ["cap-notify"]), else: user.capabilities
    updated_user = Users.update(user, %{cap_negotiating: true, cap_version: version, capabilities: capabilities})
    capabilities_list = get_capabilities_list(%{updated_user | cap_version: requested_version})

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
    # IRCv3 forbids completing registration mid-negotiation; REQ must mark the session like LS does.
    user = if user.registered, do: user, else: Users.update(user, %{cap_negotiating: true})

    capabilities = parse_capabilities_request(capabilities_string)
    {acked, nacked} = validate_capabilities(user, capabilities)

    case nacked do
      [] ->
        %Message{command: "CAP", params: [user_reply(user), "ACK"], trailing: capabilities_string}
        |> Dispatcher.broadcast(:server, user)

        # IRCv3 requires the final CAP ACK to be sent before the negotiated set
        # changes. This is also important when disabling batch or
        # labeled-response on a labeled CAP REQ.
        ResponseContext.flush(user)
        apply_capability_changes(user, acked)
        :ok

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

  @spec get_capabilities_list(User.t()) :: String.t()
  defp get_capabilities_list(user) do
    capabilities_config = Application.get_env(:elixircd, :capabilities, [])

    capabilities =
      for {config_key, name} <- [
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
            {:sasl, build_sasl_capability_value()},
            {:setname, "setname"},
            {:standard_replies, "standard-replies"},
            {:sts, build_sts_capability_value(user)},
            {:server_time, "server-time"},
            {:message_tags, "message-tags"},
            {:extended_names, "userhost-in-names"}
          ],
          capability_advertised?(config_key, user, capabilities_config) and name != nil do
        name
      end

    capabilities
    |> Enum.map_join(" ", fn capability ->
      if (user.cap_version || 301) >= 302, do: capability, else: hd(String.split(capability, "=", parts: 2))
    end)
  end

  @spec capability_advertised?(atom(), User.t(), keyword()) :: boolean()
  defp capability_advertised?(:cap_notify, user, config),
    do: (user.cap_version || 301) >= 302 or capability_enabled?(config, :cap_notify)

  defp capability_advertised?(:sts, user, config),
    do: (user.cap_version || 301) >= 302 and capability_enabled?(config, :sts)

  defp capability_advertised?(key, _user, config), do: capability_enabled?(config, key)

  @spec capability_enabled?(keyword(), atom()) :: boolean()
  defp capability_enabled?(config, :labeled_response) do
    Keyword.get(config, :batch, false) and Keyword.get(config, :labeled_response, false)
  end

  defp capability_enabled?(config, key), do: Keyword.get(config, key, false)

  @spec build_sasl_capability_value() :: String.t() | nil
  defp build_sasl_capability_value do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    mechanisms = get_enabled_sasl_mechanisms(sasl_config)

    case mechanisms do
      [] -> nil
      mechs -> "sasl=#{Enum.join(mechs, ",")}"
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

  @doc """
  Builds the STS capability string based on user connection security (port on plaintext, duration on TLS).
  """
  @spec build_sts_capability_value(User.t()) :: String.t() | nil
  @spec build_sts_capability_value(User.t(), keyword()) :: String.t() | nil
  def build_sts_capability_value(user, sts_config \\ Application.get_env(:elixircd, :sts, [])) do
    is_secure = user.transport in [:tls, :wss]

    # On TLS connections: announce duration (and optionally preload)
    # On plaintext connections: announce port for upgrade
    if is_secure do
      build_sts_duration_value(sts_config)
    else
      build_sts_port_value(sts_config)
    end
  end

  @spec build_sts_duration_value(keyword()) :: String.t() | nil
  defp build_sts_duration_value(config) do
    duration = Keyword.get(config, :duration)
    preload = Keyword.get(config, :preload, false)

    case {duration, preload} do
      {0, _} -> "sts=duration=0"
      {d, true} when is_integer(d) and d > 0 -> "sts=duration=#{d},preload"
      {d, false} when is_integer(d) and d > 0 -> "sts=duration=#{d}"
      _ -> nil
    end
  end

  @spec build_sts_port_value(keyword()) :: String.t() | nil
  defp build_sts_port_value(config) do
    case Keyword.get(config, :port) do
      port when is_integer(port) -> "sts=port=#{port}"
      _ -> nil
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
    %{action: :disable, name: capability}
  end

  defp parse_single_capability(capability) do
    %{action: :enable, name: capability}
  end

  @spec validate_capabilities(User.t(), [%{action: :enable | :disable, name: String.t()}]) ::
          {[%{action: :enable | :disable, name: String.t()}], [String.t()]}
  defp validate_capabilities(user, capabilities) do
    available_capabilities =
      user
      |> get_capabilities_list()
      |> String.split()
      |> Enum.map(fn capability -> capability |> String.split("=", parts: 2) |> hd() end)
      |> MapSet.new()

    Enum.split_with(capabilities, fn cap ->
      Map.has_key?(@supported_capabilities, cap.name) and
        (cap.action == :disable or MapSet.member?(available_capabilities, cap.name)) and
        cap.name not in @non_requestable_capabilities and
        not (cap.name == "cap-notify" and cap.action == :disable and (user.cap_version || 301) >= 302)
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
