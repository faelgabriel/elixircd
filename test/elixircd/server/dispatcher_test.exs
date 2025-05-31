defmodule ElixIRCd.Server.DispatcherTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.Dispatcher

  describe "broadcast/2" do
    setup do
      user = insert(:user)
      user_channel = insert(:user_channel)
      pid = self()
      message = Message.build(%{prefix: :server, command: "PING", params: ["target"]})
      raw_message = ":irc.test PING target\r\n"

      {:ok,
       %{
         user: user,
         user_channel: user_channel,
         pid: pid,
         message: message,
         raw_message: raw_message
       }}
    end

    test "broadcasts a single message to a single target", %{
      user: user,
      user_channel: user_channel,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      test_cases = [
        {message, user, user.pid},
        {message, user_channel, user_channel.user_pid},
        {message, pid, pid}
      ]

      for {msg, target, expected_pid} <- test_cases do
        setup_expectations([{expected_pid, raw_message}])
        assert :ok == Dispatcher.broadcast(msg, target)
      end

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts a single message to multiple targets", %{
      user: user,
      user_channel: user_channel,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      setup_expectations([
        {user.pid, raw_message},
        {user_channel.user_pid, raw_message},
        {pid, raw_message}
      ])

      assert :ok == Dispatcher.broadcast(message, [user, user_channel, pid])

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts multiple messages to a single target", %{
      user: user,
      user_channel: user_channel,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      test_cases = [
        {user, user.pid},
        {user_channel, user_channel.user_pid},
        {pid, pid}
      ]

      for {target, expected_pid} <- test_cases do
        Connection
        |> expect(:handle_send, 2, fn pid, received_message ->
          assert pid === expected_pid
          assert received_message == raw_message
          :ok
        end)

        assert :ok == Dispatcher.broadcast([message, message], target)
      end

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts multiple messages to multiple targets", %{
      user: user,
      user_channel: user_channel,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      for _ <- 1..2 do
        setup_expectations([
          {user.pid, raw_message},
          {user_channel.user_pid, raw_message},
          {pid, raw_message}
        ])
      end

      assert :ok == Dispatcher.broadcast([message, message], [user, user_channel, pid])

      Connection
      |> reject(:handle_send, 2)
    end
  end

  @spec setup_expectations(list({pid(), String.t()})) :: :ok
  defp setup_expectations(expectations) do
    for {expected_pid, expected_message} <- expectations do
      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === expected_pid
        assert received_message == expected_message
        :ok
      end)
    end
  end
end
