defmodule ElixIRCd.Utils.ProtocolTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ElixIRCd.Factory

  alias ElixIRCd.Utils.Protocol

  describe "channel_name?/1" do
    test "returns true for channel names" do
      assert true == Protocol.channel_name?("#elixir")
      assert true == Protocol.channel_name?("&local")
    end

    test "returns false for non-channel names" do
      assert false == Protocol.channel_name?("elixir")
      assert false == Protocol.channel_name?("@invalid")
    end

    test "returns false for empty strings" do
      assert false == Protocol.channel_name?("")
    end
  end

  describe "service_name?/1" do
    test "returns true for valid service names" do
      assert Protocol.service_name?("NICKSERV") == true
      assert Protocol.service_name?("nickserv") == true
      assert Protocol.service_name?("CHANSERV") == true
      assert Protocol.service_name?("chanserv") == true
    end

    test "returns false for invalid service names" do
      assert Protocol.service_name?("INVALID") == false
    end
  end

  describe "irc_operator?/1" do
    test "returns true for irc operator" do
      user = build(:user, %{modes: ["o"]})
      assert true == Protocol.irc_operator?(user)
    end

    test "returns false for non-irc operator" do
      user = build(:user, %{modes: []})
      assert false == Protocol.irc_operator?(user)
    end
  end

  describe "channel_operator?/1" do
    test "returns true for channel operator" do
      user_channel = build(:user_channel, %{modes: ["o"]})
      assert true == Protocol.channel_operator?(user_channel)
    end

    test "returns false for non-channel operator" do
      user_channel = build(:user_channel, %{modes: []})
      assert false == Protocol.channel_operator?(user_channel)
    end
  end

  describe "channel_voice?/1" do
    test "returns true for channel voice" do
      user_channel = build(:user_channel, %{modes: ["v"]})
      assert true == Protocol.channel_voice?(user_channel)
    end

    test "returns false for non-channel voice" do
      user_channel = build(:user_channel, %{modes: []})
      assert false == Protocol.channel_voice?(user_channel)
    end
  end

  describe "match_user_mask?/2" do
    test "matches user mask" do
      user = build(:user, nick: "nick", ident: "~user", hostname: "host")

      assert true == Protocol.match_user_mask?(user, "nick!~user@host")
      assert true == Protocol.match_user_mask?(user, "nick!~user@*")
      assert true == Protocol.match_user_mask?(user, "nick!*@host")
      assert true == Protocol.match_user_mask?(user, "nick!*@*")
      assert true == Protocol.match_user_mask?(user, "*!~user@host")
      assert true == Protocol.match_user_mask?(user, "*!~user@*")
      assert true == Protocol.match_user_mask?(user, "*!*@host")
      assert true == Protocol.match_user_mask?(user, "*!*@*")
      assert true == Protocol.match_user_mask?(user, "n*!*@*")
      assert true == Protocol.match_user_mask?(user, "*!~u*@host")
      assert true == Protocol.match_user_mask?(user, "*!~user@h*")
      assert true == Protocol.match_user_mask?(user, "*k!*@*")
      assert true == Protocol.match_user_mask?(user, "*!~*r@host")
      assert true == Protocol.match_user_mask?(user, "*!~user@*t")
    end

    test "does not match user mask" do
      user = build(:user, nick: "nick", ident: "~user", hostname: "host")

      assert false == Protocol.match_user_mask?(user, "difnick!~user@host")
      assert false == Protocol.match_user_mask?(user, "difnick!~user@*")
      assert false == Protocol.match_user_mask?(user, "difnick!*@host")
      assert false == Protocol.match_user_mask?(user, "difnick!*@*")
      assert false == Protocol.match_user_mask?(user, "*!~difuser@host")
      assert false == Protocol.match_user_mask?(user, "*!~difuser@*")
      assert false == Protocol.match_user_mask?(user, "*!*@difhost")
    end
  end

  describe "user_reply/1" do
    test "returns reply for registered user" do
      user = build(:user)
      reply = Protocol.user_reply(user)

      assert reply == user.nick
    end

    test "returns reply for user not registered" do
      user = build(:user, %{registered: false})
      reply = Protocol.user_reply(user)

      assert reply == "*"
    end
  end

  describe "user_mask/1" do
    test "builds user mask with ident" do
      user = build(:user, nick: "nick", ident: "~username", hostname: "host", registered: true)
      assert "nick!~username@host" == Protocol.user_mask(user)
    end

    test "builds a user mask and truncates ident" do
      user =
        build(:user, nick: "nick", ident: "useriduseriduserid", hostname: "host", registered: true)

      assert "nick!useriduser@host" == Protocol.user_mask(user)
    end

    test "builds a user mask for user not registered" do
      user = build(:user, registered: false)
      assert "*" == Protocol.user_mask(user)
    end
  end

  describe "parse_targets/1" do
    test "parses channel list" do
      assert {:channels, ["#elixir", "#elixircd"]} == Protocol.parse_targets("#elixir,#elixircd")
    end

    test "parses user list" do
      assert {:users, ["elixir", "elixircd"]} == Protocol.parse_targets("elixir,elixircd")
    end

    test "returns error" do
      assert {:error, "Invalid list of targets"} == Protocol.parse_targets("elixir,#elixircd")
    end
  end

  describe "normalize_mask/1" do
    test "normalizes user mask" do
      assert "nick!user@host" == Protocol.normalize_mask("nick!user@host")
      assert "nick!user@*" == Protocol.normalize_mask("nick!user")
      assert "nick!*@*" == Protocol.normalize_mask("nick")
      assert "nick!*@host" == Protocol.normalize_mask("nick!@host")
      assert "*!user@host" == Protocol.normalize_mask("user@host")
      assert "*!*@host" == Protocol.normalize_mask("!@host")
      assert "*!*@host" == Protocol.normalize_mask("@host")
      assert "*!*@@" == Protocol.normalize_mask("@@")
      assert "*!!@*" == Protocol.normalize_mask("!!")
      assert "**!*@*" == Protocol.normalize_mask("**")
      assert "*!*@*" == Protocol.normalize_mask("*")
      assert "*!*@*" == Protocol.normalize_mask("!")
      assert "*!*@*" == Protocol.normalize_mask("@")
      assert "*!*@*" == Protocol.normalize_mask("*!@*")
    end
  end

  describe "valid_mask_format?/1" do
    test "validates correct masks" do
      # Valid full masks
      assert Protocol.valid_mask_format?("nick!user@host.com")
      assert Protocol.valid_mask_format?("nick!user@*")
      assert Protocol.valid_mask_format?("nick!*@host.com")
      assert Protocol.valid_mask_format?("*!user@host.com")
      assert Protocol.valid_mask_format?("nick")
      assert Protocol.valid_mask_format?("user@host.com")
      assert Protocol.valid_mask_format?("nick!user")
      assert Protocol.valid_mask_format?("nick*!user@host.com")
      assert Protocol.valid_mask_format?("nick!*user@host.com")
      assert Protocol.valid_mask_format?("nick!user@*.com")
      assert Protocol.valid_mask_format?("?ick!user@host.com")
      assert Protocol.valid_mask_format?("nick!user@host.?om")

      # Wildcards
      assert Protocol.valid_mask_format?("*")
      assert Protocol.valid_mask_format?("?")
      assert Protocol.valid_mask_format?("*!*@*")
      assert Protocol.valid_mask_format?("?!?@?")

      # Mixed wildcards and characters
      assert Protocol.valid_mask_format?("nick*")
      assert Protocol.valid_mask_format?("*nick")
      assert Protocol.valid_mask_format?("ni?k")

      # Special IRC characters
      assert Protocol.valid_mask_format?("nick[test]")
      assert Protocol.valid_mask_format?("nick\\test")
      assert Protocol.valid_mask_format?("nick`test")
      assert Protocol.valid_mask_format?("nick_test")
      assert Protocol.valid_mask_format?("nick^test")
      assert Protocol.valid_mask_format?("nick{test}")
      assert Protocol.valid_mask_format?("nick|test")

      # Dots and hyphens
      assert Protocol.valid_mask_format?("nick!user@host-name.example.com")
      assert Protocol.valid_mask_format?("nick!user@192.168.1.1")
    end

    test "rejects invalid masks" do
      # Empty mask
      refute Protocol.valid_mask_format?("")

      # Invalid characters
      refute Protocol.valid_mask_format?("nick!user@host<.com")
      refute Protocol.valid_mask_format?("nick!user@host>.com")
      refute Protocol.valid_mask_format?("nick!user@host(.com")
      refute Protocol.valid_mask_format?("nick!user@host).com")

      # Non-string input
      refute Protocol.valid_mask_format?(123)
      refute Protocol.valid_mask_format?(nil)
      refute Protocol.valid_mask_format?(:atom)

      # Too long parts
      long_part = String.duplicate("a", 65)
      refute Protocol.valid_mask_format?("#{long_part}!user@host.com")
      refute Protocol.valid_mask_format?("nick!#{long_part}@host.com")
      refute Protocol.valid_mask_format?("nick!user@#{long_part}")
    end
  end
end
