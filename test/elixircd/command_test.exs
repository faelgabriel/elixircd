defmodule ElixIRCd.CommandTest do
  @moduledoc false

  use ElixIRCd.MessageCase, async: true
  use Mimic

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Command
  alias ElixIRCd.Commands
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext

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
    {"NAMES", Commands.Names},
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

    test "sends labeled ACK when a labeled command produces no response" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      message = %Message{command: "ADMIN", params: [], tags: %{"label" => "req-ack"}}

      Commands.Admin
      |> expect(:handle, fn input_user, input_message ->
        assert input_user == user
        assert input_message == message
        :ok
      end)

      assert :ok = Command.dispatch(user, message)

      assert_sent_messages([
        {user.pid, "@label=req-ack :irc.test ACK\r\n"}
      ])
    end

    test "wraps labeled multi-message responses in a labeled-response batch" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      message = %Message{command: "WHOIS", params: ["target"], tags: %{"label" => "req-batch"}}

      Commands.Whois
      |> expect(:handle, fn input_user, input_message ->
        assert input_user == user
        assert input_message == message

        %Message{command: "NOTICE", params: [user.nick], trailing: "first"}
        |> Dispatcher.broadcast(:server, user)

        %Message{command: "NOTICE", params: [user.nick], trailing: "second"}
        |> Dispatcher.broadcast(:server, user)
      end)

      assert :ok = Command.dispatch(user, message)
      user_pid = user.pid

      [{^user_pid, start}, {^user_pid, first}, {^user_pid, second}, {^user_pid, finish}] =
        Agent.get(@agent_name, &Enum.reverse/1)

      assert [batch_ref] =
               Regex.run(~r/^@label=req-batch :irc\.test BATCH \+([A-Za-z0-9-]+) labeled-response\r\n$/, start,
                 capture: :all_but_first
               )

      assert first == "@batch=#{batch_ref} :irc.test NOTICE #{user.nick} :first\r\n"
      assert second == "@batch=#{batch_ref} :irc.test NOTICE #{user.nick} :second\r\n"
      assert finish == ":irc.test BATCH -#{batch_ref}\r\n"
    end

    test "uses a single applicable manual batch as the labeled logical response" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      message = %Message{command: "TRACE", params: [], tags: %{"label" => "req-nested"}}

      Commands.Trace
      |> expect(:handle, fn input_user, input_message ->
        assert input_user == user
        assert input_message == message

        ResponseContext.with_batch("draft/example", ["meta"], fn ->
          %Message{command: "NOTICE", params: [user.nick], trailing: "nested"}
          |> Dispatcher.broadcast(:server, user)
        end)

        :ok
      end)

      assert :ok = Command.dispatch(user, message)
      user_pid = user.pid

      [{^user_pid, start}, {^user_pid, nested}, {^user_pid, finish}] =
        Agent.get(@agent_name, &Enum.reverse/1)

      assert [batch_ref] =
               Regex.run(~r/^@label=req-nested :irc\.test BATCH \+([A-Za-z0-9-]+) draft\/example meta\r\n$/, start,
                 capture: :all_but_first
               )

      assert nested == "@batch=#{batch_ref} :irc.test NOTICE #{user.nick} :nested\r\n"
      assert finish == ":irc.test BATCH -#{batch_ref}\r\n"
    end

    test "labels a single response directly without batch overhead" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      message = %Message{command: "INFO", params: [], tags: %{"label" => "req-single"}}

      expect(Commands.Info, :handle, fn _user, _message ->
        %Message{command: "NOTICE", params: [user.nick], trailing: "single"}
        |> Dispatcher.broadcast(:server, user)
      end)

      assert :ok = Command.dispatch(user, message)

      assert_sent_messages([
        {user.pid, "@label=req-single :irc.test NOTICE #{user.nick} :single\r\n"}
      ])
    end

    test "emits an explicitly empty manual batch" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      message = %Message{command: "TIME", params: [], tags: %{"label" => "req-empty"}}

      expect(Commands.Time, :handle, fn _user, _message ->
        ResponseContext.with_batch("draft/example", ["empty"], fn -> :ok end)
      end)

      assert :ok = Command.dispatch(user, message)
      user_pid = user.pid

      [{^user_pid, start}, {^user_pid, finish}] = Agent.get(@agent_name, &Enum.reverse/1)

      assert [batch_ref] =
               Regex.run(~r/^@label=req-empty :irc\.test BATCH \+([A-Za-z0-9-]+) draft\/example empty\r\n$/, start,
                 capture: :all_but_first
               )

      assert finish == ":irc.test BATCH -#{batch_ref}\r\n"
    end

    test "emits an explicitly empty batch without requiring labeled-response" do
      user = insert(:user, capabilities: ["batch"])
      message = %Message{command: "TIME", params: [], tags: %{}}

      expect(Commands.Time, :handle, fn _user, _message ->
        ResponseContext.with_batch("draft/example", ["empty"], fn -> :ok end)
      end)

      assert :ok = Command.dispatch(user, message)
      user_pid = user.pid

      [{^user_pid, start}, {^user_pid, finish}] = Agent.get(@agent_name, &Enum.reverse/1)

      assert [batch_ref] =
               Regex.run(~r/^:irc\.test BATCH \+([A-Za-z0-9-]+) draft\/example empty\r\n$/, start,
                 capture: :all_but_first
               )

      assert finish == ":irc.test BATCH -#{batch_ref}\r\n"
    end

    test "accepts a label whose UTF-8 encoding is exactly 64 bytes" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      label = String.duplicate("é", 32)
      message = %Message{command: "VERSION", params: [], tags: %{"label" => label}}

      expect(Commands.Version, :handle, fn _user, _message ->
        %Message{command: "NOTICE", params: [user.nick], trailing: "valid"}
        |> Dispatcher.broadcast(:server, user)
      end)

      assert :ok = Command.dispatch(user, message)
      assert_sent_messages([{user.pid, "@label=#{label} :irc.test NOTICE #{user.nick} :valid\r\n"}])
    end

    test "does not reflect a label whose UTF-8 encoding exceeds 64 bytes" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      label = String.duplicate("é", 33)
      message = %Message{command: "USERS", params: [], tags: %{"label" => label}}

      expect(Commands.Users, :handle, fn _user, _message ->
        %Message{command: "NOTICE", params: [user.nick], trailing: "invalid"}
        |> Dispatcher.broadcast(:server, user)
      end)

      assert :ok = Command.dispatch(user, message)
      assert_sent_messages([{user.pid, ":irc.test NOTICE #{user.nick} :invalid\r\n"}])
    end

    test "does not finalize a failed handler with a false labeled ACK" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      message = %Message{command: "TRACE", params: [], tags: %{"label" => "req-failed"}}

      expect(Commands.Trace, :handle, fn _user, _message -> raise "handler failed" end)

      assert_raise RuntimeError, "handler failed", fn -> Command.dispatch(user, message) end
      assert_sent_messages_amount(user.pid, 0)
      assert ResponseContext.current() == nil
    end

    test "preserves a partial labeled response when the handler fails" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      message = %Message{command: "TRACE", params: [], tags: %{"label" => "req-partial"}}

      expect(Commands.Trace, :handle, fn _user, _message ->
        %Message{command: "NOTICE", params: [user.nick], trailing: "partial"}
        |> Dispatcher.broadcast(:server, user)

        raise "handler failed after response"
      end)

      assert_raise RuntimeError, "handler failed after response", fn -> Command.dispatch(user, message) end

      assert_sent_messages([
        {user.pid, "@label=req-partial :irc.test NOTICE #{user.nick} :partial\r\n"}
      ])

      assert ResponseContext.current() == nil
    end

    for {command, module} <- [
          {"PRIVMSG", Commands.Privmsg},
          {"NOTICE", Commands.Notice},
          {"TAGMSG", Commands.Tagmsg}
        ] do
      test "self-targeted #{command} is delivered once without a label when echo-message is disabled" do
        command = unquote(command)
        module = unquote(module)
        user = insert(:user, capabilities: ["batch", "labeled-response", "message-tags"])

        message = %Message{
          command: command,
          params: [user.nick],
          trailing: if(command == "TAGMSG", do: nil, else: "hello"),
          tags: %{"label" => "self"}
        }

        expect(module, :handle, fn _user, _message ->
          message
          |> Map.put(:tags, %{})
          |> Dispatcher.broadcast_with_echo(user, user)
        end)

        assert :ok = Command.dispatch(user, message)

        trailing = if command == "TAGMSG", do: "", else: " :hello"
        assert_sent_messages([{user.pid, ":#{user_mask(user)} #{command} #{user.nick}#{trailing}\r\n"}])
      end

      test "self-targeted #{command} has distinct unlabeled delivery and labeled echo" do
        command = unquote(command)
        module = unquote(module)

        user =
          insert(:user,
            capabilities: ["batch", "labeled-response", "message-tags", "echo-message"]
          )

        message = %Message{
          command: command,
          params: [user.nick],
          trailing: if(command == "TAGMSG", do: nil, else: "hello"),
          tags: %{"label" => "self-echo"}
        }

        expect(module, :handle, fn _user, _message ->
          message
          |> Map.put(:tags, %{})
          |> Dispatcher.broadcast_with_echo(user, user)
        end)

        assert :ok = Command.dispatch(user, message)

        trailing = if command == "TAGMSG", do: "", else: " :hello"
        delivered = ":#{user_mask(user)} #{command} #{user.nick}#{trailing}\r\n"
        echoed = "@label=self-echo :#{user_mask(user)} #{command} #{user.nick}#{trailing}\r\n"
        assert_sent_messages([{user.pid, delivered}, {user.pid, echoed}])
      end
    end
  end
end
