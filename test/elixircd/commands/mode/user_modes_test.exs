defmodule ElixIRCd.Commands.Mode.UserModesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Mode.UserModes

  describe "display_modes/1" do
    test "handles empty modes" do
      modes = []

      assert "" == UserModes.display_modes(modes)
    end

    test "handles modes" do
      modes = ["i", "w", "o", "Z"]

      assert "+iwoZ" == UserModes.display_modes(modes)
    end
  end

  describe "display_mode_changes/1" do
    test "handles add modes" do
      mode_changes = [add: "i", add: "w"]

      assert "+iw" == UserModes.display_mode_changes(mode_changes)
    end

    test "handles remove modes" do
      mode_changes = [remove: "i", remove: "w"]

      assert "-iw" == UserModes.display_mode_changes(mode_changes)
    end

    test "handles add and remove same modes" do
      mode_changes = [{:add, "i"}, {:add, "w"}, {:remove, "i"}, {:remove, "w"}]

      assert "+iw-iw" == UserModes.display_mode_changes(mode_changes)
    end

    test "handles add and remove modes shuffled" do
      mode_changes = [{:remove, "i"}, {:add, "w"}, {:remove, "w"}, {:add, "i"}]

      assert "-i+w-w+i" == UserModes.display_mode_changes(mode_changes)
    end
  end

  describe "parse_mode_changes/2" do
    test "handles mode string not starting with plus or minus" do
      mode_string = "iw"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [{:add, "i"}, {:add, "w"}]
      assert invalid_modes == []
    end

    test "handles add modes" do
      mode_string = "+iw"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [{:add, "i"}, {:add, "w"}]
      assert invalid_modes == []
    end

    test "handles remove modes" do
      mode_string = "-iw"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [{:remove, "i"}, {:remove, "w"}]
      assert invalid_modes == []
    end

    test "handles add modes with multiple plus signs" do
      mode_string = "+i+w"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [{:add, "i"}, {:add, "w"}]
      assert invalid_modes == []
    end

    test "handles remove modes with multiple plus signs" do
      mode_string = "-i-w"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [{:remove, "i"}, {:remove, "w"}]
      assert invalid_modes == []
    end

    test "handles add and remove same modes" do
      mode_string = "+i+w-i-w"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [{:add, "i"}, {:add, "w"}, {:remove, "i"}, {:remove, "w"}]
      assert invalid_modes == []
    end

    test "handles add modes with invalid modes" do
      mode_string = "+iwxyz"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [{:add, "i"}, {:add, "w"}]
      assert invalid_modes == ["x", "y", "z"]
    end

    test "handles remove modes with invalid modes" do
      mode_string = "-iwxyz"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [{:remove, "i"}, {:remove, "w"}]
      assert invalid_modes == ["x", "y", "z"]
    end

    test "handles add and remove modes with invalid modes" do
      mode_string = "+i+w-i-wxyz+wxy"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [add: "i", add: "w", remove: "i", remove: "w", add: "w"]
      assert invalid_modes == ["x", "y", "z", "x", "y"]
    end
  end

  describe "apply_mode_changes/2" do
    test "handles add modes" do
      user = insert(:user, modes: [])
      validated_modes = [{:add, "i"}, {:add, "w"}]

      {updated_user, applied_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == ["i", "w"]
      assert applied_modes == [{:add, "i"}, {:add, "w"}]
    end

    test "handles remove modes" do
      user = insert(:user, modes: ["i", "w"])
      validated_modes = [{:remove, "i"}, {:remove, "w"}]

      {updated_user, applied_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == []
      assert applied_modes == [{:remove, "i"}, {:remove, "w"}]
    end

    test "handles add and remove same modes" do
      user = insert(:user, modes: [])
      validated_modes = [{:add, "i"}, {:add, "w"}, {:remove, "i"}, {:remove, "w"}]

      {updated_user, applied_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == []
      assert applied_modes == [{:add, "i"}, {:add, "w"}, {:remove, "i"}, {:remove, "w"}]
    end

    test "handles add and remove modes shuffled" do
      user = insert(:user, modes: ["i", "w"])
      validated_modes = [{:remove, "i"}, {:add, "w"}, {:remove, "w"}, {:add, "i"}]

      {updated_user, applied_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == ["i"]
      assert applied_modes == [{:remove, "i"}, {:remove, "w"}, {:add, "i"}]
    end

    test "handles add modes handled by the server to add" do
      user = insert(:user, modes: [])
      validated_modes = [{:add, "o"}, {:add, "Z"}]

      {updated_user, applied_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == []
      assert applied_modes == []
    end

    test "handles remove modes handled by the server to remove" do
      user = insert(:user, modes: ["Z"])
      validated_modes = [{:remove, "Z"}]

      {updated_user, applied_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == ["Z"]
      assert applied_modes == []
    end
  end
end
