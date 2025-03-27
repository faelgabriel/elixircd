defmodule ElixIRCd.Command.Oper do
  @moduledoc """
  This module defines the OPER command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "OPER"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "OPER", params: params}) when length(params) <= 1 do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "OPER"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "OPER", params: [username, password | _rest]}) do
    if valid_irc_operator_credential?(username, password) do
      updated_user = Users.update(user, %{modes: ["o" | user.modes]})

      Message.build(%{
        prefix: :server,
        command: :rpl_youreoper,
        params: [updated_user.nick],
        trailing: "You are now an IRC operator"
      })
      |> Dispatcher.broadcast(updated_user)
    else
      Message.build(%{
        prefix: :server,
        command: :err_passwdmismatch,
        params: [user.nick],
        trailing: "Password incorrect"
      })
      |> Dispatcher.broadcast(user)
    end
  end

  @spec valid_irc_operator_credential?(String.t(), String.t()) :: boolean()
  defp valid_irc_operator_credential?(username, password) do
    Application.get_env(:elixircd, :operators)
    |> Enum.any?(fn {oper_username, oper_password} ->
      oper_username == username and Pbkdf2.verify_pass(password, oper_password)
    end)
  end
end
