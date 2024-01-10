defmodule ElixIRCd.Data.Types.SocketType do
  @moduledoc """
  Socket type for Ecto.

  This socket is a type for the socket connections.
  """

  @behaviour Ecto.Type
  @type t :: :inet.socket()

  @doc """
  Returns the type.
  """
  @spec type :: atom()
  def type, do: :binary

  @doc """
  Casts the socke.
  """
  @spec cast(:inet.socket()) :: {:ok, :inet.socket()} | :error
  def cast(socket) when is_port(socket) or is_tuple(socket) do
    {:ok, socket}
  end

  def cast(_), do: :error

  @doc """
  Loads the socket.
  """
  @spec load(binary()) :: {:ok, :inet.socket()} | :error
  # sobelow_skip ["Misc.BinToTerm"]
  def load(data) when is_binary(data) do
    {:ok, :erlang.binary_to_term(data)}
  rescue
    ArgumentError ->
      :error
  end

  def load(_), do: :error

  @doc """
  Dumps the socket.
  """
  @spec dump(:inet.socket()) :: {:ok, binary()} | :error
  def dump(socket) when is_port(socket) or is_tuple(socket) do
    {:ok, :erlang.term_to_binary(socket)}
  end

  def dump(_), do: :error

  @doc """
  Embeds the socket.
  """
  @spec embed_as(atom()) :: :self
  def embed_as(_), do: :self

  @doc """
  Compares the sockets.
  """
  @spec equal?(:inet.socket(), :inet.socket()) :: boolean
  def equal?(socket1, socket2) when is_port(socket1) and is_port(socket2) do
    socket1 == socket2
  end

  def equal?(socket1, socket2) when is_tuple(socket1) and is_tuple(socket2) do
    socket1 == socket2
  end

  def equal?(_, _), do: false
end
