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
  Gets all access entries for a given account name.
  """
  @spec get_by_account_name(String.t()) :: [NickAccess.t()]
  def get_by_account_name(account_name) do
    account_name_key = CaseMapping.normalize(account_name)

    :mnesia.read(NickAccess, account_name_key)
    |> Enum.map(&Data.load/1)
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  @doc """
  Gets a specific access entry by account name and mask.
  """
  @spec get_by_account_name_and_mask(String.t(), String.t()) :: NickAccess.t() | nil
  def get_by_account_name_and_mask(account_name, mask) do
    account_name_key = CaseMapping.normalize(account_name)
    normalized_mask = String.downcase(mask)

    :mnesia.read(NickAccess, account_name_key)
    |> Enum.map(&Data.load/1)
    |> Enum.find(fn record -> record.mask == normalized_mask end)
  end

  @doc """
  Counts the number of access entries for a given account name.
  """
  @spec count_by_account_name(String.t()) :: non_neg_integer()
  def count_by_account_name(account_name) do
    account_name_key = CaseMapping.normalize(account_name)

    :mnesia.read(NickAccess, account_name_key)
    |> length()
  end

  @doc """
  Deletes a specific access entry.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(account_name, mask) do
    case get_by_account_name_and_mask(account_name, mask) do
      nil -> :ok
      record -> Memento.Query.delete_record(record)
    end

    :ok
  end

  @doc """
  Deletes all access entries for an account name.
  """
  @spec delete_by_account_name(String.t()) :: :ok
  def delete_by_account_name(account_name) do
    account_name_key = CaseMapping.normalize(account_name)

    :mnesia.read(NickAccess, account_name_key)
    |> Enum.map(&Data.load/1)
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end
end
