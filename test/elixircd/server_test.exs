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
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @wait_keywords [frequency: 10, timeout: 200]

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

      assert [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)
      assert user.modes == []

      Client.disconnect(socket)
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

      assert [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)
      assert user.modes == ["Z"]

      Client.disconnect(socket)
    end

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

    test "handles valid tcp packet" do
      Command
      |> expect(:handle, 1, fn _user, message ->
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      {:ok, socket} = Client.connect(:tcp)
      Client.send(socket, "COMMAND test\r\n")
      assert {:error, :timeout} = Client.recv(socket)

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      Client.disconnect(socket)
    end

    test "handles valid ssl packet" do
      Command
      |> expect(:handle, 1, fn _user, message ->
        assert message == %Message{command: "COMMAND", params: ["test"]}
        :ok
      end)

      {:ok, socket} = Client.connect(:ssl)
      Client.send(socket, "COMMAND test\r\n")
      assert {:error, :timeout} = Client.recv(socket)

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      Client.disconnect(socket)
    end

    test "handles invalid tcp packet" do
      Command
      |> reject(:handle, 2)

      {:ok, socket} = Client.connect(:tcp)
      Client.send(socket, "\r\n")
      Client.send(socket, " \r\n")
      Client.send(socket, " \r\n")
      assert {:error, :timeout} = Client.recv(socket)

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      Client.disconnect(socket)
    end

    test "handles invalid ssl packet" do
      Command
      |> reject(:handle, 2)

      {:ok, socket} = Client.connect(:ssl)
      Client.send(socket, "\r\n")
      Client.send(socket, " \r\n")
      Client.send(socket, " \r\n")
      assert {:error, :timeout} = Client.recv(socket)

      assert [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      Client.disconnect(socket)
    end

    test "handles successful tcp disconnect by tcp close" do
      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      {:error, :timeout} = Client.recv(socket)
      [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      Client.disconnect(socket)
      assert {:error, :closed} == Client.recv(socket)

      assert wait([] == Memento.transaction!(fn -> Memento.Query.all(UserChannel) end), @wait_keywords)
      assert wait([] == Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords)
    end

    test "handles successful ssl disconnect by ssl close" do
      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      Client.disconnect(socket)
      assert {:error, :closed} == Client.recv(socket)

      assert wait([] == Memento.transaction!(fn -> Memento.Query.all(UserChannel) end), @wait_keywords)
      assert wait([] == Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords)
    end

    test "handles successful tcp disconnect by tcp error" do
      :ranch_tcp
      |> expect(:close, 1, fn socket ->
        :ranch_tcp.close(socket)
      end)

      {:ok, socket} = Client.connect(:tcp)
      {:error, :timeout} = Client.recv(socket)
      [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      log =
        capture_log(fn ->
          send(user.pid, {:tcp_error, user.socket, :any_error})

          assert wait([] == Memento.transaction!(fn -> Memento.Query.all(UserChannel) end), @wait_keywords)
          assert wait([] == Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords)
        end)

      assert log =~ "TCP connection error: :any_error"
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful ssl disconnect by ssl error" do
      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      log =
        capture_log(fn ->
          send(user.pid, {:ssl_error, user.socket, :any_error})

          assert wait([] == Memento.transaction!(fn -> Memento.Query.all(UserChannel) end), @wait_keywords)
          assert wait([] == Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords)
        end)

      assert log =~ "SSL connection error: :any_error"
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful disconnect by disconnect process message" do
      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      send(user.pid, {:disconnect, user.socket, "Disconnect message"})

      assert wait([] == Memento.transaction!(fn -> Memento.Query.all(UserChannel) end), @wait_keywords)
      assert wait([] == Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords)

      assert {:error, :closed} == Client.recv(socket)
    end

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
      [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      log =
        capture_log(fn ->
          Client.send(socket, "COMMAND test\r\n")

          assert wait([] == Memento.transaction!(fn -> Memento.Query.all(UserChannel) end), @wait_keywords)
          assert wait([] == Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords)
        end)

      assert log =~ "Error handling connection: %RuntimeError{message: \"An error has occurred\"}"
      assert {:error, :closed} == Client.recv(socket)
    end

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
      [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      log =
        capture_log(fn ->
          Client.send(socket, "COMMAND test\r\n")

          assert wait([] == Memento.transaction!(fn -> Memento.Query.all(UserChannel) end), @wait_keywords)
          assert wait([] == Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords)
        end)

      assert log =~ "Error handling connection: %RuntimeError{message: \"An error has occurred\"}"
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful disconnect by connection timeout" do
      original_config = Application.get_env(:elixircd, :user)
      Application.put_env(:elixircd, :user, original_config |> Keyword.put(:timeout, 220))
      on_exit(fn -> Application.put_env(:elixircd, :user, original_config) end)

      :ranch_ssl
      |> expect(:close, 1, fn socket ->
        :ranch_ssl.close(socket)
      end)

      {:ok, socket} = Client.connect(:ssl)
      {:error, :timeout} = Client.recv(socket)
      [%User{} = user] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      insert(:user_channel, %{user: user, channel: insert(:channel)})
      [%UserChannel{}] = Memento.transaction!(fn -> Memento.Query.all(UserChannel) end)

      assert wait([] == Memento.transaction!(fn -> Memento.Query.all(UserChannel) end), @wait_keywords)
      assert wait([] == Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords)

      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful disconnect by command quit result" do
      Command
      |> expect(:handle, 1, fn _user, _message ->
        {:quit, "Bye!"}
      end)

      {:ok, socket} = Client.connect(:tcp)
      {:error, :timeout} = Client.recv(socket)
      [%User{}] = Memento.transaction!(fn -> Memento.Query.all(User) end)

      Client.send(socket, "COMMAND test\r\n")

      assert wait([] == Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords)
      assert {:error, :closed} == Client.recv(socket)
    end

    test "handles successful quit process with user alone in a channel" do
      {:ok, socket} = Client.connect(:ssl)

      [user] =
        case_wait(Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords) do
          [_] = expected_users -> expected_users
        end

      user =
        Memento.transaction!(fn ->
          Memento.Query.write(%User{
            user
            | registered: true,
              nick: "nick1",
              hostname: "hostname1",
              username: "username1",
              realname: "realname1"
          })
        end)

      channel = insert(:channel)
      insert(:user_channel, %{user: user, channel: channel})

      Client.send(socket, "QUIT :Quit message\r\n")

      assert {:error, :closed} = Client.recv(socket)

      # Channel should be deleted
      assert wait(
               {:error, :channel_not_found} == Memento.transaction!(fn -> Channels.get_by_name(channel.name) end),
               @wait_keywords
             )
    end

    test "handles successful quit process with user in a channel with another user" do
      {:ok, socket1} = Client.connect(:ssl)
      assert wait(1 == length(Memento.transaction!(fn -> Memento.Query.all(User) end)), @wait_keywords)
      {:ok, socket2} = Client.connect(:ssl)

      [user1, user2] =
        case_wait(Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords) do
          [_, _] = expected_users -> expected_users
        end
        |> Enum.sort(&(&1.created_at <= &2.created_at))

      user1 =
        Memento.transaction!(fn ->
          Memento.Query.write(%User{
            user1
            | registered: true,
              nick: "nick1",
              hostname: "hostname1",
              username: "username1",
              realname: "realname1"
          })
        end)

      user2 =
        Memento.transaction!(fn ->
          Memento.Query.write(%User{
            user2
            | registered: true,
              nick: "nick2",
              hostname: "hostname2",
              username: "username2",
              realname: "realname2"
          })
        end)

      channel = insert(:channel)
      insert(:user_channel, %{user: user1, channel: channel})
      insert(:user_channel, %{user: user2, channel: channel})

      Client.send(socket1, "QUIT :Quit message\r\n")

      assert {:error, :closed} = Client.recv(socket1)
      assert {:ok, ":nick1!~username1@hostname1 QUIT :Quit message\r\n"} = Client.recv(socket2)

      # Channel should not be deleted
      assert {:ok, %Channel{}} = Memento.transaction!(fn -> Channels.get_by_name(channel.name) end)

      Client.disconnect(socket2)
    end

    test "handles user not found error on disconnect" do
      {:ok, socket} = Client.connect(:ssl)

      [user] =
        case_wait(Memento.transaction!(fn -> Memento.Query.all(User) end), @wait_keywords) do
          [_] = expected_users -> expected_users
        end

      Memento.transaction!(fn -> Users.delete(user) end)

      log =
        capture_log(fn ->
          Client.disconnect(socket)
          assert {:error, :closed} == Client.recv(socket)
          :timer.sleep(50)
        end)

      assert log =~ "Error handling disconnect: :user_not_found"
    end
  end
end
