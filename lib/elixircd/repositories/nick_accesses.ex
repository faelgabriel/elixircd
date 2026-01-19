defmodule ElixIRCd.Repositories.NickAccesses do
  @moduledoc """
  Repository for managing nick access lists.
  """

  alias ElixIRCd.Tables.NickAccess
  alias ElixIRCd.Utils.CaseMapping
  alias Memento.Query.Data

  @doc """
  Creates a new nick access entry.
  """
  @spec create(map()) :: NickAccess.t()
  def create(attrs) do
    NickAccess.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Gets all access entries for a given nickname.
  """
  @spec get_by_nickname(String.t()) :: [NickAccess.t()]
  def get_by_nickname(nickname) do
    nickname_key = CaseMapping.normalize(nickname)

    :mnesia.read(NickAccess, nickname_key)
    |> Enum.map(&Data.load/1)
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  @doc """
  Gets a specific access entry by nickname and mask.
  """
  @spec get_by_nickname_and_mask(String.t(), String.t()) :: NickAccess.t() | nil
  def get_by_nickname_and_mask(nickname, mask) do
    nickname_key = CaseMapping.normalize(nickname)
    normalized_mask = String.downcase(mask)

    :mnesia.read(NickAccess, nickname_key)
    |> Enum.map(&Data.load/1)
    |> Enum.find(fn record -> record.mask == normalized_mask end)
  end

  @doc """
  Counts the number of access entries for a given nickname.
  """
  @spec count_by_nickname(String.t()) :: non_neg_integer()
  def count_by_nickname(nickname) do
    nickname_key = CaseMapping.normalize(nickname)

    :mnesia.read(NickAccess, nickname_key)
    |> length()
  end

  @doc """
  Deletes a specific access entry.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(nickname, mask) do
    case get_by_nickname_and_mask(nickname, mask) do
      nil -> :ok
      record -> Memento.Query.delete_record(record)
    end

    :ok
  end

  @doc """
  Deletes all access entries for a nickname.
  """
  @spec delete_by_nickname(String.t()) :: :ok
  def delete_by_nickname(nickname) do
    nickname_key = CaseMapping.normalize(nickname)

    :mnesia.read(NickAccess, nickname_key)
    |> Enum.map(&Data.load/1)
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end
end
