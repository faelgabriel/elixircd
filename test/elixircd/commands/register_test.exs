defmodule ElixIRCd.Commands.RegisterTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Message
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
      assert_sent_message_contains(pending.pid, ~r/ FAIL REGISTER COMPLETE_CONNECTION_REQUIRED Pending /)
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
      assert_sent_message_contains(user.pid, ~r/ FAIL REGISTER INVALID_PASSWORD Alice/)

      no_nick = insert(:user, nick: nil, registered: true, capabilities: ["draft/account-registration"])
      assert :ok = Command.dispatch(no_nick, %Message{command: "REGISTER", params: ["*", "*", "long-password"]})
      assert_sent_message_contains(no_nick.pid, ~r/ FAIL REGISTER INVALID_ACCOUNT_NAME \*/)

      assert :ok = Command.dispatch(user, %Message{command: "REGISTER", params: [nil, "*", "long-password"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL REGISTER INVALID_ACCOUNT_NAME \*/)
    end)
  end
end
