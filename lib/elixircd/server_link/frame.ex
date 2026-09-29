defmodule ElixIRCd.ServerLink.Frame do
  @moduledoc """
  Bounded, length-prefixed JSON for the native server-link socket.

  A frame has a four-byte unsigned length followed by UTF-8 JSON. The decoder
  accepts only the closed frame vocabulary; a peer cannot create atoms or
  pass arbitrary IRC lines through this socket.
  """

  @max_bytes 1_048_576
  @max_delta_entries 1_024
  @max_snapshot_entries 100_000
  @version 14
  @case_mappings ~w(ascii rfc1459 strict_rfc1459)
  @types [
    "hello",
    "ping",
    "pong",
    "route_up",
    "route_down",
    "reject",
    "snapshot_begin",
    "snapshot_user",
    "snapshot_channel",
    "snapshot_member",
    "snapshot_list",
    "snapshot_invite",
    "snapshot_end",
    "delta_begin",
    "delta_entry",
    "delta_end",
    "direct_message",
    "direct_result",
    "channel_message",
    "topic_request",
    "topic_result",
    "mode_request",
    "mode_result",
    "kick_request",
    "kick_result",
    "invite_request",
    "invite_result",
    "invite_notice",
    "user_upsert",
    "user_remove"
  ]

  alias ElixIRCd.Config.Types
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Utils.CaseMapping

  @type frame :: map()

  @doc "Maximum JSON payload size, excluding the four-byte length."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Protocol version carried in every greeting."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Maximum number of changed entries in one atomic channel delta."
  @spec max_delta_entries() :: pos_integer()
  def max_delta_entries, do: @max_delta_entries

  @doc "Maximum aggregate number of entries declared by one origin snapshot."
  @spec max_snapshot_entries() :: pos_integer()
  def max_snapshot_entries, do: @max_snapshot_entries

  @doc "Builds a fresh greeting for a single TLS connection."
  @spec hello(String.t(), String.t()) :: frame()
  def hello(id, network) do
    %{
      "type" => "hello",
      "version" => @version,
      "id" => id,
      "network" => network,
      "case_mapping" => Application.fetch_env!(:elixircd, :settings)[:case_mapping] |> Atom.to_string(),
      "nonce" => Base.encode64(:crypto.strong_rand_bytes(32), padding: false)
    }
  end

  @doc "Encodes one checked frame."
  @spec encode(frame()) :: {:ok, binary()} | {:error, :invalid_frame | :frame_too_large}
  def encode(frame) do
    with :ok <- validate(frame),
         {:ok, payload} <- Jason.encode(frame) do
      if byte_size(payload) > @max_bytes do
        {:error, :frame_too_large}
      else
        {:ok, <<byte_size(payload)::unsigned-32, payload::binary>>}
      end
    else
      _ -> {:error, :invalid_frame}
    end
  end

  @doc "Sends one frame over TLS."
  @spec send(:ssl.sslsocket(), frame()) :: :ok | {:error, term()}
  def send(socket, frame) do
    with {:ok, data} <- encode(frame), do: :ssl.send(socket, data)
  end

  @doc "Reads exactly one bounded frame over a passive TLS socket."
  @spec recv(:ssl.sslsocket(), timeout()) :: {:ok, frame()} | {:error, term()}
  def recv(socket, timeout) do
    with {:ok, <<length::unsigned-32>>} <- :ssl.recv(socket, 4, timeout),
         :ok <- valid_length(length),
         {:ok, payload} <- :ssl.recv(socket, length, timeout),
         {:ok, frame} <- Jason.decode(payload),
         :ok <- validate(frame) do
      {:ok, frame}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_frame}
    end
  end

  @doc "Decodes the first frame from an active socket buffer, preserving any following bytes."
  @spec decode_one(binary()) :: {:ok, frame(), binary()} | :more | {:error, term()}
  def decode_one(buffer) when byte_size(buffer) < 4, do: :more

  def decode_one(<<length::unsigned-32, rest::binary>>) do
    with :ok <- valid_length(length), do: decode_body(length, rest)
  end

  defp decode_body(length, rest) when byte_size(rest) < length, do: :more

  defp decode_body(length, rest) do
    <<payload::binary-size(^length), remaining::binary>> = rest

    with {:ok, frame} <- Jason.decode(payload),
         :ok <- validate(frame) do
      {:ok, frame, remaining}
    else
      _ -> {:error, :invalid_frame}
    end
  end

  @doc "Validates all fields, rejecting unknown keys and types."
  @spec validate(term()) :: :ok | {:error, :invalid_frame}
  def validate(%{"type" => "hello"} = frame) do
    valid =
      exact_keys?(frame, ["type", "version", "id", "network", "case_mapping", "nonce"]) and
        frame["version"] == @version and
        Types.valid?(:server_hostname, frame["id"]) and
        Types.valid?(:text, frame["network"]) and
        frame["case_mapping"] in @case_mappings and
        valid_nonce?(frame["nonce"])

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => type} = frame) when type in ["ping", "pong"] do
    if exact_keys?(frame, ["type", "sequence"]) and is_integer(frame["sequence"]) and
         frame["sequence"] >= 0 and frame["sequence"] <= 9_007_199_254_740_991 do
      :ok
    else
      {:error, :invalid_frame}
    end
  end

  def validate(%{"type" => "route_up"} = frame) do
    path = frame["path"]

    valid =
      exact_keys?(frame, ~w(type origin epoch path)) and
        origin?(frame["origin"]) and UserPayload.uid?(frame["epoch"]) and
        is_list(path) and length(path) in 1..64 and
        Enum.all?(path, &origin?/1) and Enum.uniq(path) == path and hd(path) == frame["origin"]

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "route_down"} = frame) do
    if exact_keys?(frame, ~w(type origin epoch)) and origin?(frame["origin"]) and
         UserPayload.uid?(frame["epoch"]),
       do: :ok,
       else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "reject"} = frame) do
    codes = ~w(topology_cycle duplicate_route route_changed wrong_route_sender)

    if exact_keys?(frame, ~w(type code)) and frame["code"] in codes,
      do: :ok,
      else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "snapshot_begin"} = frame) do
    counts = ~w(channel_count member_count list_count invite_count)
    keys = ~w(type origin epoch cursor count)

    valid =
      (exact_keys?(frame, keys) or exact_keys?(frame, keys ++ counts)) and
        origin?(frame["origin"]) and UserPayload.uid?(frame["epoch"]) and
        sequence?(frame["cursor"]) and count?(frame["count"]) and
        Enum.all?(counts, &count?(Map.get(frame, &1, 0))) and
        Enum.sum(Enum.map(["count" | counts], &Map.get(frame, &1, 0))) <= @max_snapshot_entries

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "snapshot_user"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch user)) and
        origin?(frame["origin"]) and UserPayload.uid?(frame["epoch"]) and
        UserPayload.validate(frame["user"]) == :ok

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => type} = frame)
      when type in ["snapshot_channel", "snapshot_member", "snapshot_list", "snapshot_invite"] do
    field = String.replace_prefix(type, "snapshot_", "")

    valid =
      exact_keys?(frame, ["type", "origin", "epoch", field]) and
        origin?(frame["origin"]) and UserPayload.uid?(frame["epoch"]) and
        valid_channel_entry?(field, frame[field])

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "snapshot_end"} = frame) do
    if exact_keys?(frame, ~w(type origin epoch)) and origin?(frame["origin"]) and
         UserPayload.uid?(frame["epoch"]),
       do: :ok,
       else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "delta_begin"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch sequence count)) and
        origin?(frame["origin"]) and UserPayload.uid?(frame["epoch"]) and
        sequence?(frame["sequence"]) and is_integer(frame["count"]) and frame["count"] in 1..@max_delta_entries

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "delta_entry"} = frame) do
    valid =
      valid_delta_entry_keys?(frame) and
        origin?(frame["origin"]) and UserPayload.uid?(frame["epoch"]) and
        frame["action"] in ["upsert", "remove"] and valid_channel_entry?(frame["field"], frame["entry"])

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "delta_end"} = frame) do
    if exact_keys?(frame, ~w(type origin epoch sequence)) and origin?(frame["origin"]) and
         UserPayload.uid?(frame["epoch"]) and sequence?(frame["sequence"]),
       do: :ok,
       else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "direct_message"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch from_uid to_origin to_uid command text tags ttl id sent_at)) and
        direct_identity?(frame) and direct_content?(frame) and sent_at?(frame["sent_at"])

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "direct_result"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch to_origin to_uid id code away ttl)) and
        topic_result_identity?(frame) and is_integer(frame["ttl"]) and frame["ttl"] in 1..64 and
        frame["code"] in ~w(ok unknown_target registered_only accept_only silent) and
        if(frame["code"] == "ok",
          do: UserPayload.valid_away?(frame["away"]),
          else: is_nil(frame["away"])
        )

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "channel_message"} = frame) do
    valid =
      exact_keys?(
        frame,
        ~w(type origin epoch from_uid channel channel_creator channel_created_at target command text tags ttl id)
      ) and
        channel_message_identity?(frame) and direct_content?(frame)

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "topic_request"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch from_uid to_origin channel text id ttl)) and
        direct_identity?(Map.put(frame, "to_uid", frame["from_uid"])) and
        is_integer(frame["ttl"]) and frame["ttl"] in 1..64 and
        channel_name?(frame["channel"]) and safe_message_text?(frame["text"], 4_096)

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "topic_result"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch to_origin to_uid channel id code ttl)) and
        topic_result_identity?(frame) and topic_result_content?(frame)

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "mode_request"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch from_uid to_origin channel modes values id ttl)) and
        direct_identity?(Map.put(frame, "to_uid", frame["from_uid"])) and
        is_integer(frame["ttl"]) and frame["ttl"] in 1..64 and channel_name?(frame["channel"]) and
        mode_string?(frame["modes"]) and mode_values?(frame["values"])

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "mode_result"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch to_origin to_uid channel id code ttl)) and
        topic_result_identity?(frame) and is_integer(frame["ttl"]) and frame["ttl"] in 1..64 and
        channel_name?(frame["channel"]) and
        frame["code"] in ~w(ok stale_authority unknown_sender not_on_channel operator_required invalid_mode unsupported_mode registered_channel)

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "kick_request"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch from_uid to_origin to_uid channel reason id ttl)) and
        direct_identity?(frame) and channel_name?(frame["channel"]) and
        safe_message_text?(frame["reason"], 1_600) and is_integer(frame["ttl"]) and frame["ttl"] in 1..64

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "kick_result"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch to_origin to_uid target_uid channel id code ttl)) and
        topic_result_identity?(frame) and UserPayload.uid?(frame["target_uid"]) and
        channel_name?(frame["channel"]) and is_integer(frame["ttl"]) and frame["ttl"] in 1..64 and
        frame["code"] in ~w(ok stale_channel unknown_sender not_on_channel operator_required unknown_target target_not_on_channel registered_channel)

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "invite_request"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch from_uid to_origin to_uid channel id ttl)) and
        direct_identity?(frame) and channel_name?(frame["channel"]) and
        is_integer(frame["ttl"]) and frame["ttl"] in 1..64

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "invite_result"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch to_origin to_uid target_uid channel id code away ttl)) and
        topic_result_identity?(frame) and invite_result_content?(frame)

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "invite_notice"} = frame) do
    valid =
      exact_keys?(
        frame,
        ~w(type origin epoch id from_uid from_mask from_account target_origin target_uid target_nick channel channel_creator channel_created_at ttl)
      ) and invite_notice_identity?(frame) and invite_notice_actor?(frame) and invite_notice_target?(frame) and
        invite_notice_channel?(frame)

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "user_upsert"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch sequence user)) and
        origin?(frame["origin"]) and UserPayload.uid?(frame["epoch"]) and
        sequence?(frame["sequence"]) and UserPayload.validate(frame["user"]) == :ok

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(%{"type" => "user_remove"} = frame) do
    valid =
      exact_keys?(frame, ~w(type origin epoch sequence uid)) and
        origin?(frame["origin"]) and UserPayload.uid?(frame["epoch"]) and
        sequence?(frame["sequence"]) and UserPayload.uid?(frame["uid"])

    if valid, do: :ok, else: {:error, :invalid_frame}
  end

  def validate(_frame), do: {:error, :invalid_frame}

  defp invite_notice_identity?(frame) do
    origin?(frame["origin"]) and UserPayload.uid?(frame["epoch"]) and UserPayload.uid?(frame["id"]) and
      is_integer(frame["ttl"]) and frame["ttl"] in 1..64
  end

  defp invite_notice_actor?(frame) do
    UserPayload.uid?(frame["from_uid"]) and safe_message_text?(frame["from_mask"], 512) and
      frame["from_mask"] != "" and
      (is_nil(frame["from_account"]) or
         (is_binary(frame["from_account"]) and Types.valid?(:text, frame["from_account"]) and
            byte_size(frame["from_account"]) <= 64))
  end

  defp invite_notice_target?(frame) do
    origin?(frame["target_origin"]) and UserPayload.uid?(frame["target_uid"]) and
      is_binary(frame["target_nick"]) and Types.valid?(:nickname, frame["target_nick"]) and
      byte_size(frame["target_nick"]) <= 64
  end

  defp invite_notice_channel?(frame) do
    channel_name?(frame["channel"]) and origin?(frame["channel_creator"]) and sent_at?(frame["channel_created_at"])
  end

  defp invite_result_content?(frame) do
    UserPayload.uid?(frame["target_uid"]) and channel_name?(frame["channel"]) and
      is_integer(frame["ttl"]) and frame["ttl"] in 1..64 and
      frame["code"] in ~w(ok stale_channel unknown_sender not_on_channel operator_required unknown_target already_on_channel registered_channel) and
      if(frame["code"] == "ok", do: UserPayload.valid_away?(frame["away"]), else: is_nil(frame["away"]))
  end

  defp topic_result_identity?(frame) do
    origin?(frame["origin"]) and origin?(frame["to_origin"]) and
      UserPayload.uid?(frame["epoch"]) and UserPayload.uid?(frame["to_uid"]) and UserPayload.uid?(frame["id"])
  end

  defp topic_result_content?(frame) do
    is_integer(frame["ttl"]) and frame["ttl"] in 1..64 and channel_name?(frame["channel"]) and
      frame["code"] in ~w(ok stale_authority unknown_sender not_on_channel topic_locked operator_required invalid_topic)
  end

  defp mode_string?(value) do
    is_binary(value) and byte_size(value) <= 64 and String.valid?(value) and
      Regex.match?(~r/\A[+-][A-Za-z+-]{0,63}\z/, value)
  end

  defp mode_values?(values) do
    is_list(values) and length(values) <= 64 and Enum.all?(values, &safe_message_text?(&1, 255))
  end

  @doc "Returns the closed frame vocabulary."
  @spec supported_types() :: [String.t()]
  def supported_types, do: @types

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp valid_channel_entry?("channel", entry), do: ChannelPayload.validate_channel(entry) == :ok
  defp valid_channel_entry?("member", entry), do: ChannelPayload.validate_member(entry) == :ok
  defp valid_channel_entry?("list", entry), do: ChannelPayload.validate_list(entry) == :ok
  defp valid_channel_entry?("invite", entry), do: ChannelPayload.validate_invite(entry) == :ok
  defp valid_channel_entry?(_field, _entry), do: false

  defp client_tags?(tags) when is_map(tags) and map_size(tags) <= 32 do
    Enum.all?(tags, fn {key, value} ->
      is_binary(key) and Regex.match?(~r/\A\+[A-Za-z0-9.\/-]{1,64}\z/, key) and
        (is_nil(value) or safe_message_text?(value, 512))
    end)
  end

  defp client_tags?(_tags), do: false

  defp safe_message_text?(value, max) do
    is_binary(value) and byte_size(value) <= max and String.valid?(value) and
      not String.contains?(value, ["\r", "\n", <<0>>])
  end

  defp direct_identity?(frame) do
    origin?(frame["origin"]) and origin?(frame["to_origin"]) and
      UserPayload.uid?(frame["epoch"]) and UserPayload.uid?(frame["from_uid"]) and
      UserPayload.uid?(frame["to_uid"]) and UserPayload.uid?(frame["id"])
  end

  defp channel_message_identity?(frame) do
    channel = frame["channel"]

    origin?(frame["origin"]) and UserPayload.uid?(frame["epoch"]) and
      UserPayload.uid?(frame["from_uid"]) and UserPayload.uid?(frame["id"]) and channel_name?(channel) and
      channel_message_target?(frame["target"], channel) and
      origin?(frame["channel_creator"]) and sent_at?(frame["channel_created_at"])
  end

  defp channel_message_target?(target, channel) when is_binary(target) do
    case target do
      "@" <> name -> channel_name?(name) and CaseMapping.normalize(name) == CaseMapping.normalize(channel)
      "+" <> name -> channel_name?(name) and CaseMapping.normalize(name) == CaseMapping.normalize(channel)
      name -> channel_name?(name) and CaseMapping.normalize(name) == CaseMapping.normalize(channel)
    end
  end

  defp channel_message_target?(_target, _channel), do: false

  defp channel_name?(channel) do
    is_binary(channel) and byte_size(channel) <= 255 and Types.valid?(:channel_pattern, channel) and
      String.starts_with?(channel, "#")
  end

  defp direct_content?(frame) do
    frame["command"] in ["PRIVMSG", "NOTICE"] and safe_message_text?(frame["text"], 4_096) and
      client_tags?(frame["tags"]) and is_integer(frame["ttl"]) and frame["ttl"] in 1..64
  end

  defp sent_at?(value) when is_binary(value) and byte_size(value) <= 40,
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp sent_at?(_value), do: false

  defp valid_delta_entry_keys?(frame) do
    exact_keys?(frame, ~w(type origin epoch field action entry)) or
      (exact_keys?(frame, ~w(type origin epoch field action entry kick)) and
         frame["field"] == "member" and frame["action"] == "remove" and valid_kick?(frame["kick"]))
  end

  defp valid_kick?(kick) when is_map(kick) do
    exact_keys?(kick, ~w(actor_origin actor_uid actor_mask reason)) and
      origin?(kick["actor_origin"]) and UserPayload.uid?(kick["actor_uid"]) and
      is_binary(kick["actor_mask"]) and kick["actor_mask"] != "" and
      safe_message_text?(kick["actor_mask"], 512) and safe_message_text?(kick["reason"], 1_600)
  end

  defp valid_kick?(_kick), do: false

  defp origin?(origin), do: Types.valid?(:server_hostname, origin) and origin == String.downcase(origin)
  defp sequence?(value), do: is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991
  defp count?(value), do: is_integer(value) and value >= 0 and value <= 1_000_000

  defp valid_nonce?(nonce) when is_binary(nonce) and byte_size(nonce) == 43 do
    match?({:ok, <<_::binary-size(32)>>}, Base.decode64(nonce, padding: false))
  end

  defp valid_nonce?(_nonce), do: false

  defp valid_length(length) when length > 0 and length <= @max_bytes, do: :ok
  defp valid_length(length) when length > @max_bytes, do: {:error, :frame_too_large}
  defp valid_length(_length), do: {:error, :invalid_frame}
end
