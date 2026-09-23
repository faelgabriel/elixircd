defmodule ElixIRCd.Repositories.Metadata do
  @moduledoc "Persistence operations for IRCv3 metadata."

  alias ElixIRCd.Tables.Metadata
  alias Memento.Query.Data

  @type target_type :: :account | :channel | :session

  @doc "Stores a metadata value for a target."
  @spec put(target_type(), String.t(), String.t(), String.t()) :: Metadata.t()
  def put(type, target_key, key, value) do
    Metadata.new(%{
      id: {type, target_key, key},
      target_type: type,
      target_key: target_key,
      key: key,
      value: value
    })
    |> Memento.Query.write()
  end

  @doc "Fetches one metadata value, or nil when it is unset."
  @spec get(target_type(), String.t(), String.t()) :: Metadata.t() | nil
  def get(type, target_key, key), do: Memento.Query.read(Metadata, {type, target_key, key})

  @doc "Lists metadata values for a target in key order."
  @spec list(target_type(), String.t()) :: [Metadata.t()]
  def list(type, target_key) do
    :mnesia.index_read(Metadata, target_key, :target_key)
    |> Enum.map(&Data.load/1)
    |> Enum.filter(&(&1.target_type == type))
    |> Enum.sort_by(& &1.key)
  end

  @doc "Deletes one metadata key."
  @spec delete(target_type(), String.t(), String.t()) :: :ok
  def delete(type, target_key, key), do: Memento.Query.delete(Metadata, {type, target_key, key})

  @doc "Clears and returns every metadata entry for a target."
  @spec clear(target_type(), String.t()) :: [Metadata.t()]
  def clear(type, target_key) do
    entries = list(type, target_key)
    Enum.each(entries, &Memento.Query.delete_record/1)
    entries
  end

  @doc "Moves every metadata entry between normalized target keys."
  @spec migrate(target_type(), String.t(), String.t()) :: :ok
  def migrate(_type, old_key, new_key) when old_key == new_key, do: :ok

  def migrate(type, old_key, new_key) do
    migrate(type, old_key, type, new_key)
  end

  @doc "Moves every metadata entry between target types and normalized keys."
  @spec migrate(target_type(), String.t(), target_type(), String.t()) :: :ok
  def migrate(from_type, old_key, to_type, new_key) do
    from_type
    |> list(old_key)
    |> Enum.each(fn entry ->
      Memento.Query.delete_record(entry)

      %{
        entry
        | id: {to_type, new_key, entry.key},
          target_type: to_type,
          target_key: new_key,
          updated_at: DateTime.utc_now()
      }
      |> Memento.Query.write()
    end)

    :ok
  end
end
