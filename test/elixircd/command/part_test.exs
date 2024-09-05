defmodule ElixIRCd.Command.PartTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [get_user_mask: 1]

  alias ElixIRCd.Command.Part
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Tables.Channel

  describe "handle/2" do
    test "handles PART command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "PART", params: ["#anything"]}

        assert :ok = Part.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles PART command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "PART", params: []}

        assert :ok = Part.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} PART :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles PART command with non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "PART", params: ["#new_channel"]}

        assert :ok = Part.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 403 #{user.nick} #new_channel :No such channel\r\n"}
        ])
      end)
    end

    test "handles PART command with existing channel and user is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        message = %Message{command: "PART", params: [channel.name]}

        assert :ok = Part.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 442 #{user.nick} #{channel.name} :You're not on that channel\r\n"}
        ])
      end)
    end

    test "handles PART command with existing channel and user is alone in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, user: user, channel: channel)
        message = %Message{command: "PART", params: [channel.name]}

        assert :ok = Part.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{get_user_mask(user)} PART #{channel.name}\r\n"}
        ])

        # Channel should be deleted
        assert {:error, :channel_not_found} = Channels.get_by_name(channel.name)
      end)
    end

    test "handles PART command with existing channel and user is in the channel with another user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)
        message = %Message{command: "PART", params: [channel.name]}

        assert :ok = Part.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{get_user_mask(user)} PART #{channel.name}\r\n"},
          {another_user.socket, ":#{get_user_mask(user)} PART #{channel.name}\r\n"}
        ])

        # Channel should not be deleted
        assert {:ok, %Channel{}} = Channels.get_by_name(channel.name)
      end)
    end
  end
end
