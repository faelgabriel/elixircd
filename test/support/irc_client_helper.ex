Code.require_file("../test_helper.exs", __DIR__)

defmodule ElixIRCd.IrcClientHelper do
  @moduledoc """
  This module provides a simple IRC client helper for testings.
  """
  use ExUnit.Case

  @doc """
  Sets up an IRC connection for testing.
  """
  @spec setup() :: {:ok, map()}
  def setup do
    {:ok, socket} = connect()

    on_exit(fn ->
      disconnect(socket)
    end)

    {:ok, %{socket: socket}}
  end

  @spec connect() :: {:ok, port()} | :error
  defp connect do
    case :gen_tcp.connect(~c"127.0.0.1", 6667, [:binary, active: false]) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, _} ->
        :error
    end
  end

  @spec disconnect(port()) :: :ok
  defp disconnect(socket) do
    :gen_tcp.close(socket)
    :ok
  end
end
