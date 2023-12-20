defmodule ElixIRCd.Commands.Userhost do
  @moduledoc """
  This module defines the USER command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior

  @command "USERHOST"

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: @command}) do
    MessageBuilder.server_message(:rpl_notregistered, ["*"], "You have not registered")
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: @command, params: target_nicks}) when target_nicks != [] do
    userhost_detailed =
      target_nicks
      |> Enum.map_join(" ", fn nick -> fetch_userhost_info(nick) end)
      |> String.trim()

    MessageBuilder.server_message(:rpl_userhost, [user.nick], userhost_detailed)
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: @command}) do
    user_reply = MessageBuilder.get_user_reply(user)

    MessageBuilder.server_message(:rpl_needmoreparams, [user_reply, @command], "Not enough parameters")
    |> Messaging.send_message(user)
  end

  @spec fetch_userhost_info(String.t()) :: String.t()
  defp fetch_userhost_info(nick) do
    case Contexts.User.get_by_nick(nick) do
      {:ok, user} -> "#{user.nick}=#{user.identity}"
      {:error, _} -> ""
    end
  end
end
