defmodule ElixIRCd.HelperTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ElixIRCd.Factory

  alias ElixIRCd.Client
  alias ElixIRCd.Helper

  describe "channel_name?/1" do
    test "returns true for channel names" do
      assert true == Helper.channel_name?("#elixir")
      assert true == Helper.channel_name?("&elixir")
      assert true == Helper.channel_name?("+elixir")
      assert true == Helper.channel_name?("!elixir")
    end

    test "returns false for non-channel names" do
      assert false == Helper.channel_name?("elixir")
    end
  end

  describe "socket_connected?/1" do
    test "returns true for connected tcp socket" do
      {:ok, socket} = Client.connect(:tcp)
      assert true == Helper.socket_connected?(socket)
      Client.disconnect(socket)
    end

    test "returns true for connected ssl socket" do
      {:ok, socket} = Client.connect(:ssl)
      assert true == Helper.socket_connected?(socket)
      Client.disconnect(socket)
    end

    test "returns false for disconnected tcp socket" do
      virtual_user = build(:user)
      assert false == Helper.socket_connected?(virtual_user.socket)
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

  describe "get_socket_hostname/1" do
    test "gets hostname from an ipv4 address" do
      assert {:ok, _hostname} = Helper.get_socket_hostname({127, 0, 0, 1})
    end

    test "gets hostname from an ipv6 address" do
      assert {:ok, _hostname} = Helper.get_socket_hostname({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "returns error for invalid address" do
      assert {:error, "Unable to get hostname for {300, 0, 0, 0}: :einval"} ==
               Helper.get_socket_hostname({300, 0, 0, 0})

      assert {:error, "Unable to get hostname for {999, 0, 0, 0, 0, 0, 0}: :einval"} ==
               Helper.get_socket_hostname({999, 0, 0, 0, 0, 0, 0})
    end
  end

  describe "get_socket_ip/1" do
    test "gets ip from tcp socket" do
      {:ok, socket} = Client.connect(:tcp)
      assert {:ok, {127, 0, 0, 1}} == Helper.get_socket_ip(socket)
      Client.disconnect(socket)
    end

    test "gets ip from ssl socket" do
      {:ok, socket} = Client.connect(:ssl)
      assert {:ok, {127, 0, 0, 1}} == Helper.get_socket_ip(socket)
      Client.disconnect(socket)
    end

    test "returns error for tcp socket disconnected" do
      {:ok, socket} = Client.connect(:tcp)
      Client.disconnect(socket)
      assert {:error, error} = Helper.get_socket_ip(socket)
      assert error =~ "Unable to get IP for"
    end

    test "returns error for ssl socket disconnected" do
      {:ok, socket} = Client.connect(:ssl)
      Client.disconnect(socket)
      assert {:error, error} = Helper.get_socket_ip(socket)
      assert error =~ "Unable to get IP for"
    end

    test "returns error for invalid socket" do
      virtual_user = build(:user)
      assert {:error, error} = Helper.get_socket_ip(virtual_user.socket)
      assert error =~ "Unable to get IP for"
    end
  end

  describe "get_socket_port/1" do
    test "gets port from tcp socket" do
      {:ok, socket} = Client.connect(:tcp)
      Client.disconnect(socket)
      extracted_socket_port = Helper.get_socket_port(socket)

      assert is_port(socket)
      assert is_port(extracted_socket_port)
    end

    test "gets port from ssl socket" do
      {:ok, socket} = Client.connect(:ssl)
      Client.disconnect(socket)
      extracted_socket_port = Helper.get_socket_port(socket)

      refute is_port(socket)
      assert is_port(extracted_socket_port)
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

  describe "mask_matches/2" do
    test "matches user mask" do
      user = build(:user)

      assert true == Helper.mask_matches?("nick!user@host", user)
      assert true == Helper.mask_matches?("nick!user@*", user)
      assert true == Helper.mask_matches?("nick!*@host", user)
      assert true == Helper.mask_matches?("nick!*@*", user)
      assert true == Helper.mask_matches?("*!user@host", user)
      assert true == Helper.mask_matches?("*!user@*", user)
      assert true == Helper.mask_matches?("*!*@host", user)
      assert true == Helper.mask_matches?("*!*@*", user)
    end

    test "does not match user mask" do
      # TODO
    end
  end
end
