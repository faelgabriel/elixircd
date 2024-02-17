defmodule ElixIRCd.Server.HandshakeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory
  import ExUnit.CaptureLog
  import Mimic

  alias ElixIRCd.Helper
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
      user = insert(:user, identity: nil, hostname: nil)

      Helper
      |> expect(:get_socket_ip, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)

      Messaging
      |> expect(:broadcast, fn messages, _user ->
        assert length(messages) == 5
        :ok
      end)

      refute is_nil(user.nick)
      refute is_nil(user.username)
      refute is_nil(user.realname)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.identity == "#{user.nick}!#{String.slice(user.username, 0..7)}@localhost"
      assert updated_user.hostname == "localhost"
    end
  end

  test "handles a user handshake successfully with hostname lookup error" do
    user = insert(:user, identity: nil, hostname: nil)

    Helper
    |> expect(:get_socket_ip, fn _socket -> {:ok, {127, 0, 0, 1}} end)
    |> expect(:get_socket_hostname, fn _ip -> {:error, "anyerror"} end)

    Messaging
    |> expect(:broadcast, fn messages, _user ->
      assert length(messages) == 5
      :ok
    end)

    refute is_nil(user.nick)
    refute is_nil(user.username)
    refute is_nil(user.realname)
    assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

    assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
    assert updated_user.identity == "#{user.nick}!#{String.slice(user.username, 0..7)}@127.0.0.1"
    assert updated_user.hostname == "127.0.0.1"
  end

  test "handles a user handshake error with get socket ip error" do
    user = insert(:user, identity: nil, hostname: nil)

    Helper
    |> expect(:get_socket_ip, fn _socket -> {:error, "anyerror"} end)

    refute is_nil(user.nick)
    refute is_nil(user.username)
    refute is_nil(user.realname)

    log =
      capture_log(fn ->
        assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)
      end)

    assert log =~ "Error handling handshake for user"

    assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
    assert updated_user.identity == nil
    assert updated_user.hostname == nil
  end

  test "handles a user handshake successfully for an ipv6 socket connection" do
    user = insert(:user, identity: nil, hostname: nil)

    Helper
    |> expect(:get_socket_ip, fn _socket -> {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} end)
    |> expect(:get_socket_hostname, fn _ip -> {:error, "anyerror"} end)

    Messaging
    |> expect(:broadcast, fn messages, _user ->
      assert length(messages) == 5
      :ok
    end)

    refute is_nil(user.nick)
    refute is_nil(user.username)
    refute is_nil(user.realname)
    assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

    assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
    assert updated_user.identity == "#{user.nick}!#{String.slice(user.username, 0..7)}@::1"
    assert updated_user.hostname == "::1"
  end
end
