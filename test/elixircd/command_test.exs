defmodule ElixIRCd.CommandTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic
  doctest ElixIRCd.Command

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  import ElixIRCd.Factory

  @supported_commands [
    {"CAP", Command.Cap},
    {"JOIN", Command.Join},
    {"MODE", Command.Mode},
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

      Server
      |> expect(:send_message, fn input_message, input_user ->
        assert input_message == %Message{
                 source: "server.example.com",
                 command: "421",
                 params: [user.nick, message.command],
                 body: "Unknown command"
               }

        assert input_user == user
      end)

      Command.handle(user, message)
    end
  end
end
