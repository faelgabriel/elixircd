defmodule ElixIRCd.Commands.Userhost do
  @moduledoc """
  This module defines the USERHOST command.

  USERHOST returns hostmask information for specified users.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [irc_operator_visible?: 2, user_host: 2, user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @command "USERHOST"

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: @command}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: @command, params: []}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), @command], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: @command, params: target_nicks}) do
    userhosts_detailed =
      target_nicks
      |> Enum.map(&fetch_userhost_info(&1, user))
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    %Message{command: :rpl_userhost, params: [user.nick], trailing: userhosts_detailed}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec fetch_userhost_info(String.t(), User.t()) :: String.t() | nil
  defp fetch_userhost_info(target_nick, viewer) do
    case Users.get_by_nick(target_nick) do
      {:ok, %{registered: true} = user} ->
        oper = if irc_operator_visible?(user, viewer), do: "*", else: ""
        presence = if user.away_message, do: "-", else: "+"
        "#{user.nick}#{oper}=#{presence}#{user_host(user, viewer)}"

      {:ok, %{registered: false}} ->
        nil

      {:error, :user_not_found} ->
        nil
    end
  end
end
