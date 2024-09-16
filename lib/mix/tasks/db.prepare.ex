defmodule Mix.Tasks.Db.Prepare do
  @moduledoc """
  Prepares the Mnesia database.
  """

  use Mix.Task

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
  Runs the task to prepare the Mnesia database.
  """
  @spec run(list) :: :ok
  def run(args) do
    opts = parse_opts(args)

    stop_mnesia(opts)

    if opts[:recreate], do: recreate_schema(opts)

    create_schema(opts)
    start_mnesia(opts)
    create_tables(opts)
    wait_for_tables(opts)

    shell_info("Mnesia database prepared successfully.", opts)
  end

  defp recreate_schema(opts) do
    Memento.Schema.delete([node()])
    |> tap(&verbose_info(&1, "Mnesia schema delete", opts))
  end

  @spec create_schema(keyword()) :: :ok
  defp create_schema(opts) do
    Memento.Schema.create([node()])
    |> tap(&verbose_info(&1, "Mnesia schema create", opts))
    |> case do
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, error} -> Mix.raise("Failed to create Mnesia schema:\n#{inspect(error, pretty: true)}")
      _ -> :ok
    end
  end

  @spec start_mnesia(keyword()) :: :ok
  defp start_mnesia(opts) do
    Memento.start()
    |> tap(&verbose_info(&1, "Mnesia start", opts))
    |> case do
      :ok -> :ok
      {:error, error} -> Mix.raise("Failed to start Mnesia:\n#{inspect(error, pretty: true)}")
    end
  end

  @spec create_tables(keyword()) :: :ok
  defp create_tables(opts) do
    @memory_tables
    |> Enum.each(&handle_table_create/1)
    |> tap(&verbose_info(&1, "Mnesia table create", opts))
  end

  @spec wait_for_tables(keyword()) :: :ok
  defp wait_for_tables(opts) do
    Memento.wait(@memory_tables, 30_000)
    |> tap(&verbose_info(&1, "Mnesia wait tables", opts))
    |> case do
      :ok -> :ok
      {:timeout, tables} -> Mix.raise("Timed out waiting for Mnesia tables:\n#{inspect(tables, pretty: true)}")
      {:error, error} -> Mix.raise("Failed to wait for Mnesia tables:\n#{inspect(error, pretty: true)}")
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
      Memento.stop()
      |> tap(&verbose_info(&1, "Mnesia stop", opts))
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
      {:error, error} -> Mix.raise("Failed to create Mnesia table:\n#{inspect(error, pretty: true)}")
    end
  end

  @spec verbose_info(term, String.t(), Keyword.t()) :: :ok
  defp verbose_info(output, message, opts) do
    if opts[:verbose] do
      shell_info("#{message}: #{inspect(output, pretty: true)}", opts)
    end

    :ok
  end

  @spec shell_info(String.t(), Keyword.t()) :: :ok
  defp shell_info(message, opts) do
    unless opts[:quiet] do
      Mix.shell().info(message)
    end
  end

  @spec parse_opts(list) :: Keyword.t()
  defp parse_opts(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [recreate: :boolean, verbose: :boolean, quiet: :boolean, r: :boolean, v: :boolean, q: :boolean],
        aliases: [r: :recreate, v: :verbose, q: :quiet]
      )

    opts
  end
end
