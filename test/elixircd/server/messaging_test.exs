defmodule ElixIRCd.Server.MessagingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ElixIRCd.Factory
  import Mimic

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging

  describe "broadcast/2" do
    setup :verify_on_exit!

    setup do
      user = insert(:user)
      user_channel = insert(:user_channel)
      message = Message.build(%{prefix: :server, command: "PING", params: ["target"]})

      {:ok, %{user: user, user_channel: user_channel, message: message}}
    end

    test "broadcasts a single message to a single user or user_channel", %{
      user: user,
      user_channel: user_channel,
      message: message
    } do
      Messaging
      |> expect(:send_message, fn pid, raw_message ->
        assert pid == user.pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Messaging
      |> expect(:send_message, fn pid, raw_message ->
        assert pid == user_channel.user_pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Messaging
      |> reject(:send_message, 2)

      assert :ok == Messaging.broadcast(message, user)
      assert :ok == Messaging.broadcast(message, user_channel)
    end

    test "broadcasts a single message to multiple users or user_channels", %{
      user: user,
      user_channel: user_channel,
      message: message
    } do
      Messaging
      |> expect(:send_message, fn pid, raw_message ->
        assert pid == user.pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Messaging
      |> expect(:send_message, fn pid, raw_message ->
        assert pid == user_channel.user_pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Messaging
      |> reject(:send_message, 2)

      assert :ok == Messaging.broadcast(message, [user, user_channel])
    end

    test "broadcasts multiple messages to a single user or user_channel", %{
      user: user,
      user_channel: user_channel,
      message: message
    } do
      Messaging
      |> expect(:send_message, 2, fn pid, raw_message ->
        assert pid == user.pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Messaging
      |> expect(:send_message, 2, fn pid, raw_message ->
        assert pid == user_channel.user_pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Messaging
      |> reject(:send_message, 2)

      assert :ok == Messaging.broadcast([message, message], user)
      assert :ok == Messaging.broadcast([message, message], user_channel)
    end

    test "broadcasts multiple messages to multiple users or user_channels", %{
      user: user,
      user_channel: user_channel,
      message: message
    } do
      for _ <- 1..2 do
        Messaging
        |> expect(:send_message, fn pid, raw_message ->
          assert pid == user.pid
          assert raw_message == ":server.example.com PING target\r\n"
          :ok
        end)

        Messaging
        |> expect(:send_message, fn pid, raw_message ->
          assert pid == user_channel.user_pid
          assert raw_message == ":server.example.com PING target\r\n"
          :ok
        end)
      end

      Messaging
      |> reject(:send_message, 2)

      assert :ok == Messaging.broadcast([message, message], [user, user_channel])
    end

    test "broadcasts message to user connected through WS or WSS transports", %{
      message: message
    } do
      user = insert(:user, %{pid: self(), transport: :ws})
      user_channel = insert(:user_channel, %{user: user})

      assert :ok == Messaging.broadcast(message, user)
      assert_receive {:broadcast, ":server.example.com PING target\r\n"}, 1000

      assert :ok == Messaging.broadcast(message, user_channel)
      assert_receive {:broadcast, ":server.example.com PING target\r\n"}, 1000
    end
  end
end
