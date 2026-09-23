defmodule ElixIRCd.Server.S2S.Requests do
  @moduledoc """
  Finite ENP/1 request routing, authorization context and duplicate handling.

  This is an operation coordinator, not a generic RPC engine. Domain handlers
  still own the actual service, user and channel mutations.
  """

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.JSON
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.Schema
  alias ElixIRCd.Server.S2S.Tree

  @methods ~w(query service sasl user_action invite snapshot admin)
  @query_commands ~w(ADMIN INFO MOTD STATS TIME TRACE VERSION WHOIS WHOWAS)
  @query_reply_commands %{
    "ADMIN" => ~w(256 257 258 259 451),
    "INFO" => ~w(371 374 402 451),
    "MOTD" => ~w(372 375 376 422 451),
    "STATS" => ~w(210 219 242 250 451),
    "TIME" => ~w(391 451),
    "TRACE" => ~w(205 262 401 451),
    "VERSION" => ~w(351 451),
    "WHOIS" => ~w(311 312 318 330 401),
    "WHOWAS" => ~w(314 312 369 401 406 431 451 461)
  }
  @statuses ~w(OK REJECTED NOT_FOUND STALE UNAVAILABLE UNSUPPORTED BUSY TIMEOUT CANCELLED RESOURCE UNKNOWN_OUTCOME)

  @type state :: %{
          pending: %{optional(term()) => map()},
          pending_by_origin: %{optional({String.t(), Identity.id()}) => non_neg_integer()},
          completed: %{optional(term()) => map()},
          max_pending: pos_integer(),
          max_pending_origin: pos_integer(),
          result_ttl_ms: pos_integer()
        }

  @doc "Creates bounded pending/completed request state."
  @spec new(keyword()) :: state()
  def new(options \\ []) do
    %{
      pending: %{},
      pending_by_origin: %{},
      completed: %{},
      max_pending: Keyword.get(options, :max_pending, 1_024),
      max_pending_origin: Keyword.get(options, :max_pending_origin, 128),
      result_ttl_ms: Keyword.get(options, :result_ttl_ms, 60_000)
    }
  end

  @doc "Builds and validates one finite request frame."
  @spec build(map(), map(), Identity.id(), map(), String.t(), map(), map(), pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def build(origin, to, request_id, actor, method, args, guards, ttl_ms, n) do
    frame = %{
      "t" => "request",
      "n" => n,
      "origin" => origin,
      "to" => to,
      "request_id" => request_id,
      "actor" => actor,
      "method" => method,
      "args" => args,
      "guards" => guards,
      "ttl_ms" => ttl_ms
    }

    if Schema.validate_frame(frame) == :ok, do: {:ok, frame}, else: {:error, :invalid_request_frame}
  end

  @doc "Admits a received request or returns a bounded duplicate/expiry result."
  @spec admit(state(), map(), integer()) ::
          {:ok, state(), map()} | {:duplicate, state(), term()} | {:duplicate_pending, state()} | {:error, term()}
  def admit(state, frame, now_ms \\ monotonic_ms())

  def admit(%{max_pending: max_pending, max_pending_origin: max_pending_origin} = state, frame, now_ms)
      when is_map(frame) and is_integer(now_ms) do
    state = prune(state, now_ms)

    with :ok <- Schema.validate_frame(frame),
         true <- frame["method"] in @methods do
      request_key = key_for(frame)
      fingerprint = fingerprint(frame)
      origin_key = origin_key(frame)

      cond do
        match?(%{fingerprint: ^fingerprint}, Map.get(state.completed, request_key)) ->
          {:duplicate, state, Map.fetch!(state.completed, request_key).result}

        Map.has_key?(state.completed, request_key) ->
          {:error, :request_id_conflict}

        match?(%{fingerprint: ^fingerprint}, Map.get(state.pending, request_key)) ->
          {:duplicate_pending, state}

        Map.has_key?(state.pending, request_key) ->
          {:error, :request_id_conflict}

        map_size(state.pending) >= max_pending ->
          {:error, :request_capacity}

        Map.get(state.pending_by_origin, origin_key, 0) >= max_pending_origin ->
          {:error, :request_origin_capacity}

        true ->
          pending_request = %{
            frame: frame,
            fingerprint: fingerprint,
            received_at: now_ms,
            deadline: now_ms + frame["ttl_ms"],
            next_part: 0
          }

          {:ok,
           %{
             state
             | pending: Map.put(state.pending, request_key, pending_request),
               pending_by_origin: increment_origin(state.pending_by_origin, origin_key)
           }, pending_request}
      end
    else
      false -> {:error, :request_capacity}
      {:error, _} = error -> error
    end
  end

  def admit(_state, _frame, _now_ms), do: {:error, :invalid_request}

  @doc "Completes a request and retains a short duplicate result horizon."
  @spec complete(state(), Identity.id(), term(), integer()) :: {:ok, state()} | {:error, term()}
  def complete(state, request_id, result, now_ms \\ monotonic_ms()) do
    request_key = resolve_key(state.pending, request_id)

    case Map.pop(state.pending, request_key) do
      {nil, _pending} ->
        {:error, :request_not_pending}

      {pending, remaining} ->
        completed = %{fingerprint: pending.fingerprint, result: result, expires_at: now_ms + state.result_ttl_ms}

        {:ok,
         %{
           state
           | pending: remaining,
             pending_by_origin: decrement_origin(state.pending_by_origin, origin_key(pending.frame)),
             completed: Map.put(state.completed, request_key, completed)
         }}
    end
  end

  @doc "Cancels one pending request without retaining a successful duplicate result."
  @spec cancel(state(), Identity.id()) :: state()
  def cancel(state, request_id) when is_binary(request_id) do
    request_key = resolve_key(state.pending, request_id)

    case Map.pop(state.pending, request_key) do
      {nil, _pending} ->
        state

      {pending, remaining} ->
        %{
          state
          | pending: remaining,
            pending_by_origin: decrement_origin(state.pending_by_origin, origin_key(pending.frame))
        }
    end
  end

  def cancel(state, _request_id), do: state

  @doc "Accepts one reply for a locally originated request with part ordering and source guards."
  @spec accept_reply(state(), map(), integer()) :: {:ok, state(), map()} | {:error, term()}
  def accept_reply(state, frame, now_ms \\ monotonic_ms()) do
    with :ok <- Schema.validate_frame(frame),
         request_key <- reply_key(state.pending, frame),
         %{frame: request, next_part: expected_part} = pending <- state.pending[request_key],
         :ok <- validate_method_payload(request["method"], frame["status"], frame["payload"]),
         :ok <- validate_method_items(request, frame["payload"]),
         :ok <- validate_reply_completion(request["method"], frame["status"], frame["payload"], frame["done"]),
         true <- frame["origin"] == request["to"],
         true <- frame["to"] == request["origin"],
         true <- frame["part"] == expected_part do
      result = %{status: frame["status"], payload: frame["payload"], part: frame["part"], done: frame["done"]}

      if frame["done"] do
        completed = %{fingerprint: pending.fingerprint, result: result, expires_at: now_ms + state.result_ttl_ms}

        {:ok,
         %{
           state
           | pending: Map.delete(state.pending, request_key),
             pending_by_origin: decrement_origin(state.pending_by_origin, origin_key(pending.frame)),
             completed: Map.put(state.completed, request_key, completed)
         }, result}
      else
        next_pending = Map.put(pending, :next_part, expected_part + 1)
        {:ok, %{state | pending: Map.put(state.pending, request_key, next_pending)}, result}
      end
    else
      nil -> {:error, :request_not_pending}
      false -> {:error, :reply_correlation_mismatch}
      {:error, _} = error -> error
    end
  end

  @doc "Expires pending requests and duplicate results using monotonic time."
  @spec expire(state(), integer()) :: {state(), [Identity.id()]}
  def expire(state, now_ms \\ monotonic_ms()) do
    {expired, pending} = Enum.split_with(state.pending, fn {_id, request} -> request.deadline <= now_ms end)
    completed = Enum.reject(state.completed, fn {_id, result} -> result.expires_at <= now_ms end) |> Map.new()

    pending_by_origin =
      Enum.reduce(expired, state.pending_by_origin, fn {_key, request}, counts ->
        decrement_origin(counts, origin_key(request.frame))
      end)

    {%{state | pending: Map.new(pending), pending_by_origin: pending_by_origin, completed: completed},
     Enum.map(expired, fn {_key, request} -> request.frame["request_id"] end)}
  end

  @doc "Builds a correlated reply from the authenticated pending request."
  @spec reply(state(), Identity.id(), pos_integer(), boolean(), String.t(), map(), integer()) ::
          {:ok, state(), map()} | {:error, term()}
  def reply(state, request_id, part, done, status, payload, n)
      when part >= 0 and is_boolean(done) and status in @statuses and is_map(payload) do
    case state.pending[resolve_key(state.pending, request_id)] do
      nil ->
        {:error, :request_not_pending}

      %{frame: request, next_part: expected_part} ->
        if part != expected_part do
          {:error, :reply_part_out_of_order}
        else
          case build_reply_from_request(request, status, payload, part, done, n) do
            {:ok, frame} -> {:ok, state, frame}
            {:error, _} = error -> error
          end
        end
    end
  end

  def reply(_state, _request_id, _part, _done, _status, _payload, _n), do: {:error, :invalid_reply}

  @doc "Builds a reply from an already admitted request without touching correlation state."
  @spec build_reply_from_request(map(), String.t(), map(), non_neg_integer(), boolean(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def build_reply_from_request(request, status, payload, part, done, n)
      when is_map(request) and status in @statuses and is_map(payload) and is_integer(part) and part >= 0 and
             is_boolean(done) and is_integer(n) and n > 0 do
    frame = %{
      "t" => "reply",
      "n" => n,
      "origin" => request["to"],
      "to" => request["origin"],
      "request_id" => request["request_id"],
      "part" => part,
      "done" => done,
      "status" => status,
      "payload" => payload
    }

    with :ok <- validate_method_payload(request["method"], status, payload),
         :ok <- validate_method_items(request, payload),
         :ok <- validate_reply_completion(request["method"], status, payload, done),
         :ok <- Schema.validate_frame(frame) do
      {:ok, frame}
    else
      _ -> {:error, :invalid_reply}
    end
  end

  def build_reply_from_request(_request, _status, _payload, _part, _done, _n), do: {:error, :invalid_reply}

  @doc "Returns the next configured hop for a directed request."
  @spec next_hop([map()], String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def next_hop(roster, local_sid, destination_sid), do: Tree.next_hop(roster, local_sid, destination_sid)

  @doc "Checks the finite query/service/owner/admin authorization boundary."
  @spec authorize(map(), map()) :: :ok | {:error, String.t()}
  def authorize(%{"method" => "query", "args" => %{"command" => command, "view" => view}}, context) do
    owner_detail? = command == "WHOIS" and view == "owner_detail" and context[:owner_detail] == true

    if command in @query_commands and (view == "client" or owner_detail?),
      do: :ok,
      else: {:error, "UNSUPPORTED"}
  end

  def authorize(%{"method" => "service", "args" => %{"scope" => scope}}, context)
      when scope in ~w(global channel) do
    if context[:local_sid] == context[:services_authority] and context[:policy_ready] == true,
      do: :ok,
      else: {:error, "UNAVAILABLE"}
  end

  def authorize(%{"method" => "sasl"}, context) do
    if context[:local_sid] == context[:services_authority] and context[:auth_available] == true,
      do: :ok,
      else: {:error, "UNAVAILABLE"}
  end

  def authorize(%{"method" => "user_action", "args" => %{"action" => action}}, context) do
    target_local? = context[:target_home_sid] == context[:local_sid]
    authority? = context[:local_sid] == context[:services_authority] and action == "account"

    if target_local? or authority?, do: :ok, else: {:error, "STALE"}
  end

  def authorize(%{"method" => "invite"}, context) do
    if context[:target_home_sid] == context[:local_sid], do: :ok, else: {:error, "STALE"}
  end

  def authorize(%{"method" => "snapshot", "args" => %{"scope" => scope}}, context) do
    if scope in ~w(channel policy) and (scope == "channel" or context[:local_sid] == context[:services_authority]),
      do: :ok,
      else: {:error, "UNAVAILABLE"}
  end

  def authorize(%{"method" => "admin", "args" => %{"action" => action, "neighbor_sid" => neighbor}}, context) do
    allowed = action in ~w(rehash restart shutdown enable_edge disable_edge) and configured_action?(context, action)
    neighbor_ok = is_nil(neighbor) or neighbor in List.wrap(context[:direct_neighbors])
    origin_ok = context[:origin_sid] in List.wrap(context[:remote_admin_origins])
    role_ok = context[:operator_role] in List.wrap(context[:remote_admin_roles])

    if allowed and neighbor_ok and origin_ok and role_ok and context[:remote_admin_enabled] == true,
      do: :ok,
      else: {:error, "REJECTED"}
  end

  def authorize(_frame, _context), do: {:error, "UNSUPPORTED"}

  @doc "Constructs standard bounded success and failure payloads."
  @spec ok_payload(map() | nil) :: map()
  def ok_payload(result \\ nil), do: %{"items" => [], "result" => result}

  @doc "Constructs a standard bounded error payload."
  @spec error_payload(String.t(), String.t()) :: map()
  def error_payload(code, message) when code in @statuses and is_binary(message) and byte_size(message) <= 512 do
    %{"items" => [], "error" => %{"code" => code, "message" => message}}
  end

  @doc "Constructs the closed SASL method payload."
  @spec sasl_payload(String.t(), String.t() | nil, map() | nil, String.t()) :: map()
  def sasl_payload(result, data, binding, code)
      when result in ~w(continue success failure aborted) and is_binary(code) and byte_size(code) <= 64 do
    %{"sasl" => result, "data" => data, "binding" => binding, "code" => code}
  end

  @doc "Constructs an error payload in the method's own closed shape."
  @spec failure_payload(map(), String.t(), String.t()) :: map()
  def failure_payload(%{"method" => "sasl"}, status, message) do
    error_payload(status, message)
  end

  def failure_payload(_request, status, message), do: error_payload(status, message)

  @doc "Returns a safe fingerprint for duplicate request detection."
  @spec fingerprint(map()) :: String.t()
  def fingerprint(frame) do
    frame
    |> Map.delete("n")
    |> Map.delete("ttl_ms")
    |> JSON.encode()
    |> Identity.sha256_hex()
  end

  @doc "Returns the current monotonic millisecond clock used for deadlines."
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc "Returns whether a reply status belongs to the closed ENP status set."
  @spec valid_status?(term()) :: boolean()
  def valid_status?(status), do: status in @statuses

  defp origin_key(%{"origin" => %{"sid" => sid, "boot" => boot}}), do: {sid, boot}

  defp increment_origin(counts, key), do: Map.update(counts, key, 1, &(&1 + 1))

  defp decrement_origin(counts, key) do
    case counts[key] do
      nil -> counts
      1 -> Map.delete(counts, key)
      count when count > 1 -> Map.put(counts, key, count - 1)
    end
  end

  defp configured_action?(context, action) do
    if is_binary(action) do
      context
      |> Map.get(:remote_admin_actions, [])
      |> List.wrap()
      |> Enum.any?(fn configured -> to_string(configured) == action end)
    else
      false
    end
  end

  defp validate_method_payload("sasl", "OK", payload) do
    if Map.keys(payload) |> Enum.sort() == ~w(binding code data sasl) and
         payload["sasl"] in ~w(continue success failure aborted) and
         (is_nil(payload["data"]) or is_binary(payload["data"])) and
         (is_nil(payload["binding"]) or valid_binding?(payload["binding"])) and
         is_binary(payload["code"]) and byte_size(payload["code"]) <= 64,
       do: :ok,
       else: {:error, :invalid_sasl_reply_payload}
  end

  defp validate_method_payload("sasl", status, payload) when status != "OK",
    do: Schema.validate_reply_payload(status, payload)

  defp validate_method_payload("query", "OK", %{"items" => _items, "result" => result} = payload) do
    with :ok <- Schema.validate_reply_payload("OK", payload),
         :ok <- validate_query_result(result) do
      :ok
    end
  end

  defp validate_method_payload("service", "OK", %{"items" => _items, "result" => nil} = payload),
    do: Schema.validate_reply_payload("OK", payload)

  defp validate_method_payload(method, "OK", %{"items" => [], "result" => result} = payload)
       when method in ~w(user_action invite admin) do
    with :ok <- Schema.validate_reply_payload("OK", payload),
         :ok <- validate_action_result(result) do
      :ok
    end
  end

  defp validate_method_payload("snapshot", "OK", %{"snapshot" => snapshot, "phase" => "begin"} = payload)
       when snapshot == "policy" do
    with :ok <- Schema.validate_reply_payload("OK", %{"items" => [], "result" => payload}),
         true <- Map.keys(payload) |> Enum.sort() == ~w(epoch objects phase revision snapshot),
         true <- Identity.valid_id?(payload["epoch"]),
         true <- Identity.valid_uint?(payload["revision"]),
         true <- Identity.valid_uint?(payload["objects"]) do
      :ok
    else
      _ -> {:error, :invalid_policy_snapshot_begin}
    end
  end

  defp validate_method_payload("snapshot", "OK", %{"snapshot" => "policy", "phase" => "rows"} = payload) do
    with true <- Map.keys(payload) |> Enum.sort() == ~w(rows phase snapshot),
         true <- is_list(payload["rows"]) and length(payload["rows"]) <= 256,
         true <-
           Enum.all?(payload["rows"], fn
             %{"entity" => entity, "key" => key, "value" => value} = object ->
               Map.keys(object) |> Enum.sort() == ~w(entity key value) and
                 Policy.validate_public_object(entity, key, value) == :ok

             _ ->
               false
           end) do
      :ok
    else
      _ -> {:error, :invalid_policy_snapshot_rows}
    end
  end

  defp validate_method_payload("snapshot", "OK", %{"snapshot" => "policy", "phase" => "end"} = payload) do
    with true <- Map.keys(payload) |> Enum.sort() == ~w(epoch objects phase revision snapshot),
         true <- Identity.valid_id?(payload["epoch"]),
         true <- Identity.valid_uint?(payload["revision"]),
         true <- Identity.valid_uint?(payload["objects"]) do
      :ok
    else
      _ -> {:error, :invalid_policy_snapshot_end}
    end
  end

  defp validate_method_payload("snapshot", "OK", %{"phase" => "begin", "scope" => "channel"} = payload) do
    with true <- Map.keys(payload) |> Enum.sort() == ~w(channel phase scope),
         true <- Schema.valid_bytes?(payload["channel"], max: 512, allow_empty: false) do
      :ok
    else
      _ -> {:error, :invalid_channel_snapshot_begin}
    end
  end

  defp validate_method_payload("snapshot", "OK", %{"phase" => "rows"} = payload) do
    with true <- Map.keys(payload) |> Enum.sort() == ~w(phase rows),
         true <- is_list(payload["rows"]) and length(payload["rows"]) <= 256,
         :ok <-
           Enum.reduce_while(payload["rows"], :ok, fn row, :ok ->
             if Schema.validate_row(row) == :ok, do: {:cont, :ok}, else: {:halt, {:error, :invalid_snapshot_row}}
           end) do
      :ok
    else
      _ -> {:error, :invalid_channel_snapshot_rows}
    end
  end

  defp validate_method_payload("snapshot", "OK", %{"phase" => "end", "scope" => "channel"} = payload) do
    with true <- Map.keys(payload) |> Enum.sort() == ~w(exists phase rows scope),
         true <- Identity.valid_uint?(payload["rows"]),
         true <- is_boolean(payload["exists"]) do
      :ok
    else
      _ -> {:error, :invalid_channel_snapshot_end}
    end
  end

  defp validate_method_payload("snapshot", _status, _payload), do: {:error, :invalid_snapshot_reply_payload}

  defp validate_method_payload(_method, status, payload), do: Schema.validate_reply_payload(status, payload)

  defp validate_reply_completion(_method, status, _payload, _done) when status != "OK", do: :ok

  defp validate_reply_completion(method, "OK", %{"phase" => phase}, done) when method == "snapshot" do
    expected_done = phase == "end"
    if done == expected_done, do: :ok, else: {:error, :invalid_reply_completion}
  end

  defp validate_reply_completion(method, "OK", _payload, done) when method in ~w(sasl user_action invite admin) do
    if done, do: :ok, else: {:error, :invalid_reply_completion}
  end

  defp validate_reply_completion(_method, "OK", _payload, _done), do: :ok

  defp validate_query_result(nil), do: :ok

  defp validate_query_result(
         %{"uid" => uid, "signon_ms" => signon_ms, "idle_ms" => idle_ms, "secure_client" => secure} = result
       ) do
    if Map.keys(result) |> Enum.sort() == ~w(idle_ms secure_client signon_ms uid) and
         Identity.valid_id?(uid) and Identity.valid_positive?(signon_ms) and
         (is_nil(idle_ms) or Identity.valid_uint?(idle_ms)) and is_boolean(secure),
       do: :ok,
       else: {:error, :invalid_query_result}
  end

  defp validate_query_result(%{"command" => command, "params" => params, "server" => server, "users" => users} = result) do
    if Map.keys(result) |> Enum.sort() == ~w(command params server users) and
         is_binary(command) and byte_size(command) <= 32 and String.valid?(command) and
         is_list(params) and length(params) <= 15 and Enum.all?(params, &Schema.valid_bytes?(&1, max: 4_096)) and
         Identity.valid_sid?(server) and is_list(users) and length(users) <= 256 and Enum.all?(users, &is_map/1),
       do: :ok,
       else: {:error, :invalid_query_result}
  end

  defp validate_query_result(_result), do: {:error, :invalid_query_result}

  defp validate_action_result(%{"accepted" => true} = result) do
    keys = Map.keys(result)

    if keys == ["accepted"] or
         (Enum.sort(keys) == ~w(accepted owner_rev) and Identity.valid_uint?(result["owner_rev"])),
       do: :ok,
       else: {:error, :invalid_action_result}
  end

  defp validate_action_result(_result), do: {:error, :invalid_action_result}

  defp validate_method_items(
         %{"method" => "query", "args" => %{"command" => command}, "to" => %{"sid" => sid}},
         %{"items" => items}
       )
       when is_list(items) and is_binary(command) and is_binary(sid) do
    if Enum.all?(items, fn item ->
         query_reply_command?(command, item["command"]) and item["source"] == %{"server" => sid}
       end) do
      :ok
    else
      {:error, :invalid_query_reply_item}
    end
  end

  defp validate_method_items(
         %{"method" => "service", "args" => %{"service" => service}},
         %{"items" => items}
       )
       when is_list(items) and service in ~w(NickServ ChanServ) do
    if Enum.all?(items, fn item ->
         service_reply_command?(item["command"]) and item["source"] == %{"service" => service}
       end) do
      :ok
    else
      {:error, :invalid_service_reply_item}
    end
  end

  defp validate_method_items(%{"method" => method}, %{"items" => []})
       when method in ~w(user_action invite admin),
       do: :ok

  defp validate_method_items(%{"method" => method}, %{"items" => _items})
       when method in ~w(user_action invite admin),
       do: {:error, :invalid_action_reply_items}

  defp validate_method_items(_request, _payload), do: :ok

  defp numeric_reply_command?(command) when is_binary(command),
    do: Regex.match?(~r/\A[0-9]{3}\z/, command)

  defp query_reply_command?(query, command) when is_binary(query) and is_binary(command) do
    command in Map.get(@query_reply_commands, query, [])
  end

  defp query_reply_command?(_query, _command), do: false

  defp service_reply_command?(command) when is_binary(command) do
    command in ~w(ACCOUNT AWAY CHGHOST INVITE JOIN KICK MODE NICK NOTICE PRIVMSG QUIT TOPIC WARN) or
      numeric_reply_command?(command)
  end

  defp service_reply_command?(_command), do: false

  defp valid_binding?(
         %{"account_id" => account_id, "auth_epoch" => auth_epoch, "policy_epoch" => policy_epoch} = binding
       ) do
    Map.keys(binding) |> Enum.sort() == ~w(account_id auth_epoch policy_epoch) and
      Identity.valid_id?(account_id) and Identity.valid_positive?(auth_epoch) and Identity.valid_id?(policy_epoch)
  end

  defp valid_binding?(_binding), do: false

  @doc "Scopes a request identity by the authenticated origin boot."
  @spec key_for(map()) :: {String.t(), Identity.id(), Identity.id()}
  def key_for(%{"origin" => %{"sid" => sid, "boot" => boot}, "request_id" => request_id}),
    do: {sid, boot, request_id}

  defp prune(state, now_ms) do
    {state, _expired} = expire(state, now_ms)
    state
  end

  defp resolve_key(map, request_id) do
    cond do
      Map.has_key?(map, request_id) -> request_id
      true -> Enum.find_value(map, fn {key, request} -> if request.frame["request_id"] == request_id, do: key end)
    end
  end

  defp reply_key(pending, %{"request_id" => request_id}) do
    Enum.find_value(pending, fn
      {key, %{frame: %{"request_id" => ^request_id}}} -> key
      _ -> nil
    end)
  end

  defp reply_key(_pending, _frame), do: nil
end
