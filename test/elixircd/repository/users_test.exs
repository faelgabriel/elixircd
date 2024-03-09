defmodule ElixIRCd.Repository.UsersTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Tables.User

  describe "create/1" do
    test "creates a new user" do
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])

      attrs = %{
        port: port,
        socket: port,
        transport: :ranch_tcp,
        pid: self()
      }

      user = Memento.transaction!(fn -> Users.create(attrs) end)

      assert user.port == port
      assert user.socket == port
      assert user.transport == :ranch_tcp
      assert user.pid == self()
    end
  end

  describe "update/2" do
    test "updates a user with new values" do
      user = insert(:user)

      attrs = %{
        nick: "testnick",
        modes: ["+i"]
      }

      updated_user = Memento.transaction!(fn -> Users.update(user, attrs) end)

      assert updated_user.nick == "testnick"
      assert updated_user.modes == ["+i"]
    end
  end

  describe "delete/1" do
    test "deletes a user" do
      user = insert(:user)

      Memento.transaction!(fn -> Users.delete(user) end)

      assert nil == Memento.transaction!(fn -> Memento.Query.read(User, user.port) end)
    end
  end

  describe "get_by_port/1" do
    test "returns a user by port" do
      user = insert(:user)

      assert {:ok, user} == Memento.transaction!(fn -> Users.get_by_port(user.port) end)
    end

    test "returns an error when the user is not found" do
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])

      assert {:error, "User not found"} == Memento.transaction!(fn -> Users.get_by_port(port) end)
    end
  end

  describe "get_by_nick/1" do
    test "returns a user by nick" do
      user = insert(:user)

      assert {:ok, user} == Memento.transaction!(fn -> Users.get_by_nick(user.nick) end)
    end

    test "returns an error when the user is not found" do
      assert {:error, "User not found"} == Memento.transaction!(fn -> Users.get_by_nick("testnick") end)
    end
  end

  describe "get_by_ports/1" do
    test "returns a list of users by ports" do
      user1 = insert(:user)
      user2 = insert(:user)

      assert [user1, user2] ==
               Memento.transaction!(fn -> Users.get_by_ports([user1.port, user2.port]) |> Enum.sort() end)
    end

    test "returns an empty list when no users are found" do
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])

      assert [] == Memento.transaction!(fn -> Users.get_by_ports([port, port]) end)
    end

    test "returns an empty list when no ports are given" do
      assert [] == Memento.transaction!(fn -> Users.get_by_ports([]) end)
    end
  end
end
