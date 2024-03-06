defmodule ElixIRCd.Server.HandshakeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory
  import Mimic

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  describe "handle/1" do
    test "does nothing if the user is not ready for handshake" do
      user = insert(:user, nick: nil, identity: nil, hostname: nil, username: nil, realname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.identity == nil
      assert updated_user.hostname == nil
    end

    test "handles a user handshake successfully" do
      Helper
      |> expect(:get_socket_ip, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)

      Messaging
      |> expect(:broadcast, fn messages, _user ->
        assert length(messages) == 5
        :ok
      end)

      user = insert(:user, identity: nil, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.identity == "#{user.nick}!~#{String.slice(user.username, 0..8)}@localhost"
      assert updated_user.hostname == "localhost"
    end
  end

  test "handles a user handshake successfully with hostname lookup error" do
    Helper
    |> expect(:get_socket_ip, fn _socket -> {:ok, {127, 0, 0, 1}} end)
    |> expect(:get_socket_hostname, fn _ip -> {:error, "anyerror"} end)

    Messaging
    |> expect(:broadcast, fn messages, _user ->
      assert length(messages) == 5
      :ok
    end)

    user = insert(:user, identity: nil, hostname: nil)
    assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

    assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
    assert updated_user.identity == "#{user.nick}!~#{String.slice(user.username, 0..8)}@127.0.0.1"
    assert updated_user.hostname == "127.0.0.1"
  end

  test "handles a user handshake error with get socket ip error" do
    Helper
    |> expect(:get_socket_ip, fn _socket -> {:error, "anyerror"} end)

    user = insert(:user, identity: nil, hostname: nil)
    assert {:quit, "Handshake Failed"} = Memento.transaction!(fn -> Handshake.handle(user) end)
  end

  test "handles a user handshake successfully for an ipv6 socket connection" do
    Helper
    |> expect(:get_socket_ip, fn _socket -> {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} end)
    |> expect(:get_socket_hostname, fn _ip -> {:error, "anyerror"} end)

    Messaging
    |> expect(:broadcast, fn messages, _user ->
      assert length(messages) == 5
      :ok
    end)

    user = insert(:user, identity: nil, hostname: nil)
    assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

    assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
    assert updated_user.identity == "#{user.nick}!~#{String.slice(user.username, 0..8)}@::1"
    assert updated_user.hostname == "::1"
  end

  test "handles a user handshake successfully when server has a password set and it matches user's password" do
    Application.put_env(:elixircd, :server_password, "password")

    Helper
    |> expect(:get_socket_ip, fn _socket -> {:ok, {127, 0, 0, 1}} end)
    |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)

    Messaging
    |> expect(:broadcast, fn messages, _user ->
      assert length(messages) == 5
      :ok
    end)

    user = insert(:user, identity: nil, hostname: nil, password: "password")
    assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

    assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
    assert updated_user.identity == "#{user.nick}!~#{String.slice(user.username, 0..8)}@localhost"
    assert updated_user.hostname == "localhost"

    Application.put_env(:elixircd, :server_password, nil)
  end

  test "handles a user handleshake error when server has a password set and it does not match user's password" do
    Application.put_env(:elixircd, :server_password, "password")

    Messaging
    |> expect(:broadcast, fn message, _user ->
      assert message == %Message{prefix: "server.example.com", command: "464", params: ["*"], trailing: "Bad Password"}
      :ok
    end)

    user = insert(:user, identity: nil, hostname: nil, password: "wrongpassword")
    assert {:quit, "Bad Password"} = Memento.transaction!(fn -> Handshake.handle(user) end)

    Application.put_env(:elixircd, :server_password, nil)
  end
end
