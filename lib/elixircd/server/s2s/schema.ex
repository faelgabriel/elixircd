defmodule ElixIRCd.Server.S2S.Schema do
  @moduledoc """
  Closed ENP/1 frame and row validation.

  This module deliberately returns errors instead of normalizing malformed
  input. Normalization belongs to the local domain operation that originated a
  committed change; the network boundary only accepts the finite wire schema.
  """

  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Commands.Mode.ChannelModes
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Policy

  @frame_types ~w(hello sync state message request reply ping pong close)
  @request_methods ~w(query service sasl user_action invite snapshot admin)
  @reply_statuses ~w(OK REJECTED NOT_FOUND STALE UNAVAILABLE UNSUPPORTED BUSY TIMEOUT CANCELLED RESOURCE UNKNOWN_OUTCOME)
  @close_codes ~w(AUTH PROFILE TOPOLOGY FRAME SCHEMA ORIGIN VERSION_CONFLICT DEPENDENCY CLOCK RESOURCE TIMEOUT OPERATOR TRANSPORT INTERNAL)
  @state_kinds ~w(topology.add topology.ready topology.remove merge.begin merge.end merge.abort user.put user.quit memberships.put channel.ensure channel.field channel.list member.status policy.change policy.cache.begin policy.cache.rows policy.cache.end invite.notice)
  @reply_commands ~w(ACCOUNT AWAY BATCH CAP CHGHOST FAIL JOIN KICK MODE NICK NOTICE NOTE PRIVMSG QUIT TOPIC WARN)

  @doc "Validates a decoded ENP JSON frame."
  @spec validate_frame(term()) :: :ok | {:error, atom() | {atom(), term()}}
  def validate_frame(frame) when is_map(frame) do
    case Map.get(frame, "t") do
      type when type in @frame_types -> validate_frame_type(type, frame)
      _ -> {:error, :unknown_frame_type}
    end
  end

  def validate_frame(_frame), do: {:error, :top_level_must_be_object}

  @doc "Validates the closed payload shape used by a request reply."
  @spec validate_reply_payload(String.t(), term()) :: :ok | {:error, term()}
  def validate_reply_payload("OK", %{"items" => items, "result" => _result} = payload) do
    with :ok <- exact(payload, ~w(items result)),
         true <- is_list(items) and length(items) <= 256,
         :ok <- all_ok(items, &validate_reply_item/1) do
      :ok
    else
      _ -> {:error, :invalid_success_payload}
    end
  end

  def validate_reply_payload("OK", %{"sasl" => result, "data" => data, "binding" => binding, "code" => code} = payload) do
    with :ok <- exact(payload, ~w(binding code data sasl)),
         true <- result in ~w(continue success failure aborted),
         true <- is_nil(data) or is_binary(data),
         true <- is_nil(binding) or is_map(binding),
         :ok <- string(code, 64) do
      :ok
    else
      _ -> {:error, :invalid_sasl_reply_payload}
    end
  end

  def validate_reply_payload("OK", %{"snapshot" => "policy", "phase" => phase} = payload)
      when phase in ~w(begin rows end) do
    if map_size(payload) in [3, 5] and
         ((phase == "rows" and Map.keys(payload) |> Enum.sort() == ~w(phase rows snapshot)) or
            (phase in ~w(begin end) and Map.keys(payload) |> Enum.sort() == ~w(epoch objects phase revision snapshot))),
       do: :ok,
       else: {:error, :invalid_policy_snapshot_payload}
  end

  def validate_reply_payload("OK", %{"phase" => phase, "scope" => "channel"} = payload)
      when phase == "begin" do
    if Map.keys(payload) |> Enum.sort() == ~w(channel phase scope), do: :ok, else: {:error, :invalid_snapshot_payload}
  end

  def validate_reply_payload("OK", %{"phase" => "rows", "rows" => rows} = payload) when is_list(rows) do
    if Map.keys(payload) |> Enum.sort() == ~w(phase rows) and length(rows) <= 256,
      do: :ok,
      else: {:error, :invalid_snapshot_payload}
  end

  def validate_reply_payload("OK", %{"phase" => "end", "scope" => "channel"} = payload) do
    if Map.keys(payload) |> Enum.sort() == ~w(exists phase rows scope),
      do: :ok,
      else: {:error, :invalid_snapshot_payload}
  end

  def validate_reply_payload(status, %{"items" => items, "error" => error} = payload)
      when status in @reply_statuses and status != "OK" do
    with :ok <- exact(payload, ~w(items error)),
         true <- is_list(items) and length(items) <= 256,
         :ok <- all_ok(items, &validate_reply_item/1),
         true <- is_map(error),
         :ok <- exact(error, ~w(code message)),
         true <- error["code"] in @reply_statuses,
         :ok <- string(error["message"], 512) do
      :ok
    else
      _ -> {:error, :invalid_error_payload}
    end
  end

  def validate_reply_payload(status, %{"items" => items} = payload)
      when status in @reply_statuses and status != "OK" do
    with :ok <- exact(payload, ~w(items)),
         true <- is_list(items) and length(items) <= 256,
         :ok <- all_ok(items, &validate_reply_item/1) do
      :ok
    else
      _ -> {:error, :invalid_error_items_payload}
    end
  end

  def validate_reply_payload(_status, _payload), do: {:error, :invalid_reply_payload}

  @doc "Validates one structured C2S reply item carried by a request result."
  @spec validate_reply_item(term()) :: :ok | {:error, term()}
  def validate_reply_item(
        %{
          "command" => command,
          "params" => params,
          "trailing" => trailing,
          "source" => source,
          "tags" => tags
        } = item
      ) do
    with :ok <- exact(item, ~w(command params source tags trailing)),
         :ok <- string(command, 32),
         true <- reply_command?(command),
         true <- is_list(params) and length(params) <= 32,
         true <- Enum.all?(params, &valid_bytes?(&1, max: 4_096)),
         true <- is_nil(trailing) or valid_bytes?(trailing, max: 4_096),
         :ok <- reply_source(source),
         :ok <- tags(tags) do
      :ok
    else
      _ -> {:error, :invalid_reply_item}
    end
  end

  def validate_reply_item(_item), do: {:error, :invalid_reply_item}

  @doc "Validates one state row independently of its surrounding frame."
  @spec validate_row(term()) :: :ok | {:error, term()}
  def validate_row(%{"kind" => kind} = row) when kind in @state_kinds, do: validate_row_kind(kind, row)
  def validate_row(_row), do: {:error, :invalid_state_row}

  @doc "Validates a protocol Bytes value without changing its content."
  @spec valid_bytes?(term(), keyword()) :: boolean()
  def valid_bytes?(value, options \\ []) do
    max = Keyword.get(options, :max, 4_096)
    allow_empty = Keyword.get(options, :allow_empty, true)

    case value do
      value when is_binary(value) ->
        byte_size(value) <= max and (allow_empty or value != <<>>) and String.valid?(value) and safe_text?(value)

      %{"b64" => encoded} = map when map_size(map) == 1 and is_binary(encoded) ->
        with {:ok, decoded} <- Base.decode64(encoded),
             true <- Base.encode64(decoded) == encoded,
             true <- byte_size(decoded) <= max,
             true <- allow_empty or decoded != <<>>,
             true <- safe_binary?(decoded) do
          true
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp validate_frame_type("hello", frame) do
    with :ok <- exact(frame, ~w(t protocol version network_id profile_hash sid boot name nonce time_ms)),
         :ok <- string(frame["protocol"], 64),
         true <- frame["protocol"] == "elixircd-native",
         true <- frame["version"] == 1,
         true <- Identity.valid_network_id?(frame["network_id"]),
         true <- valid_hex?(frame["profile_hash"], 64),
         true <- Identity.valid_sid?(frame["sid"]),
         true <- Identity.valid_id?(frame["boot"]),
         :ok <- string(frame["name"], 255),
         true <- Identity.valid_id?(frame["nonce"]),
         true <- Identity.valid_uint?(frame["time_ms"]) do
      :ok
    else
      false -> {:error, :invalid_hello}
      {:error, _} = error -> error
    end
  end

  defp validate_frame_type("sync", frame) do
    with :ok <- exact(frame, ~w(t n phase sync_id scope), allow: ~w(t n phase sync_id scope cut page rows pages sha256)),
         :ok <- sequence(frame),
         true <- Identity.valid_id?(frame["sync_id"]),
         true <- frame["scope"] == "network",
         :ok <- validate_sync_phase(frame) do
      :ok
    else
      false -> {:error, :invalid_sync}
      {:error, _} = error -> error
    end
  end

  defp validate_frame_type("state", frame) do
    with :ok <- exact(frame, ~w(t n origin actor context changes)),
         :ok <- sequence(frame),
         :ok <- node_ref(frame["origin"]),
         :ok <- actor(frame["actor"]),
         :ok <- context(frame["context"]),
         true <- is_list(frame["changes"]),
         true <- length(frame["changes"]) <= 256,
         :ok <- all_ok(frame["changes"], &validate_state_row/1) do
      :ok
    else
      false -> {:error, :invalid_state}
      {:error, _} = error -> error
    end
  end

  defp validate_frame_type("message", frame) do
    with :ok <- exact(frame, ~w(t n origin actor message_id sent_ms target command text tags request_id)),
         :ok <- sequence(frame),
         :ok <- node_ref(frame["origin"]),
         :ok <- actor(frame["actor"]),
         true <- Identity.valid_id?(frame["message_id"]),
         true <- Identity.valid_positive?(frame["sent_ms"]),
         :ok <- target(frame["target"]),
         true <- frame["command"] in ~w(PRIVMSG NOTICE TAGMSG),
         true <-
           (frame["command"] == "TAGMSG" and is_nil(frame["text"])) or
             (frame["command"] != "TAGMSG" and valid_bytes?(frame["text"], max: 4_096)),
         :ok <- tags(frame["tags"]),
         true <- is_nil(frame["request_id"]) or Identity.valid_id?(frame["request_id"]) do
      :ok
    else
      false -> {:error, :invalid_message}
      {:error, _} = error -> error
    end
  end

  defp validate_frame_type("request", frame) do
    with :ok <- exact(frame, ~w(t n origin to request_id actor method args guards ttl_ms)),
         :ok <- sequence(frame),
         :ok <- node_ref(frame["origin"]),
         :ok <- node_ref(frame["to"]),
         true <- Identity.valid_id?(frame["request_id"]),
         :ok <- actor(frame["actor"]),
         true <- frame["method"] in @request_methods,
         :ok <- request_args(frame["method"], frame["args"]),
         :ok <- guards(frame["guards"]),
         true <- is_integer(frame["ttl_ms"]) and frame["ttl_ms"] in 1..60_000 do
      :ok
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  defp validate_frame_type("reply", frame) do
    with :ok <- exact(frame, ~w(t n origin to request_id part done status payload)),
         :ok <- sequence(frame),
         :ok <- node_ref(frame["origin"]),
         :ok <- node_ref(frame["to"]),
         true <- Identity.valid_id?(frame["request_id"]),
         true <- Identity.valid_uint?(frame["part"]),
         true <- is_boolean(frame["done"]),
         true <- frame["status"] in @reply_statuses,
         true <- frame["done"] or frame["status"] == "OK",
         true <- is_map(frame["payload"]),
         :ok <- validate_reply_payload(frame["status"], frame["payload"]) do
      :ok
    else
      false -> {:error, :invalid_reply}
      {:error, _} = error -> error
    end
  end

  defp validate_frame_type(type, frame) when type in ~w(ping pong) do
    with :ok <- exact(frame, ~w(t n token)),
         :ok <- sequence(frame),
         true <- Identity.valid_id?(frame["token"]) do
      :ok
    else
      false -> {:error, :invalid_liveness_frame}
      {:error, _} = error -> error
    end
  end

  defp validate_frame_type("close", frame) do
    with :ok <- exact(frame, ~w(t n code reason)),
         :ok <- sequence(frame),
         true <- frame["code"] in @close_codes,
         true <- valid_bytes?(frame["reason"], max: 512) do
      :ok
    else
      false -> {:error, :invalid_close}
      {:error, _} = error -> error
    end
  end

  defp validate_sync_phase(%{"phase" => "begin"} = frame) do
    with :ok <- exact(frame, ~w(t n phase sync_id scope cut)),
         true <- Identity.valid_uint?(frame["cut"]) do
      :ok
    else
      _ -> {:error, :invalid_sync_begin}
    end
  end

  defp validate_sync_phase(%{"phase" => "rows"} = frame) do
    with :ok <- exact(frame, ~w(t n phase sync_id scope page rows)),
         true <- Identity.valid_uint?(frame["page"]),
         true <- is_list(frame["rows"]),
         true <- length(frame["rows"]) <= 256,
         :ok <- all_ok(frame["rows"], &validate_row/1) do
      :ok
    else
      _ -> {:error, :invalid_sync_rows}
    end
  end

  defp validate_sync_phase(%{"phase" => "end"} = frame) do
    with :ok <- exact(frame, ~w(t n phase sync_id scope pages rows sha256)),
         true <- Identity.valid_uint?(frame["pages"]),
         true <- Identity.valid_uint?(frame["rows"]),
         true <- valid_hex?(frame["sha256"], 64) do
      :ok
    else
      _ -> {:error, :invalid_sync_end}
    end
  end

  defp validate_sync_phase(%{"phase" => "ack"} = frame) do
    with :ok <- exact(frame, ~w(t n phase sync_id scope sha256)),
         true <- valid_hex?(frame["sha256"], 64) do
      :ok
    else
      _ -> {:error, :invalid_sync_ack}
    end
  end

  defp validate_sync_phase(_frame), do: {:error, :invalid_sync_phase}

  defp validate_row_kind("topology.add", row) do
    with :ok <- exact(row, ~w(kind nodes edges)),
         true <- is_list(row["nodes"]) and length(row["nodes"]) <= 256,
         true <- is_list(row["edges"]) and length(row["edges"]) <= 255,
         :ok <- all_ok(row["nodes"], &topology_node/1),
         :ok <- all_ok(row["edges"], &edge/1),
         true <- unique_topology_nodes?(row["nodes"]),
         true <- unique_topology_edges?(row["edges"]) do
      :ok
    else
      _ -> {:error, :invalid_topology_add}
    end
  end

  defp validate_row_kind("topology.ready", row) do
    with :ok <- exact(row, ~w(kind edge_id side)),
         true <- valid_hex?(row["edge_id"], 64),
         true <- Identity.valid_sid?(row["side"]) do
      :ok
    else
      _ -> {:error, :invalid_topology_ready}
    end
  end

  defp validate_row_kind("topology.remove", row) do
    with :ok <- exact(row, ~w(kind edge_id reporter reason)),
         true <- valid_hex?(row["edge_id"], 64),
         true <- Identity.valid_sid?(row["reporter"]),
         true <- valid_bytes?(row["reason"], max: 512) do
      :ok
    else
      _ -> {:error, :invalid_topology_remove}
    end
  end

  defp validate_row_kind("merge.begin", row) do
    with :ok <- exact(row, ~w(kind id via)),
         true <- Identity.valid_id?(row["id"]),
         :ok <- node_ref(row["via"]) do
      :ok
    else
      _ -> {:error, :invalid_merge_begin}
    end
  end

  defp validate_row_kind(kind, row) when kind in ~w(merge.end merge.abort) do
    with :ok <- exact(row, ~w(kind id)), true <- Identity.valid_id?(row["id"]) do
      :ok
    else
      _ -> {:error, :invalid_merge_marker}
    end
  end

  defp validate_row_kind("user.put", row) do
    with :ok <- exact(row, ~w(kind user)), :ok <- user_projection(row["user"]) do
      :ok
    else
      _ -> {:error, :invalid_user_put}
    end
  end

  defp validate_row_kind("user.quit", row) do
    with :ok <- exact(row, ~w(kind uid home rev reason action by)),
         true <- Identity.valid_id?(row["uid"]),
         :ok <- node_ref(row["home"]),
         true <- Identity.valid_positive?(row["rev"]),
         true <- row["action"] in ~w(quit kill),
         true <- valid_bytes?(row["reason"], max: 4_096),
         :ok <- actor(row["by"]) do
      :ok
    else
      _ -> {:error, :invalid_user_quit}
    end
  end

  defp validate_row_kind("memberships.put", row) do
    with :ok <- exact(row, ~w(kind uid home rev entries cause)),
         true <- Identity.valid_id?(row["uid"]),
         :ok <- node_ref(row["home"]),
         true <- Identity.valid_uint?(row["rev"]),
         true <- is_list(row["entries"]) and length(row["entries"]) <= 128,
         :ok <- all_ok(row["entries"], &membership_entry/1),
         :ok <- membership_cause(row["cause"]) do
      if row["rev"] == 0 and row["entries"] != [], do: {:error, :invalid_zero_membership_revision}, else: :ok
    else
      _ -> {:error, :invalid_memberships_put}
    end
  end

  defp validate_row_kind("channel.ensure", row) do
    with :ok <- exact(row, ~w(kind channel)), :ok <- channel_ref(row["channel"]) do
      :ok
    else
      _ -> {:error, :invalid_channel_ensure}
    end
  end

  defp validate_row_kind("channel.field", row) do
    with :ok <- exact(row, ~w(kind channel field value stamp setter)),
         :ok <- channel_ref(row["channel"]),
         true <- valid_field?(row["field"]),
         true <- valid_field_value?(row["field"], row["value"]),
         :ok <- stamp(row["stamp"]),
         :ok <- actor(row["setter"]) do
      :ok
    else
      _ -> {:error, :invalid_channel_field}
    end
  end

  defp validate_row_kind("channel.list", row) do
    with :ok <- exact(row, ~w(kind channel mode mask present set_by set_ms stamp)),
         :ok <- channel_ref(row["channel"]),
         true <- row["mode"] in ~w(b e I),
         true <- valid_bytes?(row["mask"], max: 512, allow_empty: false),
         true <- is_boolean(row["present"]),
         true <- valid_bytes?(row["set_by"], max: 512),
         true <- Identity.valid_uint?(row["set_ms"]),
         :ok <- stamp(row["stamp"]) do
      :ok
    else
      _ -> {:error, :invalid_channel_list}
    end
  end

  defp validate_row_kind("member.status", row) do
    with :ok <- exact(row, ~w(kind channel uid join_id mode enabled stamp setter)),
         :ok <- channel_ref(row["channel"]),
         true <- Identity.valid_id?(row["uid"]),
         true <- Identity.valid_positive?(row["join_id"]),
         true <- row["mode"] in ~w(o v),
         true <- is_boolean(row["enabled"]),
         :ok <- stamp(row["stamp"]),
         :ok <- actor(row["setter"]) do
      :ok
    else
      _ -> {:error, :invalid_member_status}
    end
  end

  defp validate_row_kind("policy.change", row) do
    with :ok <- exact(row, ~w(kind epoch revision changes)),
         true <- Identity.valid_id?(row["epoch"]),
         true <- Identity.valid_uint?(row["revision"]),
         true <- is_nil(row["changes"]) or is_list(row["changes"]),
         true <- is_nil(row["changes"]) or length(row["changes"]) <= 256,
         :ok <- policy_changes(row["changes"]) do
      :ok
    else
      _ -> {:error, :invalid_policy_change}
    end
  end

  defp validate_row_kind("policy.cache.begin", row) do
    with :ok <- exact(row, ~w(kind epoch revision objects)),
         true <- Identity.valid_id?(row["epoch"]),
         true <- Identity.valid_uint?(row["revision"]),
         true <- Identity.valid_uint?(row["objects"]) do
      :ok
    else
      _ -> {:error, :invalid_policy_cache_begin}
    end
  end

  defp validate_row_kind("policy.cache.rows", row) do
    with :ok <- exact(row, ~w(kind rows)),
         true <- is_list(row["rows"]) and length(row["rows"]) <= 256,
         :ok <- all_ok(row["rows"], &policy_cache_object/1) do
      :ok
    else
      _ -> {:error, :invalid_policy_cache_rows}
    end
  end

  defp validate_row_kind("policy.cache.end", row) do
    with :ok <- exact(row, ~w(kind epoch revision objects)),
         true <- Identity.valid_id?(row["epoch"]),
         true <- Identity.valid_uint?(row["revision"]),
         true <- Identity.valid_uint?(row["objects"]) do
      :ok
    else
      _ -> {:error, :invalid_policy_cache_end}
    end
  end

  defp validate_row_kind("invite.notice", row) do
    with :ok <- exact(row, ~w(kind invite_id target_uid inviter_uid channel expires_ms)),
         true <- Identity.valid_id?(row["invite_id"]),
         true <- Identity.valid_id?(row["target_uid"]),
         true <- Identity.valid_id?(row["inviter_uid"]),
         :ok <- channel_ref(row["channel"]),
         true <- Identity.valid_uint?(row["expires_ms"]) do
      :ok
    else
      _ -> {:error, :invalid_invite_notice}
    end
  end

  defp validate_row_kind(_kind, _row), do: {:error, :invalid_state_row}

  defp validate_state_row(%{"kind" => kind}) when kind in ~w(policy.cache.begin policy.cache.rows policy.cache.end),
    do: {:error, :policy_cache_only_in_sync}

  defp validate_state_row(row), do: validate_row(row)

  defp request_args("query", %{"command" => command, "params" => params, "target_uid" => target, "view" => view} = args) do
    with :ok <- exact(args, ~w(command params target_uid view)),
         :ok <- string(command, 32),
         true <- is_list(params) and length(params) <= 15,
         true <- Enum.all?(params, &valid_bytes?(&1, max: 4_096)),
         true <- is_nil(target) or Identity.valid_id?(target),
         true <- view == "client" or (view == "owner_detail" and command == "WHOIS" and is_binary(target)) do
      :ok
    else
      _ -> {:error, :invalid_query_args}
    end
  end

  defp request_args("service", args) do
    with :ok <- exact(args, ~w(service arguments scope channel)),
         true <- args["service"] in ~w(NickServ ChanServ),
         true <- is_list(args["arguments"]) and length(args["arguments"]) <= 512,
         true <- args["arguments"] != [],
         true <- Enum.all?(args["arguments"], &valid_bytes?(&1, max: 4_096)),
         true <- valid_service_scope?(args["scope"], args["channel"]) do
      :ok
    else
      _ -> {:error, :invalid_service_args}
    end
  end

  defp request_args("sasl", args) do
    with :ok <- exact(args, ~w(uid attempt_id step phase mechanism data client_info)),
         true <- Identity.valid_id?(args["uid"]),
         true <- Identity.valid_id?(args["attempt_id"]),
         true <- Identity.valid_uint?(args["step"]),
         true <- args["phase"] in ~w(start step abort),
         :ok <- string(args["mechanism"], 128),
         true <- is_nil(args["data"]) or valid_base64?(args["data"], 16_384),
         :ok <- client_info(args["client_info"]),
         :ok <- sasl_phase_data(args["phase"], args["step"], args["data"]) do
      :ok
    else
      _ -> {:error, :invalid_sasl_args}
    end
  end

  defp request_args("user_action", args) do
    with :ok <- exact(args, ~w(action target_uid value reason)),
         true <- args["action"] in ~w(kill kick part join nick host ident account oper),
         true <- Identity.valid_id?(args["target_uid"]),
         :ok <- action_value(args["action"], args["value"]),
         true <- valid_bytes?(args["reason"], max: 4_096) do
      :ok
    else
      _ -> {:error, :invalid_user_action_args}
    end
  end

  defp request_args("invite", args) do
    with :ok <- exact(args, ~w(invite_id inviter_uid target_uid channel expires_ms)),
         true <- Identity.valid_id?(args["invite_id"]),
         true <- Identity.valid_id?(args["inviter_uid"]),
         true <- Identity.valid_id?(args["target_uid"]),
         :ok <- channel_ref(args["channel"]),
         true <- Identity.valid_uint?(args["expires_ms"]) do
      :ok
    else
      _ -> {:error, :invalid_invite_args}
    end
  end

  defp request_args("snapshot", args) do
    with :ok <- exact(args, ~w(scope channel for_uid)),
         true <- args["scope"] in ~w(channel policy),
         true <-
           (args["scope"] == "channel" and valid_bytes?(args["channel"], max: 512) and
              String.starts_with?(args["channel"], "#")) or
             (args["scope"] == "policy" and is_nil(args["channel"])),
         true <- is_nil(args["for_uid"]) or Identity.valid_id?(args["for_uid"]),
         true <- args["scope"] == "channel" or is_nil(args["for_uid"]) do
      :ok
    else
      _ -> {:error, :invalid_snapshot_args}
    end
  end

  defp request_args("admin", args) do
    with :ok <- exact(args, ~w(action neighbor_sid reason)),
         true <- args["action"] in ~w(rehash restart shutdown enable_edge disable_edge),
         true <- admin_neighbor_shape?(args["action"], args["neighbor_sid"]),
         true <- is_nil(args["neighbor_sid"]) or Identity.valid_sid?(args["neighbor_sid"]),
         true <- valid_bytes?(args["reason"], max: 4_096) do
      :ok
    else
      _ -> {:error, :invalid_admin_args}
    end
  end

  defp request_args(_method, _args), do: {:error, :invalid_request_args}

  defp valid_service_scope?("global", nil), do: true

  defp valid_service_scope?("channel", channel) when is_binary(channel) do
    valid_bytes?(channel, max: 512, allow_empty: false) and String.starts_with?(channel, "#")
  end

  defp valid_service_scope?(_scope, _channel), do: false

  defp admin_neighbor_shape?(action, neighbor_sid) when action in ~w(enable_edge disable_edge),
    do: is_binary(neighbor_sid)

  defp admin_neighbor_shape?(_action, neighbor_sid), do: is_nil(neighbor_sid)

  defp action_value("kill", nil), do: :ok

  defp action_value(action, %{"channel" => channel, "join_id" => join_id} = value) when action in ~w(kick part) do
    with :ok <- exact(value, ~w(channel join_id)),
         :ok <- channel_ref(channel),
         true <- Identity.valid_positive?(join_id) do
      :ok
    else
      _ -> {:error, :invalid_action_value}
    end
  end

  defp action_value("join", %{"channel" => channel, "key" => key} = value) do
    with :ok <- exact(value, ~w(channel key)),
         true <- valid_bytes?(channel, max: 512, allow_empty: false),
         true <- is_nil(key) or valid_bytes?(key, max: 512) do
      :ok
    else
      _ -> {:error, :invalid_action_value}
    end
  end

  defp action_value("nick", %{"nick" => nick} = value) do
    with :ok <- exact(value, ~w(nick)), :ok <- string(nick, 64) do
      :ok
    else
      _ -> {:error, :invalid_action_value}
    end
  end

  defp action_value(action, %{"displayhost" => displayhost} = value) when action == "host" do
    with :ok <- exact(value, ~w(displayhost)), :ok <- string(displayhost, 255) do
      :ok
    else
      _ -> {:error, :invalid_action_value}
    end
  end

  defp action_value("ident", %{"ident" => ident} = value) do
    with :ok <- exact(value, ~w(ident)), :ok <- string(ident, 64) do
      :ok
    else
      _ -> {:error, :invalid_action_value}
    end
  end

  defp action_value("account", %{"binding" => binding, "response_request_id" => response_id} = value) do
    with :ok <- exact(value, ~w(binding response_request_id)),
         :ok <- user_binding(binding),
         true <- is_nil(response_id) or Identity.valid_id?(response_id) do
      :ok
    else
      _ -> {:error, :invalid_action_value}
    end
  end

  defp action_value("oper", %{"enabled" => enabled, "role" => role} = value) do
    with :ok <- exact(value, ~w(enabled role)),
         true <- is_boolean(enabled),
         true <- is_nil(role) or string(role, 64) == :ok do
      if enabled and is_nil(role), do: {:error, :invalid_action_value}, else: :ok
    else
      _ -> {:error, :invalid_action_value}
    end
  end

  defp action_value(_action, _value), do: {:error, :invalid_action_value}

  defp exact(map, required, options \\ [])

  defp exact(map, required, options) when is_map(map) do
    keys = Map.keys(map)
    allowed = Keyword.get(options, :allow, required)
    missing = required -- keys
    unknown = keys -- allowed

    cond do
      Enum.any?(keys, &(not is_binary(&1))) -> {:error, :non_string_key}
      missing != [] or unknown != [] -> {:error, {:field_set, required, keys}}
      true -> :ok
    end
  end

  defp exact(_map, _required, _options), do: {:error, :expected_object}

  defp sequence(%{"n" => n}), do: if(Identity.valid_positive?(n), do: :ok, else: {:error, :invalid_sequence})
  defp sequence(_frame), do: {:error, :invalid_sequence}

  defp string(value, max) when is_binary(value),
    do:
      if(byte_size(value) <= max and String.valid?(value) and safe_text?(value),
        do: :ok,
        else: {:error, :invalid_string}
      )

  defp string(_value, _max), do: {:error, :invalid_string}

  defp node_ref(%{"sid" => sid, "boot" => boot} = value) do
    with :ok <- exact(value, ~w(sid boot)), true <- Identity.valid_sid?(sid), true <- Identity.valid_id?(boot) do
      :ok
    else
      _ -> {:error, :invalid_node_ref}
    end
  end

  defp node_ref(_value), do: {:error, :invalid_node_ref}

  defp actor(%{"user" => uid} = value) when map_size(value) == 1,
    do: if(Identity.valid_id?(uid), do: :ok, else: {:error, :invalid_actor})

  defp actor(%{"service" => service} = value) when map_size(value) == 1,
    do: if(service in ~w(NickServ ChanServ), do: :ok, else: {:error, :invalid_actor})

  defp actor(%{"server" => sid} = value) when map_size(value) == 1,
    do: if(Identity.valid_sid?(sid), do: :ok, else: {:error, :invalid_actor})

  defp actor(_value), do: {:error, :invalid_actor}

  defp context(%{"kind" => "live"} = value), do: exact(value, ~w(kind))

  defp context(%{"kind" => "merge", "id" => id} = value) do
    with :ok <- exact(value, ~w(kind id)),
         true <- Identity.valid_id?(id),
         do: :ok,
         else: (_ -> {:error, :invalid_context})
  end

  defp context(_value), do: {:error, :invalid_context}

  defp target(%{"user" => uid} = value) when map_size(value) == 1,
    do: if(Identity.valid_id?(uid), do: :ok, else: {:error, :invalid_target})

  defp target(%{"channel" => channel, "minimum_status" => minimum} = value) when map_size(value) == 2 do
    with :ok <- channel_ref(channel),
         true <- is_nil(minimum) or minimum in ~w(o v),
         do: :ok,
         else: (_ -> {:error, :invalid_target})
  end

  defp target(%{"audience" => audience, "mask" => mask} = value) when map_size(value) == 2 do
    if audience in ~w(wallops operators snomask) and (is_nil(mask) or string(mask, 128) == :ok),
      do: :ok,
      else: {:error, :invalid_target}
  end

  defp target(_value), do: {:error, :invalid_target}

  defp tags(value) when is_map(value) and map_size(value) <= 64 do
    Enum.reduce_while(value, :ok, fn {key, tag_value}, :ok ->
      if is_binary(key) and byte_size(key) <= 128 and String.valid?(key) and safe_text?(key) and
           (is_nil(tag_value) or valid_bytes?(tag_value, max: 512)),
         do: {:cont, :ok},
         else: {:halt, {:error, :invalid_tags}}
    end)
  end

  defp tags(_value), do: {:error, :invalid_tags}

  defp guards(value) when is_map(value) do
    required =
      ~w(actor_uid actor_user_rev actor_join_id target_user_rev target_join_id channel policy_epoch policy_revision)

    with :ok <- exact(value, required),
         true <- is_nil(value["actor_uid"]) or Identity.valid_id?(value["actor_uid"]),
         true <- is_nil(value["actor_user_rev"]) or Identity.valid_uint?(value["actor_user_rev"]),
         true <- is_nil(value["actor_join_id"]) or Identity.valid_positive?(value["actor_join_id"]),
         true <- is_nil(value["target_user_rev"]) or Identity.valid_uint?(value["target_user_rev"]),
         true <- is_nil(value["target_join_id"]) or Identity.valid_positive?(value["target_join_id"]),
         true <- is_nil(value["channel"]) or channel_ref(value["channel"]) == :ok,
         true <- is_nil(value["policy_epoch"]) or Identity.valid_id?(value["policy_epoch"]),
         true <- is_nil(value["policy_revision"]) or Identity.valid_uint?(value["policy_revision"]) do
      :ok
    else
      _ -> {:error, :invalid_guards}
    end
  end

  defp guards(_value), do: {:error, :invalid_guards}

  defp topology_node(%{"sid" => sid, "boot" => boot, "name" => name, "description" => description} = value) do
    with :ok <- exact(value, ~w(sid boot name description)),
         true <- Identity.valid_sid?(sid),
         true <- Identity.valid_id?(boot),
         :ok <- string(name, 255),
         true <- valid_bytes?(description, max: 4_096) do
      :ok
    else
      _ -> {:error, :invalid_node}
    end
  end

  defp topology_node(_value), do: {:error, :invalid_node}

  defp edge(%{"id" => id, "a" => a, "b" => b, "ready_sides" => ready} = value) do
    with :ok <- exact(value, ~w(id a b ready_sides)),
         true <- valid_hex?(id, 64),
         :ok <- node_ref(a),
         :ok <- node_ref(b),
         true <- a["sid"] < b["sid"],
         true <- is_list(ready) and length(ready) <= 2,
         true <- length(ready) == length(Enum.uniq(ready)),
         true <- Enum.all?(ready, &(&1 in [a["sid"], b["sid"]])),
         true <- Enum.all?(ready, &Identity.valid_sid?/1) do
      :ok
    else
      _ -> {:error, :invalid_edge}
    end
  end

  defp edge(_value), do: {:error, :invalid_edge}

  defp unique_topology_nodes?(nodes) do
    sids = Enum.map(nodes, & &1["sid"])
    names = Enum.map(nodes, & &1["name"])
    length(sids) == length(Enum.uniq(sids)) and length(names) == length(Enum.uniq(names))
  end

  defp unique_topology_edges?(edges) do
    ids = Enum.map(edges, & &1["id"])
    length(ids) == length(Enum.uniq(ids))
  end

  defp user_projection(value) when is_map(value) do
    fields =
      ~w(uid home rev requested_nick signon_ms ident realhost displayhost address secure_client client_certfp modes oper_role away realname binding)

    with :ok <- exact(value, fields),
         true <- Identity.valid_id?(value["uid"]),
         :ok <- node_ref(value["home"]),
         true <- Identity.valid_positive?(value["rev"]),
         :ok <- string(value["requested_nick"], 64),
         true <- Identity.valid_positive?(value["signon_ms"]),
         :ok <- string(value["ident"], 64),
         :ok <- string(value["realhost"], 255),
         :ok <- string(value["displayhost"], 255),
         :ok <- string(value["address"], 128),
         true <- is_boolean(value["secure_client"]),
         true <- is_nil(value["client_certfp"]) or valid_hex?(value["client_certfp"], 64),
         true <- is_list(value["modes"]) and Enum.all?(value["modes"], &valid_user_mode?/1),
         true <- is_nil(value["oper_role"]) or string(value["oper_role"], 64) == :ok,
         :ok <- away(value["away"]),
         true <- valid_bytes?(value["realname"], max: 4_096),
         :ok <- user_binding(value["binding"]) do
      :ok
    else
      _ -> {:error, :invalid_user_projection}
    end
  end

  defp user_projection(_value), do: {:error, :invalid_user_projection}

  defp away(nil), do: :ok

  defp away(%{"text" => text, "since_ms" => since} = value) do
    with :ok <- exact(value, ~w(text since_ms)),
         true <- valid_bytes?(text, max: 4_096),
         true <- Identity.valid_positive?(since),
         do: :ok,
         else: (_ -> {:error, :invalid_away})
  end

  defp away(_value), do: {:error, :invalid_away}

  defp user_binding(nil), do: :ok

  defp user_binding(%{"account_id" => account_id, "auth_epoch" => auth_epoch, "policy_epoch" => policy_epoch} = value) do
    with :ok <- exact(value, ~w(account_id auth_epoch policy_epoch)),
         true <- Identity.valid_id?(account_id),
         true <- Identity.valid_positive?(auth_epoch),
         true <- Identity.valid_id?(policy_epoch) do
      :ok
    else
      _ -> {:error, :invalid_binding}
    end
  end

  defp user_binding(_value), do: {:error, :invalid_binding}

  defp membership_entry(%{"channel" => channel, "join_id" => join_id, "joined_ms" => joined} = value) do
    with :ok <- exact(value, ~w(channel join_id joined_ms)),
         true <- valid_bytes?(channel, max: 512, allow_empty: false) and String.starts_with?(channel, "#"),
         true <- Identity.valid_positive?(join_id),
         true <- Identity.valid_positive?(joined) do
      :ok
    else
      _ -> {:error, :invalid_membership_entry}
    end
  end

  defp membership_entry(_value), do: {:error, :invalid_membership_entry}

  defp membership_cause(
         %{"action" => action, "channel" => channel, "join_id" => join_id, "by" => by, "reason" => reason} = value
       ) do
    with :ok <- exact(value, ~w(action channel join_id by reason)),
         true <- action in ~w(join part kick sync),
         true <- membership_cause_shape?(action, channel, join_id),
         :ok <- actor(by),
         true <- valid_bytes?(reason, max: 4_096) do
      :ok
    else
      _ -> {:error, :invalid_membership_cause}
    end
  end

  defp membership_cause(_value), do: {:error, :invalid_membership_cause}

  defp membership_cause_shape?("sync", nil, nil), do: true

  defp membership_cause_shape?(action, channel, join_id) when action in ~w(join part kick) do
    is_binary(channel) and String.starts_with?(channel, "#") and Identity.valid_positive?(join_id)
  end

  defp membership_cause_shape?(_action, _channel, _join_id), do: false

  defp channel_ref(%{"name" => name, "born_ms" => born, "cid" => cid} = value) do
    with :ok <- exact(value, ~w(name born_ms cid)),
         true <- valid_bytes?(name, max: 512, allow_empty: false) and String.starts_with?(name, "#"),
         true <- Identity.valid_positive?(born),
         true <- Identity.valid_id?(cid) do
      :ok
    else
      _ -> {:error, :invalid_channel_ref}
    end
  end

  defp channel_ref(_value), do: {:error, :invalid_channel_ref}

  defp stamp([counter, sid, boot]) do
    if Identity.valid_positive?(counter) and Identity.valid_sid?(sid) and Identity.valid_id?(boot),
      do: :ok,
      else: {:error, :invalid_stamp}
  end

  defp stamp(_value), do: {:error, :invalid_stamp}

  defp valid_field?(field) when field == "topic", do: true

  defp valid_field?(<<"mode:", mode::binary>>) do
    case ModeRegistry.decode(:channel, mode) do
      {:ok, decoded} -> decoded not in [:b, :e, :I, :o, :v]
      :error -> false
    end
  end

  defp valid_field?(_field), do: false

  defp valid_field_value?("topic", nil), do: true

  defp valid_field_value?("topic", %{"text" => text, "setter" => setter, "set_ms" => set_ms} = value) do
    exact(value, ~w(text setter set_ms)) == :ok and valid_bytes?(text, max: 4_096) and
      valid_bytes?(setter, max: 512) and Identity.valid_uint?(set_ms)
  end

  defp valid_field_value?(<<"mode:", mode::binary>>, value) do
    case Enum.find(ChannelModes.mode_types(), fn {candidate, _type} -> Atom.to_string(candidate) == mode end) do
      {_mode, type} when type in [:a, :b, :c] -> is_nil(value) or valid_bytes?(value, max: 512)
      {_mode, :d} -> is_boolean(value)
      {_mode, :prefix} -> false
      nil -> false
    end
  end

  defp valid_field_value?(_field, _value), do: false

  defp policy_changes(nil), do: :ok

  defp policy_changes(changes) when is_list(changes) do
    all_ok(changes, fn
      %{"entity" => entity, "key" => key, "value" => value} = change ->
        with :ok <- exact(change, ~w(entity key value)),
             :ok <- string(entity, 32),
             :ok <- string(key, 512),
             :ok <- policy_change_value(entity, key, value) do
          :ok
        end

      _ ->
        {:error, :invalid_policy_object}
    end)
  end

  defp policy_changes(_changes), do: {:error, :invalid_policy_changes}

  defp policy_change_value(_entity, _key, nil), do: :ok

  defp policy_change_value(entity, key, value) do
    case Policy.validate_public_object(entity, key, value) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  defp policy_cache_object(%{"entity" => entity, "key" => key, "value" => value} = object) do
    with :ok <- exact(object, ~w(entity key value)),
         :ok <- Policy.validate_public_object(entity, key, value) do
      :ok
    else
      _ -> {:error, :invalid_policy_cache_object}
    end
  end

  defp policy_cache_object(_object), do: {:error, :invalid_policy_cache_object}

  defp client_info(
         %{"secure_client" => secure, "realhost" => realhost, "address" => address, "client_certfp" => cert} = value
       ) do
    with :ok <- exact(value, ~w(secure_client realhost address client_certfp)),
         true <- is_boolean(secure),
         :ok <- string(realhost, 255),
         :ok <- string(address, 128),
         true <- is_nil(cert) or valid_hex?(cert, 64) do
      :ok
    else
      _ -> {:error, :invalid_client_info}
    end
  end

  defp client_info(_value), do: {:error, :invalid_client_info}

  defp sasl_phase_data("start", 0, nil), do: :ok
  defp sasl_phase_data("abort", _step, nil), do: :ok
  defp sasl_phase_data("step", _step, data) when is_binary(data), do: :ok
  defp sasl_phase_data(_phase, _step, _data), do: {:error, :invalid_sasl_phase_data}

  defp valid_user_mode?(mode) when is_binary(mode) do
    mode not in ["r", "Z"] and match?({:ok, _}, ModeRegistry.decode(:user, mode))
  end

  defp valid_user_mode?(_mode), do: false

  defp reply_command?(command), do: command in @reply_commands or Regex.match?(~r/\A[0-9]{3}\z/, command)

  defp reply_source(%{"service" => service} = value) do
    if exact(value, ~w(service)) == :ok and service in ~w(NickServ ChanServ),
      do: :ok,
      else: {:error, :invalid_reply_source}
  end

  defp reply_source(%{"server" => sid} = value) do
    if exact(value, ~w(server)) == :ok and Identity.valid_sid?(sid),
      do: :ok,
      else: {:error, :invalid_reply_source}
  end

  defp reply_source(_source), do: {:error, :invalid_reply_source}

  defp valid_hex?(value, length) when is_binary(value),
    do: byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp valid_hex?(_value, _length), do: false

  defp valid_base64?(value, max) when is_binary(value) do
    if byte_size(value) <= max do
      case Base.decode64(value) do
        {:ok, decoded} -> Base.encode64(decoded) == value
        :error -> false
      end
    else
      false
    end
  end

  defp valid_base64?(_value, _max), do: false

  defp safe_text?(value), do: safe_binary?(value) and :binary.match(value, <<0>>) == :nomatch

  defp safe_binary?(value) when is_binary(value),
    do:
      :binary.match(value, <<0>>) == :nomatch and :binary.match(value, "\r") == :nomatch and
        :binary.match(value, "\n") == :nomatch

  defp safe_binary?(_value), do: false

  defp all_ok(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
