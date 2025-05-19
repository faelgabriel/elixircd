defmodule ElixIRCd.Repositories.RegisteredNicks do
  @moduledoc """
  Repository module for managing registered nicknames in Mnesia database.
  """

  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Utils.CaseMapping

  @doc """
  Create a new registered nickname and write it to the database.
  """
  @spec create(map()) :: RegisteredNick.t()
  def create(params) do
    RegisteredNick.new(params)
    |> Memento.Query.write()
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

  @doc """
  Get all registered nicknames.
  """
  @spec get_all() :: [RegisteredNick.t()]
  def get_all do
    Memento.Query.all(RegisteredNick)
  end

  @doc """
  Update a registered nickname in the database.
  """
  @spec update(RegisteredNick.t(), map()) :: RegisteredNick.t()
  def update(registered_nick, attrs) do
    RegisteredNick.update(registered_nick, attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a registered nickname from the database.
  """
  @spec delete(RegisteredNick.t()) :: :ok
  def delete(registered_nick) do
    Memento.Query.delete_record(registered_nick)
  end
end
