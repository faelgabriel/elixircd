defmodule ElixIRCd.Repositories.UsersTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.User

  describe "create/1" do
    test "creates a new user" do
      pid = spawn(fn -> :ok end)

      attrs = %{
        pid: pid,
        transport: :tcp
      }

      user = Memento.transaction!(fn -> Users.create(attrs) end)

      assert user.pid == pid
      assert user.transport == :tcp
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

      assert nil == Memento.transaction!(fn -> Memento.Query.read(User, user.pid) end)
    end
  end

  describe "get_by_pid/1" do
    test "returns a user by pid" do
      user = insert(:user)

      assert {:ok, user} == Memento.transaction!(fn -> Users.get_by_pid(user.pid) end)
    end

    test "returns an error when the user is not found" do
      pid = spawn(fn -> :ok end)

      assert {:error, :user_not_found} == Memento.transaction!(fn -> Users.get_by_pid(pid) end)
    end
  end

  describe "get_by_nick/1" do
    test "returns a user by nick" do
      user = insert(:user)

      assert {:ok, user} == Memento.transaction!(fn -> Users.get_by_nick(user.nick) end)
    end

    test "returns an error when the user is not found" do
      assert {:error, :user_not_found} == Memento.transaction!(fn -> Users.get_by_nick("testnick") end)
    end
  end

  describe "get_by_nick_key/1" do
    test "returns a user by nick_key" do
      user = insert(:user)

      assert {:ok, user} == Memento.transaction!(fn -> Users.get_by_nick_key(user.nick_key) end)
    end

    test "returns an error when the user is not found" do
      assert {:error, :user_not_found} == Memento.transaction!(fn -> Users.get_by_nick_key("testnick") end)
    end
  end

  describe "get_by_pids/1" do
    test "returns a list of users by pids" do
      user1 = insert(:user)
      user2 = insert(:user)

      assert [user1, user2] ==
               Memento.transaction!(fn -> Users.get_by_pids([user1.pid, user2.pid]) |> Enum.sort() end)
    end

    test "returns an empty list when no users are found" do
      pid = spawn(fn -> :ok end)

      assert [] == Memento.transaction!(fn -> Users.get_by_pids([pid, pid]) end)
    end

    test "returns an empty list when no pids are given" do
      assert [] == Memento.transaction!(fn -> Users.get_by_pids([]) end)
    end
  end

  describe "get_by_match_mask/1" do
    test "returns a list of users that match the mask" do
      insert(:user, hostname: "any")
      user = insert(:user, hostname: "host")

      assert [user] == Memento.transaction!(fn -> Users.get_by_match_mask("*!*@host") end)
    end
  end

  describe "get_by_mode/1" do
    test "returns a list of users by mode" do
      user1 = insert(:user, modes: ["i"])
      _user2 = insert(:user, modes: ["o"])

      assert [user1] == Memento.transaction!(fn -> Users.get_by_mode("i") end)
    end
  end

  describe "count_all/0" do
    test "returns the total number of users" do
      insert(:user)
      insert(:user)

      assert 2 == Memento.transaction!(fn -> Users.count_all() end)
    end
  end

  describe "count_all_states/0" do
    test "returns the total number of users in each state" do
      insert(:user, registered: true, modes: [])
      insert(:user, registered: true, modes: ["i"])
      insert(:user, registered: true, modes: ["o"])
      insert(:user, registered: false)

      assert %{
               visible: 2,
               invisible: 1,
               operators: 1,
               unknown: 1,
               total: 4
             } ==
               Memento.transaction!(fn -> Users.count_all_states() end)
    end
  end
end
