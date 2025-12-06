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
    process_user_command(user, username, realname)
  end

  def handle(user, %{command: "USER", params: [username, _, _, realname | _], trailing: nil}) do
    process_user_command(user, username, realname)
  end

  def handle(user, %{command: "USER"}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "USER"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec process_user_command(User.t(), String.t(), String.t()) :: :ok
  defp process_user_command(user, username, realname) do
    max_ident_length = Application.get_env(:elixircd, :user)[:max_ident_length]
    max_realname_length = Application.get_env(:elixircd, :user)[:max_realname_length]

    if String.length(username) > max_ident_length do
      %Message{
        command: :err_invalidusername,
        params: [user_reply(user)],
        trailing: "Your username is invalid (maximum #{max_ident_length} characters)"
      }
      |> Dispatcher.broadcast(:server, user)
    else
      truncated_realname = String.slice(realname, 0, max_realname_length)
      updated_user = Users.update(user, %{ident: "~" <> username, realname: truncated_realname})
      Handshake.handle(updated_user)
    end
  end
end
