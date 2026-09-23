defmodule ElixIRCd.Server.S2S.Protocol do
  @moduledoc """
  ENP/1 length-prefixed JSON framing.

  The protocol never shares the IRC line parser. A session owns the partial
  frame buffer and calls this module with arbitrary TLS chunks; complete frames
  are returned in arrival order and an incomplete tail is retained unchanged.
  """

  alias ElixIRCd.Server.S2S.JSON
  alias ElixIRCd.Server.S2S.Schema

  @absolute_limit 1_048_576
  @hello_limit 4_096
  @message_limit 8_192
  @request_limit 65_536
  @ordinary_limit 65_536
  @topology_limit @absolute_limit
  @max_values 8_192
  @topology_values 65_536

  @typedoc "Body and frame budgets enforced by the ENP/1 codec."
  @type limits :: %{
          hello: pos_integer(),
          message: pos_integer(),
          request: pos_integer(),
          ordinary: pos_integer(),
          topology: pos_integer(),
          absolute: pos_integer()
        }

  @doc "Returns the protocol body/frame budgets."
  @spec limits() :: limits()
  def limits do
    %{
      hello: @hello_limit,
      message: @message_limit,
      request: @request_limit,
      ordinary: @ordinary_limit,
      topology: @topology_limit,
      absolute: @absolute_limit
    }
  end

  @doc "Encodes a validated map as one ENP length-prefixed frame."
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(frame) when is_map(frame) do
    with :ok <- Schema.validate_frame(frame),
         body <- JSON.encode(frame),
         :ok <- validate_encoded_body(frame, body) do
      {:ok, <<byte_size(body)::unsigned-big-32, body::binary>>}
    else
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, {:encode_failed, Exception.message(error)}}
  end

  def encode(_frame), do: {:error, :frame_must_be_object}

  @doc "Encodes a frame or raises ArgumentError for invalid data."
  @spec encode!(map()) :: binary()
  def encode!(frame) do
    case encode(frame) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, "invalid ENP frame: #{inspect(reason)}"
    end
  end

  @doc "Decodes one complete JSON body and validates its closed schema."
  @spec decode_body(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def decode_body(body, options \\ [])

  def decode_body(body, options) when is_binary(body) do
    max_body = Keyword.get(options, :max_body, @absolute_limit)

    values =
      if topology_body?(body),
        do: Keyword.get(options, :topology_values, @topology_values),
        else: Keyword.get(options, :max_values, @max_values)

    with true <- byte_size(body) <= max_body,
         :ok <- JSON.scan(body, max_depth: 16, max_values: values),
         {:ok, frame} <- JSON.decode_object(body, max_depth: 16, max_values: values),
         :ok <- Schema.validate_frame(frame),
         :ok <- validate_encoded_body(frame, body) do
      {:ok, frame}
    else
      false -> {:error, :frame_too_large}
      {:error, _} = error -> error
    end
  end

  def decode_body(_body, _options), do: {:error, :invalid_frame_body}

  @doc "Feeds arbitrary transport bytes and returns complete frames plus a tail."
  @spec feed(binary(), binary(), keyword() | pos_integer()) ::
          {:ok, [map() | {map(), binary()}], binary()} | {:error, term()}
  def feed(buffer, data, options \\ [])

  def feed(buffer, data, options) when is_binary(buffer) and is_binary(data) do
    options = normalize_feed_options(options)

    cond do
      byte_size(buffer) > @absolute_limit + 4 -> {:error, :partial_frame_too_large}
      byte_size(data) > @absolute_limit + 4 -> {:error, :incoming_chunk_too_large}
      byte_size(buffer) + byte_size(data) > @absolute_limit + 4 -> {:error, :partial_frame_too_large}
      true -> extract_frames(buffer <> data, options, [])
    end
  end

  def feed(_buffer, _data, _options), do: {:error, :invalid_transport_buffer}

  @doc "Checks a per-direction post-hello sequence number."
  @spec validate_sequence([map()], pos_integer()) :: :ok | {:error, term()}
  def validate_sequence(frames, expected) when is_list(frames) and is_integer(expected) and expected > 0 do
    Enum.reduce_while(frames, expected, fn frame, current ->
      case frame["n"] do
        ^current -> {:cont, current + 1}
        received -> {:halt, {:error, {:sequence, current, received}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _next -> :ok
    end
  end

  def validate_sequence(_frames, _expected), do: {:error, :invalid_sequence_state}

  @doc "Returns the body budget for a frame phase/type."
  @spec body_limit(map() | String.t(), keyword()) :: pos_integer()
  def body_limit(frame_or_type, options \\ []) do
    custom = Keyword.get(options, :limit)

    if is_integer(custom) and custom > 0 do
      min(custom, @absolute_limit)
    else
      if is_map(frame_or_type) and topology_frame?(frame_or_type),
        do: @topology_limit,
        else: body_limit_for_type(frame_type(frame_or_type))
    end
  end

  defp body_limit_for_type(type) do
    case type do
      "hello" -> @hello_limit
      "message" -> @message_limit
      type when type in ~w(request reply) -> @request_limit
      "topology" -> @topology_limit
      _ -> @ordinary_limit
    end
  end

  defp extract_frames(data, options, acc) do
    if max_frames_reached?(options, acc) do
      {:ok, Enum.reverse(acc), data}
    else
      extract_frames_unbounded(data, options, acc)
    end
  end

  defp extract_frames_unbounded(<<>>, _options, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp extract_frames_unbounded(data, _options, acc) when byte_size(data) < 4 do
    {:ok, Enum.reverse(acc), data}
  end

  defp extract_frames_unbounded(<<length::unsigned-big-32, rest::binary>> = data, options, acc) do
    limit = Keyword.fetch!(options, :limit)

    cond do
      length > limit ->
        {:error, {:frame_too_large, length, limit}}

      length > @absolute_limit ->
        {:error, :frame_too_large}

      byte_size(rest) < length ->
        if byte_size(data) > limit + 4, do: {:error, :partial_frame_too_large}, else: {:ok, Enum.reverse(acc), data}

      true ->
        body = binary_part(rest, 0, length)
        tail = binary_part(rest, length, byte_size(rest) - length)

        case decode_body(body, max_body: limit, max_values: values_limit(options, body)) do
          {:ok, frame} ->
            extracted = if Keyword.get(options, :include_bodies, false), do: {frame, body}, else: frame
            extract_frames(tail, options, [extracted | acc])

          {:error, reason} ->
            {:error, {:invalid_frame, reason}}
        end
    end
  end

  defp normalize_feed_options(limit) when is_integer(limit) do
    [limit: positive_budget(limit, @absolute_limit), max_values: @max_values, topology_values: @topology_values]
  end

  defp normalize_feed_options(options) when is_list(options) do
    [
      limit: positive_budget(Keyword.get(options, :limit), @absolute_limit),
      max_values: positive_budget(Keyword.get(options, :max_values), @max_values),
      topology_values: positive_budget(Keyword.get(options, :topology_values), @topology_values),
      include_bodies: Keyword.get(options, :include_bodies, false) == true,
      max_frames: normalize_max_frames(Keyword.get(options, :max_frames))
    ]
  end

  defp normalize_feed_options(_options),
    do: [limit: @absolute_limit, max_values: @max_values, topology_values: @topology_values, max_frames: :infinity]

  defp normalize_max_frames(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_frames(_value), do: :infinity

  defp max_frames_reached?(options, acc) do
    case Keyword.get(options, :max_frames, :infinity) do
      :infinity -> false
      max_frames -> length(acc) >= max_frames
    end
  end

  defp positive_budget(value, _default) when is_integer(value) and value > 0, do: min(value, @absolute_limit)
  defp positive_budget(_value, default), do: default

  defp values_limit(options, body) do
    if topology_body?(body),
      do: Keyword.get(options, :topology_values, @topology_values),
      else: Keyword.get(options, :max_values, @max_values)
  end

  defp topology_body?(body) do
    Regex.match?(~r/"kind"\s*:\s*"topology\./, body)
  end

  defp topology_frame?(%{"t" => "topology"}), do: true

  defp topology_frame?(%{"t" => "state", "changes" => changes}) when is_list(changes),
    do: Enum.any?(changes, &topology_row?/1)

  defp topology_frame?(%{"t" => "sync", "rows" => rows}) when is_list(rows), do: Enum.any?(rows, &topology_row?/1)
  defp topology_frame?(_frame), do: false

  defp topology_row?(%{"kind" => "topology." <> _rest}), do: true
  defp topology_row?(_row), do: false

  defp frame_type(%{"t" => type}), do: type
  defp frame_type(type) when is_binary(type), do: type
  defp frame_type(_frame), do: nil

  defp validate_encoded_body(frame, body) do
    limit = body_limit(frame)

    cond do
      byte_size(body) > limit -> {:error, {:frame_too_large, byte_size(body), limit}}
      byte_size(body) > @absolute_limit -> {:error, :frame_too_large}
      true -> :ok
    end
  end
end

defmodule ElixIRCd.Server.S2S.Codec do
  @moduledoc "Compatibility name for the pure ENP/1 protocol codec."

  alias ElixIRCd.Server.S2S.Protocol

  defdelegate encode(frame), to: Protocol
  defdelegate encode!(frame), to: Protocol
  defdelegate decode_body(body), to: Protocol
  defdelegate decode_body(body, options), to: Protocol
  defdelegate feed(buffer, data), to: Protocol
  defdelegate feed(buffer, data, options), to: Protocol
  defdelegate validate_sequence(frames, expected), to: Protocol
  defdelegate limits(), to: Protocol
end
