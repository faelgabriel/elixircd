defmodule ElixIRCd.Client do
  @moduledoc """
  This module defines the client helper functions for testing.
  """

  use ExUnit.CaseTemplate

  @doc """
  Starts a client connection.
  """
  @spec connect(:tcp | :ssl) :: {:ok, :inet.socket()} | {:error, any()}
  def connect(:tcp) do
    socket_result = :gen_tcp.connect(~c"127.0.0.1", 6667, [:binary, :inet, active: false])

    case socket_result do
      {:ok, socket} -> on_exit(fn -> :gen_tcp.close(socket) end)
    end

    socket_result
  end

  def connect(:ssl) do
    socket_result = :ssl.connect(~c"127.0.0.1", 6697, [:binary, :inet, active: false, verify: :verify_none])

    case socket_result do
      {:ok, socket} -> on_exit(fn -> :ssl.close(socket) end)
      _ -> nil
    end

    socket_result
  end

  @doc """
  Closes a client connection.
  """
  @spec close(:inet.socket()) :: :ok
  def close(socket) when is_port(socket), do: :gen_tcp.close(socket)
  def close(socket), do: :ssl.close(socket)

  @spec send(:inet.socket(), binary()) :: :ok
  def send(socket, data) when is_port(socket), do: :gen_tcp.send(socket, data)
  def send(socket, data), do: :ssl.send(socket, data)

  @doc """
  Receives a message from the server.
  """
  @spec recv(:inet.socket(), pos_integer()) :: {:ok, binary()} | {:error, :closed} | {:error, :timeout}
  def recv(socket, timeout \\ 100)
  def recv(socket, timeout) when is_port(socket), do: :gen_tcp.recv(socket, 0, timeout)
  def recv(socket, timeout), do: :ssl.recv(socket, 0, timeout)
end
