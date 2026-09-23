defmodule ElixIRCd.Server.S2S.QueryEndpoint do
  @moduledoc """
  Authority-local adapter for the finite native query method.

  Queries use a transient caller context and return structured C2S items. The
  dispatch table is fixed at compile time; peer input never selects a module or
  MFA.
  """

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Schema
  alias ElixIRCd.Server.S2S.ServiceEndpoint
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

  @handlers %{
    "ADMIN" => ElixIRCd.Commands.Admin,
    "INFO" => ElixIRCd.Commands.Info,
    "MOTD" => ElixIRCd.Commands.Motd,
    "STATS" => ElixIRCd.Commands.Stats,
    "TIME" => ElixIRCd.Commands.Time,
    "TRACE" => ElixIRCd.Commands.Trace,
    "VERSION" => ElixIRCd.Commands.Version,
    "WHOWAS" => ElixIRCd.Commands.Whowas
  }

  @doc "Executes one finite query against the local daemon projection."
  @spec execute(map(), map(), map()) :: {:ok, map() | {:stream, [map()]}} | {:error, String.t(), String.t()}
  def execute(
        %{
          "actor" => %{"user" => uid},
          "args" => %{"command" => command, "params" => params, "target_uid" => target_uid, "view" => view}
        },
        runtime,
        _context
      )
      when is_binary(uid) and is_binary(command) and is_list(params) do
    with {:ok, caller} <- ServiceEndpoint.caller_user(runtime, uid),
         {:ok, normalized} <- query_command(command),
         :ok <- binary_params(params),
         {:ok, result} <- execute_query(normalized, params, target_uid, view, caller, runtime) do
      {:ok, result}
    else
      {:error, status, message} -> {:error, status, message}
    end
  end

  def execute(
        %{
          "actor" => %{"server" => server_sid},
          "args" => %{"command" => command, "params" => params, "target_uid" => target_uid, "view" => view}
        },
        runtime,
        _context
      )
      when is_binary(server_sid) and is_binary(command) and is_list(params) do
    with {:ok, normalized} <- query_command(command),
         :ok <- binary_params(params),
         caller <- server_caller(runtime, server_sid),
         {:ok, result} <- execute_query(normalized, params, target_uid, view, caller, runtime) do
      {:ok, result}
    else
      {:error, status, message} -> {:error, status, message}
    end
  end

  def execute(_frame, _runtime, _context), do: {:error, "UNSUPPORTED", "query is not enabled"}

  defp query_command(command) do
    normalized = String.upcase(command)

    if Map.has_key?(@handlers, normalized) or normalized == "WHOIS",
      do: {:ok, normalized},
      else: {:error, "UNSUPPORTED", "query command is not enabled"}
  end

  defp server_caller(runtime, server_sid) do
    User.new(%{
      uid: Identity.uid(),
      pid: nil,
      home_sid: server_sid,
      home_boot: runtime.boot,
      effective_nick: "*",
      nick: "*",
      transport: :tls,
      ip_address: {0, 0, 0, 0},
      port_connected: 0,
      hostname: "server",
      cloaked_hostname: "server",
      ident: "server",
      realname: "server",
      registered: true,
      capabilities: [],
      identified_as: nil,
      sasl_authenticated: false,
      last_activity: div(System.system_time(:millisecond), 1_000),
      created_at: DateTime.utc_now()
    })
  end

  defp binary_params(params) do
    if Enum.all?(params, &(is_binary(&1) or match?(%{"b64" => _}, &1))),
      do: :ok,
      else: {:error, "REJECTED", "query parameters must be text"}
  end

  defp execute_query("WHOIS", _params, target_uid, "owner_detail", _caller, runtime)
       when is_binary(target_uid) do
    case runtime.users[target_uid] do
      %{} = target ->
        {:ok,
         %{
           "items" => [],
           "result" => %{
             "uid" => target_uid,
             "signon_ms" => target["signon_ms"],
             "idle_ms" => nil,
             "secure_client" => target["secure_client"] == true
           }
         }}

      _ ->
        {:error, "NOT_FOUND", "target user is unavailable"}
    end
  end

  defp execute_query(_command, _params, _target_uid, "owner_detail", _caller, _runtime),
    do: {:error, "UNSUPPORTED", "owner detail is only available for WHOIS"}

  defp execute_query("WHOIS", params, target_uid, _view, caller, runtime) do
    target = resolve_target(runtime, target_uid, params)
    {:ok, stream_payload(whois_items(caller, target, runtime))}
  end

  defp execute_query(command, params, _target_uid, _view, caller, runtime) do
    handler = Map.fetch!(@handlers, command)

    case dispatch(handler, caller, command, params, runtime.sid) do
      {:ok, items} -> {:ok, stream_payload(items)}
      {:error, status, message} -> {:error, status, message}
    end
  end

  defp dispatch(handler, caller, command, params, source_sid) do
    key = {__MODULE__, make_ref()}
    Process.put(key, [])

    result =
      Dispatcher.with_s2s_sink(
        fn %Message{} = message -> Process.put(key, [message | Process.get(key, [])]) end,
        fn ->
          Output.transaction(
            fn -> handler.handle(caller, %Message{command: command, params: decode_params(params)}) end,
            drain_fun: &Dispatcher.drain_intent/1
          )
        end
      )

    messages = Process.get(key, []) |> Enum.reverse()
    Process.delete(key)

    case result do
      :ok ->
        items = Enum.map(messages, &reply_item(&1, source_sid))

        if Enum.all?(items, &(Schema.validate_reply_item(&1) == :ok)),
          do: {:ok, items},
          else: {:error, "REJECTED", "query produced an invalid reply"}

      _ ->
        {:error, "REJECTED", "query failed"}
    end
  end

  defp resolve_target(runtime, target_uid, _params) when is_binary(target_uid), do: runtime.users[target_uid]

  defp resolve_target(runtime, _target_uid, [target | _]) when is_binary(target) do
    case_mapping = Map.get(runtime, :case_mapping, :rfc1459)
    normalized = CaseMapping.normalize(target, case_mapping)

    Enum.find_value(runtime.users, fn {uid, projection} ->
      nick = projection["effective_nick"] || projection["requested_nick"]

      if is_binary(nick) and CaseMapping.normalize(nick, case_mapping) == normalized,
        do: Map.put(projection, "uid", uid)
    end)
  end

  defp resolve_target(_runtime, _target_uid, _params), do: nil

  defp whois_items(caller, nil, runtime) do
    [
      reply_item(%Message{command: "401", params: [caller.nick, "*"], trailing: "No such nick"}, runtime.sid),
      reply_item(%Message{command: "318", params: [caller.nick, "*"], trailing: "End of /WHOIS list."}, runtime.sid)
    ]
  end

  defp whois_items(caller, target, runtime) do
    nick = target["effective_nick"] || target["requested_nick"] || target["uid"]
    ident = target["ident"] || "unknown"
    host = target["displayhost"] || target["realhost"] || "unknown"
    server_name = get_in(runtime.nodes, [target["home"]["sid"], "name"]) || target["home"]["sid"]
    realname = target["realname"] || ""

    messages = [
      %Message{command: "311", params: [caller.nick, nick, ident, host, "*"], trailing: realname},
      %Message{command: "312", params: [caller.nick, nick, server_name], trailing: "ElixIRCd"},
      %Message{command: "318", params: [caller.nick, nick], trailing: "End of /WHOIS list."}
    ]

    messages
    |> Enum.map(&reply_item(&1, runtime.sid))
    |> maybe_add_account_item(caller, target, runtime.sid)
  end

  defp maybe_add_account_item(items, caller, %{"binding" => %{"account_id" => _}} = target, source_sid) do
    account = target["effective_nick"] || target["requested_nick"] || "*"

    List.insert_at(
      items,
      length(items) - 1,
      reply_item(%Message{command: "330", params: [caller.nick, account, account]}, source_sid)
    )
  end

  defp maybe_add_account_item(items, _caller, _target, _source_sid), do: items

  defp reply_item(%Message{} = message, source_sid) do
    %{
      "command" => Message.command_name(message.command),
      "params" => message.params,
      "trailing" => message.trailing,
      "source" => %{"server" => source_sid},
      "tags" => message.tags
    }
  end

  defp stream_payload([]), do: %{"items" => [], "result" => nil}

  defp stream_payload(items) do
    {:stream, Enum.map(Enum.chunk_every(items, 256), &%{"items" => &1, "result" => nil})}
  end

  defp decode_params(params), do: Enum.map(params, &decode_bytes/1)

  defp decode_bytes(value) when is_binary(value), do: value

  defp decode_bytes(%{"b64" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, decoded} -> decoded
      :error -> ""
    end
  end

  defp decode_bytes(_value), do: ""
end
