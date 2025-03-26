defmodule ElixIRCd.Command.ListTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.List
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles LIST command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "LIST", params: ["#anything"]}

        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles LIST command without search filters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#anything1")
        channel2 = insert(:channel, name: "#anything2")

        message = %Message{command: "LIST", params: []}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #{channel1.name} 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":server.example.com 322 #{user.nick} #{channel2.name} 0 :#{channel2.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with exact name filter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#anything1")
        insert(:channel, name: "#anything2")

        message = %Message{command: "LIST", params: ["#anything1,*any*"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #anything1 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with multiples exact name filters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#anything1")
        channel2 = insert(:channel, name: "#anything2")

        message = %Message{command: "LIST", params: ["#anything1,#anything2"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #anything1 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":server.example.com 322 #{user.nick} #anything2 0 :#{channel2.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with users count greater and less filters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#anything1")
        channel2 = insert(:channel, name: "#anything2")
        channel3 = insert(:channel, name: "#anything3")
        insert(:channel, name: "#anything4")
        insert(:user_channel, channel: channel1)
        insert(:user_channel, channel: channel2)
        insert(:user_channel, channel: channel2)
        insert(:user_channel, channel: channel3)
        insert(:user_channel, channel: channel3)
        insert(:user_channel, channel: channel3)

        message = %Message{command: "LIST", params: [">0,<3"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #{channel1.name} 1 :#{channel1.topic.text}\r\n"},
          {user.pid, ":server.example.com 322 #{user.nick} #{channel2.name} 2 :#{channel2.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with created at after filter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#anything1", created_at: DateTime.add(DateTime.utc_now(), -10, :minute))
        insert(:channel, name: "#anything2", created_at: DateTime.add(DateTime.utc_now(), -20, :minute))

        message = %Message{command: "LIST", params: ["C>15"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #{channel1.name} 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with created at before filter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:channel, name: "#anything1", created_at: DateTime.add(DateTime.utc_now(), -10, :minute))
        channel2 = insert(:channel, name: "#anything2", created_at: DateTime.add(DateTime.utc_now(), -20, :minute))

        message = %Message{command: "LIST", params: ["C<15"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #{channel2.name} 0 :#{channel2.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with topic older filter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        topic1 = build(:channel_topic, set_at: DateTime.add(DateTime.utc_now(), -10, :minute))
        insert(:channel, name: "#anything1", topic: topic1)
        topic2 = build(:channel_topic, set_at: DateTime.add(DateTime.utc_now(), -20, :minute))
        channel2 = insert(:channel, name: "#anything2", topic: topic2)

        message = %Message{command: "LIST", params: ["T>15"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #{channel2.name} 0 :#{channel2.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with topic newer filter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        topic1 = build(:channel_topic, set_at: DateTime.add(DateTime.utc_now(), -10, :minute))
        channel1 = insert(:channel, name: "#anything1", topic: topic1)
        topic2 = build(:channel_topic, set_at: DateTime.add(DateTime.utc_now(), -20, :minute))
        insert(:channel, name: "#anything2", topic: topic2)

        message = %Message{command: "LIST", params: ["T<15"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #{channel1.name} 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with name match and not match filters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#anything1")
        insert(:channel, name: "#anything2")

        message = %Message{command: "LIST", params: ["*any*,!*ing2*"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #{channel1.name} 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command without specific character filter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#anything1")
        insert(:channel, name: "#anything2")

        message = %Message{command: "LIST", params: ["anything1"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #{channel1.name} 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with invalid filter value type" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "LIST", params: ["T<AA"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with private and secret channels and user not in any channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:channel, name: "#anything1", modes: ["p"])
        insert(:channel, name: "#anything2", modes: ["s"])

        message = %Message{command: "LIST", params: []}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with private and secret channels and user is in the channels" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#anything1", modes: ["p"])
        channel2 = insert(:channel, name: "#anything2", modes: ["s"])
        insert(:user_channel, user: user, channel: channel1)
        insert(:user_channel, user: user, channel: channel2)

        message = %Message{command: "LIST", params: []}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 322 #{user.nick} #{channel1.name} 1 :#{channel1.topic.text}\r\n"},
          {user.pid, ":server.example.com 322 #{user.nick} #{channel2.name} 1 :#{channel2.topic.text}\r\n"},
          {user.pid, ":server.example.com 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end
  end
end
