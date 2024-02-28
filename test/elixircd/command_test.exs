defmodule ElixIRCd.CommandTest do
  @moduledoc false

  use ElixIRCd.MessageCase, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Message

  @supported_commands [
    {"CAP", Command.Cap},
    {"JOIN", Command.Join},
    {"MODE", Command.Mode},
    {"NOTICE", Command.Notice},
    {"NICK", Command.Nick},
    {"PART", Command.Part},
    {"PING", Command.Ping},
    {"PRIVMSG", Command.Privmsg},
    {"QUIT", Command.Quit},
    {"USER", Command.User},
    {"USERHOST", Command.Userhost},
    {"WHOIS", Command.Whois}
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
end
