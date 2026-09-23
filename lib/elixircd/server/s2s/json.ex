defmodule ElixIRCd.Server.S2S.JSON do
  @moduledoc """
  Bounded lexical checks for ENP JSON bodies.

  `:json.decode/1` intentionally keeps the last value for duplicate object
  keys. ENP rejects duplicates before decoding so a peer cannot change the
  meaning of a closed object by relying on map overwrite behaviour.
  """

  alias ElixIRCd.Server.S2S.Identity

  @json_whitespace [32, 9, 10, 13]
  @max_safe_integer Identity.max_uint()
  @max_safe_integer_digits byte_size(Integer.to_string(@max_safe_integer))

  @type limits :: %{max_depth: pos_integer(), max_values: pos_integer()}

  @doc "Scans one complete JSON value and rejects duplicate keys and unsafe numbers."
  @spec scan(binary(), keyword() | limits()) :: :ok | {:error, atom() | {atom(), term()}}
  def scan(body, options \\ [])

  def scan(body, options) when is_binary(body) do
    limits = normalize_limits(options)

    if not String.valid?(body) do
      {:error, :invalid_utf8}
    else
      case value(body, skip_ws(body, 0), 0, limits, %{values: 0}) do
        {:ok, index, state} ->
          cond do
            skip_ws(body, index) != byte_size(body) -> {:error, :trailing_json_data}
            state.values > limits.max_values -> {:error, :json_values_exceeded}
            true -> :ok
          end

        {:error, _} = error ->
          error

        {:error, _, _} = error ->
          error
      end
    end
  end

  def scan(_body, _options), do: {:error, :invalid_json_body}

  @doc "Scans and decodes one object without converting keys to atoms."
  @spec decode_object(binary(), keyword() | limits()) :: {:ok, map()} | {:error, term()}
  def decode_object(body, options \\ [])

  def decode_object(body, options) when is_binary(body) do
    with :ok <- scan(body, options),
         {:ok, decoded} <- decode(body),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      false -> {:error, :top_level_must_be_object}
      {:error, _} = error -> error
    end
  end

  def decode_object(_body, _options), do: {:error, :invalid_json_body}

  @doc "Encodes a value using OTP's compact JSON encoder."
  @spec encode(term()) :: binary()
  def encode(value), do: value |> encode_value() |> :json.encode() |> IO.iodata_to_binary()

  defp decode(body) do
    try do
      {:ok, :json.decode(body) |> decode_value()}
    rescue
      error -> {:error, {:invalid_json, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:invalid_json, {kind, reason}}}
    end
  end

  defp normalize_limits(options) when is_list(options) do
    %{
      max_depth: Keyword.get(options, :max_depth, 16),
      max_values: Keyword.get(options, :max_values, 8_192)
    }
  end

  defp normalize_limits(options) when is_map(options), do: options

  defp encode_value(nil), do: :null
  defp encode_value(value) when is_map(value), do: Map.new(value, fn {key, item} -> {key, encode_value(item)} end)
  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)
  defp encode_value(value), do: value

  defp decode_value(:null), do: nil
  defp decode_value(value) when is_map(value), do: Map.new(value, fn {key, item} -> {key, decode_value(item)} end)
  defp decode_value(value) when is_list(value), do: Enum.map(value, &decode_value/1)
  defp decode_value(value), do: value

  defp value(body, index, depth, limits, state) do
    if depth > limits.max_depth do
      {:error, :json_depth_exceeded}
    else
      state = %{state | values: state.values + 1}

      if state.values > limits.max_values do
        {:error, :json_values_exceeded}
      else
        case byte_at(body, index) do
          {?{, _} -> object(body, index + 1, depth + 1, limits, state)
          {91, _} -> array(body, index + 1, depth + 1, limits, state)
          {34, _} -> primitive(string(body, index), state)
          {116, _} -> primitive(literal(body, index, "true"), state)
          {102, _} -> primitive(literal(body, index, "false"), state)
          {110, _} -> primitive(literal(body, index, "null"), state)
          {byte, _} when byte in ~c"-0123456789" -> primitive(number(body, index), state)
          :eof -> {:error, :unexpected_end}
          _ -> {:error, :invalid_json_value}
        end
      end
    end
  end

  defp object(body, index, depth, limits, state) do
    index = skip_ws(body, index)

    case byte_at(body, index) do
      {?}, _} -> {:ok, index + 1, state}
      {34, _} -> object_members(body, index, depth, limits, state, MapSet.new())
      :eof -> {:error, :unexpected_end}
      _ -> {:error, :object_key_required}
    end
  end

  defp object_members(body, index, depth, limits, state, keys) do
    with {:ok, key, after_key} <- string_with_value(body, index),
         false <- MapSet.member?(keys, key),
         after_key <- skip_ws(body, after_key),
         {58, _} <- byte_at(body, after_key),
         value_start <- skip_ws(body, after_key + 1),
         {:ok, value_end, state} <- value(body, value_start, depth, limits, state) do
      next = skip_ws(body, value_end)

      case byte_at(body, next) do
        {?}, _} ->
          {:ok, next + 1, state}

        {44, _} ->
          following = skip_ws(body, next + 1)

          if match?({34, _}, byte_at(body, following)),
            do: object_members(body, following, depth, limits, state, MapSet.put(keys, key)),
            else: {:error, :object_key_required}

        :eof ->
          {:error, :unexpected_end}

        _ ->
          {:error, :object_separator_required}
      end
    else
      true -> {:error, :duplicate_json_key}
      {:error, _} = error -> error
      _ -> {:error, :invalid_object}
    end
  end

  defp array(body, index, depth, limits, state) do
    index = skip_ws(body, index)

    case byte_at(body, index) do
      {93, _} -> {:ok, index + 1, state}
      :eof -> {:error, :unexpected_end}
      _ -> array_values(body, index, depth, limits, state)
    end
  end

  defp array_values(body, index, depth, limits, state) do
    with {:ok, value_end, state} <- value(body, index, depth, limits, state) do
      next = skip_ws(body, value_end)

      case byte_at(body, next) do
        {93, _} ->
          {:ok, next + 1, state}

        {44, _} ->
          following = skip_ws(body, next + 1)

          if byte_at(body, following) == :eof,
            do: {:error, :unexpected_end},
            else: array_values(body, following, depth, limits, state)

        :eof ->
          {:error, :unexpected_end}

        _ ->
          {:error, :array_separator_required}
      end
    end
  end

  defp string(body, index) do
    with {:ok, _value, next} <- string_with_value(body, index), do: {:ok, next}
  end

  defp string_with_value(body, index) do
    unless match?({34, _}, byte_at(body, index)) do
      {:error, :string_required}
    else
      string_loop(body, index + 1, index + 1, [])
    end
  end

  defp string_loop(body, index, start, acc) do
    case byte_at(body, index) do
      :eof ->
        {:error, :unterminated_string}

      {34, _} ->
        raw = binary_part(body, start, index - start)

        case decode_string(raw) do
          {:ok, value} -> {:ok, value, index + 1}
          {:error, _} = error -> error
        end

      {?\\, _} ->
        escape_loop(body, index + 1, start, acc)

      {byte, _} when byte < 32 ->
        {:error, :control_in_string}

      {_byte, _} ->
        string_loop(body, index + 1, start, acc)
    end
  end

  defp escape_loop(body, index, start, acc) do
    case byte_at(body, index) do
      {?u, _} ->
        if byte_size(body) >= index + 5 and valid_hex4?(binary_part(body, index + 1, 4)),
          do: string_loop(body, index + 5, start, acc),
          else: {:error, :invalid_unicode_escape}

      {byte, _} when byte in [34, 92, 47, 98, 102, 110, 114, 116] ->
        string_loop(body, index + 1, start, acc)

      :eof ->
        {:error, :unterminated_escape}

      _ ->
        {:error, :invalid_escape}
    end
  end

  defp decode_string(raw) do
    try do
      {:ok, :json.decode([?", raw, ?"] |> IO.iodata_to_binary())}
    rescue
      _ -> {:error, :invalid_string}
    end
  end

  defp primitive({:ok, next}, state), do: {:ok, next, state}
  defp primitive({:error, _} = error, _state), do: error

  defp literal(body, index, literal) do
    if binary_part_safe(body, index, byte_size(literal)) == literal,
      do: {:ok, index + byte_size(literal)},
      else: {:error, :invalid_literal}
  end

  defp number(body, index) do
    {next, token} = number_token(body, index, [])

    cond do
      token == <<>> ->
        {:error, :invalid_number}

      :binary.match(token, "-") != :nomatch ->
        {:error, :negative_number}

      :binary.match(token, ".") != :nomatch ->
        {:error, :fractional_number}

      :binary.match(token, "e") != :nomatch or :binary.match(token, "E") != :nomatch ->
        {:error, :exponent_number}

      :binary.match(token, "+") != :nomatch ->
        {:error, :invalid_number}

      token == "0" ->
        {:ok, next}

      String.starts_with?(token, "0") ->
        {:error, :invalid_number}

      byte_size(token) > @max_safe_integer_digits ->
        {:error, :integer_overflow}

      true ->
        case Integer.parse(token) do
          {value, ""} when value <= @max_safe_integer -> {:ok, next}
          _ -> {:error, :integer_overflow}
        end
    end
  rescue
    _ -> {:error, :invalid_number}
  end

  defp number_token(body, index, acc) do
    case byte_at(body, index) do
      {byte, _} when byte in ~c"0123456789eE+-." -> number_token(body, index + 1, [byte | acc])
      _ -> {index, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp skip_ws(body, index) do
    case byte_at(body, index) do
      {byte, _} when byte in @json_whitespace -> skip_ws(body, index + 1)
      _ -> index
    end
  end

  defp byte_at(body, index) when index < 0 or index >= byte_size(body), do: :eof
  defp byte_at(body, index), do: {:erlang, :binary.at(body, index)} |> then(fn {_module, byte} -> {byte, body} end)

  defp binary_part_safe(body, index, length) when index >= 0 and length >= 0 and index + length <= byte_size(body),
    do: binary_part(body, index, length)

  defp binary_part_safe(_body, _index, _length), do: :invalid

  defp valid_hex4?(value), do: Regex.match?(~r/\A[0-9A-Fa-f]{4}\z/, value)
end
