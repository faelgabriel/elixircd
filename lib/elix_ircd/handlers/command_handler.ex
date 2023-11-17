defmodule ElixIRCd.Handlers.CommandHandler do
  @moduledoc """
  Module for handling IRC commands.
  """

  alias ElixIRCd.Commands
  alias ElixIRCd.Handlers.MessageHandler
  alias ElixIRCd.Schemas

  require Logger

  @commands %{
    "cap" => Commands.Cap,
    "join" => Commands.Join,
    "nick" => Commands.Nick,
    "part" => Commands.Part,
    "ping" => Commands.Ping,
    "privmsg" => Commands.Privmsg,
    "quit" => Commands.Quit,
    "user" => Commands.User,
    "whois" => Commands.Whois
  }

  @doc """
  Handles the command and forward to the proper module.
  """
  @spec handle(Schemas.User.t(), [String.t()]) :: :ok
  def handle(user, [command | args]) do
    command_module = Map.get(@commands, String.downcase(command))

    case command_module do
      nil -> MessageHandler.send_message(user, :server, "421 #{user.nick} #{command} :Unknown command")
      module -> module.handle(user, build_command(args))
    end
  end

  # When an argument in the list starts with the ":" character,
  # all arguments from that point on are joined into a single argument.
  @spec build_command([String.t()]) :: [String.t()]
  defp build_command(args) do
    case Enum.find_index(args, &String.starts_with?(&1, ":")) do
      nil ->
        args

      index ->
        # Join the arguments after the ":" character and removes the ":" character from the beginning.
        single_argument =
          Enum.join(Enum.drop(args, index), " ")
          |> String.replace_leading(":", "")

        # Take the arguments before the ":" character and append the single argument.
        [Enum.take(args, index), single_argument]
        |> List.flatten()
    end
  end
end
