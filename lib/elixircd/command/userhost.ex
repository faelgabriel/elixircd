defmodule ElixIRCd.Command.Userhost do
  @moduledoc """
  This module defines the USER command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @command "USERHOST"

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: @command}) do
    Message.build(%{source: :server, command: :err_notregistered, params: ["*"], body: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: @command, params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user_reply, @command],
      body: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: @command, params: target_nicks}) do
    userhost_detailed =
      target_nicks
      |> Enum.map_join(" ", fn nick -> fetch_userhost_info(nick) end)
      |> String.trim()

    Message.build(%{source: :server, command: :rpl_userhost, params: [user.nick], body: userhost_detailed})
    |> Messaging.broadcast(user)
  end

  @spec fetch_userhost_info(String.t()) :: String.t()
  defp fetch_userhost_info(nick) do
    case Users.get_by_nick(nick) do
      {:ok, user} -> "#{user.nick}=#{user.identity}"
      {:error, _} -> ""
    end
  end
end
