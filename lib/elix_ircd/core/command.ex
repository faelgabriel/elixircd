defmodule ElixIRCd.Core.Command do
  @moduledoc """
  Module for handling IRC commands.
  """

  alias ElixIRCd.Commands
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageBuilder

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
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(user, %{command: command} = message) do
    command_module = Map.get(@commands, command)

    case command_module do
      nil -> handle_unknown_command(user, command)
      module -> module.handle(user, message)
    end
  end

  @spec handle_unknown_command(Schemas.User.t(), String.t()) :: :ok
  defp handle_unknown_command(user, command) do
    MessageBuilder.server_message(:err_unknowncommand, [user.nick, command], "Unknown command")
    |> Messaging.send_message(user)
  end
end
