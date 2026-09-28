defmodule ElixIRCd.Operators.SessionsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Oper
  alias ElixIRCd.Message
  alias ElixIRCd.Operators
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Utils.Protocol

  setup do
    original = Application.fetch_env!(:elixircd, :operators)
    Application.put_env(:elixircd, :operators, [])
    on_exit(fn -> Application.put_env(:elixircd, :operators, original) end)
    :ok
  end

  test "disabling a database operator revokes active privileges and clears stale provenance" do
    hash = Argon2.hash_pwd_salt("a-long-password")
    assert :ok = Operators.Management.add("managed", hash)
    user = insert(:user)

    assert :ok =
             Memento.transaction!(fn ->
               Oper.handle(user, %Message{command: "OPER", params: ["managed", "a-long-password"]})
             end)

    spectator = insert(:user)

    Memento.transaction!(fn ->
      Users.update(spectator, %{oper_source: :database, oper_name: "managed"})
    end)

    assert :ok = Operators.Management.disable("managed")
    assert {:ok, revoked} = Memento.transaction!(fn -> Users.get_by_pid(user.pid) end)
    refute Protocol.irc_operator?(revoked)
    assert revoked.oper_source == nil
    assert revoked.oper_name == nil
    assert_sent_message_contains(user.pid, ~r/MODE .* -o/)
    assert {:ok, cleared} = Memento.transaction!(fn -> Users.get_by_pid(spectator.pid) end)
    assert cleared.oper_name == nil

    assert :ok = Operators.Management.enable("managed")
    refute Protocol.irc_operator?(revoked)
  end

  test "removing a file operator revokes its active sessions" do
    hash = Argon2.hash_pwd_salt("a-long-password")
    Application.put_env(:elixircd, :operators, [{"file", hash}])
    user = insert(:user)

    assert :ok =
             Memento.transaction!(fn ->
               Oper.handle(user, %Message{command: "OPER", params: ["file", "a-long-password"]})
             end)

    assert {:ok, active} = Memento.transaction!(fn -> Users.get_by_pid(user.pid) end)
    assert active.oper_source == :config
    assert Protocol.irc_operator?(active)

    Application.put_env(:elixircd, :operators, [])
    assert :ok = Operators.Sessions.revoke_changed_config([{"file", hash}], [])
    assert {:ok, revoked} = Memento.transaction!(fn -> Users.get_by_pid(user.pid) end)
    refute Protocol.irc_operator?(revoked)
    assert revoked.oper_name == nil
    assert_sent_message_contains(user.pid, ~r/MODE .* -o/)
  end

  test "file revocation waits for an in-flight OPER transaction" do
    hash = Argon2.hash_pwd_salt("a-long-password")
    Application.put_env(:elixircd, :operators, [{"file", hash}])
    user = insert(:user)
    parent = self()

    authentication =
      Task.async(fn ->
        Memento.transaction!(fn ->
          assert :ok = Oper.handle(user, %Message{command: "OPER", params: ["file", "a-long-password"]})
          send(parent, :oper_authenticated)
          assert_receive :finish_oper, 5_000
        end)
      end)

    assert_receive :oper_authenticated, 5_000
    Application.put_env(:elixircd, :operators, [])

    revocation =
      Task.async(fn ->
        send(parent, :revocation_started)
        Operators.Sessions.revoke_changed_config([{"file", hash}], [])
      end)

    assert_receive :revocation_started, 5_000
    assert Task.yield(revocation, 100) == nil
    send(authentication.pid, :finish_oper)
    assert :finish_oper == Task.await(authentication, 5_000)
    assert :ok == Task.await(revocation, 5_000)

    assert {:ok, revoked} = Memento.transaction!(fn -> Users.get_by_pid(user.pid) end)
    refute Protocol.irc_operator?(revoked)
    assert revoked.oper_name == nil
  end
end
