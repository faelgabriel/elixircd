defmodule ElixIRCd.Services.Nickserv.RegisterTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Register
  alias ElixIRCd.Utils.Mailer

  setup :verify_on_exit!

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

        Mailer
        |> expect(:send_verification_email, fn _email_address, _nickname, _verify_code ->
          send(self(), {:mailer, :send_verification_email})
          {:ok, %{}}
        end)

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

        Mailer
        |> expect(:send_verification_email, fn _email_address, _nickname, _verify_code ->
          send(self(), {:mailer, :send_verification_email})
          {:ok, %{}}
        end)

        assert :ok = Register.handle(user, ["REGISTER", "password123", invalid_email])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Invalid email address. Please provide a valid email address.\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*Syntax: \x02REGISTER.*/}
        ])
      end)
    end

    test "handles REGISTER command when email is required but not provided" do
      # Temporarily override the application config
      original_config = Application.get_env(:elixircd, :services)[:nickserv][:email_required]

      on_exit(fn ->
        # Reset the config after the test
        new_config =
          Keyword.put(Application.get_env(:elixircd, :services)[:nickserv] || [], :email_required, original_config)

        Application.put_env(:elixircd, :services, nickserv: new_config)
      end)

      # Set email as required for this test
      new_config = Keyword.put(Application.get_env(:elixircd, :services)[:nickserv] || [], :email_required, true)
      Application.put_env(:elixircd, :services, nickserv: new_config)

      Memento.transaction!(fn ->
        user = insert(:user)

        Mailer
        |> expect(:send_verification_email, fn _email_address, _nickname, _verify_code ->
          send(self(), {:mailer, :send_verification_email})
          {:ok, %{}}
        end)

        assert :ok = Register.handle(user, ["REGISTER", "password123"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You must provide an email address to register a nickname.\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*Syntax: \x02REGISTER.*/}
        ])
      end)
    end

    test "handles REGISTER command when wait time is required but not met" do
      # Temporarily override the application config
      original_config = Application.get_env(:elixircd, :services)[:nickserv][:wait_register_time]

      on_exit(fn ->
        # Reset the config after the test
        new_config =
          Keyword.put(Application.get_env(:elixircd, :services)[:nickserv] || [], :wait_register_time, original_config)

        Application.put_env(:elixircd, :services, nickserv: new_config)
      end)

      # Set wait time to 60 seconds for this test
      new_config = Keyword.put(Application.get_env(:elixircd, :services)[:nickserv] || [], :wait_register_time, 60)
      Application.put_env(:elixircd, :services, nickserv: new_config)

      Memento.transaction!(fn ->
        user = insert(:user, created_at: DateTime.utc_now())

        Mailer
        |> expect(:send_verification_email, fn _email_address, _nickname, _verify_code ->
          send(self(), {:mailer, :send_verification_email})
          {:ok, %{}}
        end)

        assert :ok = Register.handle(user, ["REGISTER", "password123", "email@example.com"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You must be connected for at least 60 seconds before you can register.\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*Please wait.*more seconds and try again.*/}
        ])
      end)
    end

    test "successfully registers a nickname without email" do
      # Temporarily override the application config for wait time
      original_config = Application.get_env(:elixircd, :services)[:nickserv][:wait_register_time]

      on_exit(fn ->
        # Reset the config after the test
        new_config =
          Keyword.put(Application.get_env(:elixircd, :services)[:nickserv] || [], :wait_register_time, original_config)

        Application.put_env(:elixircd, :services, nickserv: new_config)
      end)

      # Set wait time to 0 seconds for this test
      new_config = Keyword.put(Application.get_env(:elixircd, :services)[:nickserv] || [], :wait_register_time, 0)
      Application.put_env(:elixircd, :services, nickserv: new_config)

      # Create test data
      user = insert(:user, created_at: DateTime.add(DateTime.utc_now(), -3600))
      password = "password123"

      # Mock RegisteredNicks to return a registered nick after create
      mock_registered_nick = %ElixIRCd.Tables.RegisteredNick{
        nickname: user.nick,
        password_hash: Pbkdf2.hash_pwd_salt(password),
        email: nil,
        registered_by: "#{user.nick}!#{user.ident}@#{user.hostname}",
        verify_code: nil,
        verified_at: nil,
        last_seen_at: DateTime.utc_now(),
        reserved_until: nil,
        settings: ElixIRCd.Tables.RegisteredNick.Settings.new(),
        created_at: DateTime.utc_now()
      }

      RegisteredNicks
      |> expect(:get_by_nickname, fn nick ->
        if nick == user.nick, do: {:error, :registered_nick_not_found}, else: {:error, :registered_nick_not_found}
      end)

      RegisteredNicks
      |> expect(:create, fn _params -> mock_registered_nick end)

      Users
      |> expect(:update, fn _user, params ->
        Map.merge(user, params)
      end)

      # Call the function
      :ok = Register.handle(user, ["REGISTER", password])

      # Verify the messages sent to the user
      assert_sent_messages([
        {user.pid,
         ":NickServ!service@irc.test NOTICE #{user.nick} :Your nickname has been successfully registered.\r\n"},
        {user.pid,
         ":NickServ!service@irc.test NOTICE #{user.nick} :You are now identified for \x02#{user.nick}\x02.\r\n"},
        {user.pid, ~r/NickServ.*NOTICE.*To identify in the future, type:.*/}
      ])
    end

    test "successfully registers a nickname with email" do
      # Temporarily override the application config for wait time and unverified expiration
      original_wait_time = Application.get_env(:elixircd, :services)[:nickserv][:wait_register_time]
      original_unverified_expiration_days = Application.get_env(:elixircd, :services)[:nickserv][:unverified_expiration_days]

      on_exit(fn ->
        # Reset the config after the test
        new_config =
          Application.get_env(:elixircd, :services)[:nickserv]
          |> Keyword.put(:wait_register_time, original_wait_time)
          |> Keyword.put(:unverified_expiration_days, original_unverified_expiration_days)

        Application.put_env(:elixircd, :services, nickserv: new_config)
      end)

      # Set wait time to 0 seconds and unverified expiration to 30 days for this test
      new_config =
        Application.get_env(:elixircd, :services)[:nickserv]
        |> Keyword.put(:wait_register_time, 0)
        |> Keyword.put(:unverified_expiration_days, 30)

      Application.put_env(:elixircd, :services, nickserv: new_config)

      # Create test data
      user = insert(:user, created_at: DateTime.add(DateTime.utc_now(), -3600))
      password = "password123"
      email = "user@example.com"
      verify_code = "123456"

      # Mock RegisteredNicks to return a registered nick after create
      mock_registered_nick = %ElixIRCd.Tables.RegisteredNick{
        nickname: user.nick,
        password_hash: Pbkdf2.hash_pwd_salt(password),
        email: email,
        registered_by: "#{user.nick}!#{user.ident}@#{user.hostname}",
        verify_code: verify_code,
        verified_at: nil,
        last_seen_at: DateTime.utc_now(),
        reserved_until: nil,
        settings: ElixIRCd.Tables.RegisteredNick.Settings.new(),
        created_at: DateTime.utc_now()
      }

      RegisteredNicks
      |> expect(:get_by_nickname, fn nick ->
        if nick == user.nick, do: {:error, :registered_nick_not_found}, else: {:error, :registered_nick_not_found}
      end)

      RegisteredNicks
      |> expect(:create, fn params ->
        assert params[:email] == email
        # Return the mock with the matching verify_code
        %{mock_registered_nick | verify_code: params[:verify_code]}
      end)

      Users
      |> expect(:update, fn _user, params ->
        Map.merge(user, params)
      end)

      Mailer
      |> expect(:send_verification_email, fn email_address, nickname, code ->
        assert email_address == email
        assert nickname == user.nick
        assert is_binary(code) && String.length(code) == 6
        send(self(), {:mailer, :send_verification_email})
        {:ok, %{}}
      end)

      # Call the function
      :ok = Register.handle(user, ["REGISTER", password, email])

      # Check that the mailer was called
      assert_received({:mailer, :send_verification_email})

      # Verify the messages sent to the user
      assert_sent_messages([
        {user.pid,
         ":NickServ!service@irc.test NOTICE #{user.nick} :Your nickname has been successfully registered.\r\n"},
        {user.pid,
         ":NickServ!service@irc.test NOTICE #{user.nick} :You are now identified for \x02#{user.nick}\x02.\r\n"},
        {user.pid, ~r/NickServ.*NOTICE.*A verification email has been sent to.*/},
        {user.pid, ~r/NickServ.*NOTICE.*Please check your email and follow the instructions.*/},
        {user.pid, ~r/NickServ.*NOTICE.*You have 30 days to verify your email address.*/},
        {user.pid, ~r/NickServ.*NOTICE.*To identify in the future, type:.*/}
      ])
    end
  end
end
