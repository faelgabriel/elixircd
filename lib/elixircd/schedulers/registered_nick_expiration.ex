defmodule ElixIRCd.Schedulers.RegisteredNickExpiration do
  @moduledoc """
  A GenServer responsible for automatically expiring registered nicknames that have not been used for a configured
  period of time. It periodically checks for nicknames that have not been active and removes them from the registry.
  """

  use GenServer

  require Logger

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredNick

  # 1 hour in milliseconds
  @first_cleanup_interval 1 * 60 * 60 * 1000

  # 24 hours in milliseconds
  @cleanup_interval 24 * 60 * 60 * 1000

  @doc """
  Starts the RegisteredNickExpiration GenServer.
  """
  @spec start_link(any()) :: {:ok, pid()} | {:error, term()}
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  @spec init(any()) :: {:ok, map()}
  def init(_) do
    # Schedule the first cleanup after 1 hour of server start
    Process.send_after(self(), :cleanup, @first_cleanup_interval)

    {:ok, %{last_cleanup: nil}}
  end

  @impl true
  @spec handle_info(any(), map()) :: {:noreply, map()}
  def handle_info(:cleanup, state) do
    # Execute the cleanup
    run_cleanup()

    # Schedule the next cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:noreply, %{state | last_cleanup: DateTime.utc_now()}}
  end

  @spec run_cleanup() :: :ok
  defp run_cleanup do
    Memento.transaction!(fn ->
      Logger.info("Starting expiration of unused nicknames")
      expired_count = expire_old_nicknames()
      Logger.info("Expiration completed. #{expired_count} nicknames were removed.")

      :ok
    end)
  end

  @spec expire_old_nicknames() :: integer()
  defp expire_old_nicknames do
    RegisteredNicks.get_all()
    |> Enum.filter(&check_nick_expiration/1)
    |> Enum.map(fn nick ->
      Logger.info("Expiring nickname: #{nick.nickname} (last seen: #{nick.last_seen_at || nick.created_at})")
      RegisteredNicks.delete(nick)
      nick.nickname
    end)
    |> length()
  end

  @spec check_nick_expiration(RegisteredNick.t()) :: boolean()
  defp check_nick_expiration(registered_nick) do
    nick_expire_days =
      (Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90) * 24 * 60 * 60

    case registered_nick.last_seen_at do
      nil ->
        # Use created_at if last_seen_at is nil
        expiration_date = DateTime.add(registered_nick.created_at, nick_expire_days, :day)
        DateTime.compare(DateTime.utc_now(), expiration_date) == :gt

      last_seen_at ->
        expiration_date = DateTime.add(last_seen_at, nick_expire_days, :day)
        DateTime.compare(DateTime.utc_now(), expiration_date) == :gt
    end
  end
end
