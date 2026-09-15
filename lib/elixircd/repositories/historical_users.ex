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
    |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
  end

  def get_by_nick(_nick, 0), do: []

  def get_by_nick(nick, limit) when limit > 0 do
    # Select and sort the complete history before enforcing the result limit.
    # Mnesia's select limit is a chunk size and does not select the newest rows.
    get_by_nick(nick, nil)
    |> Enum.take(limit)
  end
end
