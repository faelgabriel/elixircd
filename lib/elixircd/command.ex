defmodule ElixIRCd.Command do
  @moduledoc """
  Module for handling incoming IRC commands.
  """

  alias ElixIRCd.Command
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @commands %{
    "ADMIN" => Command.Admin,
    "AWAY" => Command.Away,
    "CAP" => Command.Cap,
    "DIE" => Command.Die,
    "INFO" => Command.Info,
    "INVITE" => Command.Invite,
    "ISON" => Command.Ison,
    "JOIN" => Command.Join,
    "KICK" => Command.Kick,
    "KILL" => Command.Kill,
    "LIST" => Command.List,
    "LUSERS" => Command.Lusers,
    "MODE" => Command.Mode,
    "MOTD" => Command.Motd,
    "NICK" => Command.Nick,
    "NOTICE" => Command.Notice,
    "OPER" => Command.Oper,
    "PART" => Command.Part,
    "PASS" => Command.Pass,
    "PING" => Command.Ping,
    "PRIVMSG" => Command.Privmsg,
    "QUIT" => Command.Quit,
    "REHASH" => Command.Rehash,
    "RESTART" => Command.Restart,
    "STATS" => Command.Stats,
    "TIME" => Command.Time,
    "TOPIC" => Command.Topic,
    "TRACE" => Command.Trace,
    "USER" => Command.User,
    "USERS" => Command.Users,
    "USERHOST" => Command.Userhost,
    "VERSION" => Command.Version,
    "WALLOPS" => Command.Wallops,
    "WHO" => Command.Who,
    "WHOIS" => Command.Whois,
    "WHOWAS" => Command.Whowas
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
    Message.build(%{
      prefix: :server,
      command: :err_unknowncommand,
      params: [Helper.get_user_reply(user), command],
      trailing: "Unknown command"
    })
    |> Messaging.broadcast(user)
  end
end
