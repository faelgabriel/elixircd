defmodule ElixIRCd.Server.HandshakeTest do
  @moduledoc false

  use ElixIRCd.DataCase
  doctest ElixIRCd.Server.Handshake

  alias Ecto.Changeset
  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Helper
  alias ElixIRCd.Server
  alias ElixIRCd.Server.Handshake

  import ExUnit.CaptureLog
  import ElixIRCd.Factory
  import Mimic

  describe "handle/1" do
    test "does nothing if the user is not ready for handshake" do
      user = insert(:user, nick: nil, identity: nil, hostname: nil, username: nil, realname: nil)

      assert :ok = Handshake.handle(user)

      assert {:ok, updated_user} = Contexts.User.get_by_socket(user.socket)
      assert updated_user.identity == nil
      assert updated_user.hostname == nil
    end

    test "handles a user handshake successfully" do
      user = insert(:user, identity: nil, hostname: nil)

      Helper
      |> expect(:get_socket_ip, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)

      Server
      |> expect(:send_messages, fn messages, _user ->
        assert length(messages) == 5
        :ok
      end)

      refute is_nil(user.nick)
      refute is_nil(user.username)
      refute is_nil(user.realname)
      assert :ok = Handshake.handle(user)

      assert {:ok, updated_user} = Contexts.User.get_by_socket(user.socket)
      assert updated_user.identity == "#{user.nick}!#{String.slice(user.username, 0..7)}@localhost"
      assert updated_user.hostname == "localhost"
    end
  end

  test "handles a user handshake successfully with hostname lookup error" do
    user = insert(:user, identity: nil, hostname: nil)

    Helper
    |> expect(:get_socket_ip, fn _socket -> {:ok, {127, 0, 0, 1}} end)
    |> expect(:get_socket_hostname, fn _ip -> {:error, "anyerror"} end)

    Server
    |> expect(:send_messages, fn messages, _user ->
      assert length(messages) == 5
      :ok
    end)

    refute is_nil(user.nick)
    refute is_nil(user.username)
    refute is_nil(user.realname)
    assert :ok = Handshake.handle(user)

    assert {:ok, updated_user} = Contexts.User.get_by_socket(user.socket)
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

    {return, log} =
      with_log(fn ->
        Handshake.handle(user)
      end)

    assert return == :ok
    assert log =~ "Error handling handshake for user"

    assert {:ok, updated_user} = Contexts.User.get_by_socket(user.socket)
    assert updated_user.identity == nil
    assert updated_user.hostname == nil
  end

  test "handles a user handshake error with update user changeset error" do
    user = insert(:user, identity: nil, hostname: nil)

    Helper
    |> expect(:get_socket_ip, fn _socket -> {:ok, {127, 0, 0, 1}} end)
    |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)

    Contexts.User
    |> expect(:update, fn _user, _attrs -> {:error, %Changeset{}} end)

    refute is_nil(user.nick)
    refute is_nil(user.username)
    refute is_nil(user.realname)

    {return, log} =
      with_log(fn ->
        Handshake.handle(user)
      end)

    assert return == :ok
    assert log =~ "Error handling handshake for user"

    assert {:ok, updated_user} = Contexts.User.get_by_socket(user.socket)
    assert updated_user.identity == nil
    assert updated_user.hostname == nil
  end

  test "handles a user handshake successfully for an ipv6 socket connection" do
    user = insert(:user, identity: nil, hostname: nil)

    Helper
    |> expect(:get_socket_ip, fn _socket -> {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} end)
    |> expect(:get_socket_hostname, fn _ip -> {:error, "anyerror"} end)

    Server
    |> expect(:send_messages, fn messages, _user ->
      assert length(messages) == 5
      :ok
    end)

    refute is_nil(user.nick)
    refute is_nil(user.username)
    refute is_nil(user.realname)
    assert :ok = Handshake.handle(user)

    assert {:ok, updated_user} = Contexts.User.get_by_socket(user.socket)
    assert updated_user.identity == "#{user.nick}!#{String.slice(user.username, 0..7)}@::1"
    assert updated_user.hostname == "::1"
  end
end
