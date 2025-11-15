defmodule ElixIRCd.Commands.Mode.UserModesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Mode.UserModes

  describe "display_modes/2" do
    test "handles empty modes" do
      user = insert(:user, modes: [])
      modes = []

      assert "" == UserModes.display_modes(user, modes)
    end

    test "handles modes for regular user" do
      user = insert(:user, modes: [])
      modes = ["B", "H", "i", "w", "o", "Z"]

      # Regular user should not see "H" operator-only mode
      assert "+BiwoZ" == UserModes.display_modes(user, modes)
    end

    test "handles modes for operator user" do
      user = insert(:user, modes: ["o"])
      modes = ["B", "H", "i", "w", "o", "Z"]

      # Operator should see all modes including "H"
      assert "+BHiwoZ" == UserModes.display_modes(user, modes)
    end
  end

  describe "display_mode_changes/1" do
    test "handles add modes" do
      mode_changes = [add: "B", add: "i", add: "w"]

      assert "+Biw" == UserModes.display_mode_changes(mode_changes)
    end

    test "handles remove modes" do
      mode_changes = [remove: "B", remove: "i", remove: "w"]

      assert "-Biw" == UserModes.display_mode_changes(mode_changes)
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
      mode_string = "+iwabcd"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [{:add, "i"}, {:add, "w"}]
      assert invalid_modes == ["a", "b", "c", "d"]
    end

    test "handles remove modes with invalid modes" do
      mode_string = "-iwabcd"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [{:remove, "i"}, {:remove, "w"}]
      assert invalid_modes == ["a", "b", "c", "d"]
    end

    test "handles add and remove modes with invalid modes" do
      mode_string = "+i+w-i-wabc+wab"

      {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)

      assert validated_modes == [add: "i", add: "w", remove: "i", remove: "w", add: "w"]
      assert invalid_modes == ["a", "b", "c", "a", "b"]
    end
  end

  describe "apply_mode_changes/2" do
    test "handles add modes" do
      user = insert(:user, modes: [])
      validated_modes = [{:add, "i"}, {:add, "w"}]

      {updated_user, applied_modes, _unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == ["i", "w"]
      assert applied_modes == [{:add, "i"}, {:add, "w"}]
    end

    test "handles remove modes" do
      user = insert(:user, modes: ["i", "w"])
      validated_modes = [{:remove, "i"}, {:remove, "w"}]

      {updated_user, applied_modes, _unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == []
      assert applied_modes == [{:remove, "i"}, {:remove, "w"}]
    end

    test "handles add and remove same modes" do
      user = insert(:user, modes: [])
      validated_modes = [{:add, "i"}, {:add, "w"}, {:remove, "i"}, {:remove, "w"}]

      {updated_user, applied_modes, _unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == []
      assert applied_modes == [{:add, "i"}, {:add, "w"}, {:remove, "i"}, {:remove, "w"}]
    end

    test "handles add and remove modes shuffled" do
      user = insert(:user, modes: ["i", "w"])
      validated_modes = [{:remove, "i"}, {:add, "w"}, {:remove, "w"}, {:add, "i"}]

      {updated_user, applied_modes, _unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == ["i"]
      assert applied_modes == [{:remove, "i"}, {:remove, "w"}, {:add, "i"}]
    end

    test "handles add modes handled by the server to add" do
      user = insert(:user, modes: [])
      validated_modes = [{:add, "o"}, {:add, "Z"}]

      {updated_user, applied_modes, _unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == []
      assert applied_modes == []
    end

    test "handles remove modes handled by the server to remove" do
      user = insert(:user, modes: ["Z"])
      validated_modes = [{:remove, "Z"}]

      {updated_user, applied_modes, _unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == ["Z"]
      assert applied_modes == []
    end

    test "handles add and remove +g modes" do
      user = insert(:user, modes: [])
      validated_modes = [{:add, "g"}, {:remove, "g"}]

      {updated_user, applied_modes, _unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == []
      assert applied_modes == [{:add, "g"}, {:remove, "g"}]
    end

    test "handles operator-restricted modes when user is not an operator" do
      user = insert(:user, modes: [])
      validated_modes = [{:add, "H"}]

      {updated_user, applied_modes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == []
      assert applied_modes == []
      assert unauthorized_modes == [{:add, "H"}]
    end

    test "handles automatic H mode removal when operator mode is removed" do
      user = insert(:user, modes: ["o", "H"])
      validated_modes = [{:remove, "o"}]

      {updated_user, applied_modes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert "H" not in updated_user.modes
      assert "o" not in updated_user.modes
      assert applied_modes == [{:remove, "o"}, {:remove, "H"}]
      assert unauthorized_modes == []
    end

    test "handles automatic H mode removal when adding H mode and removing operator" do
      user = insert(:user, modes: ["o"])
      validated_modes = [{:add, "H"}, {:remove, "o"}]

      {updated_user, applied_modes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert "H" not in updated_user.modes
      assert "o" not in updated_user.modes
      assert applied_modes == [{:add, "H"}, {:remove, "o"}, {:remove, "H"}]
      assert unauthorized_modes == []
    end

    test "handles adding mode that user already has" do
      user = insert(:user, modes: ["i"])
      validated_modes = [{:add, "i"}]

      {updated_user, applied_modes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == ["i"]
      assert applied_modes == []
      assert unauthorized_modes == []
    end

    test "handles removing mode that user does not have" do
      user = insert(:user, modes: [])
      validated_modes = [{:remove, "i"}]

      {updated_user, applied_modes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == []
      assert applied_modes == []
      assert unauthorized_modes == []
    end

    test "allows removing mode +x when cloak_allow_disable is true (default)" do
      user = insert(:user, modes: ["x"])
      validated_modes = [{:remove, "x"}]

      {updated_user, applied_modes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == []
      assert applied_modes == [{:remove, "x"}]
      assert unauthorized_modes == []
    end

    test "prevents removing mode +x when cloak_allow_disable is false" do
      original_config = Application.get_env(:elixircd, :cloaking, [])
      Application.put_env(:elixircd, :cloaking, cloak_allow_disable: false)
      on_exit(fn -> Application.put_env(:elixircd, :cloaking, original_config) end)

      user = insert(:user, modes: ["x"])
      validated_modes = [{:remove, "x"}]

      {updated_user, applied_modes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == ["x"]
      assert applied_modes == []
      assert unauthorized_modes == [{:remove, "x"}]
    end

    test "allows removing other modes when cloak_allow_disable is false" do
      original_config = Application.get_env(:elixircd, :cloaking, [])
      Application.put_env(:elixircd, :cloaking, cloak_allow_disable: false)
      on_exit(fn -> Application.put_env(:elixircd, :cloaking, original_config) end)

      user = insert(:user, modes: ["i", "w", "x"])
      validated_modes = [{:remove, "i"}, {:remove, "w"}]

      {updated_user, applied_modes, unauthorized_modes} =
        Memento.transaction!(fn -> UserModes.apply_mode_changes(user, validated_modes) end)

      assert updated_user.modes == ["x"]
      assert applied_modes == [{:remove, "i"}, {:remove, "w"}]
      assert unauthorized_modes == []
    end
  end
end
