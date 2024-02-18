defmodule ElixIRCd.MessageCase do
  @moduledoc """
  This module defines a test case for testing message socket interactions.

  It is used to setup the message agent before running tests and to clear it after running tests,
  and to provide assertions for sent messages.
  """

  use ExUnit.CaseTemplate

  import Mimic

  alias ExUnit.AssertionError

  using do
    quote do
      import ElixIRCd.MessageCase

      setup do
        Agent.start_link(fn -> [] end, name: __MODULE__)

        :ranch_tcp
        |> stub(:send, fn socket, msg ->
          Agent.update(__MODULE__, fn messages -> [{socket, msg} | messages] end)
        end)

        :ranch_ssl
        |> stub(:send, fn socket, msg ->
          Agent.update(__MODULE__, fn messages -> [{socket, msg} | messages] end)
        end)

        :ok
      end

      defp assert_sent_messages(expected_messages) do
        agent_pid = Process.whereis(__MODULE__)

        if not (agent_pid != nil && Process.alive?(agent_pid)) do
          raise RuntimeError,
            message: """
            Message agent is not running. Did you forget to use ElixIRCd.MessageCase?
            """
        end

        sent_messages = Agent.get(__MODULE__, &Enum.reverse(&1))

        grouped_expected_messages =
          Enum.group_by(expected_messages, fn {socket, _} -> socket end, fn {_, msg} -> msg end)

        grouped_sent_messages = Enum.group_by(sent_messages, fn {socket, _} -> socket end, fn {_, msg} -> msg end)

        for {socket, expected_msgs} <- grouped_expected_messages do
          sent_msgs = Map.get(grouped_sent_messages, socket, [])

          if length(expected_msgs) > length(sent_msgs) do
            raise AssertionError, """
            Assertion failed: Number of expected messages exceeds the number of messages sent for socket #{inspect(socket)}.
            Expected message sequence for socket: #{inspect(expected_msgs)}
            Actual message sequence for socket: #{inspect(sent_msgs)}
            """
          end

          if length(sent_msgs) > length(expected_msgs) do
            raise AssertionError, """
            Assertion failed: Number of expected messages is less than the number of messages sent for socket #{inspect(socket)}.
            Expected message sequence for socket: #{inspect(expected_msgs)}
            Actual message sequence for socket: #{inspect(sent_msgs)}
            """
          end

          Enum.zip(expected_msgs, sent_msgs)
          |> Enum.with_index()
          |> Enum.each(fn {{expected_msg, sent_msg}, index} ->
            unless expected_msg == sent_msg do
              raise AssertionError, """
              Assertion failed: Message order or content does not match.
              At position #{index + 1}:
              Expected message: '{#{inspect(socket)}, #{expected_msg}}'
              Sent message: '{#{inspect(socket)}, #{sent_msg}'
              Full expected message sequence for socket: #{inspect(expected_msgs)}
              Full actual message sequence for socket: #{inspect(sent_msgs)}
              """
            end
          end)
        end

        :ok
      end
    end
  end
end
