defmodule ElixIRCd.Client do
  @moduledoc """
  This module defines the client helper functions for testing.
  """

  @doc """
  Starts a client connection.
  """
  @spec connect(:tcp | :ssl) :: {:ok, :inet.socket()} | {:error, any()}
  def connect(:tcp), do: :gen_tcp.connect(~c"127.0.0.1", 6667, [:binary, :inet, active: false])
  def connect(:ssl), do: :ssl.connect(~c"127.0.0.1", 6697, [:binary, :inet, active: false, verify: :verify_none])

  @doc """
  Sends a message to the server.
  """
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
