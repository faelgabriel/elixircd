defmodule ElixIRCd.Command.TopicTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Topic
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles TOPIC command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "TOPIC", params: ["#anything"]}

        Topic.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles TOPIC command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "TOPIC", params: []}

        Topic.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} TOPIC :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles TOPIC command with without topic message" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        message = %Message{command: "TOPIC", params: [channel.name]}

        Topic.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles TOPIC command with with topic message" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        message = %Message{command: "TOPIC", params: [channel.name], trailing: "Topic text!"}

        Topic.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
