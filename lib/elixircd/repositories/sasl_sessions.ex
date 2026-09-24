defmodule ElixIRCd.Repositories.SaslSessions do
  @moduledoc """
  Repository module for managing SASL authentication sessions in Mnesia database.
  """

  alias ElixIRCd.Tables.SaslSession
  alias Memento.Query.Data

  @created_at_position Enum.find_index(SaslSession.__info__().attributes, fn attr -> attr == :created_at end) + 1

  @doc """
  Create a new SASL session and write it to the database.
  """
  @spec create(map()) :: SaslSession.t()
  def create(attrs) do
    SaslSession.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Get a SASL session by user PID.
  """
  @spec get(pid()) :: {:ok, SaslSession.t()} | {:error, :sasl_session_not_found}
  def get(user_pid) do
    Memento.Query.read(SaslSession, user_pid)
    |> case do
      nil -> {:error, :sasl_session_not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Get all SASL sessions.
  """
  @spec get_all() :: [SaslSession.t()]
  def get_all do
    Memento.Query.all(SaslSession)
  end

  @doc "Get sessions older than the cutoff without materializing current sessions."
  @spec get_expired(DateTime.t()) :: [SaslSession.t()]
  def get_expired(cutoff) do
    :mnesia.foldl(
      fn raw, acc ->
        if DateTime.compare(elem(raw, @created_at_position), cutoff) == :lt do
          [Data.load(raw) | acc]
        else
          acc
        end
      end,
      [],
      SaslSession
    )
  end

  @doc """
  Update a SASL session in the database.
  """
  @spec update(SaslSession.t(), map()) :: SaslSession.t()
  def update(session, attrs) do
    SaslSession.update(session, attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a SASL session from the database.
  """
  @spec delete(pid()) :: :ok
  def delete(user_pid) do
    Memento.Query.delete(SaslSession, user_pid)
  end

  @doc """
  Check if a SASL session exists for a user.
  """
  @spec exists?(pid()) :: boolean()
  def exists?(user_pid) do
    match?({:ok, _session}, get(user_pid))
  end
end
