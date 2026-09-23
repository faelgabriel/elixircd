defmodule ElixIRCd.Utils.WireChunks do
  @moduledoc "Builds complete IRC messages from space-separated words without exceeding the wire limits."

  alias ElixIRCd.Message

  @max_line_bytes 512
  @max_parameters 15

  @doc "Checks the complete serialized IRC message, including its prefix and CRLF."
  @spec fits?(Message.t()) :: boolean()
  def fits?(%Message{} = message) do
    parameter_count = length(message.params) + if(is_binary(message.trailing), do: 1, else: 0)
    parameter_count <= @max_parameters and byte_size(Message.unparse_unbounded!(message)) <= @max_line_bytes
  end

  @doc "Keeps the words that fit in one reply, preserving their order."
  @spec take_fitting([String.t()], ([String.t()] -> Message.t())) :: [String.t()]
  def take_fitting(words, builder) when is_list(words) and is_function(builder, 1) do
    Enum.reduce(words, [], fn word, kept ->
      candidate = kept ++ [word]
      if fits?(builder.(candidate)), do: candidate, else: kept
    end)
  end

  @doc "Splits words across messages, passing `true` to the builder for every continuation line."
  @spec split([String.t()], ([String.t()], boolean() -> Message.t())) :: [Message.t()]
  def split(words, builder) when is_list(words) and is_function(builder, 2) do
    {completed, current} =
      Enum.reduce(words, {[], []}, &append_word(&1, &2, builder))

    chunks = Enum.reverse([current | completed])
    last_index = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      message = builder.(chunk, index < last_index)
      if fits?(message), do: message, else: raise(ArgumentError, "IRC reply exceeds the protocol line limit")
    end)
  end

  defp append_word(word, {completed, current}, builder) do
    candidate = current ++ [word]

    cond do
      fits?(builder.(candidate, true)) ->
        {completed, candidate}

      current == [] or not fits?(builder.([word], true)) ->
        raise ArgumentError, "IRC reply contains a word that cannot fit in one protocol line"

      true ->
        {[current | completed], [word]}
    end
  end
end
