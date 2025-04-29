defmodule ElixIRCd.MessageCaseTest do
  @moduledoc false

  use ElixIRCd.MessageCase, async: true

  import ExUnit.Assertions

  alias ElixIRCd.Server.Connection

  setup do
    %{target_pid: self()}
  end

  describe "assert_sent_messages_amount/2" do
    test "passes when correct number of messages are sent", %{target_pid: pid} do
      Connection.handle_send(pid, "MESSAGE1")
      Connection.handle_send(pid, "MESSAGE2")

      assert_sent_messages_amount(pid, 2)
    end

    test "fails when incorrect number of messages are sent", %{target_pid: pid} do
      Connection.handle_send(pid, "MESSAGE1")

      assert_raise ExUnit.AssertionError, fn ->
        assert_sent_messages_amount(pid, 2)
      end
    end
  end

  describe "assert_sent_messages/2" do
    test "passes when messages match exactly", %{target_pid: pid} do
      Connection.handle_send(pid, "MESSAGE1")
      Connection.handle_send(pid, "MESSAGE2")

      assert_sent_messages([{pid, "MESSAGE1"}, {pid, "MESSAGE2"}])
    end

    test "fails when message content doesn't match", %{target_pid: pid} do
      Connection.handle_send(pid, "MESSAGE1")
      Connection.handle_send(pid, "DIFFERENT")

      assert_raise ExUnit.AssertionError, fn ->
        assert_sent_messages([{pid, "MESSAGE1"}, {pid, "MESSAGE2"}])
      end
    end

    test "fails when message order doesn't match with validate_order true", %{target_pid: pid} do
      Connection.handle_send(pid, "MESSAGE2")
      Connection.handle_send(pid, "MESSAGE1")

      assert_raise ExUnit.AssertionError, fn ->
        assert_sent_messages([{pid, "MESSAGE1"}, {pid, "MESSAGE2"}], validate_order?: true)
      end
    end

    test "passes with validate_order false when content matches but order differs", %{target_pid: pid} do
      Connection.handle_send(pid, "MESSAGE2")
      Connection.handle_send(pid, "MESSAGE1")

      assert_sent_messages([{pid, "MESSAGE1"}, {pid, "MESSAGE2"}], validate_order?: false)
    end

    test "fails when expected messages exceeds sent messages", %{target_pid: pid} do
      Connection.handle_send(pid, "MESSAGE1")

      assert_raise ExUnit.AssertionError,
                   ~r/Number of expected messages exceeds the number of messages sent for target/,
                   fn ->
                     assert_sent_messages([{pid, "MESSAGE1"}, {pid, "MESSAGE2"}, {pid, "MESSAGE3"}])
                   end
    end

    test "fails when expected messages count is less than sent messages for a target", %{target_pid: pid} do
      Connection.handle_send(pid, "MESSAGE1")
      Connection.handle_send(pid, "MESSAGE2")
      Connection.handle_send(pid, "MESSAGE3")

      assert_raise ExUnit.AssertionError,
                   ~r/Number of expected messages is less than the number of messages sent for target/,
                   fn ->
                     assert_sent_messages([{pid, "MESSAGE1"}])
                   end
    end

    test "fails when total expected messages is less than total sent messages" do
      target1 =
        spawn(fn ->
          receive do
            _ -> nil
          end
        end)

      target2 =
        spawn(fn ->
          receive do
            _ -> nil
          end
        end)

      Connection.handle_send(target1, "MESSAGE1")
      Connection.handle_send(target2, "MESSAGE2")
      Connection.handle_send(target1, "MESSAGE3")

      assert_raise ExUnit.AssertionError,
                   ~r/Number of expected messages is less than the number of messages sent/,
                   fn ->
                     assert_sent_messages([{target1, "MESSAGE1"}])
                   end
    end

    test "fails with detailed message when total expected messages count is less", %{target_pid: pid} do
      Connection.handle_send(pid, "MESSAGE1")
      Connection.handle_send(pid, "MESSAGE2")
      Connection.handle_send(pid, "MESSAGE3")

      expected = [{pid, "MESSAGE1"}, {pid, "MESSAGE2"}]

      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_sent_messages(expected)
        end

      assert error.message =~ "Assertion failed: Number of expected messages is less than the number of messages sent"
      assert error.message =~ "Expected message sequence for target: [\"MESSAGE1\", \"MESSAGE2\"]"
      assert error.message =~ "Actual message sequence for target: [\"MESSAGE1\", \"MESSAGE2\", \"MESSAGE3\"]"
    end

    test "fails when message content doesn't match using validate_order false", %{target_pid: pid} do
      Connection.handle_send(pid, "ACTUAL1")
      Connection.handle_send(pid, "ACTUAL2")

      assert_raise ExUnit.AssertionError, ~r/Message content does not match/, fn ->
        assert_sent_messages([{pid, "EXPECTED1"}, {pid, "EXPECTED2"}], validate_order?: false)
      end
    end
  end

  describe "assert_sent_message_contains/2" do
    test "passes when message contains string pattern", %{target_pid: pid} do
      Connection.handle_send(pid, "Hello world!")

      assert_sent_message_contains(pid, ~r/world/)
    end

    test "passes when message matches regex pattern", %{target_pid: pid} do
      Connection.handle_send(pid, "User123 joined")

      assert_sent_message_contains(pid, ~r/User\d+ joined/)
    end

    test "fails when no message contains the pattern", %{target_pid: pid} do
      Connection.handle_send(pid, "Hello world!")

      assert_raise ExUnit.AssertionError, fn ->
        assert_sent_message_contains(pid, "goodbye")
      end
    end

    @tag :skip_message_agent
    test "raises an error if the agent is not running", %{target_pid: pid} do
      assert_raise RuntimeError, fn ->
        assert_sent_message_contains(pid, "Hello!")
      end
    end
  end
end
