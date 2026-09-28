defmodule ElixIRCd.Operators.Authentication do
  @moduledoc "Authenticates IRC operators against file and database credentials."

  alias ElixIRCd.Repositories.Operators, as: OperatorRepository
  alias ElixIRCd.Tables.Operator

  @type credential :: %{source: :config | :database, name: String.t()}

  @doc "Authenticates against one credential source."
  @spec authenticate(String.t(), String.t()) :: {:ok, credential()} | :error
  def authenticate(name, password) when is_binary(name) and is_binary(password) do
    configured = Application.fetch_env!(:elixircd, :operators)
    config_hash = Enum.find_value(configured, fn {stored_name, hash} -> if stored_name == name, do: hash end)
    database = Memento.transaction!(fn -> OperatorRepository.get(name) end)

    case {config_hash, database} do
      {hash, nil} when is_binary(hash) -> verify_config(name, password, hash)
      {nil, %Operator{enabled: true} = oper} -> verify_database(name, password, oper)
      _ -> :error
    end
  rescue
    Memento.Error -> :error
  catch
    :exit, _reason -> :error
  end

  @spec verify_config(String.t(), String.t(), String.t()) :: {:ok, credential()} | :error
  defp verify_config(name, password, hash) do
    if Argon2.verify_pass(password, hash),
      do: {:ok, %{source: :config, name: name}},
      else: :error
  end

  @spec verify_database(String.t(), String.t(), Operator.t()) :: {:ok, credential()} | :error
  defp verify_database(name, password, oper) do
    if Argon2.verify_pass(password, oper.password_hash),
      do: {:ok, %{source: :database, name: name}},
      else: :error
  end
end
