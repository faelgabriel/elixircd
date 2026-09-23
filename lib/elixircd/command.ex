defmodule ElixIRCd.Command do
  @moduledoc """
  Module for handling incoming IRC commands.
  """

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Commands
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.Tables.User

  @commands %{
    "ACCEPT" => Commands.Accept,
    "ADMIN" => Commands.Admin,
    "AUTHENTICATE" => Commands.Authenticate,
    "AWAY" => Commands.Away,
    "BATCH" => Commands.Batch,
    "CAP" => Commands.Cap,
    "CHGHOST" => Commands.Chghost,
    "CHATHISTORY" => Commands.Chathistory,
    "DIE" => Commands.Die,
    "GLOBOPS" => Commands.Globops,
    "HELP" => Commands.Help,
    "HELPOP" => Commands.Help,
    "INFO" => Commands.Info,
    "INVITE" => Commands.Invite,
    "ISON" => Commands.Ison,
    "JOIN" => Commands.Join,
    "KICK" => Commands.Kick,
    "KILL" => Commands.Kill,
    "LIST" => Commands.List,
    "MARKREAD" => Commands.Markread,
    "METADATA" => Commands.Metadata,
    "LINKS" => Commands.Links,
    "LUSERS" => Commands.Lusers,
    "MODE" => Commands.Mode,
    "MONITOR" => Commands.Monitor,
    "MOTD" => Commands.Motd,
    "NAMES" => Commands.Names,
    "NICK" => Commands.Nick,
    "NOTICE" => Commands.Notice,
    "OPER" => Commands.Oper,
    "OPERWALL" => Commands.Operwall,
    "PART" => Commands.Part,
    "PASS" => Commands.Pass,
    "PING" => Commands.Ping,
    "PONG" => Commands.Pong,
    "PRIVMSG" => Commands.Privmsg,
    "QUIT" => Commands.Quit,
    "REDACT" => Commands.Redact,
    "REGISTER" => Commands.Register,
    "RENAME" => Commands.Rename,
    "REHASH" => Commands.Rehash,
    "RESTART" => Commands.Restart,
    "SETNAME" => Commands.Setname,
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
    "VERIFY" => Commands.Verify,
    "WALLOPS" => Commands.Wallops,
    "WEBIRC" => Commands.Webirc,
    "WHO" => Commands.Who,
    "WHOIS" => Commands.Whois,
    "WHOWAS" => Commands.Whowas
  }

  @doc "Returns supported IRC command names."
  @spec names() :: [String.t()]
  def names, do: @commands |> Map.keys() |> Enum.sort()

  @doc """
  Defines the behaviour for handling incoming IRC commands.
  """
  @callback handle(user :: User.t(), message :: Message.t()) :: :ok | {:quit, String.t()}

  @doc """
  Dispatches a command to the appropriate module that implements the `ElixIRCd.Command` behaviour.
  """
  @spec dispatch(User.t(), Message.t()) :: :ok | {:quit, String.t()}
  def dispatch(user, message) do
    case ElixIRCd.Multiline.capture(user, message) do
      :handled ->
        :ok

      :continue when message.command == "BATCH" ->
        dispatch_to_module(user, message)

      :continue ->
        ResponseContext.with_command(user, message, fn -> dispatch_to_module(user, message) end)
    end
  end

  defp dispatch_to_module(user, message) do
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
