defmodule ElixIRCd.Data.Schemas.UserTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Data.Schemas.User

  alias ElixIRCd.Data.Schemas.User

  import ElixIRCd.Factory

  describe "changeset/2" do
    setup do
      user = build(:user)

      {:ok, user: user}
    end

    test "validates nicks correctly", %{user: user} do
      valid_nicks = ["ValidNick", "User_123", "TestUser", "Nick|Name", "Nick-Name"]

      Enum.each(valid_nicks, fn nick ->
        changeset = User.changeset(user, %{nick: nick})
        assert changeset.valid? == true
        assert changeset.errors[:nick] == nil
      end)

      invalid_nicks = ["Invalid!", "123start", "-notvalid", "test@user"]

      Enum.each(invalid_nicks, fn nick ->
        changeset = User.changeset(user, %{nick: nick})
        assert changeset.valid? == false
        assert changeset.errors[:nick] == {"Illegal characters", []}
      end)

      too_long_nick = "ThisNickIsTooLongForThisIRCServer"
      changeset = User.changeset(user, %{nick: too_long_nick})
      assert changeset.valid? == false
      assert changeset.errors[:nick] == {"Nickname too long", []}
    end

    test "ignores nick validation if nick is nil", %{user: user} do
      changeset = User.changeset(user, %{nick: nil})
      assert changeset.valid? == true
      assert changeset.errors[:nick] == nil
    end
  end
end
