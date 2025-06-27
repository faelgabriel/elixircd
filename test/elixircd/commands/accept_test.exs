defmodule ElixIRCd.Commands.AcceptTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Accept
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserAccepts

  describe "handle/2" do
    test "handles ACCEPT command for unregistered user" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        message = %Message{command: "ACCEPT", params: []}
        assert :ok = Accept.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles ACCEPT command with no parameters (list accept list - empty)" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "ACCEPT", params: []}
        assert :ok = Accept.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 282 #{user.nick} :End of accept list\r\n"}
        ])
      end)
    end

    test "handles ACCEPT * command (list accept list - empty)" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "ACCEPT", params: ["*"]}
        assert :ok = Accept.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 282 #{user.nick} :End of accept list\r\n"}
        ])
      end)
    end

    test "handles ACCEPT command adding valid user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)

        message = %Message{command: "ACCEPT", params: [target_user.nick]}
        assert :ok = Accept.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 287 #{user.nick} #{target_user.nick} :#{target_user.nick} has been added to your accept list\r\n"}
        ])
      end)
    end

    test "handles ACCEPT command adding user that doesn't exist" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "ACCEPT", params: ["nonexistent"]}
        assert :ok = Accept.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 401 #{user.nick} nonexistent :No such nick\r\n"}
        ])
      end)
    end

    test "handles ACCEPT command removing user from accept list" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)

        insert(:user_accept, user: user, accepted_user: target_user)

        message = %Message{command: "ACCEPT", params: ["-#{target_user.nick}"]}
        assert :ok = Accept.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 288 #{user.nick} #{target_user.nick} :#{target_user.nick} has been removed from your accept list\r\n"}
        ])
      end)
    end

    test "handles ACCEPT command removing user not in accept list" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)

        message = %Message{command: "ACCEPT", params: ["-#{target_user.nick}"]}
        assert :ok = Accept.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 457 #{user.nick} #{target_user.nick} :User is not on your accept list\r\n"}
        ])
      end)
    end

    test "handles ACCEPT command adding user already in accept list" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)

        insert(:user_accept, user: user, accepted_user: target_user)

        message = %Message{command: "ACCEPT", params: [target_user.nick]}
        assert :ok = Accept.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 458 #{user.nick} #{target_user.nick} :User is already on your accept list\r\n"}
        ])
      end)
    end

    test "handles ACCEPT command listing accept list with entries" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user1 = insert(:user, nick: "TestUser1")
        target_user2 = insert(:user, nick: "TestUser2")

        insert(:user_accept, user: user, accepted_user: target_user1)
        insert(:user_accept, user: user, accepted_user: target_user2)

        message = %Message{command: "ACCEPT", params: []}
        assert :ok = Accept.handle(user, message)

        # Check that we get messages containing the accept list entries and end message
        assert_sent_messages_count_containing(user.pid, ~r/281.*TestUser/, 2)
        assert_sent_messages_count_containing(user.pid, ~r/282/, 1)
      end)
    end

    test "handles ACCEPT command with multiple comma-separated nicks" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user1 = insert(:user, nick: "TestUser1")
        target_user2 = insert(:user, nick: "TestUser2")

        message = %Message{command: "ACCEPT", params: ["#{target_user1.nick},#{target_user2.nick}"]}
        assert :ok = Accept.handle(user, message)

        # Should get two confirmation messages
        assert_sent_messages_count_containing(user.pid, ~r/287.*has been added/, 2)
      end)
    end

    test "handles ACCEPT command with mixed add/remove operations" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user1 = insert(:user, nick: "TestUser1")
        target_user2 = insert(:user, nick: "TestUser2")

        insert(:user_accept, user: user, accepted_user: target_user1)

        message = %Message{command: "ACCEPT", params: ["-#{target_user1.nick},#{target_user2.nick}"]}
        assert :ok = Accept.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/288/, 1)
        assert_sent_messages_count_containing(user.pid, ~r/287/, 1)
      end)
    end
  end

  describe "UserAccepts.get_by_user_pid_and_accepted_user_pid/2" do
    test "returns entry when sender is on recipient's accept list" do
      Memento.transaction!(fn ->
        sender = insert(:user)
        recipient = insert(:user)

        accept_entry = insert(:user_accept, user: recipient, accepted_user: sender)

        result = UserAccepts.get_by_user_pid_and_accepted_user_pid(recipient.pid, sender.pid)
        assert result.user_pid == accept_entry.user_pid
        assert result.accepted_user_pid == accept_entry.accepted_user_pid
      end)
    end

    test "returns nil when sender is not on recipient's accept list" do
      Memento.transaction!(fn ->
        sender = insert(:user)
        recipient = insert(:user)

        result = UserAccepts.get_by_user_pid_and_accepted_user_pid(recipient.pid, sender.pid)
        assert result == nil
      end)
    end

    test "uses PIDs for precise matching" do
      Memento.transaction!(fn ->
        sender = insert(:user, nick: "TestUser")
        recipient = insert(:user)

        accept_entry = insert(:user_accept, user: recipient, accepted_user: sender)

        result = UserAccepts.get_by_user_pid_and_accepted_user_pid(recipient.pid, sender.pid)
        assert result.user_pid == accept_entry.user_pid
        assert result.accepted_user_pid == accept_entry.accepted_user_pid
      end)
    end
  end
end
