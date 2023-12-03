defmodule ElixIRCd.Data.Schemas.UserTest do
  @moduledoc """
  Tests for the User schema module.
  """

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
    end
  end
end
