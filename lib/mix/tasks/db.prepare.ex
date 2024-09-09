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

    if opts[:recreate] do
      Memento.Schema.delete([node()])
      |> verbose_info("Mnesia schema delete", opts)
    end

    Memento.Schema.create([node()])
    |> verbose_info("Mnesia schema create", opts)
    |> case do
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, error} -> Mix.raise("Failed to create Mnesia schema:\n#{inspect(error, pretty: true)}")
      _ -> :ok
    end

    Memento.start()
    |> verbose_info("Mnesia start", opts)
    |> case do
      :ok -> :ok
      {:error, error} -> Mix.raise("Failed to start Mnesia:\n#{inspect(error, pretty: true)}")
    end

    @memory_tables
    |> Enum.each(&handle_table_create/1)
    |> verbose_info("Mnesia table create", opts)

    Memento.wait(@memory_tables, 30_000)
    |> verbose_info("Mnesia wait tables", opts)
    |> case do
      :ok -> :ok
      {:timeout, tables} -> Mix.raise("Timed out waiting for Mnesia tables:\n#{inspect(tables, pretty: true)}")
      {:error, error} -> Mix.raise("Failed to wait for Mnesia tables:\n#{inspect(error, pretty: true)}")
    end

    shell_info("Mnesia database prepared successfully.", opts)
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
      |> verbose_info("Mnesia stop", opts)
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

  @spec verbose_info(term, String.t(), Keyword.t()) :: :ok | {:error, any}
  defp verbose_info(output, message, opts) do
    if opts[:verbose] do
      shell_info("#{message}: #{inspect(output, pretty: true)}", opts)
    end

    output
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
