defmodule ElixIRCd.Commands.Userhost do
  @moduledoc """
  This module defines the USERHOST command.

  USERHOST returns hostmask information for specified users.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @command "USERHOST"

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: @command}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: @command, params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply(user), @command],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: @command, params: target_nicks}) do
    userhosts_detailed =
      target_nicks
      |> Enum.map(&fetch_userhost_info/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    Message.build(%{prefix: :server, command: :rpl_userhost, params: [user.nick], trailing: userhosts_detailed})
    |> Dispatcher.broadcast(user)
  end

  @spec fetch_userhost_info(String.t()) :: String.t() | nil
  defp fetch_userhost_info(target_nick) do
    case Users.get_by_nick(target_nick) do
      {:ok, user} -> "#{user.nick}=#{user_mask(user)}"
      {:error, :user_not_found} -> nil
    end
  end
end
