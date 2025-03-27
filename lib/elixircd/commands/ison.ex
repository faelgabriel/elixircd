defmodule ElixIRCd.Commands.Ison do
  @moduledoc """
  This module defines the ISON command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "ISON"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "ISON", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply(user), "ISON"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "ISON", params: target_nicks}) do
    users_nick_online =
      target_nicks
      |> Enum.map(&fetch_user_nick/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    Message.build(%{prefix: :server, command: :rpl_ison, params: [user.nick], trailing: users_nick_online})
    |> Dispatcher.broadcast(user)
  end

  @spec fetch_user_nick(String.t()) :: String.t() | nil
  defp fetch_user_nick(nick) do
    case Users.get_by_nick(nick) do
      {:ok, user} -> user.nick
      {:error, _} -> nil
    end
  end
end
