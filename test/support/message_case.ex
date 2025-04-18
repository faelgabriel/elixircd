defmodule ElixIRCd.MessageCase do
  @moduledoc """
  This module defines a test case for testing message target interactions.

  It is used to setup the message agent before running tests and to clear it after running tests,
  and to provide assertions for sent messages.
  """

  use ExUnit.CaseTemplate
  use Mimic

  alias ElixIRCd.MessageCase.Assertions
  alias ElixIRCd.Server.Connection

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

            # race condition with the agent not being terminated immediately
            if Process.alive?(agent_pid), do: Process.sleep(50)
          end)
        end

        :ok
      end

      @doc """
      Asserts that a specific number of messages were sent to a target PID.

      This function verifies that exactly `amount` messages were sent to the specified `target` PID.
      After the assertion, it removes the verified messages from the agent state.

      ## Parameters
        * `target` - The PID to check messages for
        * `amount` - The expected number of messages
      """
      @spec assert_sent_messages_amount(pid(), integer()) :: :ok
      def assert_sent_messages_amount(target, amount) do
        Assertions.assert_sent_messages_amount(@agent_name, target, amount)
      end

      @doc """
      Asserts that specific messages were sent to their respective targets.

      This function verifies that the expected messages were sent to their targets.
      By default, it validates both the content and order of the messages.

      ## Parameters
        * `expected_messages` - A list of tuples in the format `{target_pid, message}`
        * `opts` - Options for validation:
          * `:validate_order?` - Boolean that determines if message order should be validated (default: true)
      """
      @spec assert_sent_messages([tuple()], opts :: [validate_order?: boolean()]) :: :ok
      def assert_sent_messages(expected_messages, opts \\ []) do
        Assertions.assert_sent_messages(@agent_name, expected_messages, opts)
      end

      @doc """
      Asserts that at least one message sent to a target contains a specified pattern.

      This function verifies that at least one message sent to the specified `target` PID matches
      the given pattern, which can be either a string or a regex.

      ## Parameters
        * `target` - The PID to check messages for
        * `pattern` - A string or regex pattern to match against messages
      """
      @spec assert_sent_message_contains(pid(), String.t() | Regex.t()) :: :ok
      def assert_sent_message_contains(target, pattern) do
        Assertions.assert_sent_message_contains(@agent_name, target, pattern)
      end
    end
  end
end

defmodule ElixIRCd.MessageCase.Assertions do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias ExUnit.AssertionError

  @doc """
  Asserts that a specific number of messages were sent to a target PID.

  This function verifies that exactly `amount` messages were sent to the specified `target` PID.
  After the assertion, it removes the verified messages from the agent state.

  ## Parameters
    * `agent_name` - The name of the agent storing the messages
    * `target` - The PID to check messages for
    * `amount` - The expected number of messages
  """
  @spec assert_sent_messages_amount(atom(), pid(), integer()) :: :ok
  def assert_sent_messages_amount(agent_name, target, amount) do
    ensure_agent_running!(agent_name)

    sent_messages = Agent.get(agent_name, & &1)
    sent_messages_for_target = Enum.filter(sent_messages, fn {t, _} -> t == target end)

    # Clean up the agent state for the target after each assertion
    Agent.update(agent_name, fn _messages -> sent_messages -- sent_messages_for_target end)

    if length(sent_messages_for_target) != amount do
      raise AssertionError, """
      Assertion failed: Number of expected messages is less than the number of messages sent for target #{inspect(target)}.
      Expected message amount: #{inspect(amount)}
      Actual message amount: #{inspect(length(sent_messages_for_target))}
      """
    end

    :ok
  end

  @doc """
  Asserts that specific messages were sent to their respective targets.

  This function verifies that the expected messages were sent to their targets.
  By default, it validates both the content and order of the messages.
  After the assertion, it clears the agent state.

  ## Parameters
    * `agent_name` - The name of the agent storing the messages
    * `expected_messages` - A list of tuples in the format `{target_pid, message}`
    * `opts` - Options for validation:
      * `:validate_order?` - Boolean that determines if message order should be validated (default: true)
  """
  @spec assert_sent_messages(atom(), [tuple()], opts :: [validate_order?: boolean()]) :: :ok
  def assert_sent_messages(agent_name, expected_messages, opts \\ []) do
    ensure_agent_running!(agent_name)

    validate_order? = Keyword.get(opts, :validate_order?, true)

    sent_messages = Agent.get(agent_name, &Enum.reverse(&1))

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

      validate_messages_content(target, expected_msgs, sent_msgs, validate_order?)
    end

    if length(sent_messages) > length(expected_messages) do
      raise AssertionError, """
      Assertion failed: Number of expected messages is less than the number of messages sent.
      Expected message: #{inspect(expected_messages)}
      Actual message: #{inspect(sent_messages)}
      """
    end

    # Clean up the agent state after each assertion
    Agent.update(agent_name, fn _ -> [] end)

    :ok
  end

  @doc """
  Asserts that at least one message sent to a target contains a specified pattern.

  This function verifies that at least one message sent to the specified `target` PID matches
  the given pattern, which can be either a string or a regex.

  ## Parameters
    * `agent_name` - The name of the agent storing the messages
    * `target` - The PID to check messages for
    * `pattern` - A string or regex pattern to match against messages
  """
  @spec assert_sent_message_contains(atom(), pid(), String.t() | Regex.t()) :: :ok
  def assert_sent_message_contains(agent_name, target, pattern) do
    ensure_agent_running!(agent_name)

    sent_messages = Agent.get(agent_name, &Enum.reverse(&1))

    sent_msgs_for_target =
      Enum.filter(sent_messages, fn {pid, _} -> pid == target end)
      |> Enum.map(fn {_, msg} -> msg end)

    unless Enum.any?(sent_msgs_for_target, fn msg -> message_match?(pattern, msg) end) do
      raise AssertionError, """
      Assertion failed: No message matching pattern was found for target #{inspect(target)}.
      Pattern: #{inspect(pattern)}
      Messages sent to target: #{inspect(sent_msgs_for_target)}
      """
    end

    :ok
  end

  @spec ensure_agent_running!(agent_name :: atom()) :: :ok
  defp ensure_agent_running!(agent_name) do
    agent_pid = Process.whereis(agent_name)

    if not (agent_pid != nil && Process.alive?(agent_pid)) do
      raise RuntimeError,
        message: """
        Message agent is not running. Did you forget to use ElixIRCd.MessageCase?
        """
    end

    :ok
  end

  @spec validate_messages_content(pid(), [tuple()], [tuple()], validate_order? :: boolean()) :: :ok
  defp validate_messages_content(target, expected_msgs, sent_msgs, true = _validate_order) do
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

  defp validate_messages_content(_target, expected_msgs, sent_msgs, false = _validate_order) do
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
