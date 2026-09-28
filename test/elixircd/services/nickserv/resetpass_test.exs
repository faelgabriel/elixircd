defmodule ElixIRCd.Services.Nickserv.ResetpassTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias Bamboo.Mailer, as: BambooMailer
  alias ElixIRCd.Accounts.Credentials
  alias ElixIRCd.Repositories.PasswordResets
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Services.Nickserv.Resetpass
  alias ElixIRCd.Tables.PasswordReset

  test "sends one code to a verified email, rotates credentials once, and hides account existence" do
    account = insert(:registered_nick, nickname: "Owner", password: "old-password", email: "owner@example.com")
    user = insert(:user, transport: :tls)

    expect(BambooMailer, :deliver_now, fn _adapter, email, _config, _opts ->
      assert email.to == "owner@example.com"
      [code] = Regex.run(~r/RESETPASS CONFIRM Owner ([A-Za-z0-9_-]+)/, email.text_body, capture: :all_but_first)
      send(self(), {:reset_code, code})
      {:ok, email}
    end)

    assert :ok = ElixIRCd.Observability.transaction(fn -> Resetpass.handle(user, ["RESETPASS", "Owner"]) end)
    assert_received {:reset_code, code}
    assert_sent_message_contains(user.pid, ~r/If that account has a verified email/)

    assert :ok = ElixIRCd.Observability.transaction(fn -> Resetpass.handle(user, ["RESETPASS", "missing"]) end)
    assert :ok = ElixIRCd.Observability.transaction(fn -> Resetpass.handle(user, ["RESETPASS", "Owner"]) end)
    assert_sent_messages_count_containing(user.pid, ~r/If that account has a verified email/, 3)

    assert :ok =
             ElixIRCd.Observability.transaction(fn ->
               Resetpass.handle(%{user | transport: :tcp}, ["RESETPASS", "CONFIRM", "Owner", code, "new-password"])
             end)

    assert_sent_message_contains(user.pid, ~r/secure TLS connection/)

    assert :ok =
             ElixIRCd.Observability.transaction(fn ->
               Resetpass.handle(user, ["RESETPASS", "CONFIRM", "Owner", code, "new-password"])
             end)

    assert_sent_message_contains(user.pid, ~r/password has been reset/)

    Memento.transaction!(fn ->
      {:ok, changed} = RegisteredNicks.get_by_nickname(account.nickname)
      assert Argon2.verify_pass("new-password", changed.password_hash)
      assert PasswordResets.get(account.nickname) == nil
    end)

    assert :ok =
             ElixIRCd.Observability.transaction(fn ->
               Resetpass.handle(user, ["RESETPASS", "CONFIRM", "Owner", code, "again-password"])
             end)

    assert_sent_message_contains(user.pid, ~r/Invalid or expired password reset code/)
  end

  test "does not send recovery mail to an unverified account" do
    insert(:registered_nick,
      nickname: "Pending",
      verified_at: nil,
      verify_code: "pending",
      email: "pending@example.com"
    )

    user = insert(:user)
    reject(BambooMailer, :deliver_now, 4)

    assert :ok = ElixIRCd.Observability.transaction(fn -> Resetpass.handle(user, ["RESETPASS", "Pending"]) end)
    assert_sent_message_contains(user.pid, ~r/If that account has a verified email/)
  end

  test "rejects invalid confirmation parameters, short passwords, wrong codes, and missing accounts" do
    insert(:registered_nick, nickname: "Owner", email: "owner@example.com")
    user = insert(:user, transport: :tls)

    expect(BambooMailer, :deliver_now, fn _adapter, email, _config, _opts ->
      [code] = Regex.run(~r/RESETPASS CONFIRM Owner ([A-Za-z0-9_-]+)/, email.text_body, capture: :all_but_first)
      send(self(), {:reset_code, code})
      {:ok, email}
    end)

    assert :ok = run(fn -> Resetpass.handle(user, ["RESETPASS", "Owner"]) end)
    assert_received {:reset_code, code}
    assert :ok = run(fn -> Resetpass.handle(user, ["RESETPASS"]) end)
    assert_sent_message_contains(user.pid, ~r/Syntax:.*RESETPASS/)

    assert :ok = run(fn -> Resetpass.handle(user, ["RESETPASS", "CONFIRM", "Missing", code, "new-password"]) end)
    assert_sent_message_contains(user.pid, ~r/Invalid or expired password reset code/)

    assert :ok = run(fn -> Resetpass.handle(user, ["RESETPASS", "CONFIRM", "Owner", code, "x"]) end)
    assert_sent_message_contains(user.pid, ~r/new password is too short/)

    Memento.transaction!(fn ->
      assert {:error, :invalid_code} = Credentials.reset("Owner", :not_a_code, "new-password")
      assert {:error, :invalid_code} = Credentials.reset("Missing", "bad-code", "new-password")
      assert {:error, :short_password} = Credentials.reset("Missing", "bad-code", "x")
    end)
  end

  test "a failed delivery removes only its own code, and expired codes are cleaned" do
    insert(:registered_nick, nickname: "Owner", email: "owner@example.com")
    user = insert(:user)
    expect(BambooMailer, :deliver_now, fn _adapter, _email, _config, _opts -> {:error, :delivery_failed} end)

    assert :ok = run(fn -> Resetpass.handle(user, ["RESETPASS", "Owner"]) end)
    Memento.transaction!(fn -> assert PasswordResets.get("Owner") == nil end)

    now = DateTime.utc_now()
    reset = PasswordReset.new("Owner", Credentials.code_hash("code"), now, DateTime.add(now, 10))
    Memento.transaction!(fn -> PasswordResets.put(reset) end)
    assert 0 = Memento.transaction!(fn -> PasswordResets.delete_expired(now) end)
    assert 1 = Memento.transaction!(fn -> PasswordResets.delete_expired(DateTime.add(now, 11)) end)
  end

  test "a failed older delivery preserves a newer reset code" do
    insert(:registered_nick, nickname: "Owner", email: "owner@example.com")
    user = insert(:user)
    new_hash = Credentials.code_hash("newer-code")

    expect(BambooMailer, :deliver_now, fn _adapter, _email, _config, _opts ->
      now = DateTime.utc_now()
      replacement = PasswordReset.new("Owner", new_hash, now, DateTime.add(now, 1800))
      Memento.transaction!(fn -> PasswordResets.put(replacement) end)
      {:error, :delivery_failed}
    end)

    assert :ok = run(fn -> Resetpass.handle(user, ["RESETPASS", "Owner"]) end)
    Memento.transaction!(fn -> assert %{code_hash: ^new_hash} = PasswordResets.get("Owner") end)
  end

  test "an email adapter exception removes the undelivered code" do
    insert(:registered_nick, nickname: "Owner", email: "owner@example.com")
    user = insert(:user)
    expect(BambooMailer, :deliver_now, fn _adapter, _email, _config, _opts -> raise "mail unavailable" end)

    assert :ok = run(fn -> Resetpass.handle(user, ["RESETPASS", "Owner"]) end)
    assert_sent_message_contains(user.pid, ~r/If that account has a verified email/)
    Memento.transaction!(fn -> assert PasswordResets.get("Owner") == nil end)
  end

  defp run(fun), do: ElixIRCd.Observability.transaction(fun)
end
