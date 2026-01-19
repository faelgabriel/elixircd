defmodule ElixIRCd.Services.Nickserv.AccessTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Services.Nickserv.Access

  describe "handle/2 - general validation" do
    test "handles ACCESS command when user is not identified" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Access.handle(user, ["ACCESS", "LIST"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You must identify to NickServ before using the ACCESS command.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Use \x02/msg NickServ IDENTIFY <password>\x02 to identify.\r\n"}
        ])
      end)
    end

    test "handles ACCESS command with insufficient parameters" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02ACCESS\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02ACCESS {ADD|DEL|LIST|CLEAR} [mask]\x02\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Available ACCESS subcommands:\r\n"},
          {user.pid, ~r/ADD <mask>/},
          {user.pid, ~r/DEL <mask>/},
          {user.pid, ~r/LIST/},
          {user.pid, ~r/CLEAR/}
        ])
      end)
    end

    test "handles ACCESS command with invalid subcommand" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS", "INVALID"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Unknown ACCESS subcommand: \x02INVALID\x02\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Available ACCESS subcommands:\r\n"},
          {user.pid, ~r/ADD <mask>/},
          {user.pid, ~r/DEL <mask>/},
          {user.pid, ~r/LIST/},
          {user.pid, ~r/CLEAR/}
        ])
      end)
    end
  end

  describe "handle/2 - ADD subcommand" do
    test "adds a valid mask successfully" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)
        mask = "*@trusted.vpn"

        assert :ok = Access.handle(user, ["ACCESS", "ADD", mask])

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert length(entries) == 1
        assert hd(entries).mask == String.downcase(mask)

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Added \x02#{mask}\x02 to your access list.\r\n"}
        ])
      end)
    end

    test "handles ADD with insufficient parameters" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS", "ADD"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02ACCESS ADD\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02ACCESS ADD <mask>\x02\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :\r\n"},
          {user.pid, ~r/Example:/}
        ])
      end)
    end

    test "rejects mask without @ symbol" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)
        invalid_mask = "invalidmask"

        assert :ok = Access.handle(user, ["ACCESS", "ADD", invalid_mask])

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert Enum.empty?(entries)

        assert_sent_messages([
          {user.pid, ~r/Invalid mask format/},
          {user.pid, ~r/Examples:/}
        ])
      end)
    end

    test "rejects overly permissive mask *@*" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS", "ADD", "*@*"])

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert Enum.empty?(entries)

        assert_sent_messages([
          {user.pid, ~r/too permissive/},
          {user.pid, ~r/Please use a more specific mask/}
        ])
      end)
    end

    test "rejects overly permissive mask @*" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS", "ADD", "@*"])

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert Enum.empty?(entries)

        assert_sent_messages([
          {user.pid, ~r/too permissive/},
          {user.pid, ~r/Please use a more specific mask/}
        ])
      end)
    end

    test "rejects duplicate mask" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)
        mask = "*@trusted.vpn"

        # Add first time
        insert(:nick_access, nickname: registered_nick.nickname, mask: mask)

        # Try to add again
        assert :ok = Access.handle(user, ["ACCESS", "ADD", mask])

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert length(entries) == 1

        assert_sent_messages([
          {user.pid, ~r/already in your access list/}
        ])
      end)
    end

    test "rejects when maximum entries reached" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        # Add 10 entries (default max)
        for i <- 1..10 do
          insert(:nick_access, nickname: registered_nick.nickname, mask: "*@host#{i}.com")
        end

        # Try to add 11th entry
        assert :ok = Access.handle(user, ["ACCESS", "ADD", "*@host11.com"])

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert length(entries) == 10

        assert_sent_messages([
          {user.pid, ~r/access list is full/},
          {user.pid, ~r/Use.*ACCESS DEL/}
        ])
      end)
    end

    test "normalizes mask to lowercase" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)
        mask = "*@TRUSTED.VPN"

        assert :ok = Access.handle(user, ["ACCESS", "ADD", mask])

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert hd(entries).mask == "*@trusted.vpn"
      end)
    end

    test "accepts various valid mask formats" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        valid_masks = [
          "*@trusted.vpn",
          "user@192.168.1.1",
          "~user@*.example.com",
          "?ser@host?.com",
          "*@*example.com"
        ]

        for mask <- valid_masks do
          assert :ok = Access.handle(user, ["ACCESS", "ADD", mask])
        end

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert length(entries) == length(valid_masks)
      end)
    end
  end

  describe "handle/2 - DEL subcommand" do
    test "removes an existing mask successfully" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)
        mask = "*@trusted.vpn"

        insert(:nick_access, nickname: registered_nick.nickname, mask: mask)

        assert :ok = Access.handle(user, ["ACCESS", "DEL", mask])

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert Enum.empty?(entries)

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Removed \x02#{mask}\x02 from your access list.\r\n"}
        ])
      end)
    end

    test "handles DEL with insufficient parameters" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS", "DEL"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02ACCESS DEL\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02ACCESS DEL <mask>\x02\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :\r\n"},
          {user.pid, ~r/Example:/}
        ])
      end)
    end

    test "reports error when mask does not exist" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)
        mask = "*@nonexistent.vpn"

        assert :ok = Access.handle(user, ["ACCESS", "DEL", mask])

        assert_sent_messages([
          {user.pid, ~r/not in your access list/}
        ])
      end)
    end

    test "is case-insensitive when matching masks" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        insert(:nick_access, nickname: registered_nick.nickname, mask: "*@trusted.vpn")

        # Delete with uppercase
        assert :ok = Access.handle(user, ["ACCESS", "DEL", "*@TRUSTED.VPN"])

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert Enum.empty?(entries)
      end)
    end
  end

  describe "handle/2 - LIST subcommand" do
    test "displays empty list message when no entries" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS", "LIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Your access list is empty.\r\n"}
        ])
      end)
    end

    test "lists all masks with numbering and dates" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        # Add multiple entries
        mask1 = "*@host1.com"
        mask2 = "*@host2.com"
        mask3 = "*@host3.com"

        insert(:nick_access, nickname: registered_nick.nickname, mask: mask1)
        insert(:nick_access, nickname: registered_nick.nickname, mask: mask2)
        insert(:nick_access, nickname: registered_nick.nickname, mask: mask3)

        assert :ok = Access.handle(user, ["ACCESS", "LIST"])

        assert_sent_messages([
          {user.pid, ~r/Access list for \x02#{registered_nick.nickname}\x02/},
          {user.pid, ~r/1\. \x02#{Regex.escape(mask1)}\x02.*added:/},
          {user.pid, ~r/2\. \x02#{Regex.escape(mask2)}\x02.*added:/},
          {user.pid, ~r/3\. \x02#{Regex.escape(mask3)}\x02.*added:/},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of access list.\r\n"}
        ])
      end)
    end

    test "LIST ignores extra parameters" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS", "LIST", "extra", "params"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Your access list is empty.\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - CLEAR subcommand" do
    test "clears all entries and reports count" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        # Add multiple entries
        for i <- 1..5 do
          insert(:nick_access, nickname: registered_nick.nickname, mask: "*@host#{i}.com")
        end

        assert :ok = Access.handle(user, ["ACCESS", "CLEAR"])

        entries = NickAccesses.get_by_nickname(registered_nick.nickname)
        assert Enum.empty?(entries)

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Your access list has been cleared.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Removed \x025\x02 entries from your access list.\r\n"}
        ])
      end)
    end

    test "reports when list is already empty" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS", "CLEAR"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Your access list is already empty.\r\n"}
        ])
      end)
    end

    test "uses singular form for one entry" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        insert(:nick_access, nickname: registered_nick.nickname, mask: "*@host.com")

        assert :ok = Access.handle(user, ["ACCESS", "CLEAR"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Your access list has been cleared.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Removed \x021\x02 entry from your access list.\r\n"}
        ])
      end)
    end

    test "CLEAR ignores extra parameters" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS", "CLEAR", "extra"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Your access list is already empty.\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - case insensitivity" do
    test "subcommands are case-insensitive" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Access.handle(user, ["ACCESS", "list"])
        assert_sent_messages([{user.pid, ~r/empty/}])

        assert :ok = Access.handle(user, ["ACCESS", "LiSt"])
        assert_sent_messages([{user.pid, ~r/empty/}])
      end)
    end
  end
end
