defmodule ElixIRCd.Repositories.Memos do
  @moduledoc "Repository for account-owned NickServ memos."

  alias ElixIRCd.Tables.Memo
  alias ElixIRCd.Utils.CaseMapping
  alias Memento.Query.Data

  @doc "Creates and persists a memo."
  @spec create(map()) :: Memo.t()
  def create(attrs) do
    Memo.new(attrs)
    |> Memento.Query.write()
  end

  @doc "Gets a memo by its public identifier."
  @spec get_by_id(String.t()) :: {:ok, Memo.t()} | {:error, :memo_not_found}
  def get_by_id(id) do
    case Memento.Query.read(Memo, id) do
      nil -> {:error, :memo_not_found}
      memo -> {:ok, memo}
    end
  end

  @doc "Lists the recipient account's memos, newest first."
  @spec get_by_recipient(String.t()) :: [Memo.t()]
  def get_by_recipient(account_name) do
    account_name_key = CaseMapping.normalize(account_name)

    :mnesia.index_read(Memo, account_name_key, :recipient_account_key)
    |> Enum.map(&Data.load/1)
    |> Enum.sort_by(&DateTime.to_unix(&1.created_at), :desc)
  end

  @doc "Updates a memo, typically when it is marked as read."
  @spec update(Memo.t(), map()) :: Memo.t()
  def update(memo, attrs) do
    Memo.update(memo, attrs)
    |> Memento.Query.write()
  end

  @doc "Deletes a memo owned by the recipient account."
  @spec delete(Memo.t()) :: :ok
  def delete(memo), do: Memento.Query.delete_record(memo)

  @doc "Deletes all memos owned by an account and returns the number removed."
  @spec delete_by_recipient(String.t()) :: non_neg_integer()
  def delete_by_recipient(account_name) do
    memos = get_by_recipient(account_name)
    Enum.each(memos, &delete/1)
    length(memos)
  end
end
