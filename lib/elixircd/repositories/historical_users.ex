defmodule ElixIRCd.Repositories.HistoricalUsers do
  @moduledoc """
  Module for the historical users repository.
  """

  alias ElixIRCd.Tables.HistoricalUser

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
  def get_by_nick(nick, nil), do: Memento.Query.select(HistoricalUser, {:==, :nick, nick})

  def get_by_nick(nick, limit) do
    # Issue: fix the "limit" option in Memento.Query.select/3, which is currently not working
    Memento.Query.select(HistoricalUser, {:==, :nick, nick}, limit: limit)
    # Enum.take can be removed once Memento.Query.select/3 supports the above "limit" option
    |> Enum.take(limit)
  end
end
