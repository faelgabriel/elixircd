defmodule ElixIRCd.Utils.Mnesia do
  @moduledoc """
  Utility functions for managing the Mnesia database.
  """

  require Logger

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.HistoricalUser
  alias ElixIRCd.Tables.Metric
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @memory_tables [
    Channel,
    ChannelBan,
    ChannelInvite,
    HistoricalUser,
    Metric,
    User,
    UserChannel
  ]

  @doc """
  Sets up the Mnesia database.

  ## Options
    * `:recreate` - if set to true, recreates the schema (default: false)
    * `:verbose` - if set to true, logs verbose output (default: false)
  """
  @spec setup_mnesia(keyword()) :: :ok
  def setup_mnesia(opts \\ []) do
    stop_mnesia(opts)

    if opts[:recreate], do: recreate_schema(opts)

    create_schema(opts)
    start_mnesia(opts)
    create_tables(opts)
    wait_for_tables(opts)

    if opts[:verbose], do: Logger.info("Mnesia database setup successfully.")
    :ok
  end

  @spec recreate_schema(keyword()) :: :ok
  defp recreate_schema(opts) do
    result = Memento.Schema.delete([node()])
    if opts[:verbose], do: Logger.info("Mnesia schema delete: #{inspect(result)}")
    :ok
  end

  @spec create_schema(keyword()) :: :ok
  defp create_schema(opts) do
    result = Memento.Schema.create([node()])

    if opts[:verbose], do: Logger.info("Mnesia schema create: #{inspect(result)}")

    case result do
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, error} -> raise "Failed to create Mnesia schema:\n#{inspect(error, pretty: true)}"
      _ -> :ok
    end
  end

  @spec start_mnesia(keyword()) :: :ok
  defp start_mnesia(opts) do
    result = Memento.start()

    if opts[:verbose], do: Logger.info("Mnesia start: #{inspect(result)}")

    case result do
      :ok -> :ok
      {:error, error} -> raise "Failed to start Mnesia:\n#{inspect(error, pretty: true)}"
    end
  end

  @spec create_tables(keyword()) :: :ok
  defp create_tables(opts) do
    @memory_tables
    |> Enum.each(&handle_table_create/1)

    if opts[:verbose], do: Logger.info("Mnesia table create: :ok")
    :ok
  end

  @spec wait_for_tables(keyword()) :: :ok
  defp wait_for_tables(opts) do
    result = Memento.wait(@memory_tables, 30_000)

    if opts[:verbose], do: Logger.info("Mnesia wait tables: #{inspect(result)}")

    case result do
      :ok -> :ok
      {:timeout, tables} -> raise "Timed out waiting for Mnesia tables:\n#{inspect(tables, pretty: true)}"
      {:error, error} -> raise "Failed to wait for Mnesia tables:\n#{inspect(error, pretty: true)}"
    end
  end

  @spec stop_mnesia(keyword()) :: :ok
  defp stop_mnesia(opts) do
    # changes the log level temporarily to avoid unnecessary info log from Mnesia application stop
    original_level = Logger.level()
    Logger.configure(level: :warning)

    try do
      # Setting up disk persistence in Mnesia has always been a bit weird. It involves stopping the application,
      # creating schemas on disk, restarting the application and then creating the tables with certain options.
      result = Memento.stop()
      if opts[:verbose], do: Logger.info("Mnesia stop: #{inspect(result)}")
      :ok
    after
      Logger.configure(level: original_level)
    end
  end

  @spec handle_table_create(atom) :: :ok
  defp handle_table_create(table) do
    Memento.Table.create(table)
    |> case do
      :ok -> :ok
      {:error, {:already_exists, _}} -> :ok
      {:error, error} -> raise "Failed to create Mnesia table:\n#{inspect(error, pretty: true)}"
    end
  end
end
