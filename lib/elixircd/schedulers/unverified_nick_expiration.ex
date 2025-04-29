defmodule ElixIRCd.Schedulers.UnverifiedNickExpiration do
  @moduledoc """
  A GenServer responsible for automatically expiring unverified nickname registrations after a configured
  period of time. It periodically checks for nicknames that have not been verified and removes them from the registry.
  """

  use GenServer

  require Logger

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredNick

  # 30 minutes in milliseconds
  @first_cleanup_interval 30 * 60 * 1000

  # 6 hours in milliseconds
  @cleanup_interval 6 * 60 * 60 * 1000

  @doc """
  Starts the UnverifiedNickExpiration GenServer.
  """
  @spec start_link(any()) :: {:ok, pid()} | {:error, term()}
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  @spec init(any()) :: {:ok, map()}
  def init(_) do
    # Only run if unverified_expire_days is > 0
    unverified_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:unverified_expire_days] || 1

    if unverified_expire_days > 0 do
      # Schedule the first cleanup after 30 minutes of server start
      Process.send_after(self(), :cleanup, @first_cleanup_interval)
    end

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
      Logger.info("Starting expiration of unverified nicknames")
      expired_count = expire_unverified_nicknames()
      Logger.info("Unverified nickname expiration completed. #{expired_count} nicknames were removed.")

      :ok
    end)
  end

  @spec expire_unverified_nicknames() :: integer()
  defp expire_unverified_nicknames do
    RegisteredNicks.get_all()
    |> Enum.filter(&check_unverified_nick_expiration/1)
    |> Enum.map(fn nick ->
      Logger.info("Expiring unverified nickname: #{nick.nickname} (registered: #{nick.created_at})")
      RegisteredNicks.delete(nick)
      nick.nickname
    end)
    |> length()
  end

  @spec check_unverified_nick_expiration(RegisteredNick.t()) :: boolean()
  defp check_unverified_nick_expiration(registered_nick) do
    # Only consider nicknames with verify_code (unverified and requiring verification)
    if is_nil(registered_nick.verify_code) or !is_nil(registered_nick.verified_at) do
      false
    else
      unverified_expire_days =
        (Application.get_env(:elixircd, :services)[:nickserv][:unverified_expire_days] || 1) * 24 * 60 * 60

      expiration_date = DateTime.add(registered_nick.created_at, unverified_expire_days, :second)
      DateTime.compare(DateTime.utc_now(), expiration_date) == :gt
    end
  end
end
