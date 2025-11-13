defmodule ElixIRCd.Commands.User do
  @moduledoc """
  This module defines the USER command.

  USER sets the username and real name during client registration.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: true} = user, %{command: "USER"}) do
    %Message{command: :err_alreadyregistered, params: [user_reply(user)], trailing: "You may not reregister"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "USER", params: [username, _, _ | _], trailing: realname}) when is_binary(realname) do
    updated_user = Users.update(user, %{ident: "~" <> username, realname: realname})
    Handshake.handle(updated_user)
  end

  def handle(user, %{command: "USER", params: [username, _, _, realname | _], trailing: nil}) do
    updated_user = Users.update(user, %{ident: "~" <> username, realname: realname})
    Handshake.handle(updated_user)
  end

  @impl true
  def handle(user, %{command: "USER"}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "USER"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end
end
