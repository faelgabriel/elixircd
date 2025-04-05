defmodule ElixIRCd.Services.NickservTest do
  @moduledoc false

  use ElixIRCd.MessageCase, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Nickserv

  @service_commands [
    {"HELP", Nickserv.Help},
    {"REGISTER", Nickserv.Register},
    {"VERIFY", Nickserv.Verify},
    {"IDENTIFY", Nickserv.Identify},
    {"GHOST", Nickserv.Ghost},
    {"REGAIN", Nickserv.Regain},
    {"RELEASE", Nickserv.Release},
    {"DROP", Nickserv.Drop},
    {"INFO", Nickserv.Info},
    {"SET", Nickserv.Set}
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

        assert :ok = Nickserv.handle(user, [command])
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

        assert :ok = Nickserv.handle(user, [lowercase_command])
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

        assert :ok = Nickserv.handle(user, [command | params])
      end
    end

    test "handles unknown command", %{user: user} do
      assert :ok = Nickserv.handle(user, ["UNKNOWN"])

      assert_sent_messages([
        {user.pid, ":NickServ!service@server.example.com NOTICE #{user.nick} :Unknown command: \x02UNKNOWN\x02\r\n"},
        {user.pid,
         ":NickServ!service@server.example.com NOTICE #{user.nick} :For help on using NickServ, type \x02/msg NickServ HELP\x02\r\n"}
      ])
    end

    test "displays help message for empty command list", %{user: user} do
      assert :ok = Nickserv.handle(user, [])

      assert_sent_messages([
        {user.pid,
         ":NickServ!service@server.example.com NOTICE #{user.nick} :NickServ allows you to register and manage your nickname.\r\n"},
        {user.pid,
         ":NickServ!service@server.example.com NOTICE #{user.nick} :For help on using NickServ, type \x02/msg NickServ HELP\x02\r\n"}
      ])
    end
  end
end
