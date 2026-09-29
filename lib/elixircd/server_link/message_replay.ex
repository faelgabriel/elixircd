defmodule ElixIRCd.ServerLink.MessageReplay do
  @moduledoc "Bounded replay window for transient server-link channel messages."

  @default_max_entries 4_096
  @default_ttl_ms 120_000

  defstruct entries: %{}, order: {[], []}, max_entries: @default_max_entries, ttl_ms: @default_ttl_ms

  @type key :: {String.t(), String.t(), String.t()}
  @type t :: %__MODULE__{
          entries: %{optional(key()) => integer()},
          order: :queue.queue({key(), integer()}),
          max_entries: pos_integer(),
          ttl_ms: pos_integer()
        }

  @doc "Creates a bounded replay window."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      entries: %{},
      order: :queue.new(),
      max_entries: Keyword.get(options, :max_entries, @default_max_entries),
      ttl_ms: Keyword.get(options, :ttl_ms, @default_ttl_ms)
    }
  end

  @doc "Accepts the first occurrence of a message ID in its origin and epoch."
  @spec accept(t(), String.t(), String.t(), String.t(), integer()) :: {:new | :duplicate, t()}
  def accept(window, origin, epoch, id, now \\ System.monotonic_time(:millisecond)) do
    window = trim_expired(window, now)
    key = {origin, epoch, id}

    if Map.has_key?(window.entries, key) do
      {:duplicate, window}
    else
      window = %{
        window
        | entries: Map.put(window.entries, key, now),
          order: :queue.in({key, now}, window.order)
      }

      {:new, trim_capacity(window)}
    end
  end

  defp trim_expired(window, now) do
    case :queue.peek(window.order) do
      {:value, {_key, timestamp}} when now - timestamp >= window.ttl_ms ->
        window |> remove_oldest() |> trim_expired(now)

      _ ->
        window
    end
  end

  defp trim_capacity(window) do
    if map_size(window.entries) > window.max_entries,
      do: window |> remove_oldest() |> trim_capacity(),
      else: window
  end

  defp remove_oldest(window) do
    {{:value, {key, _timestamp}}, order} = :queue.out(window.order)
    %{window | entries: Map.delete(window.entries, key), order: order}
  end
end
