defmodule ElixIRCd.Utils.NicknameExpirationScheduler do
  @moduledoc """
  GenServer responsible for automatically expiring registered nicknames
  that have not been used for the configured period of time.
  """

  use GenServer
  require Logger

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredNick

  # 24 hours in milliseconds
  @cleanup_interval 24 * 60 * 60 * 1000

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Schedule the first cleanup after 1 hour of server start
    Process.send_after(self(), :cleanup, 60 * 60 * 1000)
    {:ok, %{last_cleanup: nil}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Execute the cleanup
    cleanup_result = run_cleanup()

    # Record when the last cleanup was executed
    now = DateTime.utc_now()

    # Schedule the next execution
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:noreply, %{state | last_cleanup: now, last_result: cleanup_result}}
  end

  @doc """
  Executes the expiration of unused nicknames.
  Returns the number of expired nicknames.
  """
  def run_cleanup do
    Logger.info("Starting expiration of unused nicknames")
    expired_count = expire_old_nicknames()
    Logger.info("Expiration completed. #{expired_count} nicknames were removed.")
    expired_count
  end

  @doc """
  Forces the execution of the expiration immediately.
  """
  def force_cleanup do
    GenServer.call(__MODULE__, :force_cleanup)
  end

  @impl true
  def handle_call(:force_cleanup, _from, state) do
    result = run_cleanup()
    {:reply, result, %{state | last_cleanup: DateTime.utc_now(), last_result: result}}
  end

  @doc """
  Checks if a nickname has expired based on the last_seen_at timestamp.
  """
  @spec check_nick_expiration(RegisteredNick.t()) :: boolean()
  def check_nick_expiration(registered_nick) do
    nick_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90

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

  @doc """
  Finds and expires nicknames that have not been used in the configured time period.
  Returns the number of expired nicknames.
  """
  @spec expire_old_nicknames() :: integer()
  def expire_old_nicknames() do
    RegisteredNicks.get_all()
    |> Enum.filter(&check_nick_expiration/1)
    |> Enum.map(fn nick ->
      Logger.info("Expiring nickname: #{nick.nickname} (last seen: #{nick.last_seen_at || nick.created_at})")
      RegisteredNicks.delete(nick)
      nick.nickname
    end)
    |> length()
  end
end
