defmodule ElixIRCd.Commands.Ison do
  @moduledoc """
  This module defines the ISON command.

  ISON checks if specified nicknames are currently online.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "ISON"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "ISON", params: []}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "ISON"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "ISON", params: target_nicks}) do
    users_nick_online =
      target_nicks
      |> Enum.map(&fetch_user_nick/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    %Message{command: :rpl_ison, params: [user.nick], trailing: users_nick_online}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec fetch_user_nick(String.t()) :: String.t() | nil
  defp fetch_user_nick(target_nick) do
    case Users.get_by_nick(target_nick) do
      {:ok, user} -> user.nick
      {:error, :user_not_found} -> network_user_nick(target_nick)
    end
  end

  defp network_user_nick(target_nick) do
    with manager when is_pid(manager) <- Process.whereis(Manager),
         {:ok, runtime} <- View.runtime(manager) do
      case View.user_by_nick(runtime, target_nick) do
        {:ok, _uid, user} ->
          user.nick

        _ ->
          chanserv_nick(runtime, target_nick)
      end
    else
      _ -> nil
    end
  end

  defp chanserv_nick(runtime, target_nick) do
    case View.chanserv_user_by_nick(runtime, target_nick) do
      {:ok, service} -> service.nick
      _ -> nil
    end
  end
end
