defmodule ElixIRCd.Services.Nickserv.RegisterTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Services.Nickserv.Register
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.RegisteredNick.Settings
  alias ElixIRCd.Utils.Mailer

  describe "handle/2" do
    test "handles REGISTER command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Register.handle(user, ["REGISTER"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02REGISTER\x02.\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*Syntax: \x02REGISTER <password>.*/}
        ])
      end)
    end

    test "handles REGISTER command for already registered nickname" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, nick: registered_nick.nickname)

        assert :ok = Register.handle(user, ["REGISTER", "password", "email@example.com"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :This nick is already registered. Please choose a different nick.\r\n"}
        ])
      end)
    end

    test "handles REGISTER command with password that is too short" do
      Memento.transaction!(fn ->
        min_password_length = Application.get_env(:elixircd, :services)[:nickserv][:min_password_length] || 6
        user = insert(:user)
        short_password = String.duplicate("a", min_password_length - 1)

        assert :ok = Register.handle(user, ["REGISTER", short_password, "email@example.com"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Password is too short. Please use at least #{min_password_length} characters.\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*Syntax: \x02REGISTER.*/}
        ])
      end)
    end

    test "handles REGISTER command with invalid email" do
      Memento.transaction!(fn ->
        user = insert(:user)
        invalid_email = "invalid_email"

        assert :ok = Register.handle(user, ["REGISTER", "password123", invalid_email])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Invalid email address. Please provide a valid email address.\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*Syntax: \x02REGISTER.*/}
        ])
      end)
    end

    test "handles REGISTER command when email is required but not provided" do
      original_config = Application.get_env(:elixircd, :services)
      on_exit(fn -> Application.put_env(:elixircd, :services, original_config) end)

      nickserv_config = Keyword.put(original_config[:nickserv] || [], :email_required, true)
      updated_config = Keyword.put(original_config, :nickserv, nickserv_config)

      Application.put_env(:elixircd, :services, updated_config)

      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Register.handle(user, ["REGISTER", "password123"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You must provide an email address to register a nickname.\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*Syntax: \x02REGISTER.*/}
        ])
      end)
    end

    test "handles REGISTER command when wait time is required but not met" do
      original_config = Application.get_env(:elixircd, :services)
      on_exit(fn -> Application.put_env(:elixircd, :services, original_config) end)

      nickserv_config = Keyword.put(original_config[:nickserv] || [], :wait_register_time, 60)
      updated_config = Keyword.put(original_config, :nickserv, nickserv_config)

      Application.put_env(:elixircd, :services, updated_config)

      Memento.transaction!(fn ->
        user = insert(:user, created_at: DateTime.utc_now())

        assert :ok = Register.handle(user, ["REGISTER", "password123", "email@example.com"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You must be connected for at least 60 seconds before you can register.\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*Please wait.*more seconds and try again.*/}
        ])
      end)
    end

    test "successfully registers a nickname without email" do
      original_config = Application.get_env(:elixircd, :services)
      on_exit(fn -> Application.put_env(:elixircd, :services, original_config) end)

      nickserv_config = Keyword.put(original_config[:nickserv] || [], :wait_register_time, 0)
      updated_config = Keyword.put(original_config, :nickserv, nickserv_config)

      Application.put_env(:elixircd, :services, updated_config)

      user = insert(:user, created_at: DateTime.add(DateTime.utc_now(), -3600))
      password = "password123"

      mock_registered_nick = %RegisteredNick{
        nickname: user.nick,
        password_hash: Pbkdf2.hash_pwd_salt(password),
        email: nil,
        registered_by: "#{user.nick}!#{user.ident}@#{user.hostname}",
        verify_code: nil,
        verified_at: nil,
        last_seen_at: DateTime.utc_now(),
        reserved_until: nil,
        settings: Settings.new(),
        created_at: DateTime.utc_now()
      }

      RegisteredNicks
      |> expect(:get_by_nickname, fn nick ->
        if nick == user.nick, do: {:error, :registered_nick_not_found}, else: {:error, :registered_nick_not_found}
      end)

      RegisteredNicks
      |> expect(:create, fn _params -> mock_registered_nick end)

      :ok = Register.handle(user, ["REGISTER", password])

      assert_sent_messages([
        {user.pid,
         ":NickServ!service@irc.test NOTICE #{user.nick} :Your nickname has been successfully registered.\r\n"},
        {user.pid, ~r/NickServ.*NOTICE.*To identify in the future, type:.*/}
      ])
    end

    test "successfully registers a nickname with email" do
      original_config = Application.get_env(:elixircd, :services)
      on_exit(fn -> Application.put_env(:elixircd, :services, original_config) end)

      nickserv_config =
        original_config[:nickserv]
        |> Keyword.put(:wait_register_time, 0)
        |> Keyword.put(:unverified_expire_days, 30)

      updated_config = Keyword.put(original_config, :nickserv, nickserv_config)

      Application.put_env(:elixircd, :services, updated_config)

      user = insert(:user, created_at: DateTime.add(DateTime.utc_now(), -3600))
      password = "password123"
      email = "user@example.com"
      verify_code = "123456"

      mock_registered_nick = %RegisteredNick{
        nickname: user.nick,
        password_hash: Pbkdf2.hash_pwd_salt(password),
        email: email,
        registered_by: "#{user.nick}!#{user.ident}@#{user.hostname}",
        verify_code: verify_code,
        verified_at: nil,
        last_seen_at: DateTime.utc_now(),
        reserved_until: nil,
        settings: Settings.new(),
        created_at: DateTime.utc_now()
      }

      RegisteredNicks
      |> expect(:get_by_nickname, fn nick ->
        if nick == user.nick, do: {:error, :registered_nick_not_found}, else: {:error, :registered_nick_not_found}
      end)

      RegisteredNicks
      |> expect(:create, fn params ->
        assert params[:email] == email
        %{mock_registered_nick | verify_code: params[:verify_code]}
      end)

      Mailer
      |> expect(:send_verification_email, fn email_address, nickname, code ->
        assert email_address == email
        assert nickname == user.nick
        assert is_binary(code) && String.length(code) == 8
        {:ok, %{}}
      end)

      :ok = Register.handle(user, ["REGISTER", password, email])

      assert_sent_messages([
        {user.pid,
         ~r/NickServ.*NOTICE.*An email containing nickname activation instructions has been sent to \x02#{email}\x02/},
        {user.pid, ~r/NickServ.*NOTICE.*Please check the address if you don't receive it/},
        {user.pid, ~r/NickServ.*NOTICE.*If you do not complete registration within 30 days, your nickname will expire/},
        {user.pid, ~r/NickServ.*NOTICE.*\x02#{user.nick}\x02 is now registered to \x02#{email}\x02/},
        {user.pid, ~r/NickServ.*NOTICE.*To identify in the future, type:.*/}
      ])
    end
  end

  describe "pluralize_days/1" do
    test "returns 'day' when value is 1" do
      original_config = Application.get_env(:elixircd, :services)
      on_exit(fn -> Application.put_env(:elixircd, :services, original_config) end)

      nickserv_config =
        original_config[:nickserv]
        |> Keyword.put(:unverified_expire_days, 1)
        |> Keyword.put(:wait_register_time, 0)

      updated_config = Keyword.put(original_config, :nickserv, nickserv_config)

      Application.put_env(:elixircd, :services, updated_config)

      Memento.transaction!(fn ->
        user = insert(:user)
        password = "password123"
        email = "user@example.com"

        expect(Mailer, :send_verification_email, fn _, _, _ -> {:ok, %{}} end)

        assert :ok = Register.handle(user, ["REGISTER", password, email])

        assert_sent_messages([
          {user.pid,
           ~r/NickServ.*NOTICE.*An email containing nickname activation instructions has been sent to \x02#{email}\x02/},
          {user.pid, ~r/NickServ.*NOTICE.*Please check the address if you don't receive it/},
          {user.pid, ~r/NickServ.*NOTICE.*If you do not complete registration within 1 day, your nickname will expire/},
          {user.pid, ~r/NickServ.*NOTICE.*\x02#{user.nick}\x02 is now registered to \x02#{email}\x02/},
          {user.pid, ~r/NickServ.*NOTICE.*To identify in the future, type:.*/}
        ])
      end)
    end

    test "returns 'days' when value is not 1" do
      original_config = Application.get_env(:elixircd, :services)
      on_exit(fn -> Application.put_env(:elixircd, :services, original_config) end)

      nickserv_config =
        original_config[:nickserv]
        |> Keyword.put(:unverified_expire_days, 2)
        |> Keyword.put(:wait_register_time, 0)

      updated_config = Keyword.put(original_config, :nickserv, nickserv_config)

      Application.put_env(:elixircd, :services, updated_config)

      Memento.transaction!(fn ->
        user = insert(:user)
        password = "password123"
        email = "user@example.com"

        expect(Mailer, :send_verification_email, fn _, _, _ -> {:ok, %{}} end)

        assert :ok = Register.handle(user, ["REGISTER", password, email])

        assert_sent_messages([
          {user.pid,
           ~r/NickServ.*NOTICE.*An email containing nickname activation instructions has been sent to \x02#{email}\x02/},
          {user.pid, ~r/NickServ.*NOTICE.*Please check the address if you don't receive it/},
          {user.pid,
           ~r/NickServ.*NOTICE.*If you do not complete registration within 2 days, your nickname will expire/},
          {user.pid, ~r/NickServ.*NOTICE.*\x02#{user.nick}\x02 is now registered to \x02#{email}\x02/},
          {user.pid, ~r/NickServ.*NOTICE.*To identify in the future, type:.*/}
        ])
      end)
    end
  end
end
