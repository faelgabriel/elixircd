defmodule ElixIRCd.Services.ChanservTest do
  @moduledoc false

  use ElixIRCd.MessageCase, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Chanserv

  @service_commands [
    {"HELP", Chanserv.Help},
    {"REGISTER", Chanserv.Register},
    {"SET", Chanserv.Set}
  ]

  setup do
    user = insert(:user)
    {:ok, user: user}
  end

  describe "handle/2" do
    test "dispatches command to the appropriate service module", %{user: user} do
      for {command, module} <- @service_commands do
        module
        |> expect(:handle, fn input_user, input_commands ->
          assert input_user == user
          assert hd(input_commands) == command
          :ok
        end)

        assert :ok = Chanserv.handle(user, [command])
      end
    end

    test "normalizes command case before dispatching", %{user: user} do
      for {command, module} <- @service_commands do
        lowercase_command = String.downcase(command)

        module
        |> expect(:handle, fn input_user, input_commands ->
          assert input_user == user
          assert hd(input_commands) == command
          :ok
        end)

        assert :ok = Chanserv.handle(user, [lowercase_command])
      end
    end

    test "handles command with parameters", %{user: user} do
      for {command, module} <- @service_commands do
        params = ["param1", "param2"]

        module
        |> expect(:handle, fn input_user, input_commands ->
          assert input_user == user
          assert input_commands == [command] ++ params
          :ok
        end)

        assert :ok = Chanserv.handle(user, [command | params])
      end
    end

    test "handles unknown command", %{user: user} do
      assert :ok = Chanserv.handle(user, ["UNKNOWN"])

      assert_sent_messages([
        {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Unknown command: \x02UNKNOWN\x02\r\n"},
        {user.pid,
         ":ChanServ!service@irc.test NOTICE #{user.nick} :For help on using ChanServ, type \x02/msg ChanServ HELP\x02\r\n"}
      ])
    end

    test "displays help message for empty command list", %{user: user} do
      assert :ok = Chanserv.handle(user, [])

      assert_sent_messages([
        {user.pid,
         ":ChanServ!service@irc.test NOTICE #{user.nick} :ChanServ allows you to register and manage your channels.\r\n"},
        {user.pid,
         ":ChanServ!service@irc.test NOTICE #{user.nick} :For help on using ChanServ, type \x02/msg ChanServ HELP\x02\r\n"}
      ])
    end
  end
end
