defmodule ElixIRCd.Operators.Management do
  @moduledoc "Validates and applies database operator changes."

  require Logger

  alias ElixIRCd.Config.Types
  alias ElixIRCd.Operators
  alias ElixIRCd.Repositories.Operators, as: OperatorRepository
  alias ElixIRCd.Tables.User

  @doc "Creates an operator using a precomputed Argon2 hash."
  @spec add(String.t(), String.t()) :: :ok | {:error, atom()}
  def add(name, hash) do
    with :ok <- validate_input(name, hash) do
      Operators.Registry.synchronized(fn -> do_add(name, hash) end)
    end
  end

  @doc "Changes an operator password and revokes its active sessions."
  @spec rotate(String.t(), String.t()) :: :ok | {:error, atom()}
  def rotate(name, hash) do
    with :ok <- validate_input(name, hash), do: change(name, :rotate, hash)
  end

  @doc "Disables an operator and revokes its active sessions."
  @spec disable(String.t()) :: :ok | {:error, atom()}
  def disable(name), do: change(name, :disable)

  @doc "Enables an operator for future authentication."
  @spec enable(String.t()) :: :ok | {:error, atom()}
  def enable(name), do: change(name, :enable)

  @doc "Removes an operator and revokes its active sessions."
  @spec remove(String.t()) :: :ok | {:error, atom()}
  def remove(name), do: change(name, :remove)

  @spec do_add(String.t(), String.t()) :: :ok | {:error, atom()}
  defp do_add(name, hash) do
    result = Memento.transaction!(fn -> create_database_operator(name, hash) end)
    if result == :ok, do: audit(:add, name)
    result
  end

  @spec create_database_operator(String.t(), String.t()) :: :ok | {:error, atom()}
  defp create_database_operator(name, hash) do
    cond do
      configured?(name) -> {:error, :configured}
      OperatorRepository.get_for_update(name) != nil -> {:error, :exists}
      true -> OperatorRepository.create(name, hash)
    end
  end

  @spec change(String.t(), atom(), String.t() | nil) :: :ok | {:error, atom()}
  defp change(name, action, hash \\ nil) do
    if Types.valid?(:token, name) do
      Operators.Registry.synchronized(fn -> do_change(name, action, hash) end)
    else
      {:error, :invalid_name}
    end
  end

  @spec do_change(String.t(), atom(), String.t() | nil) :: :ok | {:error, atom()}
  defp do_change(name, action, hash) do
    result = Memento.transaction!(fn -> change_database_operator(name, action, hash) end)

    case result do
      {:ok, revoked} ->
        Operators.Sessions.notify_revoked(revoked)
        audit(action, name)
        :ok

      error ->
        error
    end
  end

  @spec change_database_operator(String.t(), atom(), String.t() | nil) ::
          {:ok, [{User.t(), [atom()]}]} | {:error, atom()}
  defp change_database_operator(name, action, hash) do
    if configured?(name), do: {:error, :configured}, else: update_database_operator(name, action, hash)
  end

  @spec update_database_operator(String.t(), atom(), String.t() | nil) ::
          {:ok, [{User.t(), [atom()]}]} | {:error, atom()}
  defp update_database_operator(name, action, hash) do
    case OperatorRepository.get_for_update(name) do
      nil ->
        {:error, :not_found}

      oper ->
        case action do
          :remove -> OperatorRepository.delete(name)
          :rotate -> OperatorRepository.update(oper, password_hash: hash)
          :disable -> OperatorRepository.update(oper, enabled: false)
          :enable -> OperatorRepository.update(oper, enabled: true)
        end

        revoked = if action == :enable, do: [], else: Operators.Sessions.clear(:database, name)
        {:ok, revoked}
    end
  end

  @spec configured?(String.t()) :: boolean()
  defp configured?(name) do
    Enum.any?(Application.fetch_env!(:elixircd, :operators), fn {stored_name, _hash} -> stored_name == name end)
  end

  @spec validate_input(String.t(), String.t()) :: :ok | {:error, atom()}
  defp validate_input(name, hash) do
    cond do
      not Types.valid?(:token, name) -> {:error, :invalid_name}
      not Types.valid?(:argon2_hash, hash) -> {:error, :invalid_hash}
      true -> :ok
    end
  end

  @spec audit(atom(), String.t()) :: :ok
  defp audit(action, name), do: Logger.info("operator changed", event: "audit.oper.admin", action: action, target: name)
end
