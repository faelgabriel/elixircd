defmodule ElixIRCd.Repositories.ScramCredentials do
  @moduledoc """
  Repository for SCRAM credentials.

  Provides functions to create, retrieve, update, and delete SCRAM credentials
  used for SCRAM-SHA-256 and SCRAM-SHA-512 authentication.
  """

  alias ElixIRCd.Tables.ScramCredential
  alias ElixIRCd.Utils.CaseMapping

  @doc """
  Get SCRAM credentials for a nickname and algorithm.
  """
  @spec get(String.t(), :sha256 | :sha512) :: {:ok, ScramCredential.t()} | {:error, :not_found}
  def get(nickname, algorithm) do
    nickname_key = CaseMapping.normalize(nickname)
    key = "#{nickname_key}:#{algorithm}"

    Memento.transaction!(fn ->
      case Memento.Query.read(ScramCredential, key) do
        nil -> {:error, :not_found}
        credential -> {:ok, credential}
      end
    end)
  end

  @doc """
  Get all SCRAM credentials for a nickname (all algorithms).
  """
  @spec get_all(String.t()) :: [ScramCredential.t()]
  def get_all(nickname) do
    nickname_key = CaseMapping.normalize(nickname)

    Memento.transaction!(fn ->
      ScramCredential
      |> Memento.Query.select({:==, :nickname_key, nickname_key})
    end)
  end

  @doc """
  Create or update SCRAM credentials for a nickname.
  """
  @spec upsert(ScramCredential.t()) :: ScramCredential.t()
  def upsert(credential) do
    Memento.transaction!(fn ->
      # Update timestamp
      updated_credential = Map.put(credential, :updated_at, DateTime.utc_now())

      # Write (will overwrite if key exists)
      Memento.Query.write(updated_credential)
    end)

    credential
  end

  @doc """
  Delete SCRAM credentials for a specific nickname and algorithm.
  """
  @spec delete(String.t(), :sha256 | :sha512) :: :ok
  def delete(nickname, algorithm) do
    nickname_key = CaseMapping.normalize(nickname)
    key = "#{nickname_key}:#{algorithm}"

    Memento.transaction!(fn ->
      case Memento.Query.read(ScramCredential, key) do
        nil -> :ok
        record -> Memento.Query.delete_record(record)
      end
    end)

    :ok
  end

  @doc """
  Delete all SCRAM credentials for a nickname.
  """
  @spec delete_all(String.t()) :: :ok
  def delete_all(nickname) do
    nickname_key = CaseMapping.normalize(nickname)

    Memento.transaction!(fn ->
      ScramCredential
      |> Memento.Query.select({:==, :nickname_key, nickname_key})
      |> Enum.each(&Memento.Query.delete_record/1)
    end)

    :ok
  end

  @doc """
  Generate and store SCRAM credentials for a nickname and password.

  This will create credentials for all configured SCRAM algorithms.
  """
  @spec generate_and_store(String.t(), String.t()) :: :ok
  def generate_and_store(nickname, password) do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    scram_config = sasl_config[:scram] || []
    iterations = Keyword.get(scram_config, :iterations, 4096)
    algorithms = Keyword.get(scram_config, :algorithms, ["SHA-256", "SHA-512"])

    # Generate and store for each configured algorithm
    algorithms
    |> Enum.each(fn algo_str ->
      algorithm =
        case algo_str do
          "SHA-256" -> :sha256
          "SHA-512" -> :sha512
          _ -> nil
        end

      if algorithm do
        credential =
          ScramCredential.generate_from_password(
            nickname,
            password,
            algorithm,
            iterations
          )

        upsert(credential)
      end
    end)

    :ok
  end

  @doc """
  Check if SCRAM credentials exist for a nickname and algorithm.
  """
  @spec exists?(String.t(), :sha256 | :sha512) :: boolean()
  def exists?(nickname, algorithm) do
    case get(nickname, algorithm) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end
end
