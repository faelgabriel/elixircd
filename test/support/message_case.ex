defmodule ElixIRCd.MessageCase do
  @moduledoc """
  This module defines a test case for testing message target interactions.

  It is used to setup the message agent before running tests and to clear it after running tests,
  and to provide assertions for sent messages.
  """

  use ExUnit.CaseTemplate

  alias ElixIRCd.MessageCase.Assertions
  alias ElixIRCd.Server.Connection

  using do
    quote do
      import ElixIRCd.MessageCase

      @agent_name Module.concat(__MODULE__, "MessageCase")

      setup context do
        if Map.get(context, :skip_message_agent, false) == false do
          {:ok, agent_pid} = Agent.start_link(fn -> [] end, name: @agent_name)

          Mimic.stub(Connection, :handle_send, fn pid, msg ->
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

      # Asserts that a specific number of messages were sent to a target PID.
      @spec assert_sent_messages_amount(pid(), integer()) :: :ok
      defp assert_sent_messages_amount(target, amount) do
        Assertions.assert_sent_messages_amount(@agent_name, target, amount)
      end

      # Asserts that specific messages were sent to their respective targets.
      @spec assert_sent_messages([tuple()], opts :: [validate_order?: boolean()]) :: :ok
      defp assert_sent_messages(expected_messages, opts \\ []) do
        Assertions.assert_sent_messages(@agent_name, expected_messages, opts)
      end

      # Asserts that at least one message sent to a target contains a specified pattern.
      @spec assert_sent_message_contains(pid(), String.t() | Regex.t()) :: :ok
      defp assert_sent_message_contains(target, pattern) do
        Assertions.assert_sent_message_contains(@agent_name, target, pattern)
      end

      # Asserts that a specific number of messages sent to a target contain a specified pattern.
      @spec assert_sent_messages_count_containing(pid(), String.t() | Regex.t(), integer()) :: :ok
      defp assert_sent_messages_count_containing(target, pattern, expected_count) do
        Assertions.assert_sent_messages_count_containing(@agent_name, target, pattern, expected_count)
      end
    end
  end
end

defmodule ElixIRCd.MessageCase.Assertions do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias ExUnit.AssertionError

  @doc false
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

  @doc false
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
        Expected message sequence for target: #{inspect(expected_msgs, binaries: :as_strings, limit: :infinity)}
        Actual message sequence for target: #{inspect(sent_msgs, binaries: :as_strings, limit: :infinity)}
        """
      end

      if length(sent_msgs) > length(expected_msgs) do
        raise AssertionError, """
        Assertion failed: Number of expected messages is less than the number of messages sent for target #{inspect(target)}.
        Expected message sequence for target: #{inspect(expected_msgs, binaries: :as_strings, limit: :infinity)}
        Actual message sequence for target: #{inspect(sent_msgs, binaries: :as_strings, limit: :infinity)}
        """
      end

      validate_messages_content(target, expected_msgs, sent_msgs, validate_order?)
    end

    # Clean up the agent state after each assertion
    Agent.update(agent_name, fn _ -> [] end)

    :ok
  end

  @doc false
  @spec assert_sent_message_contains(atom(), pid(), String.t() | Regex.t()) :: :ok
  def assert_sent_message_contains(agent_name, target, pattern) do
    ensure_agent_running!(agent_name)

    sent_messages = Agent.get(agent_name, &Enum.reverse(&1))

    sent_msgs_for_target =
      Enum.filter(sent_messages, fn {pid, _} -> pid == target end)
      |> Enum.map(fn {_, msg} -> msg end)

    if !Enum.any?(sent_msgs_for_target, fn msg -> message_match?(pattern, msg) end) do
      raise AssertionError, """
      Assertion failed: No message matching pattern was found for target #{inspect(target)}.
      Pattern: #{inspect(pattern)}
      Messages sent to target: #{inspect(sent_msgs_for_target, binaries: :as_strings, limit: :infinity)}
      """
    end

    :ok
  end

  @doc false
  @spec assert_sent_messages_count_containing(atom(), pid(), String.t() | Regex.t(), integer()) :: :ok
  def assert_sent_messages_count_containing(agent_name, target, pattern, expected_count) do
    ensure_agent_running!(agent_name)

    sent_messages = Agent.get(agent_name, &Enum.reverse(&1))

    sent_msgs_for_target =
      Enum.filter(sent_messages, fn {pid, _} -> pid == target end)
      |> Enum.map(fn {_, msg} -> msg end)

    matching_messages = Enum.filter(sent_msgs_for_target, fn msg -> message_match?(pattern, msg) end)
    actual_count = length(matching_messages)

    if actual_count != expected_count do
      raise AssertionError, """
      Assertion failed: Expected #{expected_count} messages matching pattern, but found #{actual_count} for target #{inspect(target)}.
      Pattern: #{inspect(pattern)}
      Matching messages: #{inspect(matching_messages, binaries: :as_strings, limit: :infinity)}
      All messages sent to target: #{inspect(sent_msgs_for_target, binaries: :as_strings, limit: :infinity)}
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
      if !message_match?(expected_msg, sent_msg) do
        raise AssertionError, """
        Assertion failed: Message order or content does not match.
        At position #{index + 1}:
        Expected message: '{#{inspect(target)}, #{inspect(expected_msg, binaries: :as_strings, limit: :infinity)}}'
        Sent message: '{#{inspect(target)}, #{inspect(sent_msg, binaries: :as_strings, limit: :infinity)}}'
        Full expected message sequence for target: #{inspect(expected_msgs, binaries: :as_strings, limit: :infinity)}
        Full actual message sequence for target: #{inspect(sent_msgs, binaries: :as_strings, limit: :infinity)}
        """
      end
    end)
  end

  defp validate_messages_content(_target, expected_msgs, sent_msgs, false = _validate_order) do
    ordered_expected_msgs = Enum.sort(expected_msgs)
    ordered_sent_msgs = Enum.sort(sent_msgs)

    Enum.zip(ordered_expected_msgs, ordered_sent_msgs)
    |> Enum.each(fn {expected_msg, sent_msg} ->
      if !message_match?(expected_msg, sent_msg) do
        raise AssertionError, """
        Assertion failed: Message content does not match.
        Expected message sequence for target: #{inspect(expected_msgs, binaries: :as_strings, limit: :infinity)}
        Actual message sequence for target: #{inspect(sent_msgs, binaries: :as_strings, limit: :infinity)}
        """
      end
    end)
  end

  @spec message_match?(String.t() | Regex.t(), String.t()) :: boolean()
  defp message_match?(expected_msg, sent_msg) when is_binary(expected_msg), do: expected_msg == sent_msg
  defp message_match?(%Regex{} = expected_msg, sent_msg), do: Regex.match?(expected_msg, sent_msg)
end
