defmodule ElixIRCd.Command.Userhost do
  @moduledoc """
  This module defines the USER command.
  """

  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  @behaviour ElixIRCd.Command

  @command "USERHOST"

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: @command}) do
    Message.new(%{source: :server, command: :err_notregistered, params: ["*"], body: "You have not registered"})
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: @command, params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user_reply, @command],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: @command, params: target_nicks}) do
    userhost_detailed =
      target_nicks
      |> Enum.map_join(" ", fn nick -> fetch_userhost_info(nick) end)
      |> String.trim()

    Message.new(%{source: :server, command: :rpl_userhost, params: [user.nick], body: userhost_detailed})
    |> Server.send_message(user)
  end

  @spec fetch_userhost_info(String.t()) :: String.t()
  defp fetch_userhost_info(nick) do
    case Contexts.User.get_by_nick(nick) do
      {:ok, user} -> "#{user.nick}=#{user.identity}"
      {:error, _} -> ""
    end
  end
end
