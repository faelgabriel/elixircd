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
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "ADMIN"} = message), do: Command.Admin.handle(user, message)
  def handle(user, %{command: "AWAY"} = message), do: Command.Away.handle(user, message)
  def handle(user, %{command: "CAP"} = message), do: Command.Cap.handle(user, message)
  def handle(user, %{command: "DIE"} = message), do: Command.Die.handle(user, message)
  def handle(user, %{command: "INFO"} = message), do: Command.Info.handle(user, message)
  def handle(user, %{command: "INVITE"} = message), do: Command.Invite.handle(user, message)
  def handle(user, %{command: "ISON"} = message), do: Command.Ison.handle(user, message)
  def handle(user, %{command: "JOIN"} = message), do: Command.Join.handle(user, message)
  def handle(user, %{command: "KICK"} = message), do: Command.Kick.handle(user, message)
  def handle(user, %{command: "KILL"} = message), do: Command.Kill.handle(user, message)
  def handle(user, %{command: "LIST"} = message), do: Command.List.handle(user, message)
  def handle(user, %{command: "LUSERS"} = message), do: Command.Lusers.handle(user, message)
  def handle(user, %{command: "MODE"} = message), do: Command.Mode.handle(user, message)
  def handle(user, %{command: "MOTD"} = message), do: Command.Motd.handle(user, message)
  def handle(user, %{command: "NICK"} = message), do: Command.Nick.handle(user, message)
  def handle(user, %{command: "NOTICE"} = message), do: Command.Notice.handle(user, message)
  def handle(user, %{command: "OPER"} = message), do: Command.Oper.handle(user, message)
  def handle(user, %{command: "PART"} = message), do: Command.Part.handle(user, message)
  def handle(user, %{command: "PASS"} = message), do: Command.Pass.handle(user, message)
  def handle(user, %{command: "PING"} = message), do: Command.Ping.handle(user, message)
  def handle(user, %{command: "PRIVMSG"} = message), do: Command.Privmsg.handle(user, message)
  def handle(user, %{command: "QUIT"} = message), do: Command.Quit.handle(user, message)
  def handle(user, %{command: "REHASH"} = message), do: Command.Rehash.handle(user, message)
  def handle(user, %{command: "RESTART"} = message), do: Command.Restart.handle(user, message)
  def handle(user, %{command: "STATS"} = message), do: Command.Stats.handle(user, message)
  def handle(user, %{command: "SUMMON"} = message), do: Command.Summon.handle(user, message)
  def handle(user, %{command: "TIME"} = message), do: Command.Time.handle(user, message)
  def handle(user, %{command: "TOPIC"} = message), do: Command.Topic.handle(user, message)
  def handle(user, %{command: "TRACE"} = message), do: Command.Trace.handle(user, message)
  def handle(user, %{command: "USER"} = message), do: Command.User.handle(user, message)
  def handle(user, %{command: "USERS"} = message), do: Command.Users.handle(user, message)
  def handle(user, %{command: "USERHOST"} = message), do: Command.Userhost.handle(user, message)
  def handle(user, %{command: "VERSION"} = message), do: Command.Version.handle(user, message)
  def handle(user, %{command: "WALLOPS"} = message), do: Command.Wallops.handle(user, message)
  def handle(user, %{command: "WHO"} = message), do: Command.Who.handle(user, message)
  def handle(user, %{command: "WHOIS"} = message), do: Command.Whois.handle(user, message)
  def handle(user, %{command: "WHOWAS"} = message), do: Command.Whowas.handle(user, message)

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
