defmodule ElixIRCd.HelperTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Helper

  alias ElixIRCd.Helper

  import ElixIRCd.Factory

  describe "get_target_list/1" do
    test "extracts channels" do
      assert {:channels, ["#elixir", "#elixircd"]} == Helper.get_target_list("#elixir,#elixircd")
    end

    test "extracts users" do
      assert {:users, ["elixir", "elixircd"]} == Helper.get_target_list("elixir,elixircd")
    end

    test "returns error" do
      assert {:error, "Invalid list of targets"} == Helper.get_target_list("elixir,#elixircd")
    end
  end

  describe "is_channel_name?/1" do
    test "returns true for channel names" do
      assert true == Helper.is_channel_name?("#elixir")
      assert true == Helper.is_channel_name?("&elixir")
      assert true == Helper.is_channel_name?("+elixir")
      assert true == Helper.is_channel_name?("!elixir")
    end

    test "returns false for non-channel names" do
      assert false == Helper.is_channel_name?("elixir")
    end
  end

  describe "get_socket_port/1" do
    test "extracts port from tcp socket" do
      socket = create_socket(:tcp)
      extracted_socket_port = Helper.get_socket_port(socket)

      assert is_port(socket)
      assert is_port(extracted_socket_port)
    end

    test "extracts port from ssl socket" do
      socket = create_socket(:ssl)
      extracted_socket_port = Helper.get_socket_port(socket)

      refute is_port(socket)
      assert is_port(extracted_socket_port)
    end
  end

  describe "get_user_reply/1" do
    test "gets reply for registered user" do
      user = build(:user)
      reply = Helper.get_user_reply(user)

      assert reply == user.nick
    end

    test "gets reply for unregistered user" do
      user = build(:user, %{identity: nil})
      reply = Helper.get_user_reply(user)

      assert reply == "*"
    end
  end
end
