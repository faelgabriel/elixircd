defmodule ElixIRCd.Utils.ProtocolTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ElixIRCd.Factory

  alias ElixIRCd.Utils.Protocol

  describe "channel_name?/1" do
    test "returns true for channel names" do
      assert true == Protocol.channel_name?("#elixir")
    end

    test "returns false for non-channel names" do
      assert false == Protocol.channel_name?("elixir")
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

    test "returns reply for unregistered user" do
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

    test "builds a user mask for unregistered user" do
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
end
