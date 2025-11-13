defmodule ElixIRCd.Commands.Stats do
  @moduledoc """
  This module defines the STATS command.

  STATS returns various server statistics and information.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Metrics
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "STATS"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "STATS", params: []}) do
    [
      "/stats <flag> - Request specific server statistics",
      "Available flags:",
      "u - uptime - Send the server uptime and connection count"
    ]
    |> Enum.map(&%Message{command: :rpl_stats, params: [user.nick], trailing: &1})
    |> Dispatcher.broadcast(:server, user)

    %Message{
      command: :rpl_endofstats,
      params: [user.nick, "*"],
      trailing: "End of /STATS report"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "STATS", params: [flag | _rest]}) do
    handle_flag(user, flag)

    %Message{
      command: :rpl_endofstats,
      params: [user.nick, flag],
      trailing: "End of /STATS report"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_flag(User.t(), String.t()) :: :ok
  defp handle_flag(user, "u") do
    server_start_time = :persistent_term.get(:server_start_time)
    uptime = format_uptime(server_start_time)

    %Message{command: :rpl_statsuptime, params: [user.nick], trailing: "Server Up #{uptime}"}
    |> Dispatcher.broadcast(:server, user)

    current_connections = Users.count_all()
    highest_connections = Metrics.get(:highest_connections)
    total_connections = Metrics.get(:total_connections)

    %Message{
      command: :rpl_statsconn,
      params: [user.nick],
      trailing:
        "Highest connection count: #{highest_connections} (#{current_connections} clients) (#{total_connections} connections received)"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp handle_flag(_user, _flag), do: :ok

  @spec format_uptime(DateTime.t()) :: String.t()
  defp format_uptime(server_start_time) do
    current_datetime = DateTime.utc_now()
    diff_seconds = DateTime.diff(current_datetime, server_start_time)

    days = div(diff_seconds, 60 * 60 * 24)
    diff_seconds = rem(diff_seconds, 60 * 60 * 24)
    hours = div(diff_seconds, 60 * 60)
    diff_seconds = rem(diff_seconds, 60 * 60)
    minutes = div(diff_seconds, 60)
    seconds = rem(diff_seconds, 60)

    day_word = if days == 1, do: "day", else: "days"
    "#{days} #{day_word}, #{pad_zero(hours)}:#{pad_zero(minutes)}:#{pad_zero(seconds)}"
  end

  @spec pad_zero(integer()) :: String.t()
  defp pad_zero(n) when n < 10, do: "0#{n}"
  defp pad_zero(n), do: to_string(n)
end
