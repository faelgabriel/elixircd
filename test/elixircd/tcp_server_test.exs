defmodule ElixIRCd.Server.TcpListenerTest do
  @moduledoc false

  use ExUnit.Case, async: false
  use Mimic

  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.TcpListener
  alias ThousandIsland.Socket

  describe "handle_connection/2" do
    test "initializes connection with TCP transport" do
      socket = tcp_socket()

      expect(Socket, :sockname, fn _socket -> {:ok, {{127, 0, 0, 1}, 12_345}} end)
      expect(Socket, :setopts, fn _socket, _opts -> :ok end)

      expect(Connection, :handle_connect, fn _pid, transport, data ->
        assert transport == :tcp
        assert data == %{ip_address: {127, 0, 0, 1}, port_connected: 12_345}
        :ok
      end)

      assert {:continue, %{transport: :tcp}, {:persistent, _timeout}} =
               TcpListener.handle_connection(socket, %{})
    end

    test "initializes connection with TLS transport" do
      socket = tls_socket()

      expect(Socket, :sockname, fn _socket -> {:ok, {{127, 0, 0, 1}, 12_345}} end)
      expect(Socket, :setopts, fn _socket, _opts -> :ok end)

      expect(Connection, :handle_connect, fn _pid, transport, data ->
        assert transport == :tls
        assert data == %{ip_address: {127, 0, 0, 1}, port_connected: 12_345}
        :ok
      end)

      assert {:continue, %{transport: :tls}, {:persistent, _timeout}} =
               TcpListener.handle_connection(socket, %{})
    end

    test "closes connection when Connection returns :close" do
      socket = tcp_socket()

      expect(Socket, :sockname, fn _socket -> {:ok, {{127, 0, 0, 1}, 12_345}} end)

      expect(Connection, :handle_connect, fn _pid, transport, data ->
        assert transport == :tcp
        assert data == %{ip_address: {127, 0, 0, 1}, port_connected: 12_345}
        :close
      end)

      assert {:close, %{transport: :tcp}} =
               TcpListener.handle_connection(socket, %{})
    end
  end

  describe "handle_data/3" do
    test "processes data and continues when Connection returns :ok" do
      state = %{transport: :tcp}

      expect(Connection, :handle_recv, fn _pid, data ->
        assert data == "PING :test\r\n"
        :ok
      end)

      assert {:continue, ^state} = TcpListener.handle_data("PING :test\r\n", nil, state)
    end

    test "closes connection when Connection returns quit reason" do
      state = %{transport: :tcp}

      expect(Connection, :handle_recv, fn _pid, _data ->
        {:quit, "Quit: Goodbye"}
      end)

      assert {:close, %{transport: :tcp, quit_reason: "Quit: Goodbye"}} =
               TcpListener.handle_data("QUIT :Goodbye\r\n", nil, state)
    end
  end

  describe "handle_info/2" do
    test "handles broadcast messages" do
      socket = tcp_socket()
      state = %{transport: :tcp}

      expect(Socket, :send, fn socket_arg, message ->
        assert socket_arg == socket
        assert message == "MESSAGE"
        :ok
      end)

      assert {:noreply, {^socket, ^state}, 5000} =
               TcpListener.handle_info({:broadcast, "MESSAGE"}, {socket, state})
    end

    test "handles disconnect messages" do
      socket = tcp_socket()
      state = %{transport: :tcp}

      assert {:close, {^socket, %{transport: :tcp, quit_reason: "Client quit"}}} =
               TcpListener.handle_info({:disconnect, "Client quit"}, {socket, state})
    end

    test "ignores EXIT messages" do
      socket = tcp_socket()
      state = %{transport: :tcp}

      assert {:noreply, {^socket, ^state}, 5000} =
               TcpListener.handle_info({:EXIT, self(), :normal}, {socket, state})
    end
  end

  describe "error and disconnection handlers" do
    test "handle_error calls Connection.handle_disconnect" do
      state = %{transport: :tcp}

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :tcp
        assert reason == "Connection Error"
        :ok
      end)

      TcpListener.handle_error(:econnreset, nil, state)
    end

    test "handle_timeout calls Connection.handle_disconnect" do
      state = %{transport: :tcp}

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :tcp
        assert reason == "Connection Timeout"
        :ok
      end)

      TcpListener.handle_timeout(nil, state)
    end

    test "handle_shutdown calls Connection.handle_disconnect" do
      state = %{transport: :tcp}

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :tcp
        assert reason == "Server Shutdown"
        :ok
      end)

      TcpListener.handle_shutdown(nil, state)
    end

    test "handle_close calls Connection.handle_disconnect with quit_reason" do
      state = %{transport: :tcp, quit_reason: "User quit"}

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :tcp
        assert reason == "User quit"
        :ok
      end)

      TcpListener.handle_close(nil, state)
    end

    test "handle_close uses default reason when quit_reason is nil" do
      state = %{transport: :tcp, quit_reason: nil}

      expect(Connection, :handle_disconnect, fn _pid, transport, reason ->
        assert transport == :tcp
        assert reason == "Connection Closed"
        :ok
      end)

      TcpListener.handle_close(nil, state)
    end
  end

  @spec tcp_socket() :: Socket.t()
  defp tcp_socket do
    %Socket{
      socket: nil,
      transport_module: ThousandIsland.Transports.TCP,
      read_timeout: 5000,
      silent_terminate_on_error: false,
      span: nil
    }
  end

  @spec tls_socket() :: Socket.t()
  defp tls_socket do
    %Socket{
      socket: nil,
      transport_module: ThousandIsland.Transports.SSL,
      read_timeout: 5000,
      silent_terminate_on_error: false,
      span: nil
    }
  end
end
