defmodule ElixIRCd.Tables.UserTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.User

  describe "new/1" do
    test "creates a new user with default values" do
      pid = spawn(fn -> :ok end)

      attrs = %{
        pid: pid,
        transport: :tcp
      }

      user = User.new(attrs)

      assert user.pid == pid
      assert user.transport == :tcp
      assert user.nick == nil
      assert user.hostname == nil
      assert user.ident == nil
      assert user.realname == nil
      assert user.registered == false
      assert user.modes == []
      assert user.password == nil
      assert user.away_message == nil
      assert_in_delta user.last_activity, :erlang.system_time(:second), 1
      assert user.registered_at == nil
      assert DateTime.diff(DateTime.utc_now(), user.created_at) < 1000
    end

    test "creates a new user with custom values" do
      pid = spawn(fn -> :ok end)
      time_now = :erlang.system_time(:second)
      utc_now = DateTime.utc_now()

      attrs = %{
        pid: pid,
        transport: :tcp,
        nick: "test",
        hostname: "test",
        ident: "test",
        realname: "test",
        registered: true,
        modes: [],
        password: "test",
        away_message: "test",
        last_activity: time_now,
        registered_at: utc_now,
        created_at: utc_now
      }

      user = User.new(attrs)

      assert user.pid == pid
      assert user.transport == :tcp
      assert user.nick == "test"
      assert user.hostname == "test"
      assert user.ident == "test"
      assert user.realname == "test"
      assert user.registered == true
      assert user.modes == []
      assert user.password == "test"
      assert user.away_message == "test"
      assert user.last_activity == time_now
      assert user.registered_at == utc_now
      assert user.created_at == utc_now
    end
  end

  describe "update/2" do
    test "updates a user with new values" do
      pid = spawn(fn -> :ok end)
      user = User.new(%{pid: pid, transport: :tcp})
      utc_now = DateTime.utc_now()

      updated_user =
        User.update(user, %{
          nick: "test",
          hostname: "test",
          ident: "test",
          realname: "test",
          registered: true,
          modes: [{:a, "test"}],
          password: "test",
          away_message: "test",
          last_activity: :erlang.system_time(:second),
          registered_at: utc_now
        })

      assert updated_user.pid == pid
      assert updated_user.transport == :tcp
      assert updated_user.nick == "test"
      assert updated_user.hostname == "test"
      assert updated_user.ident == "test"
      assert updated_user.realname == "test"
      assert updated_user.registered == true
      assert updated_user.modes == [{:a, "test"}]
      assert updated_user.password == "test"
      assert updated_user.away_message == "test"
      assert_in_delta updated_user.last_activity, :erlang.system_time(:second), 1
      assert updated_user.registered_at == utc_now
      assert updated_user.created_at == user.created_at
    end
  end
end
