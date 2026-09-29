defmodule ElixIRCd.ServerLink.KickReplay do
  @moduledoc "Bounded recipient-home cache for the first decision on a routed KICK ID."

  @default_max_entries 4_096
  @default_ttl_ms 120_000

  defmodule Entry do
    @moduledoc "The authenticated request content and its first target-home decision."

    @enforce_keys [:fingerprint, :code, :seen_at]
    defstruct [:fingerprint, :code, :seen_at]

    @type t :: %__MODULE__{fingerprint: binary(), code: String.t(), seen_at: integer()}
  end

  @enforce_keys [:entries, :order, :max_entries, :ttl_ms]
  defstruct [:entries, :order, :max_entries, :ttl_ms]

  @type key :: {String.t(), String.t(), String.t()}
  @type t :: %__MODULE__{
          entries: %{optional(key()) => Entry.t()},
          order: :queue.queue({key(), integer()}),
          max_entries: pos_integer(),
          ttl_ms: pos_integer()
        }

  @doc "Creates a bounded decision cache."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      entries: %{},
      order: :queue.new(),
      max_entries: Keyword.get(options, :max_entries, @default_max_entries),
      ttl_ms: Keyword.get(options, :ttl_ms, @default_ttl_ms)
    }
  end

  @doc "Checks an authenticated request, ignoring its hop-dependent TTL."
  @spec check(t(), map(), integer()) :: {:new, t()} | {:duplicate, Entry.t(), t()} | {:conflict, t()}
  def check(cache, frame, now \\ System.monotonic_time(:millisecond)) do
    cache = trim_expired(cache, now)

    case Map.fetch(cache.entries, key(frame)) do
      :error ->
        {:new, cache}

      {:ok, %Entry{fingerprint: fingerprint} = entry} ->
        if fingerprint == fingerprint(frame), do: {:duplicate, entry, cache}, else: {:conflict, cache}
    end
  end

  @doc "Remembers the first decision without replacing an existing one."
  @spec remember(t(), map(), String.t(), integer()) :: t()
  def remember(cache, frame, code, now \\ System.monotonic_time(:millisecond)) do
    cache = trim_expired(cache, now)
    key = key(frame)

    if Map.has_key?(cache.entries, key) do
      cache
    else
      entry = %Entry{fingerprint: fingerprint(frame), code: code, seen_at: now}

      %{cache | entries: Map.put(cache.entries, key, entry), order: :queue.in({key, now}, cache.order)}
      |> trim_capacity()
    end
  end

  defp key(frame), do: {frame["origin"], frame["epoch"], frame["id"]}

  defp fingerprint(frame) do
    {frame["origin"], frame["epoch"], frame["from_uid"], frame["to_origin"], frame["to_uid"], frame["channel"],
     frame["reason"]}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp trim_expired(cache, now) do
    case :queue.peek(cache.order) do
      {:value, {_key, seen_at}} when now - seen_at >= cache.ttl_ms ->
        cache |> remove_oldest() |> trim_expired(now)

      _ ->
        cache
    end
  end

  defp trim_capacity(cache) do
    if map_size(cache.entries) > cache.max_entries,
      do: cache |> remove_oldest() |> trim_capacity(),
      else: cache
  end

  defp remove_oldest(cache) do
    {{:value, {key, _seen_at}}, order} = :queue.out(cache.order)
    %{cache | entries: Map.delete(cache.entries, key), order: order}
  end
end
