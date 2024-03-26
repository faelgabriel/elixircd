defmodule ElixIRCd.Server.HandshakeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import Mimic

  alias ElixIRCd.Command.Motd
  alias ElixIRCd.Helper
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Server.Handshake.IdentClient
  alias ElixIRCd.Tables.User

  describe "handle/1" do
    test "does nothing if the user is not ready for handshake" do
      user = insert(:user, nick: nil, registered: false, hostname: nil, username: nil, realname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.hostname == nil
      assert updated_user.registered == false
    end

    test "handles a user handshake successfully with found lookup hostname and got ident response" do
      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)
      |> expect(:get_socket_port_connected, fn _socket -> {:ok, 6667} end)

      IdentClient
      |> expect(:fetch_user_id, fn _ip, _server_port_query -> {:ok, "anyuserid"} end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages(
        [
          {user.socket, ":server.example.com NOTICE * :*** Looking up your hostname...\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Found your hostname\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Checking Ident\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Got Ident response\r\n"}
          # MOTD messages are mocked as we don't care about it here
        ],
        validate_order?: false
      )

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.hostname == "localhost"
      assert updated_user.identity == "anyuserid"
      assert updated_user.registered == true
    end

    test "handles a user handshake successfully with not found hostname lookup and not got ident response" do
      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:error, "anyerror"} end)
      |> expect(:get_socket_port_connected, fn _socket -> {:ok, 6667} end)

      IdentClient
      |> expect(:fetch_user_id, fn _ip, _server_port_query -> {:error, "anyerror"} end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages(
        [
          {user.socket, ":server.example.com NOTICE * :*** Looking up your hostname...\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Couldn't look up your hostname\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Checking Ident\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** No Ident response\r\n"}
          # MOTD messages are mocked as we don't care about it here
        ],
        validate_order?: false
      )

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.registered == true
      assert updated_user.identity == nil
      assert updated_user.hostname == "127.0.0.1"
    end

    test "handles a user handshake successfully for an ipv6 socket connection with not found hostname lookup and no ident response" do
      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:error, "anyerror"} end)
      |> expect(:get_socket_port_connected, fn _socket -> {:ok, 6667} end)

      IdentClient
      |> expect(:fetch_user_id, fn _ip, _server_port_query -> {:error, "anyerror"} end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages_amount(user.socket, 4)

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.registered == true
      assert updated_user.identity == nil
      assert updated_user.hostname == "::1"
    end

    test "handles a user handshake successfully with ident protocol disabled" do
      Application.put_env(:elixircd, :ident_protocol_enabled, false)

      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)
      |> expect(:get_socket_port_connected, fn _socket -> {:ok, 6667} end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages([
        {user.socket, ":server.example.com NOTICE * :*** Looking up your hostname...\r\n"},
        {user.socket, ":server.example.com NOTICE * :*** Found your hostname\r\n"}
        # MOTD messages are mocked as we don't care about it here
      ])

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.hostname == "localhost"
      assert updated_user.identity == nil
      assert updated_user.registered == true

      Application.put_env(:elixircd, :ident_protocol_enabled, true)
    end

    test "handles a user handshake successfully when server has a password set and it matches user's password" do
      Application.put_env(:elixircd, :server_password, "password")

      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)
      |> expect(:get_socket_port_connected, fn _socket -> {:ok, 6667} end)

      IdentClient
      |> expect(:fetch_user_id, fn _ip, _server_port_query -> {:error, "anyerror"} end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil, password: "password")
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages_amount(user.socket, 4)

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.registered == true
      assert updated_user.hostname == "localhost"

      Application.put_env(:elixircd, :server_password, nil)
    end

    test "handles a user handshake error with get socket ip error" do
      Helper
      |> expect(:get_socket_ip, fn _socket -> {:error, "anyerror"} end)

      user = insert(:user, registered: false, hostname: nil)
      assert {:quit, "Handshake Failed"} = Memento.transaction!(fn -> Handshake.handle(user) end)
    end

    test "handles a user handleshake error when server has a password set and it does not match user's password" do
      Application.put_env(:elixircd, :server_password, "password")

      user = insert(:user, registered: false, hostname: nil, password: "wrongpassword")
      assert {:quit, "Bad Password"} = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages([
        {user.socket, ":server.example.com 464 * :Bad Password\r\n"}
      ])

      Application.put_env(:elixircd, :server_password, nil)
    end
  end
end
