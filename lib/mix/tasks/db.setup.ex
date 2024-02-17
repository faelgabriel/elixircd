defmodule Mix.Tasks.Db.Setup do
  @moduledoc """
  Setups the Mnesia database.
  """

  use Mix.Task

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @memory_tables [
    Channel,
    User,
    UserChannel
  ]

  # Setting up disk persistence in Mnesia has always been a bit weird. It involves stopping the application,
  # creating schemas on disk, restarting the application and then creating the tables with certain options.
  @shortdoc "Setups the Mnesia database"
  def run(args) do
    options = parse_args(args)

    Memento.stop()
    |> verbose_info("Mnesia stop", options)

    if options[:recreate] do
      Memento.Schema.delete([node()])
      |> verbose_info("Mnesia schema delete", options)
    end

    Memento.Schema.create([node()])
    |> verbose_info("Mnesia schema create", options)
    |> case do
      {:error, {_, {:already_exists, _}}} ->
        Mix.raise(
          "Failed to create Mnesia schema. Database already exists.\nUse -r or --recreate to recreate the database."
        )

      {:error, error} ->
        Mix.raise("Failed to create Mnesia schema. Error:\n#{inspect(error, pretty: true)}")

      _ ->
        :ok
    end

    Memento.start()
    |> verbose_info("Mnesia start", options)

    @memory_tables
    |> Enum.each(&Memento.Table.create/1)
    |> verbose_info("Mnesia table create", options)

    Memento.wait(@memory_tables, 10_000)
    |> verbose_info("Mnesia wait tables", options)

    if options[:recreate] do
      Mix.shell().info("Mnesia database recreated successfully.")
    else
      Mix.shell().info("Mnesia database created successfully.")
    end
  end

  @spec parse_args(list) :: Keyword.t()
  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [recreate: :boolean, verbose: :boolean, r: :boolean, v: :boolean],
        aliases: [r: :recreate, v: :verbose]
      )

    opts
  end

  @spec verbose_info(term, String.t(), Keyword.t()) :: :ok | {:error, any}
  defp verbose_info(output, message, options) do
    if options[:verbose] do
      Mix.shell().info("#{message}: #{inspect(output, pretty: true)}")
    end

    output
  end
end
