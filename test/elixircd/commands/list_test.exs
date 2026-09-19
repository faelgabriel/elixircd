defmodule ElixIRCd.Commands.ListTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.List
  alias ElixIRCd.Message
  alias ElixIRCd.Tables.RegisteredChannel.Settings

  describe "handle/2" do
    test "handles LIST command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "LIST", params: ["#anything"]}

        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
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
          {user.pid, ":irc.test 322 #{user.nick} #{channel1.name} 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":irc.test 322 #{user.nick} #{channel2.name} 0 :#{channel2.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
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
          {user.pid, ":irc.test 322 #{user.nick} #anything1 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
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
          {user.pid, ":irc.test 322 #{user.nick} #anything1 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":irc.test 322 #{user.nick} #anything2 0 :#{channel2.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
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
          {user.pid, ":irc.test 322 #{user.nick} #{channel1.name} 1 :#{channel1.topic.text}\r\n"},
          {user.pid, ":irc.test 322 #{user.nick} #{channel2.name} 2 :#{channel2.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with channels created more than the requested minutes ago" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:channel, name: "#anything1", created_at: DateTime.add(DateTime.utc_now(), -10, :minute))
        channel2 = insert(:channel, name: "#anything2", created_at: DateTime.add(DateTime.utc_now(), -20, :minute))

        message = %Message{command: "LIST", params: ["C>15"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 322 #{user.nick} #{channel2.name} 0 :#{channel2.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with channels created less than the requested minutes ago" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#anything1", created_at: DateTime.add(DateTime.utc_now(), -10, :minute))
        insert(:channel, name: "#anything2", created_at: DateTime.add(DateTime.utc_now(), -20, :minute))

        message = %Message{command: "LIST", params: ["C<15"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 322 #{user.nick} #{channel1.name} 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
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
          {user.pid, ":irc.test 322 #{user.nick} #{channel2.name} 0 :#{channel2.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
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
          {user.pid, ":irc.test 322 #{user.nick} #{channel1.name} 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
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
          {user.pid, ":irc.test 322 #{user.nick} #{channel1.name} 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles channel-prefixed wildcard filters and topics that are not set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#chan2", topic: nil)
        insert(:channel, name: "#other")

        assert :ok = List.handle(user, %Message{command: "LIST", params: ["#c*n2"]})

        assert_sent_messages([
          {user.pid, ":irc.test 322 #{user.nick} #{channel.name} 0 :No topic is set\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
        ])

        assert :ok = List.handle(user, %Message{command: "LIST", params: ["T>1"]})
        assert_sent_messages([{user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}])
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
          {user.pid, ":irc.test 322 #{user.nick} #{channel1.name} 0 :#{channel1.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with invalid filter value type" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "LIST", params: ["T<AA"]}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with private and secret channels and user not in any channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:channel, name: "#anything1", modes: [:p])
        insert(:channel, name: "#anything2", modes: [:s])

        message = %Message{command: "LIST", params: []}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "handles LIST command with private and secret channels and user is in the channels" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#anything1", modes: [:p])
        channel2 = insert(:channel, name: "#anything2", modes: [:s])
        insert(:user_channel, user: user, channel: channel1)
        insert(:user_channel, user: user, channel: channel2)

        message = %Message{command: "LIST", params: []}
        assert :ok = List.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 322 #{user.nick} #{channel1.name} 1 :#{channel1.topic.text}\r\n"},
          {user.pid, ":irc.test 322 #{user.nick} #{channel2.name} 1 :#{channel2.topic.text}\r\n"},
          {user.pid, ":irc.test 323 #{user.nick} :End of LIST\r\n"}
        ])
      end)
    end

    test "hides registered private channels from outsiders but shows them to the founder" do
      Memento.transaction!(fn ->
        visitor = insert(:user, nick: "visitor")
        founder = insert(:user, nick: "founder", identified_as: "founder")
        private_channel = insert(:channel, name: "#registered-private")
        public_channel = insert(:channel, name: "#registered-public")

        insert(:registered_channel,
          name: private_channel.name,
          founder: founder.identified_as,
          settings: Settings.new(%{private: true})
        )

        insert(:registered_channel, name: public_channel.name, founder: founder.identified_as)

        assert :ok = List.handle(visitor, %Message{command: "LIST", params: []})

        assert_sent_messages([
          {visitor.pid, ":irc.test 322 #{visitor.nick} #{public_channel.name} 0 :#{public_channel.topic.text}\r\n"},
          {visitor.pid, ":irc.test 323 #{visitor.nick} :End of LIST\r\n"}
        ])

        assert :ok = List.handle(founder, %Message{command: "LIST", params: []})

        assert_sent_messages([
          {founder.pid, ":irc.test 322 #{founder.nick} #{private_channel.name} 0 :#{private_channel.topic.text}\r\n"},
          {founder.pid, ":irc.test 322 #{founder.nick} #{public_channel.name} 0 :#{public_channel.topic.text}\r\n"},
          {founder.pid, ":irc.test 323 #{founder.nick} :End of LIST\r\n"}
        ])
      end)
    end
  end
end
