defmodule ElixIRCd.CommandTest do
  @moduledoc false

  use ElixIRCd.MessageCase, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Message

  @supported_commands [
    {"ADMIN", Command.Admin},
    {"AWAY", Command.Away},
    {"CAP", Command.Cap},
    {"DIE", Command.Die},
    {"INFO", Command.Info},
    {"INVITE", Command.Invite},
    {"ISON", Command.Ison},
    {"JOIN", Command.Join},
    {"KICK", Command.Kick},
    {"KILL", Command.Kill},
    {"LIST", Command.List},
    {"LUSERS", Command.Lusers},
    {"MODE", Command.Mode},
    {"MOTD", Command.Motd},
    {"NOTICE", Command.Notice},
    {"NICK", Command.Nick},
    {"OPER", Command.Oper},
    {"PART", Command.Part},
    {"PASS", Command.Pass},
    {"PING", Command.Ping},
    {"PRIVMSG", Command.Privmsg},
    {"QUIT", Command.Quit},
    {"REHASH", Command.Rehash},
    {"RESTART", Command.Restart},
    {"STATS", Command.Stats},
    {"SUMMON", Command.Summon},
    {"TOPIC", Command.Topic},
    {"TRACE", Command.Trace},
    {"TIME", Command.Time},
    {"USER", Command.User},
    {"USERS", Command.Users},
    {"USERHOST", Command.Userhost},
    {"VERSION", Command.Version},
    {"WALLOPS", Command.Wallops},
    {"WHO", Command.Who},
    {"WHOIS", Command.Whois},
    {"WHOWAS", Command.Whowas}
  ]

  describe "handle/2" do
    setup do
      user = build(:user)
      {:ok, user: user}
    end

    test "handles and dispatches message for command module", %{user: user} do
      for {command, module} <- @supported_commands do
        message = %Message{command: command, params: []}

        module
        |> expect(:handle, fn input_user, input_message ->
          assert input_user == user
          assert input_message == message
        end)

        Command.handle(user, message)
      end
    end

    test "handles unknown command", %{user: user} do
      message = %Message{command: "UNKNOWN", params: []}

      Command.handle(user, message)

      assert_sent_messages([
        {user.socket, ":server.example.com 421 #{user.nick} #{message.command} :Unknown command\r\n"}
      ])
    end
  end

  # TODO: create a test that try to handles the messages in all possible eays (1 parameter, 2, 3..., nil trailing or not, etc.)
end
