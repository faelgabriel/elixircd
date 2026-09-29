defmodule ElixIRCd.Commands.AcceptTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Accept
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserAcceptRemotes
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.User

  describe "handle/2" do
    test "handles ACCEPT command for user not registered" do
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

    test "remote ACCEPT follows a stable UID across nickname changes and can be removed" do
      table = Directory.create()
      uid = UserPayload.new_uid()
      remote = build(:user, nick: "Remote") |> UserPayload.from_local(uid)
      old = Replica.new()
      present = %{old | users: %{{"east.example", uid} => remote}, nick_keys: %{"remote" => {"east.example", uid}}}
      Directory.sync(table, old, present)

      user = Memento.transaction!(fn -> insert(:user, nick: "Local", modes: [:g]) end)

      Memento.transaction!(fn ->
        assert :ok = Accept.handle(user, %Message{command: "ACCEPT", params: ["Remote"]})

        assert %ElixIRCd.Tables.UserAcceptRemote{} =
                 UserAcceptRemotes.get_by_user_pid_and_identity(user.pid, {"east.example", uid})

        assert :ok = Accept.handle(user, %Message{command: "ACCEPT", params: ["Remote"]})
      end)

      assert_sent_message_contains(user.pid, ~r/287 Local Remote :Remote has been added/)
      assert_sent_message_contains(user.pid, ~r/458 Local Remote :User is already on your accept list/)
      assert [%{uid: ^uid}] = Directory.all()

      renamed_user = %{remote | "nick" => "Renamed"}

      renamed = %{
        present
        | users: %{{"east.example", uid} => renamed_user},
          nick_keys: %{"renamed" => {"east.example", uid}}
      }

      Directory.sync(table, present, renamed)
      assert {:ok, %{user: %{"nick" => "Renamed"}}} = Directory.get_by_identity("east.example", uid)

      Memento.transaction!(fn ->
        assert :ok = Accept.handle(user, %Message{command: "ACCEPT", params: ["*"]})
        assert :ok = Accept.handle(user, %Message{command: "ACCEPT", params: ["-Renamed"]})
        assert nil == UserAcceptRemotes.get_by_user_pid_and_identity(user.pid, {"east.example", uid})
      end)

      assert_sent_message_contains(user.pid, ~r/281 Local Renamed/)
      assert_sent_message_contains(user.pid, ~r/288 Local Renamed :Renamed has been removed/)

      Directory.sync(table, renamed, old)
      assert :error = Directory.get_by_identity("east.example", uid)
      assert Directory.all() == []
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

    test "handles ACCEPT command removing non-existent user" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "ACCEPT", params: ["-nonexistent"]}
        assert :ok = Accept.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 401 #{user.nick} nonexistent :No such nick\r\n"}
        ])
      end)
    end

    test "handles ACCEPT command listing accept list with deleted accepted user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user1 = insert(:user, nick: "TestUser1")
        target_user2 = insert(:user, nick: "TestUser2")

        insert(:user_accept, user: user, accepted_user: target_user1)
        insert(:user_accept, user: user, accepted_user: target_user2)

        # Simulate the accepted user being deleted
        Memento.Query.delete(User, target_user1.pid)

        message = %Message{command: "ACCEPT", params: []}
        assert :ok = Accept.handle(user, message)

        # Should only get one accept list entry (for the existing user)
        assert_sent_messages_count_containing(user.pid, ~r/281.*TestUser2/, 1)
        assert_sent_messages_count_containing(user.pid, ~r/282/, 1)
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
