defmodule ElixIRCd.Server.S2S.Identity do
  @moduledoc """
  Canonical identities and ordering primitives for ElixIRCd Native Protocol 1.

  ENP identities are deliberately binaries. They never become atoms and they do
  not contain an Erlang PID, reference, node name or transport detail.
  """

  @id_bytes 16
  @max_uint 9_007_199_254_740_991
  @id_length 26
  @sid_pattern ~r/\A[a-z][a-z0-9-]{0,15}\z/

  @type id :: String.t()
  @type node_ref :: %{sid: String.t(), boot: id()}
  @type stamp :: [pos_integer() | String.t()]

  @doc "The largest integer that can be represented exactly in ENP JSON."
  @spec max_uint() :: pos_integer()
  def max_uint, do: @max_uint

  @doc "Generates one canonical 128-bit Base32 identity."
  @spec new_id() :: id()
  def new_id do
    :crypto.strong_rand_bytes(@id_bytes)
    |> Base.encode32(case: :upper, padding: false)
  end

  @doc "Generates a fresh daemon boot identity."
  @spec boot() :: id()
  def boot, do: new_id()

  @doc "Generates a fresh client UID."
  @spec uid() :: id()
  def uid, do: new_id()

  @doc "Generates a fresh channel incarnation ID."
  @spec cid() :: id()
  def cid, do: new_id()

  @doc "Generates a fresh request/snapshot/message nonce."
  @spec nonce() :: id()
  def nonce, do: new_id()

  @doc "Generates a positive credential epoch that fits the ENP integer range."
  @spec auth_epoch() :: pos_integer()
  def auth_epoch do
    <<value::unsigned-size(64)>> = :crypto.strong_rand_bytes(8)
    1 + rem(value, @max_uint - 1)
  end

  @doc "Validates the exact unpadded, uppercase 128-bit Base32 representation."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(value) do
    match?({:ok, _}, decode_id(value))
  end

  @doc "Decodes an ID only when its alphabet, unused bits and canonical spelling are valid."
  @spec decode_id(term()) :: {:ok, binary()} | {:error, atom()}
  def decode_id(value) when is_binary(value) do
    cond do
      byte_size(value) != @id_length -> {:error, :invalid_length}
      not Regex.match?(~r/\A[A-Z2-7]{26}\z/, value) -> {:error, :invalid_alphabet}
      true -> canonical_decode(value)
    end
  end

  def decode_id(_value), do: {:error, :invalid_id}

  @doc "Validates a configured server ID."
  @spec valid_sid?(term()) :: boolean()
  def valid_sid?(value) when is_binary(value), do: Regex.match?(@sid_pattern, value)
  def valid_sid?(_value), do: false

  @doc "Validates a profile network ID."
  @spec valid_network_id?(term()) :: boolean()
  def valid_network_id?(value) when is_binary(value) do
    byte_size(value) in 1..64 and Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, value)
  end

  def valid_network_id?(_value), do: false

  @doc "Validates an ENP unsigned integer after JSON decoding."
  @spec valid_uint?(term()) :: boolean()
  def valid_uint?(value), do: is_integer(value) and value >= 0 and value <= @max_uint

  @doc "Validates a positive ENP integer after JSON decoding."
  @spec valid_positive?(term()) :: boolean()
  def valid_positive?(value), do: is_integer(value) and value > 0 and value <= @max_uint

  @doc "Builds a typed node reference."
  @spec node_ref(String.t(), id()) :: node_ref()
  def node_ref(sid, boot), do: %{sid: sid, boot: boot}

  @doc "Compares two stamps lexicographically by counter, SID and boot."
  @spec compare_stamp(stamp(), stamp()) :: :lt | :eq | :gt
  def compare_stamp([left_counter, left_sid, left_boot], [right_counter, right_sid, right_boot])
      when is_integer(left_counter) and is_integer(right_counter) do
    compare_terms({left_counter, left_sid, left_boot}, {right_counter, right_sid, right_boot})
  end

  @doc "Compares channel incarnations by birth time, then CID."
  @spec compare_incarnation(pos_integer(), id(), pos_integer(), id()) :: :lt | :eq | :gt
  def compare_incarnation(left_born, left_cid, right_born, right_cid) do
    compare_terms({left_born, left_cid}, {right_born, right_cid})
  end

  @doc "Returns the current UTC Unix time in milliseconds."
  @spec now_ms() :: pos_integer()
  def now_ms, do: System.system_time(:millisecond)

  @doc "Derives the connection identity from both independently sent hello values."
  @spec edge_id(map(), map()) :: {:ok, String.t()} | {:error, atom()}
  def edge_id(left, right) when is_map(left) and is_map(right) do
    with {:ok, left_tuple} <- hello_tuple(left),
         {:ok, right_tuple} <- hello_tuple(right) do
      entries = Enum.sort_by([left_tuple, right_tuple], &elem(&1, 0))

      encoded =
        entries
        |> Enum.map(&Tuple.to_list/1)
        |> :json.encode()

      {:ok, Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)}
    end
  end

  def edge_id(_left, _right), do: {:error, :invalid_hello}

  @doc "Returns the canonical compact JSON profile hash representation."
  @spec sha256_hex(iodata()) :: String.t()
  def sha256_hex(value), do: Base.encode16(:crypto.hash(:sha256, IO.iodata_to_binary(value)), case: :lower)

  @doc "Constant-time comparison for externally supplied fingerprints or hashes."
  @spec secure_equal?(binary(), binary()) :: boolean()
  def secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    size = max(byte_size(left), byte_size(right))
    difference = bxor(byte_size(left), byte_size(right))

    difference =
      Enum.reduce(0..max(size - 1, 0), difference, fn index, acc ->
        left_byte = if index < byte_size(left), do: :binary.at(left, index), else: 0
        right_byte = if index < byte_size(right), do: :binary.at(right, index), else: 0
        bor(acc, bxor(left_byte, right_byte))
      end)

    difference == 0
  end

  def secure_equal?(_left, _right), do: false

  defp canonical_decode(value) do
    case Base.decode32(value, case: :upper, padding: false) do
      {:ok, <<_::binary-size(@id_bytes)>> = bytes} ->
        if Base.encode32(bytes, case: :upper, padding: false) == value,
          do: {:ok, bytes},
          else: {:error, :noncanonical}

      {:ok, _bytes} ->
        {:error, :wrong_decoded_size}

      :error ->
        {:error, :invalid_encoding}
    end
  end

  defp hello_tuple(hello) do
    sid = Map.get(hello, "sid") || Map.get(hello, :sid)
    boot = Map.get(hello, "boot") || Map.get(hello, :boot)
    nonce = Map.get(hello, "nonce") || Map.get(hello, :nonce)

    if valid_sid?(sid) and valid_id?(boot) and valid_id?(nonce),
      do: {:ok, {sid, boot, nonce}},
      else: {:error, :invalid_hello}
  end

  defp compare_terms(left, right) when left < right, do: :lt
  defp compare_terms(left, right) when left > right, do: :gt
  defp compare_terms(_left, _right), do: :eq

  defp bxor(left, right), do: Bitwise.bxor(left, right)
  defp bor(left, right), do: Bitwise.bor(left, right)
end
