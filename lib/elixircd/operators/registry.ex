defmodule ElixIRCd.Operators.Registry do
  @moduledoc """
  Coordinates configuration and database operator names and lists both sources.
  """

  alias ElixIRCd.Config.Error
  alias ElixIRCd.Repositories.Operators, as: OperatorRepository

  @lock {__MODULE__, :configuration_and_operators}

  @type source :: :config | :database

  @doc "Serializes changes to configuration and database operators."
  @spec synchronized((-> result)) :: result when result: term()
  def synchronized(fun) when is_function(fun, 0), do: :global.trans(@lock, fun, [node()])

  @doc "Rejects database names present in a validated candidate configuration before activation."
  @spec validate_config!(keyword(), String.t()) :: :ok
  def validate_config!(candidate, path) do
    configured = candidate |> Keyword.fetch!(:operators) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    conflicts =
      Memento.transaction!(fn ->
        OperatorRepository.all()
        |> Enum.map(& &1.name)
        |> Enum.filter(&MapSet.member?(configured, &1))
      end)

    case conflicts do
      [] ->
        :ok

      names ->
        raise Error, path: path, errors: ["elixircd.operators: also stored in database: #{Enum.join(names, ", ")}"]
    end
  end

  @doc "Lists names, origins, and status without returning password hashes."
  @spec list() :: [{String.t(), source(), boolean()}]
  def list do
    configured = for {name, _hash} <- Application.fetch_env!(:elixircd, :operators), do: {name, :config, true}

    database =
      Memento.transaction!(fn ->
        for oper <- OperatorRepository.all(), do: {oper.name, :database, oper.enabled}
      end)

    Enum.sort_by(configured ++ database, &elem(&1, 0))
  end
end
