defmodule ElixIRCd.Repositories.ChatHistory do
  @moduledoc "Persistent history queries, retention and redaction."

  alias ElixIRCd.Tables.ChatHistory
  alias Memento.Query.Data

  @occurred_at_position Enum.find_index(ChatHistory.__info__().attributes, fn attr -> attr == :occurred_at end) + 1

  @doc "Creates and persists a history entry."
  @spec create(map()) :: ChatHistory.t()
  def create(attrs), do: attrs |> ChatHistory.new() |> Memento.Query.write()

  @doc "Replaces a history entry, including when its target key changes."
  @spec replace(ChatHistory.t(), ChatHistory.t()) :: ChatHistory.t()
  def replace(old, new) do
    Memento.Query.delete_record(old)
    Memento.Query.write(new)
  end

  @doc "Lists a target's history in chronological order."
  @spec for_target(String.t()) :: [ChatHistory.t()]
  def for_target(target_key) do
    :mnesia.index_read(ChatHistory, target_key, :target_key)
    |> Enum.map(&Data.load/1)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Lists all persisted history entries in chronological order."
  @spec all() :: [ChatHistory.t()]
  def all do
    ChatHistory
    |> Memento.Query.all()
    |> Enum.sort_by(fn entry -> {DateTime.to_unix(entry.occurred_at, :microsecond), entry.msgid} end)
  end

  @doc "Scans history for entries older than the cutoff, loading only matches as structs."
  @spec expired(DateTime.t()) :: [ChatHistory.t()]
  def expired(cutoff) do
    :mnesia.foldl(
      fn raw, acc ->
        if DateTime.compare(elem(raw, @occurred_at_position), cutoff) == :lt do
          [Data.load(raw) | acc]
        else
          acc
        end
      end,
      [],
      ChatHistory
    )
  end

  @doc "Lists direct history involving one stable identity using Mnesia indices."
  @spec for_identity(String.t()) :: [ChatHistory.t()]
  def for_identity(identity) do
    (:mnesia.index_read(ChatHistory, identity, :sender_account_key) ++
       :mnesia.index_read(ChatHistory, identity, :recipient_account_key))
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.map(&Data.load/1)
    |> Enum.filter(&(&1.target_type == :direct))
  end

  @doc "Finds a history entry by its stable message ID."
  @spec get_by_msgid(String.t()) :: {:ok, ChatHistory.t()} | {:error, :history_not_found}
  def get_by_msgid(msgid) do
    case :mnesia.index_read(ChatHistory, msgid, :msgid) do
      [entry | _] -> {:ok, Data.load(entry)}
      [] -> {:error, :history_not_found}
    end
  end

  @doc "Marks a history entry as redacted at the supplied time."
  @spec redact(ChatHistory.t(), DateTime.t()) :: ChatHistory.t()
  def redact(entry, at) do
    entry
    |> Map.put(:redacted_at, at)
    |> Memento.Query.write()
  end

  @doc "Deletes a history entry."
  @spec delete(ChatHistory.t()) :: :ok
  def delete(entry), do: Memento.Query.delete_record(entry)
end
