defmodule ElixIRCd.Server.DispatcherTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ElixIRCd.Factory
  import Mimic

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher

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
      Connection
      |> expect(:handle_send, fn pid, raw_message ->
        assert pid == user.pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Connection
      |> expect(:handle_send, fn pid, raw_message ->
        assert pid == user_channel.user_pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Connection
      |> reject(:handle_send, 2)

      assert :ok == Dispatcher.broadcast(message, user)
      assert :ok == Dispatcher.broadcast(message, user_channel)
    end

    test "broadcasts a single message to multiple users or user_channels", %{
      user: user,
      user_channel: user_channel,
      message: message
    } do
      Connection
      |> expect(:handle_send, fn pid, raw_message ->
        assert pid == user.pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Connection
      |> expect(:handle_send, fn pid, raw_message ->
        assert pid == user_channel.user_pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Connection
      |> reject(:handle_send, 2)

      assert :ok == Dispatcher.broadcast(message, [user, user_channel])
    end

    test "broadcasts multiple messages to a single user or user_channel", %{
      user: user,
      user_channel: user_channel,
      message: message
    } do
      Connection
      |> expect(:handle_send, 2, fn pid, raw_message ->
        assert pid == user.pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Connection
      |> expect(:handle_send, 2, fn pid, raw_message ->
        assert pid == user_channel.user_pid
        assert raw_message == ":server.example.com PING target\r\n"
        :ok
      end)

      Connection
      |> reject(:handle_send, 2)

      assert :ok == Dispatcher.broadcast([message, message], user)
      assert :ok == Dispatcher.broadcast([message, message], user_channel)
    end

    test "broadcasts multiple messages to multiple users or user_channels", %{
      user: user,
      user_channel: user_channel,
      message: message
    } do
      for _ <- 1..2 do
        Connection
        |> expect(:handle_send, fn pid, raw_message ->
          assert pid == user.pid
          assert raw_message == ":server.example.com PING target\r\n"
          :ok
        end)

        Connection
        |> expect(:handle_send, fn pid, raw_message ->
          assert pid == user_channel.user_pid
          assert raw_message == ":server.example.com PING target\r\n"
          :ok
        end)
      end

      Connection
      |> reject(:handle_send, 2)

      assert :ok == Dispatcher.broadcast([message, message], [user, user_channel])
    end
  end
end
