defmodule ElixIRCd.Commands.Lusers do
  @moduledoc """
  This module defines the LUSERS command.

  LUSERS returns statistics about the number of users and channels on the server.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.Metrics
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.NetworkStats
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "LUSERS"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "LUSERS"}) do
    send_lusers(user)
  end

  @doc """
  Sends the LUSERS information to the user.
  """
  @spec send_lusers(User.t()) :: :ok
  def send_lusers(user) do
    case network_snapshot() do
      {:ok, %NetworkStats{} = network} -> send_counts(user, network)
      :unavailable -> send_unavailable(user)
    end
  end

  defp network_snapshot do
    if Application.fetch_env!(:elixircd, :server_links)[:enabled],
      do: NetworkStats.get(),
      else: {:ok, NetworkStats.standalone(Channels.count_all())}
  end

  defp send_unavailable(user) do
    %Message{
      command: :err_unavailresource,
      params: [user.nick, "LUSERS"],
      trailing: "Network statistics are temporarily unavailable"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_counts(user, %NetworkStats{} = network) do
    %{visible: visible, invisible: invisible, operators: operators, unknown: unknown} =
      Users.count_all_states()

    local_users = visible + invisible
    global_visible = visible + network.remote_visible
    global_invisible = invisible + network.remote_invisible
    global_users = global_visible + global_invisible
    local_highest = max(local_users, Metrics.get(:highest_users))
    global_highest = max(global_users, local_highest)
    server_count = network.remote_servers + 1
    server_label = if server_count == 1, do: "server", else: "servers"

    [
      %Message{
        command: :rpl_luserclient,
        params: [user.nick],
        trailing:
          "There are #{global_visible} users and #{global_invisible} invisible on #{server_count} #{server_label}"
      },
      %Message{
        command: :rpl_luserop,
        params: [user.nick, to_string(operators + network.remote_operators)],
        trailing: "operator(s) online"
      },
      %Message{command: :rpl_luserunknown, params: [user.nick, to_string(unknown)], trailing: "unknown connection(s)"},
      %Message{
        command: :rpl_luserchannels,
        params: [user.nick, to_string(network.channels)],
        trailing: "channels formed"
      },
      %Message{
        command: :rpl_luserme,
        params: [user.nick],
        trailing: "I have #{local_users} clients and #{network.direct_servers} servers"
      },
      %Message{
        command: :rpl_localusers,
        params: [user.nick, to_string(local_users), to_string(local_highest)],
        trailing: "Current local users #{local_users}, max #{local_highest}"
      },
      %Message{
        command: :rpl_globalusers,
        params: [user.nick, to_string(global_users), to_string(global_highest)],
        trailing: "Current global users #{global_users}, max #{global_highest}"
      }
    ]
    |> Dispatcher.broadcast(:server, user)
  end
end
