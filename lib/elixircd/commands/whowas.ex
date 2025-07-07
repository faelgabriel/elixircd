defmodule ElixIRCd.Commands.Whowas do
  @moduledoc """
  This module defines the WHOWAS command.

  WHOWAS returns information about users who have disconnected from the server.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.HistoricalUsers
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.HistoricalUser
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "WHOWAS"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "WHOWAS", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "WHOWAS"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "WHOWAS", params: params}) do
    {target_nick, max_replies} = extract_parameters(params)

    handle_whowas(user, target_nick, max_replies)

    Message.build(%{
      prefix: :server,
      command: :rpl_endofwhowas,
      params: [user.nick, target_nick],
      trailing: "End of WHOWAS list"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec handle_whowas(User.t(), String.t(), non_neg_integer() | nil) :: :ok
  defp handle_whowas(user, target_nick, max_replies) do
    historical_users = HistoricalUsers.get_by_nick(target_nick, max_replies)

    whowasuser_message(user, historical_users, target_nick)
  end

  @spec extract_parameters([String.t()]) :: {String.t(), non_neg_integer() | nil}
  defp extract_parameters([target_nick]), do: {target_nick, nil}

  defp extract_parameters([target_nick, max_replies | _rest]) do
    max_replies =
      case Integer.parse(max_replies) do
        {num, ""} when num >= 0 -> num
        _ -> nil
      end

    {target_nick, max_replies}
  end

  @spec whowasuser_message(User.t(), [HistoricalUser.t()], String.t()) :: :ok
  defp whowasuser_message(user, [], target_nick) do
    Message.build(%{
      prefix: :server,
      command: :err_wasnosuchnick,
      params: [user.nick, target_nick],
      trailing: "There was no such nickname"
    })
    |> Dispatcher.broadcast(user)
  end

  defp whowasuser_message(user, historical_users, _target_nick) do
    server_hostname = Application.get_env(:elixircd, :server)[:hostname]

    Enum.each(historical_users, fn historical_user ->
      created_at_time = historical_user.created_at |> Calendar.strftime("%A %B %d %Y -- %H:%M:%S %Z")

      [
        Message.build(%{
          prefix: :server,
          command: :rpl_whowasuser,
          params: [
            user.nick,
            historical_user.nick,
            historical_user.ident,
            historical_user.hostname,
            historical_user.realname
          ]
        }),
        Message.build(%{
          prefix: :server,
          command: :rpl_whoisserver,
          params: [user.nick, historical_user.nick, server_hostname, created_at_time]
        })
      ]
      |> Dispatcher.broadcast(user)
    end)
  end
end
