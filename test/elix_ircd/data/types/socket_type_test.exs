defmodule ElixIRCd.Data.Types.SocketTypeTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Data.Types.SocketType

  alias ElixIRCd.Client
  alias ElixIRCd.Data.Types.SocketType

  setup do
    tcp_socket = Client.connect(:tcp)
    ssl_socket = Client.connect(:ssl)

    {:ok,
     %{
       tcp_socket: tcp_socket,
       ssl_socket: ssl_socket,
       binary_tcp_socket: :erlang.term_to_binary(tcp_socket),
       binary_ssl_socket: :erlang.term_to_binary(ssl_socket)
     }}
  end

  describe "type/0" do
    test "returns :binary" do
      assert SocketType.type() == :binary
    end
  end

  describe "cast/1" do
    test "casts a valid socket", %{tcp_socket: tcp_socket, ssl_socket: ssl_socket} do
      assert {:ok, ^tcp_socket} = SocketType.cast(tcp_socket)
      assert {:ok, ^ssl_socket} = SocketType.cast(ssl_socket)
    end

    test "returns :error for invalid input" do
      invalid_input = "not_a_socket"
      assert :error == SocketType.cast(invalid_input)
    end
  end

  describe "load/1" do
    test "loads a valid socket", %{
      tcp_socket: tcp_socket,
      ssl_socket: ssl_socket,
      binary_tcp_socket: binary_tcp_socket,
      binary_ssl_socket: binary_ssl_socket
    } do
      assert {:ok, ^tcp_socket} = SocketType.load(binary_tcp_socket)
      assert {:ok, ^ssl_socket} = SocketType.load(binary_ssl_socket)
    end

    test "returns :error for invalid input" do
      invalid_input = "not_a_valid_binary_term"
      assert :error == SocketType.load(invalid_input)

      invalid_input = :not_a_binary
      assert :error == SocketType.load(invalid_input)
    end
  end

  describe "dump/1" do
    test "dumps a valid socket", %{
      tcp_socket: tcp_socket,
      ssl_socket: ssl_socket,
      binary_tcp_socket: binary_tcp_socket,
      binary_ssl_socket: binary_ssl_socket
    } do
      assert {:ok, ^binary_tcp_socket} = SocketType.dump(tcp_socket)
      assert {:ok, ^binary_ssl_socket} = SocketType.dump(ssl_socket)
    end

    test "returns :error for invalid input" do
      invalid_input = "not_a_socket"
      assert :error == SocketType.dump(invalid_input)
    end
  end

  describe "embed_as/1" do
    test "always returns :self" do
      assert :self == SocketType.embed_as(:json)
      assert :self == SocketType.embed_as(:atom)
    end
  end

  describe "equal?/2" do
    test "returns true for equal sockets", %{tcp_socket: tcp_socket, ssl_socket: ssl_socket} do
      assert SocketType.equal?(tcp_socket, tcp_socket)
      assert SocketType.equal?(ssl_socket, ssl_socket)
    end

    test "returns false for non-equal sockets", %{tcp_socket: tcp_socket, ssl_socket: ssl_socket} do
      another_tcp_socket = Client.connect(:tcp)
      another_ssl_socket = Client.connect(:ssl)
      refute SocketType.equal?(tcp_socket, another_tcp_socket)
      refute SocketType.equal?(ssl_socket, another_ssl_socket)
      refute SocketType.equal?(tcp_socket, ssl_socket)
    end
  end
end
