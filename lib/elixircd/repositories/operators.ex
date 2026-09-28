defmodule ElixIRCd.Repositories.Operators do
  @moduledoc "Mnesia reads and writes for database managed IRC operators."

  alias ElixIRCd.Tables.Operator

  @doc "Returns all database operators inside a transaction."
  @spec all() :: [Operator.t()]
  def all, do: Memento.Query.all(Operator)

  @doc "Reads an operator by name inside a transaction."
  @spec get(String.t()) :: Operator.t() | nil
  def get(name), do: Memento.Query.read(Operator, name)

  @doc "Reads and write locks an operator inside a transaction."
  @spec get_for_update(String.t()) :: Operator.t() | nil
  def get_for_update(name), do: Memento.Query.read(Operator, name, lock: :write)

  @doc "Writes a new enabled operator inside a transaction."
  @spec create(String.t(), String.t()) :: :ok
  def create(name, hash) do
    now = DateTime.utc_now()

    Memento.Query.write(%Operator{
      name: name,
      password_hash: hash,
      enabled: true,
      created_at: now,
      updated_at: now
    })

    :ok
  end

  @doc "Updates an operator inside a transaction."
  @spec update(Operator.t(), keyword()) :: Operator.t()
  def update(oper, attrs) do
    changed = %{oper | updated_at: DateTime.utc_now()}
    Memento.Query.write(struct(changed, attrs))
  end

  @doc "Deletes an operator inside a transaction."
  @spec delete(String.t()) :: :ok
  def delete(name), do: Memento.Query.delete(Operator, name)
end
