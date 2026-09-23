defmodule ElixIRCd.Commands.RegisterTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Accounts.Password
  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Jobs
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users

  test "registers the current nickname and logs the session into the account" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", capabilities: ["draft/account-registration"])

      assert :ok =
               Command.dispatch(user, %Message{
                 command: "REGISTER",
                 params: ["*", "*", "long-password"]
               })

      assert_sent_message_contains(user.pid, ~r/ REGISTER SUCCESS Alice :Account Alice has been registered/)
      assert {:ok, account} = RegisteredNicks.get_by_nickname("Alice")
      assert Argon2.verify_pass("long-password", account.password_hash)
      assert is_map(account.scram_sha_256)
      assert {:ok, updated_user} = Users.get_by_pid(user.pid)
      assert updated_user.identified_as == "Alice"
      assert :r in updated_user.modes
    end)
  end

  test "rejects custom names and registration before connection when not advertised" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", registered: true, capabilities: ["draft/account-registration"])
      custom = %Message{command: "REGISTER", params: ["Other", "*", "long-password"]}
      assert :ok = Command.dispatch(user, custom)
      assert_sent_message_contains(user.pid, ~r/ FAIL REGISTER ACCOUNT_NAME_MUST_BE_NICK Other /)
      Agent.update(@agent_name, fn _ -> [] end)

      pending = insert(:user, nick: "Pending", registered: false, capabilities: ["draft/account-registration"])
      request = %Message{command: "REGISTER", params: ["*", "*", "long-password"]}
      assert :ok = Command.dispatch(pending, request)
      assert_sent_message_contains(pending.pid, ~r/ FAIL REGISTER COMPLETE_CONNECTION_REQUIRED :/)
    end)
  end

  test "emails a verification code and authenticates only after VERIFY succeeds" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", capabilities: ["draft/account-registration"])

      assert :ok =
               Command.dispatch(user, %Message{
                 command: "REGISTER",
                 params: ["*", "alice@example.test", "long-password"]
               })

      assert_sent_message_contains(user.pid, ~r/ REGISTER VERIFICATION_REQUIRED Alice /)
      assert {:ok, pending} = RegisteredNicks.get_by_nickname("Alice")
      assert is_binary(pending.verify_code)
      assert is_nil(pending.verified_at)
      assert :error = Password.verify_and_upgrade(pending, "long-password")
      assert {:ok, still_anonymous} = Users.get_by_pid(user.pid)
      assert is_nil(still_anonymous.identified_as)

      assert Enum.any?(Jobs.get_all(), fn job ->
               job.module == ElixIRCd.Jobs.VerificationEmailDelivery and
                 job.payload["verification_code"] == pending.verify_code
             end)

      assert :ok = Command.dispatch(user, %Message{command: "VERIFY", params: ["*", "wrong"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL VERIFY INVALID_CODE Alice /)

      assert :ok = Command.dispatch(user, %Message{command: "VERIFY", params: ["*", pending.verify_code]})
      assert_sent_message_contains(user.pid, ~r/ VERIFY SUCCESS Alice /)
      assert {:ok, verified} = RegisteredNicks.get_by_nickname("Alice")
      assert is_nil(verified.verify_code)
      assert verified.verified_at
      assert {:ok, authenticated} = Users.get_by_pid(user.pid)
      assert authenticated.identified_as == "Alice"
      assert :r in authenticated.modes
    end)
  end

  test "accepts trailing password and code and reports authentication state errors" do
    original = Application.fetch_env!(:elixircd, :account_registration)
    on_exit(fn -> Application.put_env(:elixircd, :account_registration, original) end)

    Memento.transaction!(fn ->
      authenticated = insert(:user, nick: "Taken", identified_as: "Taken", capabilities: ["draft/account-registration"])

      assert :ok =
               Command.dispatch(authenticated, %Message{
                 command: "REGISTER",
                 params: ["*", "*"],
                 trailing: "long-password"
               })

      assert_sent_message_contains(authenticated.pid, ~r/ FAIL REGISTER ALREADY_AUTHENTICATED Taken /)

      assert :ok = Command.dispatch(authenticated, %Message{command: "VERIFY", params: ["*", "code"]})
      assert_sent_message_contains(authenticated.pid, ~r/ FAIL VERIFY ALREADY_AUTHENTICATED Taken /)

      user = insert(:user, nick: "Alice", capabilities: ["draft/account-registration"])
      assert :ok = Command.dispatch(user, %Message{command: "VERIFY", params: []})
      assert_sent_message_contains(user.pid, ~r/ FAIL VERIFY NEED_MORE_PARAMS \* /)

      assert :ok =
               Command.dispatch(user, %Message{
                 command: "REGISTER",
                 params: ["*", "alice@example.test"],
                 trailing: "long-password"
               })

      assert {:ok, pending} = RegisteredNicks.get_by_nickname("Alice")
      assert :ok = Command.dispatch(user, %Message{command: "VERIFY", params: ["*"], trailing: pending.verify_code})
      assert_sent_message_contains(user.pid, ~r/ VERIFY SUCCESS Alice /)

      Application.put_env(:elixircd, :account_registration, Keyword.put(original, :enabled, false))
      assert :ok = Command.dispatch(user, %Message{command: "VERIFY", params: ["*", "code"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL VERIFY REGISTRATION_DISABLED Alice /)
    end)
  end

  test "VERIFY checks the connection policy and supports advertised before-connect verification" do
    original = Application.fetch_env!(:elixircd, :account_registration)
    on_exit(fn -> Application.put_env(:elixircd, :account_registration, original) end)

    Memento.transaction!(fn ->
      insert(:registered_nick, nickname: "Pending", verify_code: "valid-code", verified_at: nil)
      user = insert(:user, nick: "Pending", registered: false, capabilities: ["draft/account-registration"])

      assert :ok = Command.dispatch(user, %Message{command: "VERIFY", params: ["*", "valid-code"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL VERIFY COMPLETE_CONNECTION_REQUIRED :/)

      Application.put_env(:elixircd, :account_registration, Keyword.put(original, :before_connect, true))
      assert :ok = Command.dispatch(user, %Message{command: "VERIFY", params: ["*", "valid-code"]})
      assert_sent_message_contains(user.pid, ~r/ VERIFY SUCCESS Pending /)
    end)
  end

  test "reports duplicate, missing, invalid identity, email, password and capability errors" do
    Memento.transaction!(fn ->
      insert(:registered_nick, nickname: "Taken", account_name: "Taken")
      taken = insert(:user, nick: "Taken", capabilities: ["draft/account-registration"])

      assert :ok = Command.dispatch(taken, %Message{command: "REGISTER", params: ["*", "*", "long-password"]})
      assert_sent_message_contains(taken.pid, ~r/ FAIL REGISTER ACCOUNT_EXISTS Taken/)

      unavailable = insert(:user, nick: "Unavailable")
      assert :ok = Command.dispatch(unavailable, %Message{command: "REGISTER", params: ["*", "*", "long-password"]})
      assert_sent_message_contains(unavailable.pid, ~r/ FAIL REGISTER REGISTRATION_DISABLED Unavailable/)

      user = insert(:user, nick: "Alice", capabilities: ["draft/account-registration"])
      assert :ok = Command.dispatch(user, %Message{command: "REGISTER", params: []})
      assert_sent_message_contains(user.pid, ~r/ FAIL REGISTER NEED_MORE_PARAMS \*/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "REGISTER", params: ["*", "invalid", "long-password"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL REGISTER INVALID_EMAIL Alice/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "REGISTER", params: ["*", "*", "short"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL REGISTER WEAK_PASSWORD Alice/)

      no_nick = insert(:user, nick: nil, registered: true, capabilities: ["draft/account-registration"])
      assert :ok = Command.dispatch(no_nick, %Message{command: "REGISTER", params: ["*", "*", "long-password"]})
      assert_sent_message_contains(no_nick.pid, ~r/ FAIL REGISTER NEED_NICK \*/)

      assert :ok = Command.dispatch(user, %Message{command: "REGISTER", params: [nil, "*", "long-password"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL REGISTER BAD_ACCOUNT_NAME \*/)
    end)
  end
end
