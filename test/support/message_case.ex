defmodule ElixIRCd.MessageCase do
  @moduledoc """
  This module defines a test case for testing message socket interactions.

  It is used to setup the message agent before running tests and to clear it after running tests,
  and to provide assertions for sent messages.

  Use this with async: false since agent is global.
  """

  use ExUnit.CaseTemplate

  alias ExUnit.AssertionError

  import Mimic

  using do
    quote do
      import ElixIRCd.MessageCase
    end
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> [] end, name: __MODULE__)

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

  @doc """
  Asserts that the given messages were sent.
  """
  @spec assert_sent_messages([{:inet.socket(), String.t()}]) :: :ok
  def assert_sent_messages(expected_messages) do
    sent_messages = Agent.get(__MODULE__, & &1)

    for {expected_socket, expected_msg} <- expected_messages do
      unless Enum.any?(sent_messages, fn {socket, msg} -> socket == expected_socket and msg == expected_msg end) do
        raise AssertionError, """
        Assertion failed: expected message not sent.
        Expected to send: #{inspect(sort_messages(expected_messages))}
        Actual messages sent: #{inspect(sort_messages(sent_messages))}
        """
      end
    end

    :ok
  end

  @spec sort_messages([{:inet.socket(), String.t()}]) :: [{:inet.socket(), String.t()}]
  defp sort_messages(messages) do
    Enum.sort(messages, fn
      {port1, msg1}, {port2, msg2} ->
        if port1 == port2 do
          msg1 < msg2
        else
          port1 < port2
        end
    end)
  end
end
