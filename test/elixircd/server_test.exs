defmodule ElixIRCd.ServerTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory
  import ExUnit.CaptureLog
  import Mimic

  alias ElixIRCd.Client
  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  describe "init/1 by client connection" do
    setup :set_mimic_global
    setup :verify_on_exit!

    @tag capture_log: true
    test "handles successful tcp connect" do
      :ranch_tcp
      |> expect(:setopts, 1, fn _socket, opts ->
        assert opts == [{:packet, :line}]
        :ok
      end)

      :ranch_tcp
      |> expect(:setopts, 1, fn _socket, opts ->
        assert opts == [{:active, :once}]
        :ok
      end)

      assert {:ok, socket} = Client.connect(:tcp)
      assert {:error, :timeout} == Client.recv(socket)

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles successful ssl connect" do
      :ranch_ssl
      |> expect(:setopts, 1, fn _socket, opts ->
        assert opts == [{:packet, :line}]
        :ok
      end)

      :ranch_ssl
      |> expect(:setopts, 1, fn _socket, opts ->
        assert opts == [{:active, :once}]
        :ok
      end)

      assert {:ok, socket} = Client.connect(:ssl)
      assert {:error, :timeout} == Client.recv(socket)

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles ranch handshake error on tcp connect" do
      :ranch
      |> expect(:handshake, 1, fn _ref -> :error end)

      :ranch_tcp
      |> reject(:setopts, 2)

      log =
        capture_log(fn ->
          assert {:ok, socket} = Client.connect(:tcp)
          assert {:error, :closed} == Client.recv(socket)
        end)

      assert log =~ "Error initializing connection: :error"

      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles ranch handshake error on ssl connect" do
      :ranch
      |> expect(:handshake, 1, fn _ref -> :error end)

      :ranch_ssl
      |> reject(:setopts, 2)

      log =
        capture_log(fn ->
          # ssl socket is not returned if the handshake erroed
          assert {:error, :closed} = Client.connect(:ssl)
        end)

      assert log =~ "Error initializing connection: :error"

      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles valid tcp packet" do
      Command
      |> expect(:handle, 1, fn _user, message ->
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      {:ok, socket} = Client.connect(:tcp)
      Client.send(socket, "COMMAND test\r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles valid ssl packet" do
      Command
      |> expect(:handle, 1, fn _user, message ->
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      {:ok, socket} = Client.connect(:ssl)
      Client.send(socket, "COMMAND test\r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles invalid tcp packet" do
      Command
      |> reject(:handle, 2)

      {:ok, socket} = Client.connect(:tcp)
      Client.send(socket, "\r\n")
      Client.send(socket, " \r\n")
      Client.send(socket, " \r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles invalid ssl packet" do
      Command
      |> reject(:handle, 2)

      {:ok, socket} = Client.connect(:ssl)
      Client.send(socket, "\r\n")
      Client.send(socket, " \r\n")
      Client.send(socket, " \r\n")
      assert {:error, :timeout} = Client.recv(socket), "The connection did not remain open"

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles successful tcp disconnect by tcp close" do
      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      {:error, :timeout} = Client.recv(socket)

      assert [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      assert [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      send(user.pid, {:tcp_closed, user.socket})
      :timer.sleep(100)

      assert {:error, :closed} == Client.recv(socket)

      assert [] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)
      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles successful ssl disconnect by ssl close" do
      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      assert [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      assert [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      send(user.pid, {:ssl_closed, user.socket})
      :timer.sleep(100)

      assert {:error, :closed} == Client.recv(socket)

      assert [] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)
      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles successful tcp disconnect by tcp error" do
      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      {:error, :timeout} = Client.recv(socket)
      assert [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      assert [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      log =
        capture_log(fn ->
          send(user.pid, {:tcp_error, user.socket, :any_error})
          :timer.sleep(100)
        end)

      assert log =~ "TCP connection error: :any_error"
      assert {:error, :closed} == Client.recv(socket)

      assert [] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)
      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles successful ssl disconnect by ssl error" do
      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      assert [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      assert [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      log =
        capture_log(fn ->
          send(user.pid, {:ssl_error, user.socket, :any_error})
          :timer.sleep(100)
        end)

      assert log =~ "SSL connection error: :any_error"
      assert {:error, :closed} == Client.recv(socket)

      assert [] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)
      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles successful tcp disconnect by unexpected error rescued" do
      Command
      |> expect(:handle, 1, fn _user, _message ->
        raise "An error has occurred"
      end)

      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      {:error, :timeout} = Client.recv(socket)
      assert [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      assert [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      log =
        capture_log(fn ->
          Client.send(socket, "COMMAND test\r\n")
          :timer.sleep(100)
        end)

      assert log =~ "Error handling connection: %RuntimeError{message: \"An error has occurred\"}"
      assert {:error, :closed} == Client.recv(socket)

      assert [] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)
      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles successful ssl disconnect by unexpected error rescued" do
      Command
      |> expect(:handle, 1, fn _user, _message ->
        raise "An error has occurred"
      end)

      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      assert [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      assert [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      log =
        capture_log(fn ->
          Client.send(socket, "COMMAND test\r\n")
          :timer.sleep(100)
        end)

      assert {:error, :closed} == Client.recv(socket)
      assert log =~ "Error handling connection: %RuntimeError{message: \"An error has occurred\"}"

      assert [] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)
      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles successful disconnect by connection timeout" do
      original_timeout = Application.get_env(:elixircd, :client_timeout)
      Application.put_env(:elixircd, :client_timeout, 220)

      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      assert [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      assert [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      :timer.sleep(200)

      assert {:error, :closed} == Client.recv(socket)

      assert [] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)
      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      Application.put_env(:elixircd, :client_timeout, original_timeout)
    end

    @tag capture_log: true
    test "handles successful disconnect by user quit" do
      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      assert [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      assert [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      send(user.pid, {:user_quit, user.socket, "Quit message"})
      :timer.sleep(100)

      assert {:error, :closed} == Client.recv(socket)

      assert [] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)
      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles successful quit notification" do
      {:ok, socket1} = Client.connect(:ssl)
      {:ok, socket2} = Client.connect(:ssl)
      :timer.sleep(100)

      [user1, user2] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      user1 = Memento.transaction!(fn -> Users.update(user1, %{identity: "any@identity"}) end)

      channel = insert(:channel)
      insert(:user_channel, %{user: user1, channel: channel})
      insert(:user_channel, %{user: user2, channel: channel})

      send(user1.pid, {:user_quit, user1.socket, "Quit message"})

      received = Enum.sort([Client.recv(socket1), Client.recv(socket2)])
      assert received == [{:error, :closed}, {:ok, ":any@identity QUIT :Quit message\r\n"}]
    end

    @tag capture_log: true
    test "handles user not found error on disconnect" do
      Client.connect(:ssl)
      :timer.sleep(100)

      [user] = Memento.transaction!(fn -> Memento.Query.all(User) end)
      Memento.transaction!(fn -> Users.delete(user) end)

      log =
        capture_log(fn ->
          send(user.pid, {:ssl_closed, user.socket})
          :timer.sleep(100)
        end)

      assert log =~ "Error handling disconnect: \"User port not found: #{inspect(user.port)}\""
    end

    # test "handling multiple connections" do
    #   max_connections = 15
    #   allowed_time = 5_000

    #   start_time = :erlang.monotonic_time(:millisecond)

    #   tasks =
    #     1..max_connections
    #     |> Enum.map(fn i ->
    #       Task.async(fn ->
    #         assert {:ok, socket} = Client.connect(:tcp)
    #         IO.puts("Connected #{i}")
    #         # create random nick
    #         nick =
    #           Client.send(socket, "NICK test#{i}\r\n")

    #         Client.send(socket, "USER test#{i} 0 * :Test#{i} User\r\n")
    #         Client.recv(socket) == ""
    #         Client.recv(socket)
    #         Client.disconnect(socket)
    #         IO.puts("Disconnected #{i}")
    #       end)
    #     end)

    #   Enum.each(tasks, fn task ->
    #     Task.await(task, 60_000)
    #   end)

    #   :timer.sleep(8_000)

    #   end_time = :erlang.monotonic_time(:millisecond)
    #   duration = end_time - start_time

    #   assert duration <= allowed_time, "The operations took longer than allowed. Duration: #{duration}ms"
    # end
  end
end
