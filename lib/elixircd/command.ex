defmodule ElixIRCd.Command do
  @moduledoc """
  Module for handling incoming IRC commands.
  """

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Commands
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @commands %{
    "ACCEPT" => Commands.Accept,
    "ADMIN" => Commands.Admin,
    "AWAY" => Commands.Away,
    "CAP" => Commands.Cap,
    "DIE" => Commands.Die,
    "GLOBOPS" => Commands.Globops,
    "INFO" => Commands.Info,
    "INVITE" => Commands.Invite,
    "ISON" => Commands.Ison,
    "JOIN" => Commands.Join,
    "KICK" => Commands.Kick,
    "KILL" => Commands.Kill,
    "LIST" => Commands.List,
    "LUSERS" => Commands.Lusers,
    "MODE" => Commands.Mode,
    "MOTD" => Commands.Motd,
    "NAMES" => Commands.Names,
    "NICK" => Commands.Nick,
    "NOTICE" => Commands.Notice,
    "OPER" => Commands.Oper,
    "OPERWALL" => Commands.Operwall,
    "PART" => Commands.Part,
    "PASS" => Commands.Pass,
    "PING" => Commands.Ping,
    "PRIVMSG" => Commands.Privmsg,
    "QUIT" => Commands.Quit,
    "REHASH" => Commands.Rehash,
    "RESTART" => Commands.Restart,
    "SILENCE" => Commands.Silence,
    "STATS" => Commands.Stats,
    "TIME" => Commands.Time,
    "TOPIC" => Commands.Topic,
    "TRACE" => Commands.Trace,
    "TAGMSG" => Commands.Tagmsg,
    "USER" => Commands.User,
    "USERS" => Commands.Users,
    "USERHOST" => Commands.Userhost,
    "VERSION" => Commands.Version,
    "WALLOPS" => Commands.Wallops,
    "WHO" => Commands.Who,
    "WHOIS" => Commands.Whois,
    "WHOWAS" => Commands.Whowas
  }

  @doc """
  Defines the behaviour for handling incoming IRC commands.
  """
  @callback handle(user :: User.t(), message :: Message.t()) :: :ok | {:quit, String.t()}

  @doc """
  Dispatches a command to the appropriate module that implements the `ElixIRCd.Command` behaviour.
  """
  @spec dispatch(User.t(), Message.t()) :: :ok | {:quit, String.t()}
  def dispatch(user, message) do
    case Map.fetch(@commands, message.command) do
      {:ok, command_module} -> command_module.handle(user, message)
      :error -> unknown_command_message(user, message.command)
    end
  end

  @spec unknown_command_message(User.t(), String.t()) :: :ok
  defp unknown_command_message(user, command) do
    %Message{command: :err_unknowncommand, params: [user_reply(user), command], trailing: "Unknown command"}
    |> Dispatcher.broadcast(:server, user)
  end
end
