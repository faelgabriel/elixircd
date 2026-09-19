defmodule ElixIRCd.Repositories.ChatHistory do
  @moduledoc "Persistent history queries, retention and redaction."

  alias ElixIRCd.Tables.ChatHistory
  alias Memento.Query.Data

  @doc "Creates and persists a history entry."
  @spec create(map()) :: ChatHistory.t()
  def create(attrs), do: attrs |> ChatHistory.new() |> Memento.Query.write()

  @doc "Lists a target's history in chronological order."
  @spec for_target(String.t()) :: [ChatHistory.t()]
  def for_target(target_key) do
    :mnesia.index_read(ChatHistory, target_key, :target_key)
    |> Enum.map(&Data.load/1)
    |> Enum.sort_by(&DateTime.to_unix(&1.occurred_at, :microsecond))
  end

  @doc "Lists all persisted history entries in chronological order."
  @spec all() :: [ChatHistory.t()]
  def all do
    ChatHistory
    |> Memento.Query.all()
    |> Enum.sort_by(&DateTime.to_unix(&1.occurred_at, :microsecond))
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
