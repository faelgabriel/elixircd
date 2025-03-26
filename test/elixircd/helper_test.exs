defmodule ElixIRCd.HelperTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ElixIRCd.Factory

  alias ElixIRCd.Helper

  describe "channel_name?/1" do
    test "returns true for channel names" do
      assert true == Helper.channel_name?("#elixir")
    end

    test "returns false for non-channel names" do
      assert false == Helper.channel_name?("elixir")
    end
  end

  describe "irc_operator?/1" do
    test "returns true for irc operator" do
      user = build(:user, %{modes: ["o"]})
      assert true == Helper.irc_operator?(user)
    end

    test "returns false for non-irc operator" do
      user = build(:user, %{modes: []})
      assert false == Helper.irc_operator?(user)
    end
  end

  describe "channel_operator?/1" do
    test "returns true for channel operator" do
      user_channel = build(:user_channel, %{modes: ["o"]})
      assert true == Helper.channel_operator?(user_channel)
    end

    test "returns false for non-channel operator" do
      user_channel = build(:user_channel, %{modes: []})
      assert false == Helper.channel_operator?(user_channel)
    end
  end

  describe "channel_voice?/1" do
    test "returns true for channel voice" do
      user_channel = build(:user_channel, %{modes: ["v"]})
      assert true == Helper.channel_voice?(user_channel)
    end

    test "returns false for non-channel voice" do
      user_channel = build(:user_channel, %{modes: []})
      assert false == Helper.channel_voice?(user_channel)
    end
  end

  describe "user_mask_match?/2" do
    test "matches user mask" do
      user = build(:user, nick: "nick", ident: "~user", hostname: "host")

      assert true == Helper.user_mask_match?(user, "nick!~user@host")
      assert true == Helper.user_mask_match?(user, "nick!~user@*")
      assert true == Helper.user_mask_match?(user, "nick!*@host")
      assert true == Helper.user_mask_match?(user, "nick!*@*")
      assert true == Helper.user_mask_match?(user, "*!~user@host")
      assert true == Helper.user_mask_match?(user, "*!~user@*")
      assert true == Helper.user_mask_match?(user, "*!*@host")
      assert true == Helper.user_mask_match?(user, "*!*@*")
      assert true == Helper.user_mask_match?(user, "n*!*@*")
      assert true == Helper.user_mask_match?(user, "*!~u*@host")
      assert true == Helper.user_mask_match?(user, "*!~user@h*")
      assert true == Helper.user_mask_match?(user, "*k!*@*")
      assert true == Helper.user_mask_match?(user, "*!~*r@host")
      assert true == Helper.user_mask_match?(user, "*!~user@*t")
    end

    test "does not match user mask" do
      user = build(:user, nick: "nick", ident: "~user", hostname: "host")

      assert false == Helper.user_mask_match?(user, "difnick!~user@host")
      assert false == Helper.user_mask_match?(user, "difnick!~user@*")
      assert false == Helper.user_mask_match?(user, "difnick!*@host")
      assert false == Helper.user_mask_match?(user, "difnick!*@*")
      assert false == Helper.user_mask_match?(user, "*!~difuser@host")
      assert false == Helper.user_mask_match?(user, "*!~difuser@*")
      assert false == Helper.user_mask_match?(user, "*!*@difhost")
    end
  end

  describe "get_user_reply/1" do
    test "gets reply for registered user" do
      user = build(:user)
      reply = Helper.get_user_reply(user)

      assert reply == user.nick
    end

    test "gets reply for unregistered user" do
      user = build(:user, %{registered: false})
      reply = Helper.get_user_reply(user)

      assert reply == "*"
    end
  end

  describe "get_target_list/1" do
    test "gets channel list" do
      assert {:channels, ["#elixir", "#elixircd"]} == Helper.get_target_list("#elixir,#elixircd")
    end

    test "gets user list" do
      assert {:users, ["elixir", "elixircd"]} == Helper.get_target_list("elixir,elixircd")
    end

    test "returns error" do
      assert {:error, "Invalid list of targets"} == Helper.get_target_list("elixir,#elixircd")
    end
  end

  describe "get_user_mask/1" do
    test "builds user mask with ident" do
      user = build(:user, nick: "nick", ident: "~username", hostname: "host", registered: true)
      assert "nick!~username@host" == Helper.get_user_mask(user)
    end

    test "builds a user mask and truncates ident" do
      user =
        build(:user, nick: "nick", ident: "useriduseriduserid", hostname: "host", registered: true)

      assert "nick!useriduser@host" == Helper.get_user_mask(user)
    end

    test "builds a user mask for unregistered user" do
      user = build(:user, registered: false)
      assert "*" == Helper.get_user_mask(user)
    end
  end

  describe "lookup_hostname/1" do
    test "gets hostname from an ipv4 address" do
      assert {:ok, _hostname} = Helper.lookup_hostname({127, 0, 0, 1})
    end

    test "gets hostname from an ipv6 address" do
      assert {:ok, _hostname} = Helper.lookup_hostname({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "returns error for invalid address" do
      assert {:error, "Unable to get hostname for {300, 0, 0, 0}: :einval"} ==
               Helper.lookup_hostname({300, 0, 0, 0})

      assert {:error, "Unable to get hostname for {999, 0, 0, 0, 0, 0, 0}: :einval"} ==
               Helper.lookup_hostname({999, 0, 0, 0, 0, 0, 0})
    end
  end

  describe "format_ip_address/1" do
    test "formats ipv4 address" do
      assert "127.0.0.1" = Helper.format_ip_address({127, 0, 0, 1})
    end

    test "formats ipv6 address" do
      assert "::1" = Helper.format_ip_address({0, 0, 0, 0, 0, 0, 0, 1})
    end
  end

  describe "format_transport/1" do
    test "formats transport" do
      assert "TCP" = Helper.format_transport(:tcp)
      assert "TLS" = Helper.format_transport(:tls)
      assert "HTTP" = Helper.format_transport(:http)
      assert "HTTPS" = Helper.format_transport(:https)
      assert "WS" = Helper.format_transport(:ws)
      assert "WSS" = Helper.format_transport(:wss)
    end
  end

  describe "normalize_mask/1" do
    test "normalizes user mask" do
      assert "nick!user@host" == Helper.normalize_mask("nick!user@host")
      assert "nick!user@*" == Helper.normalize_mask("nick!user")
      assert "nick!*@*" == Helper.normalize_mask("nick")
      assert "nick!*@host" == Helper.normalize_mask("nick!@host")
      assert "*!user@host" == Helper.normalize_mask("user@host")
      assert "*!*@host" == Helper.normalize_mask("!@host")
      assert "*!*@host" == Helper.normalize_mask("@host")
      assert "*!*@@" == Helper.normalize_mask("@@")
      assert "*!!@*" == Helper.normalize_mask("!!")
      assert "**!*@*" == Helper.normalize_mask("**")
      assert "*!*@*" == Helper.normalize_mask("*")
      assert "*!*@*" == Helper.normalize_mask("!")
      assert "*!*@*" == Helper.normalize_mask("@")
      assert "*!*@*" == Helper.normalize_mask("*!@*")
    end
  end
end
