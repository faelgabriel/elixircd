defmodule ElixIRCd.Repositories.HistoricalUsers do
  @moduledoc """
  Module for the historical users repository.
  """

  alias ElixIRCd.Tables.HistoricalUser
  alias ElixIRCd.Utils.CaseMapping

  @doc """
  Create a new historical user and write it to the database.
  """
  @spec create(map()) :: HistoricalUser.t()
  def create(attrs) do
    HistoricalUser.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Get historical users by the nick and limit.
  """
  @spec get_by_nick(String.t(), non_neg_integer() | nil) :: [HistoricalUser.t()]
  def get_by_nick(nick, nil) do
    nick_key = CaseMapping.normalize(nick)
    Memento.Query.select(HistoricalUser, {:==, :nick_key, nick_key})
  end

  def get_by_nick(nick, limit) do
    nick_key = CaseMapping.normalize(nick)
    # Mnesia treats the requested limit as a suggested chunk size and may return more
    # records than requested. Enum.take/2 enforces the maximum number of results.
    Memento.Query.select(HistoricalUser, {:==, :nick_key, nick_key}, limit: limit)
    |> Enum.take(limit)
  end
end
