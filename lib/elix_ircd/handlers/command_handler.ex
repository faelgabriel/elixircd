defmodule ElixIRCd.Handlers.CommandHandler do
  @moduledoc """
  Module for handling IRC commands.
  """

  alias ElixIRCd.Commands
  alias ElixIRCd.Handlers.MessageHandler
  alias ElixIRCd.Schemas
  alias ElixIRCd.Structs.IrcMessage

  require Logger

  @commands %{
    "CAP" => Commands.Cap,
    "JOIN" => Commands.Join,
    "NICK" => Commands.Nick,
    "PART" => Commands.Part,
    "PING" => Commands.Ping,
    "PRIVMSG" => Commands.Privmsg,
    "QUIT" => Commands.Quit,
    "USER" => Commands.User,
    "WHOIS" => Commands.Whois
  }

  @doc """
  Handles the irc message command and forwards to the proper module.
  """
  @spec handle(Schemas.User.t(), IrcMessage.t()) :: :ok
  def handle(user, %{command: command} = irc_message) do
    command_module = Map.get(@commands, command)

    case command_module do
      nil -> handle_unknown_command(user, command)
      module -> module.handle(user, irc_message)
    end
  end

  @spec handle_unknown_command(Schemas.User.t(), String.t()) :: :ok
  defp handle_unknown_command(user, command) do
    MessageHandler.send_message(user, :server, "421 #{user.nick} #{command} :Unknown command")
  end
end
