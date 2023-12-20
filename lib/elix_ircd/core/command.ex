defmodule ElixIRCd.Core.Command do
  @moduledoc """
  Module for handling IRC commands.
  """

  alias ElixIRCd.Commands
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageBuilder

  @doc """
  Handles the irc message command and forwards to the proper module.
  """
  @spec handle(Schemas.User.t(), Message.t()) :: :ok | {:error, String.t()}
  def handle(user, %{command: "CAP"} = message), do: Commands.Cap.handle(user, message)
  def handle(user, %{command: "JOIN"} = message), do: Commands.Join.handle(user, message)
  def handle(user, %{command: "MODE"} = message), do: Commands.Mode.handle(user, message)
  def handle(user, %{command: "NICK"} = message), do: Commands.Nick.handle(user, message)
  def handle(user, %{command: "PART"} = message), do: Commands.Part.handle(user, message)
  def handle(user, %{command: "PING"} = message), do: Commands.Ping.handle(user, message)
  def handle(user, %{command: "PRIVMSG"} = message), do: Commands.Privmsg.handle(user, message)
  def handle(user, %{command: "QUIT"} = message), do: Commands.Quit.handle(user, message)
  def handle(user, %{command: "USER"} = message), do: Commands.User.handle(user, message)
  def handle(user, %{command: "USERHOST"} = message), do: Commands.Userhost.handle(user, message)
  def handle(user, %{command: "WHOIS"} = message), do: Commands.Whois.handle(user, message)

  def handle(user, %{command: command}) do
    MessageBuilder.server_message(:err_unknowncommand, [user.nick, command], "Unknown command")
    |> Messaging.send_message(user)
  end
end
