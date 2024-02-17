defmodule ElixIRCd.Command do
  @moduledoc """
  Module for handling incoming IRC commands.
  """

  alias ElixIRCd.Command
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @doc """
  Handles the IRC message command.

  Modules that implement this behaviour should define their own logic for handling the IRC message command.
  """
  @callback handle(user :: User.t(), message :: Message.t()) :: :ok

  @doc """
  Forwards the IRC message command to the proper module.
  """
  @spec handle(User.t(), Message.t()) :: :ok | {:error, String.t()}
  def handle(user, %{command: "CAP"} = message), do: Command.Cap.handle(user, message)
  def handle(user, %{command: "JOIN"} = message), do: Command.Join.handle(user, message)
  def handle(user, %{command: "MODE"} = message), do: Command.Mode.handle(user, message)
  def handle(user, %{command: "NICK"} = message), do: Command.Nick.handle(user, message)
  def handle(user, %{command: "PART"} = message), do: Command.Part.handle(user, message)
  def handle(user, %{command: "PING"} = message), do: Command.Ping.handle(user, message)
  def handle(user, %{command: "PRIVMSG"} = message), do: Command.Privmsg.handle(user, message)
  def handle(user, %{command: "QUIT"} = message), do: Command.Quit.handle(user, message)
  def handle(user, %{command: "USER"} = message), do: Command.User.handle(user, message)
  def handle(user, %{command: "USERHOST"} = message), do: Command.Userhost.handle(user, message)
  def handle(user, %{command: "WHOIS"} = message), do: Command.Whois.handle(user, message)

  def handle(user, %{command: command}) do
    Message.build(%{
      prefix: :server,
      command: :err_unknowncommand,
      params: [Helper.get_user_reply(user), command],
      trailing: "Unknown command"
    })
    |> Messaging.broadcast(user)
  end
end
