defmodule ElixIRCd.Command.User do
  @moduledoc """
  This module defines the USER command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: identity} = user, %{command: "USER"}) when not is_nil(identity) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_alreadyregistered,
      params: [user_reply],
      trailing: "You may not reregister"
    })
    |> Messaging.broadcast(user)
  end

  def handle(user, %{command: "USER", params: [username, _, _], trailing: realname}) do
    updated_user = Users.update(user, %{username: username, realname: realname})

    Handshake.handle(updated_user)
  end

  @impl true
  def handle(user, %{command: "USER"}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "USER"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end
end
