defmodule ElixIRCd.ServerTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory
  import ExUnit.CaptureLog
  import Mimic
  import WaitForIt

  alias ElixIRCd.Client
  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Metrics
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  describe "init/1 by client connection" do
    setup :set_mimic_global
    setup :verify_on_exit!

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

      assert [%User{} = user] = wait_for_records(User, 1)
      assert user.modes == []
    end

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

      assert [%User{} = user] = wait_for_records(User, 1)
      assert user.modes == ["Z"]
    end

    test "handles ranch handshake error on tcp connect" do
      :ranch
      |> expect(:handshake, 1, fn _ref -> :error end)

      :ranch_tcp
      |> reject(:setopts, 2)

      assert {:ok, socket} = Client.connect(:tcp)
      assert {:error, :closed} == Client.recv(socket)

      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    @tag capture_log: true
    test "handles ranch handshake error on ssl connect" do
      :ranch
      |> expect(:handshake, 1, fn _ref -> :error end)

      :ranch_ssl
      |> reject(:setopts, 2)

      # ssl socket is not returned if the handshake erroed
      assert {:error, :closed} = Client.connect(:ssl)

      assert [] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    test "handles valid tcp packet" do
      Command
      |> expect(:dispatch, 1, fn _user, message ->
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      {:ok, socket} = Client.connect(:tcp)
      Client.send(socket, "COMMAND test\r\n")
      assert {:error, :timeout} = Client.recv(socket)

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    test "handles valid ssl packet" do
      Command
      |> expect(:dispatch, 1, fn _user, message ->
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      {:ok, socket} = Client.connect(:ssl)
      Client.send(socket, "COMMAND test\r\n")
      assert {:error, :timeout} = Client.recv(socket)

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    test "handles invalid tcp packet" do
      Command
      |> reject(:dispatch, 2)

      {:ok, socket} = Client.connect(:tcp)
      Client.send(socket, "\r\n")
      Client.send(socket, " \r\n")
      Client.send(socket, " \r\n")
      assert {:error, :timeout} = Client.recv(socket)

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    test "handles invalid ssl packet" do
      Command
      |> reject(:dispatch, 2)

      {:ok, socket} = Client.connect(:ssl)
      Client.send(socket, "\r\n")
      Client.send(socket, " \r\n")
      Client.send(socket, " \r\n")
      assert {:error, :timeout} = Client.recv(socket)

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)
    end

    test "handles successful tcp disconnect by tcp close" do
      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      [user] = wait_for_records(User, 1)
      insert(:user_channel, %{user: user})

      Client.disconnect(socket)
      assert {:error, :closed} == Client.recv(socket)

      assert [] = wait_for_records(User, 0)
      assert [] = wait_for_records(UserChannel, 0)
    end

    test "handles successful ssl disconnect by ssl close" do
      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      [user] = wait_for_records(User, 1)
      insert(:user_channel, %{user: user})

      Client.disconnect(socket)
      assert {:error, :closed} == Client.recv(socket)

      assert [] = wait_for_records(User, 0)
      assert [] = wait_for_records(UserChannel, 0)
    end

    test "handles successful tcp disconnect by tcp error" do
      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      [user] = wait_for_records(User, 1)
      insert(:user_channel, %{user: user})

      log =
        capture_log(fn ->
          send(user.pid, {:tcp_error, user.socket, :any_error})

          assert [] = wait_for_records(User, 0)
          assert [] = wait_for_records(UserChannel, 0)
        end)

      assert log =~ "Connection error [tcp_error]: :any_error"
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful ssl disconnect by ssl error" do
      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      [user] = wait_for_records(User, 1)
      insert(:user_channel, %{user: user})

      log =
        capture_log(fn ->
          send(user.pid, {:ssl_error, user.socket, :any_error})

          assert [] = wait_for_records(User, 0)
          assert [] = wait_for_records(UserChannel, 0)
        end)

      assert log =~ "Connection error [ssl_error]: :any_error"
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful disconnect by disconnect process message" do
      {:ok, socket} = Client.connect(:ssl)
      [user] = wait_for_records(User, 1)
      insert(:user_channel, %{user: user})

      send(user.pid, {:disconnect, user.socket, "Disconnect message"})

      assert [] = wait_for_records(User, 0)
      assert [] = wait_for_records(UserChannel, 0)

      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful tcp disconnect by unexpected error rescued" do
      Command
      |> expect(:dispatch, 1, fn _user, _message ->
        raise "An error has occurred"
      end)

      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      [user] = wait_for_records(User, 1)
      insert(:user_channel, %{user: user})

      log =
        capture_log(fn ->
          Client.send(socket, "COMMAND test\r\n")

          assert [] = wait_for_records(User, 0)
          assert [] = wait_for_records(UserChannel, 0)
        end)

      assert log =~ "Error handling connection: %RuntimeError{message: \"An error has occurred\"}"
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful ssl disconnect by unexpected error rescued" do
      Command
      |> expect(:dispatch, 1, fn _user, _message ->
        raise "An error has occurred"
      end)

      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      [user] = wait_for_records(User, 1)
      insert(:user_channel, %{user: user})

      log =
        capture_log(fn ->
          Client.send(socket, "COMMAND test\r\n")

          assert [] = wait_for_records(User, 0)
          assert [] = wait_for_records(UserChannel, 0)
        end)

      assert log =~ "Error handling connection: %RuntimeError{message: \"An error has occurred\"}"
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful disconnect by connection timeout" do
      original_config = Application.get_env(:elixircd, :user)
      Application.put_env(:elixircd, :user, original_config |> Keyword.put(:timeout, 150))
      on_exit(fn -> Application.put_env(:elixircd, :user, original_config) end)

      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      [user] = wait_for_records(User, 1)
      insert(:user_channel, %{user: user})

      # waits for the connection to timeout
      :timer.sleep(150)

      assert [] = wait_for_records(User, 0)
      assert [] = wait_for_records(UserChannel, 0)

      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful disconnect by command quit result" do
      Command
      |> expect(:dispatch, 1, fn _user, _message ->
        {:quit, "Bye!"}
      end)

      {:ok, socket} = Client.connect(:tcp)
      [%User{}] = wait_for_records(User, 1)

      Client.send(socket, "COMMAND test\r\n")

      assert [] = wait_for_records(User, 0)
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful quit process with user alone in a channel" do
      {:ok, socket} = Client.connect(:ssl)
      [user] = wait_for_records(User, 1)

      user =
        Memento.transaction!(fn ->
          Memento.Query.write(%User{
            user
            | registered: true,
              nick: "nick1",
              hostname: "hostname1",
              ident: "ident1",
              realname: "realname1"
          })
        end)

      channel = insert(:channel)
      insert(:user_channel, %{user: user, channel: channel})

      Client.send(socket, "QUIT :Quit message\r\n")

      assert {:error, :closed} = Client.recv(socket)
      # Channel should be deleted
      assert [] = wait_for_records(Channel, 0)
    end

    test "handles successful quit process with user in a channel with another user" do
      {:ok, socket_tcp} = Client.connect(:tcp)
      {:ok, socket_ssl} = Client.connect(:ssl)

      users = wait_for_records(User, 2)
      user_tcp = Enum.find(users, &(&1.transport == :ranch_tcp))
      user_ssl = Enum.find(users, &(&1.transport == :ranch_ssl))

      user_tcp =
        Memento.transaction!(fn ->
          Memento.Query.write(%User{
            user_tcp
            | registered: true,
              nick: "nick1",
              hostname: "hostname1",
              ident: "ident1",
              realname: "realname1"
          })
        end)

      user_ssl =
        Memento.transaction!(fn ->
          Memento.Query.write(%User{
            user_ssl
            | registered: true,
              nick: "nick2",
              hostname: "hostname2",
              ident: "ident2",
              realname: "realname2"
          })
        end)

      channel = insert(:channel)
      insert(:user_channel, %{user: user_tcp, channel: channel})
      insert(:user_channel, %{user: user_ssl, channel: channel})

      Client.send(socket_tcp, "QUIT :Quit message\r\n")

      assert {:error, :closed} = Client.recv(socket_tcp)
      assert {:ok, ":nick1!ident1@hostname1 QUIT :Quit message\r\n"} = Client.recv(socket_ssl)

      # Channel should not be deleted
      assert [_channel] = wait_for_records(Channel, 1)
    end

    test "handles user not found error on disconnect" do
      {:ok, socket} = Client.connect(:ssl)
      [user] = wait_for_records(User, 1)

      Memento.transaction!(fn -> Users.delete(user) end)

      log =
        capture_log(fn ->
          Client.disconnect(socket)
          assert {:error, :closed} == Client.recv(socket)
          # waits for the disconnect process to log the error
          :timer.sleep(50)
        end)

      assert log =~ "Error handling disconnect: :user_not_found"
    end

    test "updates connection stats on new connections successfully" do
      {:ok, socket1} = Client.connect(:tcp)
      {:ok, socket2} = Client.connect(:tcp)
      wait_for_records(User, 2)

      Client.disconnect(socket1)
      Client.disconnect(socket2)

      # waits for the two connections to be closed; highest connections should be 2
      wait_for_records(User, 0)

      # connects a new client; total connections should be 3
      {:ok, _socket3} = Client.connect(:tcp)
      wait_for_records(User, 1)

      assert Metrics.get(:highest_connections) == 2
      assert Metrics.get(:total_connections) == 3
    end
  end

  @spec wait_for_records(struct(), pos_integer()) :: [struct()]
  defp wait_for_records(table, count) when is_integer(count) do
    Memento.transaction!(fn -> Memento.Query.all(table) end)
    |> case_wait(frequency: 100, timeout: 2000) do
      expected_items when length(expected_items) == count -> expected_items
    else
      result -> raise "Expected #{count} items from table #{inspect(table)}, but got #{inspect(length(result))}"
    end
  end
end
