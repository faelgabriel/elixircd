defmodule ElixIRCd.Contexts.UserTest do
  @moduledoc false

  use ElixIRCd.DataCase
  doctest ElixIRCd.Contexts.User

  alias Ecto.Changeset
  alias ElixIRCd.Contexts.User
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas

  import ElixIRCd.Factory

  describe "create/1" do
    test "creates a user with valid attributes" do
      new_attrs = build(:user) |> Map.from_struct()

      assert {:ok, %Schemas.User{} = user} = User.create(new_attrs)
      assert user.socket == new_attrs.socket
      assert user.transport == new_attrs.transport
      assert user.nick == new_attrs.nick
      assert user.hostname == new_attrs.hostname
      assert user.username == new_attrs.username
      assert user.realname == new_attrs.realname
      assert user.identity == new_attrs.identity
    end

    test "fails to create a user with invalid attributes" do
      new_attrs = %{socket: nil, transport: nil, nick: "-invalidnick"}

      assert {:error, %Changeset{} = changeset} = User.create(new_attrs)
      assert length(changeset.errors) == 3
      assert changeset.errors[:socket] == {"can't be blank", [validation: :required]}
      assert changeset.errors[:transport] == {"can't be blank", [validation: :required]}
      assert changeset.errors[:nick] == {"Illegal characters", []}
    end
  end

  describe "update/2" do
    test "updates a user with valid attributes" do
      user = insert(:user)
      new_attrs = %{nick: "newn", hostname: "newh", username: "newu", realname: "newr", identity: "newi"}

      assert {:ok, %Schemas.User{} = updated_user} = User.update(user, new_attrs)
      assert updated_user.nick == new_attrs.nick
      assert updated_user.hostname == new_attrs.hostname
      assert updated_user.username == new_attrs.username
      assert updated_user.realname == new_attrs.realname
      assert updated_user.identity == new_attrs.identity
    end

    test "fails to update a user with invalid attributes" do
      user = insert(:user)
      new_attrs = %{socket: nil, transport: nil, nick: "-invalidnick"}

      assert {:error, %Changeset{} = changeset} = User.update(user, new_attrs)
      assert length(changeset.errors) == 3
      assert changeset.errors[:nick] == {"Illegal characters", []}
      assert changeset.errors[:socket] == {"can't be blank", [validation: :required]}
      assert changeset.errors[:transport] == {"can't be blank", [validation: :required]}
    end
  end

  describe "delete/1" do
    test "deletes a user" do
      user = insert(:user)

      assert {:ok, deleted_user} = User.delete(user)
      assert deleted_user.socket == user.socket
      assert Repo.get(Schemas.User, user.socket) == nil
    end
  end

  describe "get_by_socket/1" do
    test "gets a user by socket" do
      user = insert(:user)

      assert User.get_by_socket(user.socket) == user
    end
  end

  describe "get_by_nick/1" do
    test "gets a user by nick" do
      user = insert(:user)

      assert User.get_by_nick(user.nick) == user
    end

    test "returns nil if no user is found" do
      assert User.get_by_nick("nonexistent") == nil
    end
  end
end
