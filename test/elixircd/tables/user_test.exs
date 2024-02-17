defmodule ElixIRCd.Tables.UserTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.User

  describe "new/1" do
    test "creates a new user with default values" do
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])

      attrs = %{
        port: port,
        socket: port,
        transport: :ranch_tcp,
        pid: self()
      }

      user = User.new(attrs)

      assert user.port == port
      assert user.socket == port
      assert user.transport == :ranch_tcp
      assert user.pid == self()
      assert user.nick == nil
      assert user.hostname == nil
      assert user.username == nil
      assert user.realname == nil
      assert user.identity == nil
      assert user.modes == []
      assert DateTime.diff(DateTime.utc_now(), user.created_at) < 1000
    end

    test "creates a new user with custom values" do
      utc_now = DateTime.utc_now()
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])

      attrs = %{
        port: port,
        socket: port,
        transport: :ranch_tcp,
        pid: self(),
        nick: "test",
        hostname: "test",
        username: "test",
        realname: "test",
        identity: "test",
        modes: [],
        created_at: utc_now
      }

      user = User.new(attrs)

      assert user.port == port
      assert user.socket == port
      assert user.transport == :ranch_tcp
      assert user.pid == self()
      assert user.nick == "test"
      assert user.hostname == "test"
      assert user.username == "test"
      assert user.realname == "test"
      assert user.identity == "test"
      assert user.modes == []
      assert user.created_at == utc_now
    end
  end

  describe "update/2" do
    test "updates a user with new values" do
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])
      user = User.new(%{port: port, socket: port, transport: :ranch_tcp, pid: self()})

      updated_user =
        User.update(user, %{
          nick: "test",
          hostname: "test",
          username: "test",
          realname: "test",
          identity: "test",
          modes: [{:a, "test"}]
        })

      assert updated_user.port == port
      assert updated_user.socket == port
      assert updated_user.transport == :ranch_tcp
      assert updated_user.pid == self()
      assert updated_user.nick == "test"
      assert updated_user.hostname == "test"
      assert updated_user.username == "test"
      assert updated_user.realname == "test"
      assert updated_user.identity == "test"
      assert updated_user.modes == [{:a, "test"}]
      assert updated_user.created_at == user.created_at
    end
  end
end
