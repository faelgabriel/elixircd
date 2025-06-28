defmodule ElixIRCd.Commands.Mode.UserModesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Mode.UserModes

  describe "parse_mode_changes/2" do
    test "parses basic mode changes without parameters" do
      {validated_modes, invalid_modes} = UserModes.parse_mode_changes("+i", [])

      assert validated_modes == [{:add, "i"}]
      assert invalid_modes == []
    end

    test "parses snomask mode changes with parameters" do
      {validated_modes, invalid_modes} = UserModes.parse_mode_changes("+s", ["ck"])

      assert validated_modes == [{:add, {"s", "ck"}}]
      assert invalid_modes == []
    end

    test "parses complex snomask parameters with +/- prefixes" do
      {validated_modes, invalid_modes} = UserModes.parse_mode_changes("+s", ["+ck-k+f"])

      assert validated_modes == [{:add, {"s", "cf"}}]
      assert invalid_modes == []
    end

    test "filters invalid snomask letters" do
      {validated_modes, invalid_modes} = UserModes.parse_mode_changes("+s", ["xyz"])

      assert validated_modes == [{:add, {"s", "x"}}]  # Only 'x' is valid from the allowed letters
      assert invalid_modes == []
    end

    test "returns nil parameter for empty snomask result" do
      {validated_modes, invalid_modes} = UserModes.parse_mode_changes("+s", ["zzz"])

      # All invalid letters should result in no mode change
      assert validated_modes == []
      assert invalid_modes == []
    end

    test "parses multiple mode changes" do
      {validated_modes, invalid_modes} = UserModes.parse_mode_changes("+is-w", ["ck"])

      assert validated_modes == [{:add, "i"}, {:add, {"s", "ck"}}, {:remove, "w"}]
      assert invalid_modes == []
    end

    test "handles invalid modes" do
      {validated_modes, invalid_modes} = UserModes.parse_mode_changes("+xyz", [])

      assert validated_modes == []
      assert invalid_modes == ["x", "y", "z"]
    end
  end

  describe "apply_mode_changes/2" do
    test "applies basic mode changes for regular user" do
      user = insert(:user, modes: [])

      {updated_user, applied_changes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, [{:add, "i"}]) end)

      assert updated_user.modes == ["i"]
      assert applied_changes == [{:add, "i"}]
      assert unauthorized_modes == []
    end

    test "applies snomask mode for operator" do
      user = insert(:user, modes: ["o"])

      {updated_user, applied_changes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, [{:add, {"s", "ck"}}]) end)

      assert updated_user.modes == ["o", {"s", "ck"}]
      assert applied_changes == [{:add, {"s", "ck"}}]
      assert unauthorized_modes == []
    end

    test "rejects snomask mode for non-operator" do
      user = insert(:user, modes: [])

      {updated_user, applied_changes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, [{:add, {"s", "ck"}}]) end)

      assert updated_user.modes == []
      assert applied_changes == []
      assert unauthorized_modes == [{:add, {"s", "ck"}}]
    end

    test "replaces existing snomask with new value" do
      user = insert(:user, modes: ["o", {"s", "ck"}])

      {updated_user, applied_changes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, [{:add, {"s", "fo"}}]) end)

      assert updated_user.modes == ["o", {"s", "fo"}]
      assert applied_changes == [{:add, {"s", "fo"}}]
      assert unauthorized_modes == []
    end

    test "removes snomask mode" do
      user = insert(:user, modes: ["o", {"s", "ck"}])

      {updated_user, applied_changes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, [{:remove, {"s", "ck"}}]) end)

      assert updated_user.modes == ["o"]
      assert applied_changes == [{:remove, {"s", "ck"}}]
      assert unauthorized_modes == []
    end

    test "removes H mode when operator mode is removed" do
      user = insert(:user, modes: ["o", "H"])

      {updated_user, applied_changes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, [{:remove, "o"}]) end)

      assert "H" not in updated_user.modes
      assert "o" not in updated_user.modes
      assert applied_changes == [{:remove, "o"}, {:remove, "H"}]
      assert unauthorized_modes == []
    end
  end

  describe "display_modes/2" do
    test "displays basic modes" do
      user = insert(:user, modes: ["i", "w"])

      result = UserModes.display_modes(user, user.modes)

      assert result == "+iw"
    end

    test "displays snomask mode for operator" do
      user = insert(:user, modes: ["o", {"s", "ck"}])

      result = UserModes.display_modes(user, user.modes)

      assert result == "+s=ck"
    end

    test "filters operator-only modes for non-operator" do
      user = insert(:user, modes: ["i", "w"])

      result = UserModes.display_modes(user, ["i", "H", "w"])

      assert result == "+iw"
    end

    test "shows operator-only modes for operator" do
      user = insert(:user, modes: ["o", "H"])

      result = UserModes.display_modes(user, user.modes)

      assert result == "+oH"
    end
  end

  describe "display_mode_changes/1" do
    test "displays basic mode changes" do
      result = UserModes.display_mode_changes([{:add, "i"}, {:remove, "w"}])

      assert result == "+i-w"
    end

    test "displays snomask mode changes" do
      result = UserModes.display_mode_changes([{:add, {"s", "ck"}}])

      assert result == "+s ck"
    end

    test "displays mixed mode changes" do
      result = UserModes.display_mode_changes([{:add, {"s", "ck"}}, {:add, "i"}, {:remove, "w"}])

      assert result == "+si-w ck"
    end
  end

  describe "get_users_with_snomask/1" do
    test "finds users with specific snomask" do
      user1 = insert(:user, modes: ["o", {"s", "ck"}])
      user2 = insert(:user, modes: ["o", {"s", "fo"}])
      user3 = insert(:user, modes: ["i"])

      result = Memento.transaction!(fn -> UserModes.get_users_with_snomask("c") end)

      user_pids = Enum.map(result, & &1.pid)
      assert user1.pid in user_pids
      assert user2.pid not in user_pids
      assert user3.pid not in user_pids
    end

    test "returns empty list when no users have snomask" do
      insert(:user, modes: ["i"])
      insert(:user, modes: ["o"])

      result = Memento.transaction!(fn -> UserModes.get_users_with_snomask("c") end)

      assert result == []
    end
  end

  describe "snomask normalization" do
    test "normalizes snomask parameter correctly" do
      # This tests the internal normalize_snomask_param function indirectly
      {validated_modes, _} = UserModes.parse_mode_changes("+s", ["+ck-k+f"])

      assert validated_modes == [{:add, {"s", "cf"}}]
    end

    test "handles duplicate snomask letters" do
      {validated_modes, _} = UserModes.parse_mode_changes("+s", ["cckkff"])

      assert validated_modes == [{:add, {"s", "cfk"}}]  # Should be sorted and unique
    end

    test "handles empty result after normalization" do
      {validated_modes, _} = UserModes.parse_mode_changes("+s", ["+c-c"])

      # Adding and removing the same snomask should result in empty
      assert validated_modes == []
    end
  end
end
