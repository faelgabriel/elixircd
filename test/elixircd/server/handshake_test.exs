defmodule ElixIRCd.Server.HandshakeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Lusers
  alias ElixIRCd.Commands.Motd
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Isupport
  alias ElixIRCd.Utils.Network

  describe "handle/1" do
    setup do
      app_version = "ElixIRCd-#{Application.spec(:elixircd, :vsn)}"
      server_start_date = :persistent_term.get(:server_start_time) |> Calendar.strftime("%Y-%m-%d")

      {:ok, app_version: app_version, server_start_date: server_start_date}
    end

    test "does nothing if the user is not ready for handshake" do
      user = insert(:user, nick: nil, registered: false, hostname: nil, ident: nil, realname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.pid) end)
      assert updated_user.hostname == nil
      assert updated_user.registered == false
      assert updated_user.registered_at == nil
    end

    test "handles a user handshake successfully with found lookup hostname and got ident response", %{
      app_version: app_version,
      server_start_date: server_start_date
    } do
      Network
      |> expect(:lookup_hostname, fn _ip -> {:ok, "localhost"} end)

      Network
      |> expect(:query_identd, fn _ip, _irc_server_port -> {:ok, "anyuserid"} end)

      Lusers
      |> expect(:send_lusers, fn _user -> :ok end)

      Isupport
      |> stub(:send_isupport_messages, fn _user -> :ok end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages(
        [
          {user.pid, ":irc.test NOTICE * :*** Looking up your hostname...\r\n"},
          {user.pid, ":irc.test NOTICE * :*** Found your hostname\r\n"},
          {user.pid, ":irc.test NOTICE * :*** Checking Ident\r\n"},
          {user.pid, ":irc.test NOTICE * :*** Got Ident response\r\n"},
          {user.pid,
           ":irc.test 001 #{user.nick} :Welcome to the Server Example Internet Relay Chat Network #{user.nick}\r\n"},
          {user.pid, ":irc.test 002 #{user.nick} :Your host is Server Example, running version #{app_version}.\r\n"},
          {user.pid, ":irc.test 003 #{user.nick} :This server was created #{server_start_date}\r\n"},
          {user.pid, ":irc.test 004 #{user.nick} :irc.test #{app_version} BgHiorRwZ bCcdijklmnOopstTv\r\n"}
          # LUSERS messages are mocked as we don't care about it here
          # ISUPPORT messages are mocked as we don't care about it here
          # MOTD messages are mocked as we don't care about it here
        ],
        validate_order?: false
      )

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.pid) end)
      assert updated_user.hostname == "localhost"
      assert updated_user.ident == "anyuserid"
      assert updated_user.registered == true
      assert DateTime.diff(DateTime.utc_now(), updated_user.registered_at) < 1000
    end

    test "handles a user handshake successfully with not found hostname lookup and no ident response", %{
      app_version: app_version,
      server_start_date: server_start_date
    } do
      Network
      |> expect(:lookup_hostname, fn _ip -> {:error, "anyerror"} end)

      Network
      |> expect(:query_identd, fn _ip, _irc_server_port -> {:error, "anyerror"} end)

      Lusers
      |> expect(:send_lusers, fn _user -> :ok end)

      Isupport
      |> stub(:send_isupport_messages, fn _user -> :ok end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages(
        [
          {user.pid, ":irc.test NOTICE * :*** Looking up your hostname...\r\n"},
          {user.pid, ":irc.test NOTICE * :*** Couldn't look up your hostname\r\n"},
          {user.pid, ":irc.test NOTICE * :*** Checking Ident\r\n"},
          {user.pid, ":irc.test NOTICE * :*** No Ident response\r\n"},
          {user.pid,
           ":irc.test 001 #{user.nick} :Welcome to the Server Example Internet Relay Chat Network #{user.nick}\r\n"},
          {user.pid, ":irc.test 002 #{user.nick} :Your host is Server Example, running version #{app_version}.\r\n"},
          {user.pid, ":irc.test 003 #{user.nick} :This server was created #{server_start_date}\r\n"},
          {user.pid, ":irc.test 004 #{user.nick} :irc.test #{app_version} BgHiorRwZ bCcdijklmnOopstTv\r\n"}
          # LUSERS messages are mocked as we don't care about it here
          # ISUPPORT messages are mocked as we don't care about it here
          # MOTD messages are mocked as we don't care about it here
        ],
        validate_order?: false
      )

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.pid) end)
      assert updated_user.hostname == "127.0.0.1"
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

      Network
      |> expect(:lookup_hostname, fn _ip -> {:ok, "localhost"} end)

      Lusers
      |> expect(:send_lusers, fn _user -> :ok end)

      Isupport
      |> stub(:send_isupport_messages, fn _user -> :ok end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil)
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages([
        {user.pid, ":irc.test NOTICE * :*** Looking up your hostname...\r\n"},
        {user.pid, ":irc.test NOTICE * :*** Found your hostname\r\n"},
        {user.pid,
         ":irc.test 001 #{user.nick} :Welcome to the Server Example Internet Relay Chat Network #{user.nick}\r\n"},
        {user.pid, ":irc.test 002 #{user.nick} :Your host is Server Example, running version #{app_version}.\r\n"},
        {user.pid, ":irc.test 003 #{user.nick} :This server was created #{server_start_date}\r\n"},
        {user.pid, ":irc.test 004 #{user.nick} :irc.test #{app_version} BgHiorRwZ bCcdijklmnOopstTv\r\n"}
        # LUSERS messages are mocked as we don't care about it here
        # ISUPPORT messages are mocked as we don't care about it here
        # MOTD messages are mocked as we don't care about it here
      ])

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.pid) end)
      assert updated_user.hostname == "localhost"
      assert updated_user.ident == "~username"
      assert updated_user.registered == true
    end

    test "handles a user handshake successfully with user modes (user is registered at this point)", %{
      app_version: app_version,
      server_start_date: server_start_date
    } do
      Network
      |> expect(:lookup_hostname, fn _ip -> {:error, "anyerror"} end)

      Network
      |> expect(:query_identd, fn _ip, _irc_server_port -> {:error, "anyerror"} end)

      Lusers
      |> expect(:send_lusers, fn _user -> :ok end)

      Isupport
      |> stub(:send_isupport_messages, fn _user -> :ok end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: true, hostname: "127.0.0.1", modes: ["Z"])
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages(
        [
          {user.pid, ":irc.test NOTICE * :*** Looking up your hostname...\r\n"},
          {user.pid, ":irc.test NOTICE * :*** Couldn't look up your hostname\r\n"},
          {user.pid, ":irc.test NOTICE * :*** Checking Ident\r\n"},
          {user.pid, ":irc.test NOTICE * :*** No Ident response\r\n"},
          {user.pid,
           ":irc.test 001 #{user.nick} :Welcome to the Server Example Internet Relay Chat Network #{user.nick}\r\n"},
          {user.pid, ":irc.test 002 #{user.nick} :Your host is Server Example, running version #{app_version}.\r\n"},
          {user.pid, ":irc.test 003 #{user.nick} :This server was created #{server_start_date}\r\n"},
          {user.pid, ":irc.test 004 #{user.nick} :irc.test #{app_version} BgHiorRwZ bCcdijklmnOopstTv\r\n"},
          # LUSERS messages are mocked as we don't care about it here
          # ISUPPORT messages are mocked as we don't care about it here
          # MOTD messages are mocked as we don't care about it here
          {user.pid, ":#{user_mask(user)} MODE #{user.nick} :+Z\r\n"}
        ],
        validate_order?: false
      )

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.pid) end)
      assert updated_user.hostname == "127.0.0.1"
      assert updated_user.ident == "~username"
      assert updated_user.registered == true
    end

    test "handles a user handshake successfully when server has a password set and it matches user's password" do
      original_config = Application.get_env(:elixircd, :server)
      Application.put_env(:elixircd, :server, original_config |> Keyword.put(:password, "password"))
      on_exit(fn -> Application.put_env(:elixircd, :server, original_config) end)

      Network
      |> expect(:lookup_hostname, fn _ip -> {:ok, "localhost"} end)

      Network
      |> expect(:query_identd, fn _ip, _irc_server_port -> {:error, "anyerror"} end)

      Lusers
      |> expect(:send_lusers, fn _user -> :ok end)

      Isupport
      |> stub(:send_isupport_messages, fn _user -> :ok end)

      Motd
      |> expect(:send_motd, fn _user -> :ok end)

      user = insert(:user, registered: false, hostname: nil, password: "password")
      assert :ok = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages_amount(user.pid, 8)

      assert %User{} = updated_user = Memento.transaction!(fn -> Memento.Query.read(User, user.pid) end)
      assert updated_user.hostname == "localhost"
      assert updated_user.registered == true
    end

    test "handles a user handleshake error when server has a password set and it does not match user's password" do
      original_config = Application.get_env(:elixircd, :server)
      Application.put_env(:elixircd, :server, original_config |> Keyword.put(:password, "password"))
      on_exit(fn -> Application.put_env(:elixircd, :server, original_config) end)

      user = insert(:user, registered: false, hostname: nil, password: "wrongpassword")
      assert {:quit, "Bad Password"} = Memento.transaction!(fn -> Handshake.handle(user) end)

      assert_sent_messages([
        {user.pid, ":irc.test 464 * :Bad Password\r\n"}
      ])
    end
  end
end
