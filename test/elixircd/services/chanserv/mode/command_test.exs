defmodule ElixIRCd.Services.Chanserv.Mode.CommandTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Services.Chanserv.Deop
  alias ElixIRCd.Services.Chanserv.Devoice
  alias ElixIRCd.Services.Chanserv.Op
  alias ElixIRCd.Services.Chanserv.Voice
  alias ElixIRCd.Tables.RegisteredChannel

  describe "OP/DEOP/VOICE/DEVOICE" do
    test "requires the user to be identified" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Op.handle(user, ["OP", "#channel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])
      end)
    end

    test "shows syntax errors" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Op.handle(user, ["OP"])
        assert :ok = Deop.handle(user, ["DEOP", "#chan", "nick", "extra"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02OP <channel> [nickname]\x02\r\n"},
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02DEOP <channel> [nickname]\x02\r\n"}
        ])
      end)
    end

    test "ops the current user when no nickname is provided" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        watcher = insert(:user)
        channel = insert(:channel, name: "#testchannel")
        settings = RegisteredChannel.Settings.new(%{guard: true, fantasy: true})

        insert(:registered_channel, name: channel.name, founder: "founder", settings: settings)
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "VAFS")
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Op.handle(user, ["OP", channel.name])

        assert {:ok, updated_user_channel} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)
        assert :o in updated_user_channel.modes

        assert_sent_messages(
          [
            {user.pid, ":ChanServ!service@irc.test MODE #{channel.name} +o #{user.nick}\r\n"},
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :Operator status granted to \x02#{user.nick}\x02 on \x02#{channel.name}\x02.\r\n"},
            {watcher.pid, ":ChanServ!service@irc.test MODE #{channel.name} +o #{user.nick}\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "reports unchanged operator and voice states" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, identified_as: "target")
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "VAFS")
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: target, channel: channel, modes: [:o])

        assert :ok = Op.handle(user, ["OP", channel.name, target.nick])
        assert :ok = Devoice.handle(user, ["DEVOICE", channel.name, target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{target.nick}\x02 is already opped on \x02#{channel.name}\x02.\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{target.nick}\x02 is not voiced on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "reports unchanged DEOP and VOICE states" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, identified_as: "target")
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "VAFS")
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: target, channel: channel, modes: [:v])

        assert :ok = Deop.handle(user, ["DEOP", channel.name, target.nick])
        assert :ok = Voice.handle(user, ["VOICE", channel.name, target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{target.nick}\x02 is not opped on \x02#{channel.name}\x02.\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{target.nick}\x02 is already voiced on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "denies OP when the user lacks the S flag" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "V")
        insert(:user_channel, user: target, channel: channel)

        assert :ok = Op.handle(user, ["OP", channel.name, target.nick])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "honors SECURE when granting privileges" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, identified_as: nil)
        channel = insert(:channel, name: "#testchannel")
        settings = RegisteredChannel.Settings.new(%{secure: true})

        insert(:registered_channel, name: channel.name, founder: "founder", settings: settings)
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "VAFS")
        insert(:user_channel, user: target, channel: channel)

        assert :ok = Voice.handle(user, ["VOICE", channel.name, target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel.name}\x02 has \x02SECURE\x02 enabled; \x02#{target.nick}\x02 must be identified to receive privileges.\r\n"}
        ])
      end)
    end

    test "grants privileges on SECURE channels when the target is identified" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, identified_as: "target")
        watcher = insert(:user)
        channel = insert(:channel, name: "#testchannel")
        settings = RegisteredChannel.Settings.new(%{secure: true})

        insert(:registered_channel, name: channel.name, founder: "founder", settings: settings)
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "V")
        insert(:user_channel, user: target, channel: channel)
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Voice.handle(user, ["VOICE", channel.name, target.nick])

        assert_sent_messages(
          [
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :Voice status granted to \x02#{target.nick}\x02 on \x02#{channel.name}\x02.\r\n"},
            {target.pid, ":ChanServ!service@irc.test MODE #{channel.name} +v #{target.nick}\r\n"},
            {watcher.pid, ":ChanServ!service@irc.test MODE #{channel.name} +v #{target.nick}\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "honors PEACE when removing privileges from equal or higher access targets" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, identified_as: "target")
        channel = insert(:channel, name: "#testchannel")
        settings = RegisteredChannel.Settings.new(%{peace: true})

        insert(:registered_channel, name: channel.name, founder: "founder", settings: settings)
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "VAFS")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "target", flags: "VAFS")
        insert(:user_channel, user: target, channel: channel, modes: [:o, :v])

        assert :ok = Deop.handle(user, ["DEOP", channel.name, target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel.name}\x02 has \x02PEACE\x02 enabled; you cannot change privileges for that target.\r\n"}
        ])
      end)
    end

    test "allows removals under PEACE when the target has lower access" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, identified_as: "target")
        watcher = insert(:user)
        channel = insert(:channel, name: "#testchannel")
        settings = RegisteredChannel.Settings.new(%{peace: true})

        insert(:registered_channel, name: channel.name, founder: "founder", settings: settings)
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "VAFS")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "target", flags: "V")
        insert(:user_channel, user: target, channel: channel, modes: [:v])
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Devoice.handle(user, ["DEVOICE", channel.name, target.nick])

        assert_sent_messages(
          [
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :Voice status removed from \x02#{target.nick}\x02 on \x02#{channel.name}\x02.\r\n"},
            {target.pid, ":ChanServ!service@irc.test MODE #{channel.name} -v #{target.nick}\r\n"},
            {watcher.pid, ":ChanServ!service@irc.test MODE #{channel.name} -v #{target.nick}\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "deops users when permitted" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, identified_as: "target")
        watcher = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "VAFS")
        insert(:user_channel, user: target, channel: channel, modes: [:o])
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Deop.handle(user, ["DEOP", channel.name, target.nick])
        assert {:ok, updated_user_channel} = UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name)
        refute :o in updated_user_channel.modes

        assert_sent_messages(
          [
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :Operator status removed from \x02#{target.nick}\x02 on \x02#{channel.name}\x02.\r\n"},
            {target.pid, ":ChanServ!service@irc.test MODE #{channel.name} -o #{target.nick}\r\n"},
            {watcher.pid, ":ChanServ!service@irc.test MODE #{channel.name} -o #{target.nick}\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "voices and devoices users when permitted" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, identified_as: "target")
        watcher = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "V")
        insert(:user_channel, user: target, channel: channel)
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Voice.handle(user, ["VOICE", channel.name, target.nick])
        assert {:ok, voiced_user_channel} = UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name)
        assert :v in voiced_user_channel.modes

        assert :ok = Devoice.handle(user, ["DEVOICE", channel.name, target.nick])
        assert {:ok, devoiced_user_channel} = UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name)
        refute :v in devoiced_user_channel.modes

        assert_sent_messages(
          [
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :Voice status granted to \x02#{target.nick}\x02 on \x02#{channel.name}\x02.\r\n"},
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :Voice status removed from \x02#{target.nick}\x02 on \x02#{channel.name}\x02.\r\n"},
            {target.pid, ":ChanServ!service@irc.test MODE #{channel.name} +v #{target.nick}\r\n"},
            {target.pid, ":ChanServ!service@irc.test MODE #{channel.name} -v #{target.nick}\r\n"},
            {watcher.pid, ":ChanServ!service@irc.test MODE #{channel.name} +v #{target.nick}\r\n"},
            {watcher.pid, ":ChanServ!service@irc.test MODE #{channel.name} -v #{target.nick}\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles missing channels and targets" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user)

        assert :ok = Voice.handle(user, ["VOICE", "#missing", target.nick])

        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Voice.handle(user, ["VOICE", "#testchannel", target.nick])

        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "VAFS")

        assert :ok = Voice.handle(user, ["VOICE", channel.name, "missing"])
        assert :ok = Voice.handle(user, ["VOICE", channel.name, target.nick])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel.name}\x02 is not currently in use.\r\n"},
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :The nickname \x02missing\x02 is not online.\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{target.nick}\x02 is not on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end
  end
end
