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
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "WHOWAS", params: []}) do
    if Application.fetch_env!(:elixircd, :compatibility)[:rfc1459_whowas_errors] do
      [
        %Message{command: "431", params: [user.nick], trailing: "No nickname given"},
        %Message{command: :rpl_endofwhowas, params: [user.nick, "*"], trailing: "End of WHOWAS list"}
      ]
      |> Dispatcher.broadcast(:server, user)
    else
      %Message{command: :err_needmoreparams, params: [user.nick, "WHOWAS"], trailing: "Not enough parameters"}
      |> Dispatcher.broadcast(:server, user)
    end
  end

  @impl true
  def handle(user, %{command: "WHOWAS", params: params}) do
    {target_nick, max_replies} = extract_parameters(params)

    historical_users = handle_whowas(user, target_nick, max_replies)

    reply_target =
      case {String.contains?(target_nick, ["*", "?"]), historical_users} do
        {true, [%HistoricalUser{nick: nick} | _]} -> nick
        _ -> target_nick
      end

    %Message{command: :rpl_endofwhowas, params: [user.nick, reply_target], trailing: "End of WHOWAS list"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_whowas(User.t(), String.t(), non_neg_integer() | nil) :: [HistoricalUser.t()]
  defp handle_whowas(user, target_nick, max_replies) do
    historical_users =
      if String.contains?(target_nick, ["*", "?"]),
        do: HistoricalUsers.get_by_mask(target_nick, max_replies),
        else: HistoricalUsers.get_by_nick(target_nick, max_replies)

    whowasuser_message(user, historical_users, target_nick)
    historical_users
  end

  @spec extract_parameters([String.t()]) :: {String.t(), non_neg_integer() | nil}
  defp extract_parameters([target_nick]), do: {target_nick, nil}

  defp extract_parameters([target_nick, max_replies | _rest]) do
    max_replies =
      case Integer.parse(max_replies) do
        {num, ""} when num > 0 -> num
        _ -> nil
      end

    {target_nick, max_replies}
  end

  @spec whowasuser_message(User.t(), [HistoricalUser.t()], String.t()) :: :ok
  defp whowasuser_message(user, [], target_nick) do
    %Message{command: :err_wasnosuchnick, params: [user.nick, target_nick], trailing: "There was no such nickname"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp whowasuser_message(user, historical_users, _target_nick) do
    server_hostname = Application.fetch_env!(:elixircd, :server)[:hostname]

    Enum.each(historical_users, fn historical_user ->
      created_at_time = historical_user.created_at |> Calendar.strftime("%A %B %d %Y -- %H:%M:%S %Z")

      [
        %Message{
          command: :rpl_whowasuser,
          params: [
            user.nick,
            historical_user.nick,
            historical_user.ident,
            historical_user.hostname,
            "*"
          ],
          trailing: historical_user.realname
        },
        %Message{
          command: :rpl_whoisserver,
          params: [user.nick, historical_user.nick, server_hostname],
          trailing: created_at_time
        }
      ]
      |> Dispatcher.broadcast(:server, user)
    end)
  end
end
