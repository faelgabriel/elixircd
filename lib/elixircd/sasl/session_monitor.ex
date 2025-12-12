defmodule ElixIRCd.Sasl.SessionMonitor do
  @moduledoc """
  Monitors SASL authentication sessions and cleans up expired ones.

  This GenServer periodically checks for SASL sessions that have exceeded
  the configured timeout and removes them, sending appropriate error messages
  to the clients.
  """

  use GenServer
  require Logger

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher

  # Check every 30 seconds
  @check_interval 30_000

  @doc """
  Start the session monitor.
  """
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Initializes the session monitor GenServer.

  Schedules the first timeout check and returns the initial state.
  """
  @impl true
  @spec init(map()) :: {:ok, map()}
  def init(state) do
    schedule_check()
    {:ok, state}
  end

  @doc """
  Handles the periodic timeout check message.

  When receiving `:check_timeouts`, this callback:
  - Checks for and cleans up expired SASL sessions
  - Schedules the next timeout check
  """
  @impl true
  @spec handle_info(:check_timeouts, map()) :: {:noreply, map()}
  def handle_info(:check_timeouts, state) do
    check_and_cleanup_expired_sessions()
    schedule_check()
    {:noreply, state}
  end

  @spec schedule_check() :: reference()
  defp schedule_check do
    Process.send_after(self(), :check_timeouts, @check_interval)
  end

  @spec check_and_cleanup_expired_sessions() :: any()
  defp check_and_cleanup_expired_sessions do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    timeout_ms = Keyword.get(sasl_config, :session_timeout_ms, 60_000)
    cutoff_time = DateTime.add(DateTime.utc_now(), -timeout_ms, :millisecond)

    Memento.transaction!(fn ->
      ElixIRCd.Tables.SaslSession
      |> Memento.Query.all()
      |> Enum.filter(fn session ->
        DateTime.compare(session.created_at, cutoff_time) == :lt
      end)
      |> Enum.each(&cleanup_expired_session/1)
    end)
  end

  @spec cleanup_expired_session(ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp cleanup_expired_session(session) do
    Logger.debug("SASL session timeout for user PID #{inspect(session.user_pid)}")

    case Users.get_by_pid(session.user_pid) do
      {:ok, user} ->
        %Message{
          command: :err_saslaborted,
          params: [user.nick || "*"],
          trailing: "SASL authentication timeout"
        }
        |> Dispatcher.broadcast(:server, user)

      _ ->
        :ok
    end

    SaslSessions.delete(session.user_pid)
  end
end
