defmodule ElixIRCd.Repositories.RegisteredNicks do
  @moduledoc """
  Repository module for managing registered nicknames in Mnesia database.
  """

  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Server.S2S.Publication
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Utils.CaseMapping
  alias Memento.Query.Data

  @doc """
  Create a new registered nickname and write it to the database.
  """
  @spec create(map()) :: RegisteredNick.t()
  def create(params) do
    params
    |> account_identity_params()
    |> RegisteredNick.new()
    |> Memento.Query.write()
    |> tap(fn _record -> Publication.policy_changed() end)
  end

  @doc """
  Get a registered nickname by nickname.
  """
  @spec get_by_nickname(String.t()) :: {:ok, RegisteredNick.t()} | {:error, :registered_nick_not_found}
  def get_by_nickname(nickname) do
    nickname_key = CaseMapping.normalize(nickname)

    Memento.Query.read(RegisteredNick, nickname_key)
    |> case do
      nil -> {:error, :registered_nick_not_found}
      registered_nick -> {:ok, registered_nick}
    end
  end

  @doc "Gets and write-locks a registered nickname for an atomic account update."
  @spec get_by_nickname_for_update(String.t()) ::
          {:ok, RegisteredNick.t()} | {:error, :registered_nick_not_found}
  def get_by_nickname_for_update(nickname) do
    nickname_key = CaseMapping.normalize(nickname)

    Memento.Query.read(RegisteredNick, nickname_key, lock: :write)
    |> case do
      nil -> {:error, :registered_nick_not_found}
      registered_nick -> {:ok, registered_nick}
    end
  end

  @doc """
  Get all registered nicknames.
  """
  @spec get_all() :: [RegisteredNick.t()]
  def get_all do
    Memento.Query.all(RegisteredNick)
  end

  @doc """
  Get all registered nicknames that belong to the same canonical account.
  """
  @spec get_by_account_name(String.t()) :: [RegisteredNick.t()]
  def get_by_account_name(account_name) do
    account_name_key = CaseMapping.normalize(account_name)

    :mnesia.index_read(RegisteredNick, account_name_key, :account_name_key)
    |> Enum.map(&Data.load/1)
    |> Enum.sort_by(&String.downcase(&1.nickname))
  end

  @doc """
  Update a registered nickname in the database.
  """
  @spec update(RegisteredNick.t(), map()) :: RegisteredNick.t()
  def update(registered_nick, attrs) do
    updated = RegisteredNick.update(registered_nick, attrs)

    updated =
      if updated.account_name_key == registered_nick.account_name_key,
        do: updated,
        else: align_account_identity(updated)

    updated =
      if Identity.valid_id?(updated.account_id) and Identity.valid_positive?(updated.auth_epoch),
        do: updated,
        else: align_account_identity(updated)

    updated
    |> Memento.Query.write()
    |> tap(fn _record -> Publication.policy_changed() end)
  end

  @doc """
  Delete a registered nickname from the database.
  """
  @spec delete(RegisteredNick.t()) :: :ok
  def delete(registered_nick) do
    Memento.Query.delete_record(registered_nick)
    |> tap(fn _result -> Publication.policy_changed() end)
  end

  defp account_identity_params(params) do
    account_key =
      Map.get(params, :account_name_key) || Map.get(params, "account_name_key") ||
        CaseMapping.normalize(Map.get(params, :account_name) || Map.get(params, "account_name", ""))

    existing =
      case get_by_account_name(account_key) do
        [%RegisteredNick{} = account | _] -> account
        _ -> nil
      end

    if existing && Identity.valid_id?(existing.account_id) && Identity.valid_positive?(existing.auth_epoch) do
      Map.merge(params, %{account_id: existing.account_id, auth_epoch: existing.auth_epoch})
    else
      params
    end
  end

  defp align_account_identity(%RegisteredNick{account_name_key: account_key} = registered_nick) do
    existing =
      case get_by_account_name(account_key) do
        [%RegisteredNick{} = account | _] -> account
        _ -> nil
      end

    cond do
      existing && Identity.valid_id?(existing.account_id) && Identity.valid_positive?(existing.auth_epoch) ->
        %{registered_nick | account_id: existing.account_id, auth_epoch: existing.auth_epoch}

      Identity.valid_id?(registered_nick.account_id) and Identity.valid_positive?(registered_nick.auth_epoch) ->
        registered_nick

      true ->
        %{registered_nick | account_id: Identity.new_id(), auth_epoch: Identity.auth_epoch()}
    end
  end
end
