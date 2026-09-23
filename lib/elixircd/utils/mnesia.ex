defmodule ElixIRCd.Utils.Mnesia do
  @moduledoc """
  Utility functions for managing the Mnesia database.
  """

  require Logger

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelExcept
  alias ElixIRCd.Tables.ChannelInvex
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.ChatHistory
  alias ElixIRCd.Tables.ClientBatch
  alias ElixIRCd.Tables.HistoricalUser
  alias ElixIRCd.Tables.Job
  alias ElixIRCd.Tables.Memo
  alias ElixIRCd.Tables.Metadata
  alias ElixIRCd.Tables.MetadataSubscription
  alias ElixIRCd.Tables.Metric
  alias ElixIRCd.Tables.NickAccess
  alias ElixIRCd.Tables.ReadMarker
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.RegisteredChannelAccess
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.RegisteredNick.Settings
  alias ElixIRCd.Tables.SaslSession
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserAccept
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Tables.UserMonitor
  alias ElixIRCd.Tables.UserSilence
  alias Memento.Query.Data

  @memory_tables [
    Channel,
    ChannelBan,
    ChannelExcept,
    ChannelInvex,
    ChannelInvite,
    ClientBatch,
    HistoricalUser,
    Metric,
    MetadataSubscription,
    SaslSession,
    User,
    UserAccept,
    UserChannel,
    UserMonitor,
    UserSilence
  ]

  @disk_tables [
    ChatHistory,
    Job,
    Memo,
    Metadata,
    NickAccess,
    ReadMarker,
    RegisteredChannel,
    RegisteredChannelAccess,
    RegisteredNick
  ]

  @doc """
  Returns a list of all table modules.
  """
  @spec all_tables() :: [atom()]
  def all_tables do
    @memory_tables ++ @disk_tables
  end

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
    upgrade_schemas()

    if opts[:verbose], do: Logger.info("Mnesia database setup successfully.")
    :ok
  end

  @doc "Runs compatible table migrations after local table copies are available."
  @spec upgrade_schemas() :: :ok
  def upgrade_schemas do
    upgrade_user_connection_fields()
    upgrade_monitor_nickname()
    upgrade_sasl_session_schema()
    upgrade_registered_nick_schema()
    ensure_index(ChatHistory, :sender_account_key)
    ensure_index(ChatHistory, :recipient_account_key)
    ensure_index(ReadMarker, :target_key)
    ensure_index(ChannelInvite, :channel_name_key)
    :ok
  end

  defp ensure_index(table, field) do
    case :mnesia.add_table_index(table, field) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^table, _position}} -> :ok
      {:aborted, reason} -> raise "Failed adding #{inspect(table)} index #{field}: #{inspect(reason)}"
    end
  end

  defp upgrade_user_connection_fields do
    expected = User.__info__().attributes
    attributes = :mnesia.table_info(User, :attributes)
    additions = [{:client_port, nil}, {:cap_version, 301}]
    missing = Enum.filter(additions, fn {field, _default} -> field not in attributes end)
    known_old_attributes = expected -- Enum.map(missing, &elem(&1, 0))

    cond do
      attributes == expected ->
        :ok

      attributes == known_old_attributes ->
        transform = fn row ->
          row |> insert_missing_fields(User, attributes, expected, missing) |> Data.load() |> Data.dump()
        end

        {:atomic, :ok} = :mnesia.transform_table(User, transform, expected)

      true ->
        raise "User table has unexpected attributes: #{inspect(attributes)}"
    end

    :ok
  end

  defp upgrade_monitor_nickname do
    expected = UserMonitor.__info__().attributes
    attributes = :mnesia.table_info(UserMonitor, :attributes)

    if attributes == List.delete(expected, :target_nick) do
      transform = fn row ->
        monitor = Data.load(row)
        monitor |> Map.put(:target_nick, monitor.target_nick_key) |> Data.dump()
      end

      {:atomic, :ok} = :mnesia.transform_table(UserMonitor, transform, expected)
    end

    :ok
  end

  defp upgrade_sasl_session_schema do
    expected = SaslSession.__info__().attributes
    attributes = :mnesia.table_info(SaslSession, :attributes)

    if attributes == List.delete(expected, :state) do
      position = Enum.find_index(expected, &(&1 == :state)) + 1
      transform = fn row -> row |> Tuple.insert_at(position, nil) |> Data.load() |> Data.dump() end
      {:atomic, :ok} = :mnesia.transform_table(SaslSession, transform, expected)
    end

    :ok
  end

  defp upgrade_registered_nick_schema do
    expected = RegisteredNick.__info__().attributes
    attributes = :mnesia.table_info(RegisteredNick, :attributes)

    additions = [
      {:scram_sha_256, nil},
      {:pending_email, nil},
      {:pending_email_verify_code, nil},
      {:pending_email_requested_at, nil}
    ]

    missing = Enum.filter(additions, fn {field, _default} -> field not in attributes end)
    known_old_attributes = expected -- Enum.map(missing, &elem(&1, 0))

    cond do
      attributes == expected ->
        :ok

      attributes == known_old_attributes ->
        transform_registered_nicks(expected, fn row ->
          insert_missing_fields(row, RegisteredNick, attributes, expected, missing)
        end)

      true ->
        raise "RegisteredNick table has unexpected attributes: #{inspect(attributes)}"
    end

    :ok
  end

  defp transform_registered_nicks(expected, insert_fields) do
    transform = fn row ->
      row
      |> insert_fields.()
      |> Data.load()
      |> then(fn registered_nick -> %{registered_nick | settings: Settings.normalize(registered_nick.settings)} end)
      |> Data.dump()
    end

    {:atomic, :ok} = :mnesia.transform_table(RegisteredNick, transform, expected)
  end

  defp insert_missing_fields(row, table, old_attributes, expected, missing) do
    old_values =
      row |> Tuple.to_list() |> tl() |> Enum.zip(old_attributes) |> Map.new(fn {value, field} -> {field, value} end)

    defaults = Map.new(missing)

    values =
      Enum.map(expected, fn field ->
        case Map.fetch(old_values, field) do
          {:ok, value} -> value
          :error -> Map.fetch!(defaults, field)
        end
      end)

    List.to_tuple([table | values])
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

    @disk_tables
    |> Enum.each(&handle_disk_table_create/1)

    if opts[:verbose], do: Logger.info("Mnesia table create: :ok")
    :ok
  end

  @spec wait_for_tables(keyword()) :: :ok
  defp wait_for_tables(opts) do
    all_tables = @memory_tables ++ @disk_tables
    result = Memento.wait(all_tables, 30_000)

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

  @spec handle_disk_table_create(atom) :: :ok
  defp handle_disk_table_create(table) do
    Memento.Table.create(table, disc_copies: [node()])
    |> case do
      :ok -> :ok
      {:error, {:already_exists, _}} -> :ok
      {:error, error} -> raise "Failed to create Mnesia disk table:\n#{inspect(error, pretty: true)}"
    end
  end
end
