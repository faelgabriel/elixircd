defmodule ElixIRCd.Command.Mode.ChannelModesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [build_user_mask: 1]

  alias ElixIRCd.Command.Mode.ChannelModes
  alias ElixIRCd.Repository.ChannelBans
  alias ElixIRCd.Repository.UserChannels

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
      modes = [{"l", "10"}, {"k", "password"}]

      assert "+lk 10 password" == ChannelModes.display_modes(modes)
    end

    test "handles modes with and without value" do
      modes = [{"l", "10"}, "n", "t", "s", "i", "m", "p", {"k", "password"}]

      assert "+lntsimpk 10 password" == ChannelModes.display_modes(modes)
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
        {:add, {"b", "nick!*@mask"}}
      ]

      assert "+lntsimpkb 10 password nick!*@mask" == ChannelModes.display_mode_changes(mode_changes)
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
        {:remove, {"b", "nick!*@mask"}}
      ]

      assert "-lntsimpkb nick!*@mask" == ChannelModes.display_mode_changes(mode_changes)
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
        {:add, {"b", "nick!*@mask"}},
        {:remove, "l"},
        {:remove, "n"},
        {:remove, "t"},
        {:remove, "s"},
        {:remove, "i"},
        {:remove, "m"},
        {:remove, "p"},
        {:remove, "k"},
        {:remove, {"b", "nick!*@mask"}}
      ]

      assert "+lntsimpkb-lntsimpkb 10 password nick!*@mask nick!*@mask" ==
               ChannelModes.display_mode_changes(mode_changes)
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
        {:remove, {"b", "nick!*@mask"}}
      ]

      assert "-n+lt-s+i-p+k-b 10 pass nick!*@mask" == ChannelModes.display_mode_changes(mode_changes)
    end
  end

  describe "parse_mode_changes/2" do
    test "handles mode string not starting with plus or minus" do
      mode_string = "lnt"
      values = ["10"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [{:add, {"l", "10"}}, {:add, "n"}, {:add, "t"}]
      assert invalid_modes == []
    end

    test "handles add single mode without value" do
      mode_string = "+n"
      values = []

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [{:add, "n"}]
      assert invalid_modes == []
    end

    test "handles remove single mode without value" do
      mode_string = "-n"
      values = []

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [{:remove, "n"}]
      assert invalid_modes == []
    end

    test "handles add single mode with value" do
      mode_string = "+l"
      values = ["10"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [{:add, {"l", "10"}}]
      assert invalid_modes == []
    end

    test "handles remove single mode with value" do
      mode_string = "-l"
      values = []

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [{:remove, "l"}]
      assert invalid_modes == []
    end

    test "handles add multiple modes with single plus sign" do
      mode_string = "+lntsimpkb"
      values = ["10", "password", "nick!*@mask"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [
               {:add, {"l", "10"}},
               {:add, "n"},
               {:add, "t"},
               {:add, "s"},
               {:add, "i"},
               {:add, "m"},
               {:add, "p"},
               {:add, {"k", "password"}},
               {:add, {"b", "nick!*@mask"}}
             ]

      assert invalid_modes == []
    end

    test "handles add multiple modes with multiple plus signs" do
      mode_string = "+l+n+t+s+i+m+p+k+b"
      values = ["10", "password", "nick!*@mask"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [
               {:add, {"l", "10"}},
               {:add, "n"},
               {:add, "t"},
               {:add, "s"},
               {:add, "i"},
               {:add, "m"},
               {:add, "p"},
               {:add, {"k", "password"}},
               {:add, {"b", "nick!*@mask"}}
             ]

      assert invalid_modes == []
    end

    test "handles remove multiple modes with single minus sign" do
      mode_string = "-lntsimpkb"
      values = ["nick!*@mask"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [
               {:remove, "l"},
               {:remove, "n"},
               {:remove, "t"},
               {:remove, "s"},
               {:remove, "i"},
               {:remove, "m"},
               {:remove, "p"},
               {:remove, "k"},
               {:remove, {"b", "nick!*@mask"}}
             ]

      assert invalid_modes == []
    end

    test "handles remove multiple modes with multiple minus signs" do
      mode_string = "-l-n-t-s-i-m-p-k-b"
      values = ["nick!*@mask"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [
               {:remove, "l"},
               {:remove, "n"},
               {:remove, "t"},
               {:remove, "s"},
               {:remove, "i"},
               {:remove, "m"},
               {:remove, "p"},
               {:remove, "k"},
               {:remove, {"b", "nick!*@mask"}}
             ]

      assert invalid_modes == []
    end

    test "handles add and remove same modes" do
      mode_string = "+lntsimpkb-lntsimpkb"
      values = ["10", "password", "nick!*@mask", "nick!*@mask"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [
               {:add, {"l", "10"}},
               {:add, "n"},
               {:add, "t"},
               {:add, "s"},
               {:add, "i"},
               {:add, "m"},
               {:add, "p"},
               {:add, {"k", "password"}},
               {:add, {"b", "nick!*@mask"}},
               {:remove, "l"},
               {:remove, "n"},
               {:remove, "t"},
               {:remove, "s"},
               {:remove, "i"},
               {:remove, "m"},
               {:remove, "p"},
               {:remove, "k"},
               {:remove, {"b", "nick!*@mask"}}
             ]

      assert invalid_modes == []
    end

    test "handles add modes with value" do
      mode_string = "+lkbov"
      values = ["20", "newpassword", "nick!*@mask", "nick_operator", "nick_voice"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [
               {:add, {"l", "20"}},
               {:add, {"k", "newpassword"}},
               {:add, {"b", "nick!*@mask"}},
               {:add, {"o", "nick_operator"}},
               {:add, {"v", "nick_voice"}}
             ]

      assert invalid_modes == []
    end

    test "handles replace modes with value" do
      mode_string = "+lk"
      values = ["20", "newpassword"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [{:add, {"l", "20"}}, {:add, {"k", "newpassword"}}]
      assert invalid_modes == []
    end

    test "handles remove modes with value" do
      mode_string = "-lkbov"
      values = ["nick!*@mask", "nick_operator", "nick_voice"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [
               {:remove, "l"},
               {:remove, "k"},
               {:remove, {"b", "nick!*@mask"}},
               {:remove, {"o", "nick_operator"}},
               {:remove, {"v", "nick_voice"}}
             ]

      assert invalid_modes == []
    end

    test "handles add modes ignoring exceed values" do
      mode_string = "+l"
      values = ["10", "exceed", "exceed"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [{:add, {"l", "10"}}]
      assert invalid_modes == []
    end

    test "handles add modes with invalid modes" do
      mode_string = "+lntsimxyz"
      values = ["10"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [{:add, {"l", "10"}}, {:add, "n"}, {:add, "t"}, {:add, "s"}, {:add, "i"}, {:add, "m"}]
      assert invalid_modes == ["x", "y", "z"]
    end

    test "handles remove modes with invalid modes" do
      mode_string = "-lntsixyz"
      values = []

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [{:remove, "l"}, {:remove, "n"}, {:remove, "t"}, {:remove, "s"}, {:remove, "i"}]
      assert invalid_modes == ["x", "y", "z"]
    end

    test "handles add and remove modes with invalid modes" do
      mode_string = "+l-n+t-w+m-p-k+z"
      values = ["20"]

      {validated_modes, invalid_modes} = ChannelModes.parse_mode_changes(mode_string, values)

      assert validated_modes == [
               {:add, {"l", "20"}},
               {:remove, "n"},
               {:add, "t"},
               {:add, "m"},
               {:remove, "p"},
               {:remove, "k"}
             ]

      assert invalid_modes == ["w", "z"]
    end
  end

  describe "filter_mode_changes/1" do
    test "handles empty modes" do
      mode_changes = []

      {filtered_modes, listing_modes, missing_value_modes} = ChannelModes.filter_mode_changes(mode_changes)

      assert filtered_modes == []
      assert listing_modes == []
      assert missing_value_modes == []
    end

    test "handles modes without value" do
      mode_changes = [add: "n", remove: "t"]

      {filtered_modes, listing_modes, missing_value_modes} = ChannelModes.filter_mode_changes(mode_changes)

      assert filtered_modes == [{:add, "n"}, {:remove, "t"}]
      assert listing_modes == []
      assert missing_value_modes == []
    end

    test "handles modes with value" do
      mode_changes = [add: {"l", "10"}, remove: {"k", "password"}]

      {filtered_modes, listing_modes, missing_value_modes} = ChannelModes.filter_mode_changes(mode_changes)

      assert filtered_modes == [{:add, {"l", "10"}}, {:remove, {"k", "password"}}]
      assert listing_modes == []
      assert missing_value_modes == []
    end

    test "handles modes with and without value" do
      mode_changes = [add: {"l", "10"}, add: "n", remove: "t", remove: {"k", "password"}]

      {filtered_modes, listing_modes, missing_value_modes} = ChannelModes.filter_mode_changes(mode_changes)

      assert filtered_modes == [
               {:add, {"l", "10"}},
               {:add, "n"},
               {:remove, "t"},
               {:remove, {"k", "password"}}
             ]

      assert listing_modes == []
      assert missing_value_modes == []
    end

    test "handles modes with listing modes" do
      mode_changes = [add: "b"]

      {filtered_modes, listing_modes, missing_value_modes} = ChannelModes.filter_mode_changes(mode_changes)

      assert filtered_modes == []
      assert listing_modes == ["b"]
      assert missing_value_modes == []
    end

    test "handles modes with doubled listing modes" do
      mode_changes = [add: "b", remove: "b"]

      {filtered_modes, listing_modes, missing_value_modes} = ChannelModes.filter_mode_changes(mode_changes)

      assert filtered_modes == []
      assert listing_modes == ["b"]
      assert missing_value_modes == []
    end

    test "handles modes with value and listing modes" do
      mode_changes = [add: {"l", "10"}, add: "n", add: "b", add: "t", add: {"b", "nick!*@mask"}]

      {filtered_modes, listing_modes, missing_value_modes} = ChannelModes.filter_mode_changes(mode_changes)

      assert filtered_modes == [{:add, {"l", "10"}}, {:add, "n"}, {:add, "t"}, {:add, {"b", "nick!*@mask"}}]
      assert listing_modes == ["b"]
      assert missing_value_modes == []
    end
  end

  describe "apply_mode_changes/3" do
    test "handles add modes" do
      user = insert(:user)
      channel = insert(:channel, modes: [])

      validated_modes = [
        {:add, {"l", "10"}},
        {:add, "n"},
        {:add, "t"},
        {:add, "s"},
        {:add, "i"},
        {:add, "m"},
        {:add, "p"},
        {:add, {"k", "password"}},
        {:add, {"b", "nick!*@mask"}}
      ]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert applied_changes == [
               {:add, {"l", "10"}},
               {:add, "n"},
               {:add, "t"},
               {:add, "s"},
               {:add, "i"},
               {:add, "m"},
               {:add, "p"},
               {:add, {"k", "password"}},
               {:add, {"b", "nick!*@mask"}}
             ]

      assert updated_channel.modes == [
               {"l", "10"},
               "n",
               "t",
               "s",
               "i",
               "m",
               "p",
               {"k", "password"}
             ]

      assert [channel_ban] = Memento.transaction!(fn -> ChannelBans.get_by_channel_name(channel.name) end)
      assert channel_ban.mask == "nick!*@mask"
      assert channel_ban.setter == build_user_mask(user)
      assert channel_ban.created_at != nil
    end

    test "handles remove modes" do
      user = insert(:user)
      channel = insert(:channel, modes: [{"l", "10"}, "n", "t", "s", "i", "m", "p", {"k", "password"}])
      insert(:channel_ban, channel: channel, mask: "nick!*@mask")

      validated_modes = [
        {:remove, "l"},
        {:remove, "n"},
        {:remove, "t"},
        {:remove, "s"},
        {:remove, "i"},
        {:remove, "m"},
        {:remove, "p"},
        {:remove, "k"},
        {:remove, {"b", "nick!*@mask"}}
      ]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert applied_changes == [
               {:remove, "l"},
               {:remove, "n"},
               {:remove, "t"},
               {:remove, "s"},
               {:remove, "i"},
               {:remove, "m"},
               {:remove, "p"},
               {:remove, "k"},
               {:remove, {"b", "nick!*@mask"}}
             ]

      assert updated_channel.modes == []

      assert [] = Memento.transaction!(fn -> ChannelBans.get_by_channel_name(channel.name) end)
    end

    test "handles add and remove same modes" do
      channel = insert(:channel, modes: [])
      user = insert(:user)

      validated_modes = [
        {:add, {"l", "10"}},
        {:add, "n"},
        {:add, "t"},
        {:add, "s"},
        {:add, "i"},
        {:add, "m"},
        {:add, "p"},
        {:add, {"k", "password"}},
        {:add, {"b", "nick!*@mask"}},
        {:remove, "l"},
        {:remove, "n"},
        {:remove, "t"},
        {:remove, "s"},
        {:remove, "i"},
        {:remove, "m"},
        {:remove, "p"},
        {:remove, "k"},
        {:remove, {"b", "nick!*@mask"}}
      ]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert applied_changes == [
               {:add, {"l", "10"}},
               {:add, "n"},
               {:add, "t"},
               {:add, "s"},
               {:add, "i"},
               {:add, "m"},
               {:add, "p"},
               {:add, {"k", "password"}},
               {:add, {"b", "nick!*@mask"}},
               {:remove, "l"},
               {:remove, "n"},
               {:remove, "t"},
               {:remove, "s"},
               {:remove, "i"},
               {:remove, "m"},
               {:remove, "p"},
               {:remove, "k"},
               {:remove, {"b", "nick!*@mask"}}
             ]

      assert updated_channel.modes == []

      assert [] = Memento.transaction!(fn -> ChannelBans.get_by_channel_name(channel.name) end)
    end

    test "handles add modes with value" do
      user = insert(:user)
      channel = insert(:channel, modes: [])
      user_operator = insert(:user, nick: "nick_operator")
      user_voice = insert(:user, nick: "nick_voice")
      insert(:user_channel, user: user_operator, channel: channel, modes: [])
      insert(:user_channel, user: user_voice, channel: channel, modes: [])

      validated_modes = [
        {:add, {"l", "20"}},
        {:add, {"k", "newpassword"}},
        {:add, {"b", "nick!*@mask"}},
        {:add, {"o", "nick_operator"}},
        {:add, {"v", "nick_voice"}}
      ]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert applied_changes == [
               {:add, {"l", "20"}},
               {:add, {"k", "newpassword"}},
               {:add, {"b", "nick!*@mask"}},
               {:add, {"o", "nick_operator"}},
               {:add, {"v", "nick_voice"}}
             ]

      assert updated_channel.modes == [
               {"l", "20"},
               {"k", "newpassword"}
             ]

      {{:ok, user_channel_operator}, {:ok, user_channel_voice}} =
        Memento.transaction!(fn ->
          {UserChannels.get_by_user_port_and_channel_name(user_operator.port, channel.name),
           UserChannels.get_by_user_port_and_channel_name(user_voice.port, channel.name)}
        end)

      assert user_channel_operator.modes == ["o"]
      assert user_channel_voice.modes == ["v"]

      assert [channel_ban] = Memento.transaction!(fn -> ChannelBans.get_by_channel_name(channel.name) end)
      assert channel_ban.mask == "nick!*@mask"
      assert channel_ban.setter == build_user_mask(user)
      assert channel_ban.created_at != nil
    end

    test "handles add modes with value that requires to be an integer but is not" do
      user = insert(:user)
      channel = insert(:channel, modes: [])
      validated_modes = [{:add, {"l", "invalid"}}]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert updated_channel.modes == []
      assert applied_changes == []
    end

    test "handles replace modes with value" do
      user = insert(:user)
      channel = insert(:channel, modes: [{"l", "10"}, {"k", "password"}])
      validated_modes = [{:add, {"l", "20"}}, {:add, {"k", "newpassword"}}]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert updated_channel.modes == [{"l", "20"}, {"k", "newpassword"}]
      assert applied_changes == [{:add, {"l", "20"}}, {:add, {"k", "newpassword"}}]
    end

    test "handles remove modes with value" do
      user = insert(:user)
      channel = insert(:channel, modes: [{"l", "10"}, {"k", "password"}])
      user_operator = insert(:user, nick: "nick_operator")
      user_voice = insert(:user, nick: "nick_voice")
      insert(:user_channel, user: user_operator, channel: channel, modes: ["o"])
      insert(:user_channel, user: user_voice, channel: channel, modes: ["v"])
      insert(:channel_ban, channel: channel, mask: "nick!*@mask")

      validated_modes = [
        {:remove, "l"},
        {:remove, "k"},
        {:remove, {"b", "nick!*@mask"}},
        {:remove, {"o", "nick_operator"}},
        {:remove, {"v", "nick_voice"}}
      ]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert applied_changes == [
               {:remove, "l"},
               {:remove, "k"},
               {:remove, {"b", "nick!*@mask"}},
               {:remove, {"o", "nick_operator"}},
               {:remove, {"v", "nick_voice"}}
             ]

      assert updated_channel.modes == []

      {{:ok, user_channel_operator}, {:ok, user_channel_voice}} =
        Memento.transaction!(fn ->
          {UserChannels.get_by_user_port_and_channel_name(user_operator.port, channel.name),
           UserChannels.get_by_user_port_and_channel_name(user_voice.port, channel.name)}
        end)

      assert user_channel_operator.modes == []
      assert user_channel_voice.modes == []

      assert [] = Memento.transaction!(fn -> ChannelBans.get_by_channel_name(channel.name) end)
    end

    test "handles add modes already set" do
      user = insert(:user)
      modes = ["t", {"l", "10"}, {"k", "password"}]
      channel = insert(:channel, modes: modes)
      user_operator = insert(:user, nick: "nick_operator")
      user_voice = insert(:user, nick: "nick_voice")
      insert(:user_channel, user: user_operator, channel: channel, modes: ["o"])
      insert(:user_channel, user: user_voice, channel: channel, modes: ["v"])
      insert(:channel_ban, channel: channel, mask: "nick!*@mask")

      validated_modes = [
        {:add, "t"},
        {:add, {"l", "10"}},
        {:add, {"k", "password"}},
        {:add, {"b", "nick!*@mask"}},
        {:add, {"o", "nick_operator"}},
        {:add, {"v", "nick_voice"}}
      ]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert updated_channel.modes == modes

      assert applied_changes == [
               {:add, {"l", "10"}},
               {:add, {"k", "password"}},
               {:add, {"o", "nick_operator"}},
               {:add, {"v", "nick_voice"}}
             ]
    end

    test "handles remove modes that are not set" do
      user = insert(:user)
      channel = insert(:channel, modes: [])
      user_operator = insert(:user, nick: "nick_operator")
      user_voice = insert(:user, nick: "nick_voice")
      insert(:user_channel, user: user_operator, channel: channel)
      insert(:user_channel, user: user_voice, channel: channel)

      validated_modes = [
        {:remove, "t"},
        {:remove, {"b", "nick!*@mask"}},
        {:remove, {"o", "nick_operator"}},
        {:remove, {"v", "nick_voice"}}
      ]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert updated_channel.modes == []
      assert applied_changes == []

      assert_sent_messages([])
    end

    test "handles add modes for user that is not in the channel" do
      user = insert(:user)
      user_operator = insert(:user, nick: "nick_operator")
      channel = insert(:channel, modes: [])
      insert(:user_channel, user: user, channel: channel, modes: ["o"])

      validated_modes = [{:add, {"o", "nick_operator"}}]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert updated_channel.modes == []
      assert applied_changes == []

      assert_sent_messages([
        {user.socket,
         ":server.example.com 441 #{user.nick} #{channel.name} #{user_operator.nick} :They aren't on that channel\r\n"}
      ])
    end

    test "handles add modes for user that is not in the server" do
      user = insert(:user)
      channel = insert(:channel, modes: [])

      validated_modes = [{:add, {"o", "nonexistent"}}]

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert updated_channel.modes == []
      assert applied_changes == []

      assert_sent_messages([
        {user.socket, ":server.example.com 401 #{user.nick} #{channel.name} nonexistent :No such nick\r\n"}
      ])
    end

    test "handles mask normalization for channel ban mode changes" do
      user = insert(:user)
      channel = insert(:channel, modes: [])
      insert(:user_channel, user: user, channel: channel, modes: ["o"])

      validated_modes = [{:add, {"b", "mask"}}, {:remove, {"b", "mask"}}]

      {_updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert applied_changes == [{:add, {"b", "mask!*@*"}}, {:remove, {"b", "mask!*@*"}}]
    end

    test "handles empty modes" do
      user = insert(:user)
      channel = insert(:channel, modes: [])

      validated_modes = []

      {updated_channel, applied_changes} =
        Memento.transaction!(fn -> ChannelModes.apply_mode_changes(user, channel, validated_modes) end)

      assert updated_channel.modes == []
      assert applied_changes == []
    end
  end
end
