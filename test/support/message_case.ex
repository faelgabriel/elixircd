defmodule ElixIRCd.MessageCase do
  @moduledoc """
  This module defines a test case for testing message target interactions.

  It is used to setup the message agent before running tests and to clear it after running tests,
  and to provide assertions for sent messages.
  """

  use ExUnit.CaseTemplate

  import Mimic

  alias ElixIRCd.Server.Connection
  alias ExUnit.AssertionError

  using do
    quote do
      import ElixIRCd.MessageCase

      @agent_name Module.concat(__MODULE__, "MessageCase")

      setup context do
        if Map.get(context, :skip_message_agent, false) == false do
          {:ok, agent_pid} = Agent.start_link(fn -> [] end, name: @agent_name)

          Connection
          |> stub(:handle_send, fn pid, msg ->
            Agent.update(@agent_name, fn messages -> [{pid, msg} | messages] end)
          end)

          on_exit(fn ->
            Process.exit(agent_pid, :kill)
          end)
        end

        :ok
      end

      @spec assert_sent_messages_amount(pid(), integer()) :: :ok
      defp assert_sent_messages_amount(target, amount) do
        sent_messages = Agent.get(@agent_name, & &1)
        sent_messages_for_target = Enum.filter(sent_messages, fn {t, _} -> t == target end)

        # Clean up the agent state for the target after each assertion
        Agent.update(@agent_name, fn _messages -> sent_messages -- sent_messages_for_target end)

        assert length(sent_messages_for_target) == amount
      end

      @spec assert_sent_messages([tuple()], opts :: [validate_order?: boolean()]) :: :ok
      defp assert_sent_messages(expected_messages, opts \\ []) do
        validate_order? = Keyword.get(opts, :validate_order?, true)
        agent_pid = Process.whereis(@agent_name)

        if not (agent_pid != nil && Process.alive?(agent_pid)) do
          raise RuntimeError,
            message: """
            Message agent is not running. Did you forget to use ElixIRCd.MessageCase?
            """
        end

        sent_messages = Agent.get(@agent_name, &Enum.reverse(&1))

        grouped_expected_messages =
          Enum.group_by(expected_messages, fn {target, _} -> target end, fn {_, msg} -> msg end)

        grouped_sent_messages = Enum.group_by(sent_messages, fn {target, _} -> target end, fn {_, msg} -> msg end)

        for {target, expected_msgs} <- grouped_expected_messages do
          sent_msgs = Map.get(grouped_sent_messages, target, [])

          if length(expected_msgs) > length(sent_msgs) do
            raise AssertionError, """
            Assertion failed: Number of expected messages exceeds the number of messages sent for target #{inspect(target)}.
            Expected message sequence for target: #{inspect(expected_msgs)}
            Actual message sequence for target: #{inspect(sent_msgs)}
            """
          end

          if length(sent_msgs) > length(expected_msgs) do
            raise AssertionError, """
            Assertion failed: Number of expected messages is less than the number of messages sent for target #{inspect(target)}.
            Expected message sequence for target: #{inspect(expected_msgs)}
            Actual message sequence for target: #{inspect(sent_msgs)}
            """
          end

          assert_messages_content(target, expected_msgs, sent_msgs, validate_order?)
        end

        if length(sent_messages) > length(expected_messages) do
          raise AssertionError, """
          Assertion failed: Number of expected messages is less than the number of messages sent.
          Expected message: #{inspect(expected_messages)}
          Actual message: #{inspect(sent_messages)}
          """
        end

        # Clean up the agent state after each assertion
        Agent.update(@agent_name, fn _ -> [] end)

        :ok
      end

      @spec assert_messages_content(pid(), [tuple()], [tuple()], validate_order? :: boolean()) :: :ok
      defp assert_messages_content(target, expected_msgs, sent_msgs, true = _validate_order) do
        Enum.zip(expected_msgs, sent_msgs)
        |> Enum.with_index()
        |> Enum.each(fn {{expected_msg, sent_msg}, index} ->
          unless message_match?(expected_msg, sent_msg) do
            raise AssertionError, """
            Assertion failed: Message order or content does not match.
            At position #{index + 1}:
            Expected message: '{#{inspect(target)}, #{inspect(expected_msg)}}'
            Sent message: '{#{inspect(target)}, #{inspect(sent_msg)}'
            Full expected message sequence for target: #{inspect(expected_msgs)}
            Full actual message sequence for target: #{inspect(sent_msgs)}
            """
          end
        end)
      end

      defp assert_messages_content(_target, expected_msgs, sent_msgs, false = _validate_order) do
        ordered_expected_msgs = Enum.sort(expected_msgs)
        ordered_sent_msgs = Enum.sort(sent_msgs)

        Enum.zip(ordered_expected_msgs, ordered_sent_msgs)
        |> Enum.each(fn {expected_msg, sent_msg} ->
          unless message_match?(expected_msg, sent_msg) do
            raise AssertionError, """
            Assertion failed: Message content does not match.
            Expected message sequence for target: #{inspect(expected_msgs)}
            Actual message sequence for target: #{inspect(sent_msgs)}
            """
          end
        end)
      end

      @spec message_match?(String.t() | Regex.t(), String.t()) :: boolean()
      defp message_match?(expected_msg, sent_msg) when is_binary(expected_msg), do: expected_msg == sent_msg
      defp message_match?(%Regex{} = expected_msg, sent_msg), do: Regex.match?(expected_msg, sent_msg)
    end
  end
end
