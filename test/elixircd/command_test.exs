defmodule ElixIRCd.CommandTest do
  @moduledoc false

  use ElixIRCd.MessageCase, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Commands
  alias ElixIRCd.Message

  @commands [
    {"ADMIN", Commands.Admin},
    {"AWAY", Commands.Away},
    {"CAP", Commands.Cap},
    {"DIE", Commands.Die},
    {"INFO", Commands.Info},
    {"INVITE", Commands.Invite},
    {"ISON", Commands.Ison},
    {"JOIN", Commands.Join},
    {"KICK", Commands.Kick},
    {"KILL", Commands.Kill},
    {"LIST", Commands.List},
    {"LUSERS", Commands.Lusers},
    {"MODE", Commands.Mode},
    {"MOTD", Commands.Motd},
    {"NOTICE", Commands.Notice},
    {"NICK", Commands.Nick},
    {"OPER", Commands.Oper},
    {"PART", Commands.Part},
    {"PASS", Commands.Pass},
    {"PING", Commands.Ping},
    {"PRIVMSG", Commands.Privmsg},
    {"QUIT", Commands.Quit},
    {"REHASH", Commands.Rehash},
    {"RESTART", Commands.Restart},
    {"STATS", Commands.Stats},
    {"TOPIC", Commands.Topic},
    {"TRACE", Commands.Trace},
    {"TIME", Commands.Time},
    {"USER", Commands.User},
    {"USERS", Commands.Users},
    {"USERHOST", Commands.Userhost},
    {"VERSION", Commands.Version},
    {"WALLOPS", Commands.Wallops},
    {"WHO", Commands.Who},
    {"WHOIS", Commands.Whois},
    {"WHOWAS", Commands.Whowas}
  ]

  describe "dispatch/2" do
    setup do
      user = build(:user)
      {:ok, user: user}
    end

    test "dispatches message to the appropriate command module", %{user: user} do
      for {command, module} <- @commands do
        message = %Message{command: command, params: []}

        module
        |> expect(:handle, fn input_user, input_message ->
          assert input_user == user
          assert input_message == message
          :ok
        end)

        assert :ok = Command.dispatch(user, message)
      end
    end

    test "handles unknown command", %{user: user} do
      message = %Message{command: "UNKNOWN", params: []}

      assert :ok = Command.dispatch(user, message)

      assert_sent_messages([
        {user.pid, ":irc.test 421 #{user.nick} #{message.command} :Unknown command\r\n"}
      ])
    end
  end
end
