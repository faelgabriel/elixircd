defmodule ElixIRCd.Command.Mode.ChannelModesTest do
  @moduledoc false

  use ExUnit.Case

  alias ElixIRCd.Command.Mode.ChannelModes

  describe "display_modes/1" do
    test "handles empty modes" do
      modes = []

      assert "" == ChannelModes.display_modes(modes)
    end

    test "handles modes without value" do
      modes = ["n", "t", "s", "i", "m", "p"]

      assert "+ntsimp" == ChannelModes.display_modes(modes)
    end

    test "handles modes with value" do
      modes = [{"l", "10"}, {"k", "password"}, {"b", "user!@mask"}]

      assert "+lk 10 password" == ChannelModes.display_modes(modes)
    end

    test "handles modes with and without value" do
      modes = [{"l", "10"}, "n", "t", "s", "i", "m", "p", {"k", "password"}, {"b", "user!@mask"}]

      assert "+lntsimpk 10 password" == ChannelModes.display_modes(modes)
    end

    test "handles modes not displayed" do
      modes = [{"b", "user!@mask"}]

      assert "" == ChannelModes.display_modes(modes)
    end
  end

  describe "display_mode_changes/1" do
    test "handles add single mode without value" do
      mode_changes = [add: "n"]

      assert "+n" == ChannelModes.display_mode_changes(mode_changes)
    end

    test "handles remove single mode without value" do
      mode_changes = [remove: "n"]

      assert "-n" == ChannelModes.display_mode_changes(mode_changes)
    end

    test "handles add single mode with value" do
      mode_changes = [add: {"l", "10"}]

      assert "+l 10" == ChannelModes.display_mode_changes(mode_changes)
    end

    test "handles remove single mode with value" do
      mode_changes = [remove: "l"]

      assert "-l" == ChannelModes.display_mode_changes(mode_changes)
    end

    test "handles add multiple modes" do
      mode_changes = [
        {:add, {"l", "10"}},
        {:add, "n"},
        {:add, "t"},
        {:add, "s"},
        {:add, "i"},
        {:add, "m"},
        {:add, "p"},
        {:add, {"k", "password"}},
        {:add, {"b", "user!@mask"}}
      ]

      assert "+lntsimpkb 10 password user!@mask" == ChannelModes.display_mode_changes(mode_changes)
    end

    test "handles remove multiple modes" do
      mode_changes = [
        {:remove, "l"},
        {:remove, "n"},
        {:remove, "t"},
        {:remove, "s"},
        {:remove, "i"},
        {:remove, "m"},
        {:remove, "p"},
        {:remove, "k"},
        {:remove, {"b", "user!@mask"}}
      ]

      assert "-lntsimpkb user!@mask" == ChannelModes.display_mode_changes(mode_changes)
    end

    test "handles add and remove same modes" do
      mode_changes = [
        {:add, {"l", "10"}},
        {:add, "n"},
        {:add, "t"},
        {:add, "s"},
        {:add, "i"},
        {:add, "m"},
        {:add, "p"},
        {:add, {"k", "password"}},
        {:add, {"b", "user!@mask"}},
        {:remove, "l"},
        {:remove, "n"},
        {:remove, "t"},
        {:remove, "s"},
        {:remove, "i"},
        {:remove, "m"},
        {:remove, "p"},
        {:remove, "k"},
        {:remove, {"b", "user!@mask"}}
      ]

      assert "+lntsimpkb-lntsimpkb 10 password user!@mask user!@mask" == ChannelModes.display_mode_changes(mode_changes)
    end

    test "handles add and remove modes shuffled" do
      mode_changes = [
        {:remove, "n"},
        {:add, {"l", "10"}},
        {:add, "t"},
        {:remove, "s"},
        {:add, "i"},
        {:remove, "p"},
        {:add, {"k", "pass"}},
        {:remove, {"b", "user!@mask"}}
      ]

      assert "-n+lt-s+i-p+k-b 10 pass user!@mask" == ChannelModes.display_mode_changes(mode_changes)
    end
  end

  describe "parse_mode_changes/3" do
    test "handles add single mode without value" do
      current_modes = []
      mode_string = "+n"
      values = []

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == ["n"]
      assert applied_modes == [{:add, "n"}]
      assert invalid_modes == []
    end

    test "handles remove single mode without value" do
      current_modes = ["n"]
      mode_string = "-n"
      values = []

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == []
      assert applied_modes == [{:remove, "n"}]
      assert invalid_modes == []
    end

    test "handles add single mode with value" do
      current_modes = []
      mode_string = "+l"
      values = ["10"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == [{"l", "10"}]
      assert applied_modes == [{:add, {"l", "10"}}]
      assert invalid_modes == []
    end

    test "handles remove single mode with value" do
      current_modes = [{"l", "10"}]
      mode_string = "-l"
      values = []

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == []
      assert applied_modes == [{:remove, "l"}]
      assert invalid_modes == []
    end

    test "handles add multiple modes with single plus sign" do
      current_modes = []
      mode_string = "+lntsimpkb"
      values = ["10", "password", "user!@mask"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == [{"l", "10"}, "n", "t", "s", "i", "m", "p", {"k", "password"}, {"b", "user!@mask"}]

      assert applied_modes == [
               {:add, {"l", "10"}},
               {:add, "n"},
               {:add, "t"},
               {:add, "s"},
               {:add, "i"},
               {:add, "m"},
               {:add, "p"},
               {:add, {"k", "password"}},
               {:add, {"b", "user!@mask"}}
             ]

      assert invalid_modes == []
    end

    test "handles add multiple modes with multiple plus signs" do
      current_modes = []
      mode_string = "+l+n+t+s+i+m+p+k+b"
      values = ["10", "password", "user!@mask"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == [{"l", "10"}, "n", "t", "s", "i", "m", "p", {"k", "password"}, {"b", "user!@mask"}]

      assert applied_modes == [
               {:add, {"l", "10"}},
               {:add, "n"},
               {:add, "t"},
               {:add, "s"},
               {:add, "i"},
               {:add, "m"},
               {:add, "p"},
               {:add, {"k", "password"}},
               {:add, {"b", "user!@mask"}}
             ]

      assert invalid_modes == []
    end

    test "handles remove multiple modes with single minus sign" do
      current_modes = [{"l", "10"}, "n", "t", "s", "i", "m", "p", {"k", "password"}, {"b", "user!@mask"}]
      mode_string = "-lntsimpkb"
      values = ["user!@mask"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == []

      assert applied_modes == [
               {:remove, "l"},
               {:remove, "n"},
               {:remove, "t"},
               {:remove, "s"},
               {:remove, "i"},
               {:remove, "m"},
               {:remove, "p"},
               {:remove, "k"},
               {:remove, {"b", "user!@mask"}}
             ]

      assert invalid_modes == []
    end

    test "handles remove multiple modes with multiple minus signs" do
      current_modes = [{"l", "10"}, "n", "t", "s", "i", "m", "p", {"k", "password"}, {"b", "user!@mask"}]
      mode_string = "-l-n-t-s-i-m-p-k-b"
      values = ["user!@mask"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == []

      assert applied_modes == [
               {:remove, "l"},
               {:remove, "n"},
               {:remove, "t"},
               {:remove, "s"},
               {:remove, "i"},
               {:remove, "m"},
               {:remove, "p"},
               {:remove, "k"},
               {:remove, {"b", "user!@mask"}}
             ]

      assert invalid_modes == []
    end

    test "handles add and remove same modes" do
      current_modes = []
      mode_string = "+lntsimpkb-lntsimpkb"
      values = ["10", "password", "user!@mask", "user!@mask"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == []

      assert applied_modes == [
               {:add, {"l", "10"}},
               {:add, "n"},
               {:add, "t"},
               {:add, "s"},
               {:add, "i"},
               {:add, "m"},
               {:add, "p"},
               {:add, {"k", "password"}},
               {:add, {"b", "user!@mask"}},
               {:remove, "l"},
               {:remove, "n"},
               {:remove, "t"},
               {:remove, "s"},
               {:remove, "i"},
               {:remove, "m"},
               {:remove, "p"},
               {:remove, "k"},
               {:remove, {"b", "user!@mask"}}
             ]

      assert invalid_modes == []
    end

    test "handles add modes with value" do
      current_modes = []
      mode_string = "+lkbov"
      values = ["20", "newpassword", "user!@mask", "nick_operator", "nick_voice"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == [
               {"l", "20"},
               {"k", "newpassword"},
               {"b", "user!@mask"},
               {"o", "nick_operator"},
               {"v", "nick_voice"}
             ]

      assert applied_modes == [
               {:add, {"l", "20"}},
               {:add, {"k", "newpassword"}},
               {:add, {"b", "user!@mask"}},
               {:add, {"o", "nick_operator"}},
               {:add, {"v", "nick_voice"}}
             ]

      assert invalid_modes == []
    end

    test "handles replace modes with value" do
      current_modes = [{"l", "10"}, {"k", "password"}]
      mode_string = "+lk"
      values = ["20", "newpassword"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == [{"l", "20"}, {"k", "newpassword"}]
      assert applied_modes == [{:add, {"l", "20"}}, {:add, {"k", "newpassword"}}]
      assert invalid_modes == []
    end

    test "handles remove modes with value" do
      current_modes = [{"l", "10"}, {"k", "password"}, {"b", "user!@mask"}, {"o", "nick_operator"}, {"v", "nick_voice"}]
      mode_string = "-lkbov"
      values = ["user!@mask", "nick_operator", "nick_voice"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == []

      assert applied_modes == [
               {:remove, "l"},
               {:remove, "k"},
               {:remove, {"b", "user!@mask"}},
               {:remove, {"o", "nick_operator"}},
               {:remove, {"v", "nick_voice"}}
             ]

      assert invalid_modes == []
    end

    test "handles add modes ignoring exceed values" do
      current_modes = []
      mode_string = "+l"
      values = ["10", "exceed", "exceed"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == [{"l", "10"}]
      assert applied_modes == [{:add, {"l", "10"}}]
      assert invalid_modes == []
    end

    test "handles add modes with invalid modes" do
      current_modes = []
      mode_string = "+lntsimxyz"
      values = ["10"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == [{"l", "10"}, "n", "t", "s", "i", "m"]
      assert applied_modes == [{:add, {"l", "10"}}, {:add, "n"}, {:add, "t"}, {:add, "s"}, {:add, "i"}, {:add, "m"}]
      assert invalid_modes == ["x", "y", "z"]
    end

    test "handles remove modes with invalid modes" do
      current_modes = [{"l", "10"}, "n", "t", "s", "i"]
      mode_string = "-lntsixyz"
      values = []

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == []
      assert applied_modes == [{:remove, "l"}, {:remove, "n"}, {:remove, "t"}, {:remove, "s"}, {:remove, "i"}]
      assert invalid_modes == ["x", "y", "z"]
    end

    test "handles add and remove modes with invalid modes" do
      current_modes = [{"l", "10"}, "n", "m", "p", {"k", "password"}, {"b", "user!@mask"}]
      mode_string = "+l-n+t-w+m-p-k+z"
      values = ["20"]

      {new_modes, applied_modes, invalid_modes} = ChannelModes.parse_mode_changes(current_modes, mode_string, values)

      assert new_modes == [{"b", "user!@mask"}, "m", {"l", "20"}, "t"]
      assert applied_modes == [{:add, {"l", "20"}}, {:remove, "n"}, {:add, "t"}, {:remove, "p"}, {:remove, "k"}]
      assert invalid_modes == ["w", "z"]
    end
  end
end
