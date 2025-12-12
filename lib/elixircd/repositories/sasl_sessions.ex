defmodule ElixIRCd.Repositories.SaslSessions do
  @moduledoc """
  Repository for SASL sessions.
  """

  alias ElixIRCd.Tables.SaslSession

  @doc """
  Get a SASL session by user PID.
  """
  @spec get(pid()) :: {:ok, SaslSession.t()} | {:error, :not_found}
  def get(user_pid) do
    case Memento.Query.read(SaslSession, user_pid) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Create a new SASL session.
  """
  @spec create(SaslSession.t_attrs()) :: SaslSession.t()
  def create(attrs) do
    session = SaslSession.new(attrs)
    Memento.Query.write(session)
    session
  end

  @doc """
  Update a SASL session.
  """
  @spec update(SaslSession.t(), SaslSession.t_attrs()) :: SaslSession.t()
  def update(session, attrs) do
    updated_session = SaslSession.update(session, attrs)
    Memento.Query.write(updated_session)
    updated_session
  end

  @doc """
  Delete a SASL session.
  """
  @spec delete(pid()) :: :ok
  def delete(user_pid) do
    Memento.Query.delete(SaslSession, user_pid)
    :ok
  end

  @doc """
  Check if a SASL session exists for a user.
  """
  @spec exists?(pid()) :: boolean()
  def exists?(user_pid) do
    case get(user_pid) do
      {:ok, _session} -> true
      {:error, :not_found} -> false
    end
  end
end
