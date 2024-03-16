defmodule ElixIRCd.Command.Mode.UserModesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Command.Mode.UserModes

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
end
