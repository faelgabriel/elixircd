defmodule ElixIRCd.Commands.Help do
  @moduledoc """
  Implements the Modern IRC HELP and HELPOP commands.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: _command}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: command, params: params}) when command in ["HELP", "HELPOP"] do
    subject = params |> List.first("index") |> String.upcase()

    if subject == "INDEX" or subject in Command.names() do
      send_help(user, subject)
    else
      %Message{command: :err_helpnotfound, params: [user.nick, subject], trailing: "No help available"}
      |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec send_help(User.t(), String.t()) :: :ok
  defp send_help(user, "INDEX" = subject) do
    command_list = Command.names() |> Enum.chunk_every(12) |> Enum.map(&Enum.join(&1, " "))

    [
      %Message{command: :rpl_helpstart, params: [user.nick, subject], trailing: "ElixIRCd command index"},
      Enum.map(command_list, &%Message{command: :rpl_helptxt, params: [user.nick, subject], trailing: &1}),
      %Message{command: :rpl_endofhelp, params: [user.nick, subject], trailing: "End of HELP"}
    ]
    |> List.flatten()
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_help(user, subject) do
    [
      %Message{
        command: :rpl_helpstart,
        params: [user.nick, subject],
        trailing: "#{subject} is supported by this server"
      },
      %Message{
        command: :rpl_helptxt,
        params: [user.nick, subject],
        trailing: "Use standard IRC syntax and consult the Modern IRC specification for parameters."
      },
      %Message{command: :rpl_endofhelp, params: [user.nick, subject], trailing: "End of HELP"}
    ]
    |> Dispatcher.broadcast(:server, user)
  end
end
