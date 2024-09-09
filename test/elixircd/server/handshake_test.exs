defmodule ElixIRCd.Server.HandshakeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import Mimic

  alias ElixIRCd.Command.Lusers
  alias ElixIRCd.Command.Motd
  alias ElixIRCd.Helper
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Server.Handshake.IdentClient
  alias ElixIRCd.Tables.User

  describe "handle/1" do
    setup do
      app_version = "ElixIRCd-#{Application.spec(:elixircd, :vsn)}"
      server_start_date = Application.get_env(:elixircd, :server_start_time) |> Calendar.strftime("%Y-%m-%d")

      {:ok, app_version: app_version, server_start_date: server_start_date}
    end

    test "does nothing if the user is not ready for handshake" do
      user = insert(:user, nick: nil, registered: false, hostname: nil, ident: nil, realname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.hostname == nil
      assert updated_user.registered == false
      assert updated_user.registered_at == nil
    end

    test "handles a user handshake successfully with found lookup hostname and got ident response", %{
      app_version: app_version,
      server_start_date: server_start_date
    } do
      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)
      |> expect(:get_socket_port_connected, fn _socket -> {:ok, 6667} end)

      IdentClient
      |> expect(:query_userid, fn _ip, _server_port_query -> {:ok, "anyuserid"} end)

      Lusers
      |> expect(:send_lusers, fn _user -> :ok end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages(
        [
          {user.socket, ":server.example.com NOTICE * :*** Looking up your hostname...\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Found your hostname\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Checking Ident\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Got Ident response\r\n"},
          {user.socket,
           ":server.example.com 001 #{user.nick} :Welcome to the Server Example Internet Relay Chat Network #{user.nick}\r\n"},
          {user.socket,
           ":server.example.com 002 #{user.nick} :Your host is Server Example, running version #{app_version}.\r\n"},
          {user.socket, ":server.example.com 003 #{user.nick} :This server was created #{server_start_date}\r\n"},
          {user.socket, ":server.example.com 004 #{user.nick} :server.example.com #{app_version} iowZ biklmnopstv\r\n"}
          # LUSERS messages are mocked as we don't care about it here
          # MOTD messages are mocked as we don't care about it here
        ],
        validate_order?: false
      )

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.hostname == "localhost"
      assert updated_user.ident == "anyuserid"
      assert updated_user.registered == true
      assert DateTime.diff(DateTime.utc_now(), updated_user.registered_at) < 1000
    end

    test "handles a user handshake successfully with not found hostname lookup and no ident response", %{
      app_version: app_version,
      server_start_date: server_start_date
    } do
      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:error, "anyerror"} end)
      |> expect(:get_socket_port_connected, fn _socket -> {:ok, 6667} end)

      IdentClient
      |> expect(:query_userid, fn _ip, _server_port_query -> {:error, "anyerror"} end)

      Lusers
      |> expect(:send_lusers, fn _user -> :ok end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages(
        [
          {user.socket, ":server.example.com NOTICE * :*** Looking up your hostname...\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Couldn't look up your hostname\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Checking Ident\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** No Ident response\r\n"},
          {user.socket,
           ":server.example.com 001 #{user.nick} :Welcome to the Server Example Internet Relay Chat Network #{user.nick}\r\n"},
          {user.socket,
           ":server.example.com 002 #{user.nick} :Your host is Server Example, running version #{app_version}.\r\n"},
          {user.socket, ":server.example.com 003 #{user.nick} :This server was created #{server_start_date}\r\n"},
          {user.socket, ":server.example.com 004 #{user.nick} :server.example.com #{app_version} iowZ biklmnopstv\r\n"}
          # LUSERS messages are mocked as we don't care about it here
          # MOTD messages are mocked as we don't care about it here
        ],
        validate_order?: false
      )

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.hostname == "127.0.0.1"
      assert updated_user.ident == "~username"
      assert updated_user.registered == true
    end

    test "handles a user handshake successfully for an ipv6 socket connection with not found hostname lookup and no ident response",
         %{app_version: app_version, server_start_date: server_start_date} do
      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:error, "anyerror"} end)
      |> expect(:get_socket_port_connected, fn _socket -> {:ok, 6667} end)

      IdentClient
      |> expect(:query_userid, fn _ip, _server_port_query -> {:error, "anyerror"} end)

      Lusers
      |> expect(:send_lusers, fn _user -> :ok end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil, modes: ["Z"])
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages(
        [
          {user.socket, ":server.example.com NOTICE * :*** Looking up your hostname...\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Couldn't look up your hostname\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** Checking Ident\r\n"},
          {user.socket, ":server.example.com NOTICE * :*** No Ident response\r\n"},
          {user.socket,
           ":server.example.com 001 #{user.nick} :Welcome to the Server Example Internet Relay Chat Network #{user.nick}\r\n"},
          {user.socket,
           ":server.example.com 002 #{user.nick} :Your host is Server Example, running version #{app_version}.\r\n"},
          {user.socket, ":server.example.com 003 #{user.nick} :This server was created #{server_start_date}\r\n"},
          {user.socket, ":server.example.com 004 #{user.nick} :server.example.com #{app_version} iowZ biklmnopstv\r\n"},
          # LUSERS messages are mocked as we don't care about it here
          # MOTD messages are mocked as we don't care about it here
          {user.socket, ":#{user.nick} MODE #{user.nick} :+Z\r\n"}
        ],
        validate_order?: false
      )

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.hostname == "::1"
      assert updated_user.ident == "~username"
      assert updated_user.registered == true
    end

    test "handles a user handshake successfully with ident protocol disabled", %{
      app_version: app_version,
      server_start_date: server_start_date
    } do
      original_config = Application.get_env(:elixircd, :ident_service)
      Application.put_env(:elixircd, :ident_service, original_config |> Keyword.put(:enabled, false))
      on_exit(fn -> Application.put_env(:elixircd, :ident_service, original_config) end)

      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)
      |> expect(:get_socket_port_connected, fn _socket -> {:ok, 6667} end)

      Lusers
      |> expect(:send_lusers, fn _user -> :ok end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages([
        {user.socket, ":server.example.com NOTICE * :*** Looking up your hostname...\r\n"},
        {user.socket, ":server.example.com NOTICE * :*** Found your hostname\r\n"},
        {user.socket,
         ":server.example.com 001 #{user.nick} :Welcome to the Server Example Internet Relay Chat Network #{user.nick}\r\n"},
        {user.socket,
         ":server.example.com 002 #{user.nick} :Your host is Server Example, running version #{app_version}.\r\n"},
        {user.socket, ":server.example.com 003 #{user.nick} :This server was created #{server_start_date}\r\n"},
        {user.socket, ":server.example.com 004 #{user.nick} :server.example.com #{app_version} iowZ biklmnopstv\r\n"}
        # LUSERS messages are mocked as we don't care about it here
        # MOTD messages are mocked as we don't care about it here
      ])

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.hostname == "localhost"
      assert updated_user.ident == "~username"
      assert updated_user.registered == true
    end

    test "handles a user handshake successfully when server has a password set and it matches user's password" do
      original_config = Application.get_env(:elixircd, :server)
      Application.put_env(:elixircd, :server, original_config |> Keyword.put(:password, "password"))
      on_exit(fn -> Application.put_env(:elixircd, :server, original_config) end)

      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {127, 0, 0, 1}} end)
      |> expect(:get_socket_hostname, fn _ip -> {:ok, "localhost"} end)
      |> expect(:get_socket_port_connected, fn _socket -> {:ok, 6667} end)

      IdentClient
      |> expect(:query_userid, fn _ip, _server_port_query -> {:error, "anyerror"} end)

      Lusers
      |> expect(:send_lusers, fn _user -> :ok end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil, password: "password")
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages_amount(user.socket, 8)

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
      assert updated_user.hostname == "localhost"
      assert updated_user.registered == true
    end

    test "handles a user handshake error with get socket ip error" do
      Helper
      |> expect(:get_socket_ip, fn _socket -> {:error, "anyerror"} end)

      user = insert(:user, registered: false, hostname: nil)
      assert {:quit, "Handshake Failed"} = Memento.transaction!(fn -> Handshake.handle(user) end)
    end

    test "handles a user handleshake error when server has a password set and it does not match user's password" do
      original_config = Application.get_env(:elixircd, :server)
      Application.put_env(:elixircd, :server, original_config |> Keyword.put(:password, "password"))
      on_exit(fn -> Application.put_env(:elixircd, :server, original_config) end)

      user = insert(:user, registered: false, hostname: nil, password: "wrongpassword")
      assert {:quit, "Bad Password"} = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages([
        {user.socket, ":server.example.com 464 * :Bad Password\r\n"}
      ])
    end
  end
end
