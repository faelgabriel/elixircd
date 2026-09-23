defmodule ElixIRCd.Repositories.Memos do
  @moduledoc "Repository for account-owned NickServ memos."

  alias ElixIRCd.Tables.Memo
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Utils.CaseMapping
  alias Memento.Query.Data

  @doc "Creates and persists a memo."
  @spec create(map()) :: Memo.t()
  def create(attrs) do
    Memo.new(attrs)
    |> Memento.Query.write()
  end

  @doc "Creates a memo only when the recipient count and byte quotas allow it."
  @spec create_with_limits(map(), keyword()) ::
          {:ok, Memo.t()} | {:error, :memo_count_limit | :memo_bytes_limit}
  def create_with_limits(attrs, limits) do
    operation = fn -> create_with_limits_in_transaction(attrs, limits) end

    if Memento.Transaction.inside?(), do: operation.(), else: Memento.transaction!(operation)
  end

  defp create_with_limits_in_transaction(attrs, limits) do
    recipient_account = Map.fetch!(attrs, :recipient_account)
    account_key = CaseMapping.normalize(recipient_account)
    _account = Memento.Query.read(RegisteredNick, account_key, lock: :write)
    memos = get_by_recipient(recipient_account)
    body_bytes = byte_size(Map.fetch!(attrs, :body))

    cond do
      length(memos) >= Keyword.fetch!(limits, :max_count) ->
        {:error, :memo_count_limit}

      Enum.reduce(memos, 0, &(byte_size(&1.body) + &2)) + body_bytes > Keyword.fetch!(limits, :max_bytes) ->
        {:error, :memo_bytes_limit}

      true ->
        {:ok, create(attrs)}
    end
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
