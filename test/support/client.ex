defmodule ElixIRCd.Client do
  @moduledoc """
  This module defines the base command for IRC client tests.
  """

  use ExUnit.CaseTemplate

  @doc """
  Starts a client connection for the TCP or SSL server protocol.
  """
  @spec connect(:tcp | :ssl) :: :inet.socket()
  def connect(:tcp) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", 6667, [:binary, :inet, active: false])
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  def connect(:ssl) do
    {:ok, socket} = :ssl.connect(~c"127.0.0.1", 6697, [:binary, :inet, active: false, verify: :verify_none])
    on_exit(fn -> :ssl.close(socket) end)
    socket
  end

  @doc """
  Closes a client connectio.
  """
  @spec close(:inet.socket()) :: :ok
  def close(socket) when is_port(socket), do: :gen_tcp.close(socket)
  def close(socket), do: :ssl.close(socket)

  @doc """
  Receives a message from the server.
  """
  @spec recv(:inet.socket(), pos_integer()) :: {:ok, binary()} | {:error, :closed} | {:error, :timeout}
  def recv(socket, timeout \\ 100)
  def recv(socket, timeout) when is_port(socket), do: :gen_tcp.recv(socket, 0, timeout)
  def recv(socket, timeout), do: :ssl.recv(socket, 0, timeout)
end
