defmodule ElixIRCd.Server.TcpListenerTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.TcpListener
  alias ThousandIsland.Socket

  describe "handle_connection/2" do
    test "initializes connection with TCP transport" do
      socket = tcp_socket()

      expect(Socket, :sockname, fn _socket -> {:ok, {{127, 0, 0, 1}, 12_345}} end)

      expect(Socket, :setopts, fn ^socket, opts ->
        assert opts == [packet: :line, packet_size: 4608]
        :ok
      end)

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

      expect(Socket, :setopts, fn ^socket, opts ->
        assert opts == [packet: :line, packet_size: 4608]
        :ok
      end)

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

      expect(Connection, :handle_receive, fn _pid, data ->
        assert data == "PING :test\r\n"
        :ok
      end)

      assert {:continue, ^state} = TcpListener.handle_data("PING :test\r\n", nil, state)
    end

    test "queues closure after replies and ignores further input when Connection returns quit" do
      state = %{transport: :tcp}

      expect(Connection, :handle_receive, fn _pid, _data ->
        {:quit, "Quit: Goodbye"}
      end)

      assert {:continue, %{transport: :tcp, quit_reason: "Quit: Goodbye"} = closing_state} =
               TcpListener.handle_data("QUIT :Goodbye\r\n", nil, state)

      assert_receive {:disconnect, "Quit: Goodbye"}
      assert {:continue, ^closing_state} = TcpListener.handle_data("PING :late\r\n", nil, closing_state)
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

      assert {:noreply, {^socket, ^state}} =
               TcpListener.handle_info({:broadcast, "MESSAGE"}, {socket, state})
    end

    test "handles disconnect messages" do
      socket = tcp_socket()
      state = %{transport: :tcp}

      assert {:stop, {:shutdown, :local_closed}, {^socket, %{transport: :tcp, quit_reason: "Client quit"}}} =
               TcpListener.handle_info({:disconnect, "Client quit"}, {socket, state})
    end

    test "ignores EXIT messages" do
      socket = tcp_socket()
      state = %{transport: :tcp}

      assert {:noreply, {^socket, ^state}} =
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

  describe "real TCP responses" do
    @describetag capture_log: true

    setup do
      listener = start_supervised!({ThousandIsland, port: 0, handler_module: TcpListener})
      {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
      on_exit(fn -> :gen_tcp.close(socket) end)
      %{socket: socket}
    end

    for labeled? <- [false, true] do
      @tag labeled_response: labeled?
      test "real TCP preserves WHOIS and orderly self KILL with labeled responses #{labeled?}", %{
        socket: socket,
        labeled_response: labeled?
      } do
        :ok = :gen_tcp.send(socket, "CAP LS 302\r\n")
        read_until(socket, &(&1.command == "CAP"))

        if labeled? do
          :ok = :gen_tcp.send(socket, "CAP REQ :batch labeled-response\r\n")
          assert [%Message{command: "CAP", params: [_, "ACK"]}] = read_until(socket, &(&1.command == "CAP"))
        end

        :ok = :gen_tcp.send(socket, "NICK TcpReview\r\nUSER review 0 * :Transport Test\r\nCAP END\r\n")
        read_until(socket, &(&1.command == "376"))

        # A non-negotiated label must have no effect on a legacy client.
        :ok = :gen_tcp.send(socket, "@label=whois WHOIS TcpReview\r\n")

        whois =
          if labeled? do
            socket |> read_until(&batch_end?/1) |> assert_labeled_batch("whois")
          else
            messages = read_until(socket, &(&1.command == "318"))
            assert Enum.all?(messages, &(&1.tags == %{}))
            messages
          end

        assert Enum.any?(whois, &(&1.command == "311"))
        assert List.last(whois).command == "318"

        user =
          Memento.transaction!(fn ->
            {:ok, user} = Users.get_by_nick("TcpReview")
            Users.update(user, %{modes: ["o", "s"]})
          end)

        monitor = Process.monitor(user.pid)
        :ok = :gen_tcp.send(socket, "@label=kill KILL TcpReview :transport test\r\n")
        messages = read_until_closed(socket)

        replies =
          if labeled? do
            assert_labeled_batch(messages, "kill")
          else
            assert Enum.all?(messages, &(&1.tags == %{}))
            messages
          end

        assert Enum.map(replies, & &1.command) == ["ERROR", "NOTICE"]
        assert_receive {:DOWN, ^monitor, :process, _pid, {:shutdown, :local_closed}}, 5_000
        assert {:error, :user_not_found} == Memento.transaction!(fn -> Users.get_by_pid(user.pid) end)
      end
    end

    test "a labeled QUIT sends its ACK before closing the socket", %{socket: socket} do
      :ok = :gen_tcp.send(socket, "CAP LS 302\r\n")
      read_until(socket, &(&1.command == "CAP"))
      :ok = :gen_tcp.send(socket, "CAP REQ :batch labeled-response\r\n")
      read_until(socket, &(&1.command == "CAP"))
      :ok = :gen_tcp.send(socket, "NICK QuitReview\r\nUSER review 0 * :Transport Test\r\nCAP END\r\n")
      read_until(socket, &(&1.command == "376"))

      :ok = :gen_tcp.send(socket, "@label=quit QUIT :done\r\n")
      assert [%Message{command: "ACK", tags: %{"label" => "quit"}}] = read_until_closed(socket)
    end
  end

  @spec read_until(port(), (Message.t() -> boolean()), [Message.t()]) :: [Message.t()]
  defp read_until(socket, predicate, messages \\ []) do
    assert {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
    message = Message.parse!(line)

    if predicate.(message) do
      Enum.reverse([message | messages])
    else
      read_until(socket, predicate, [message | messages])
    end
  end

  @spec read_until_closed(port(), [Message.t()]) :: [Message.t()]
  defp read_until_closed(socket, messages \\ []) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, line} -> read_until_closed(socket, [Message.parse!(line) | messages])
      {:error, :closed} -> Enum.reverse(messages)
      other -> flunk("Expected a complete response followed by socket close, got #{inspect(other)}")
    end
  end

  @spec batch_end?(Message.t()) :: boolean()
  defp batch_end?(%Message{command: "BATCH", params: ["-" <> _ref]}), do: true
  defp batch_end?(_message), do: false

  @spec assert_labeled_batch([Message.t()], String.t()) :: [Message.t()]
  defp assert_labeled_batch([start | rest], label) do
    assert %Message{command: "BATCH", params: ["+" <> ref, "labeled-response"], tags: %{"label" => ^label}} = start
    {contents, [finish]} = Enum.split(rest, -1)
    assert Enum.all?(contents, &(&1.tags == %{"batch" => ref}))
    assert finish.command == "BATCH"
    assert finish.params == ["-" <> ref]
    assert finish.tags == %{}
    contents
  end
end
