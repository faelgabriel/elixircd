defmodule ElixIRCd.Message.MessageBuilderTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Message.MessageBuilder

  alias ElixIRCd.Data.Schemas.User
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageBuilder

  describe "user_message/4" do
    test "creates a user message struct" do
      user_identity = "user123"
      command = "JOIN"
      params = ["#channel"]
      body = "Hello"

      expected = %Message{
        source: user_identity,
        command: command,
        params: params,
        body: body
      }

      assert MessageBuilder.user_message(user_identity, command, params, body) == expected
    end
  end

  describe "server_message/3" do
    test "creates a server message struct with an atom command" do
      command = :rpl_welcome
      params = ["Welcome to the server!"]
      body = nil

      expected = %Message{
        source: "server.example.com",
        command: "001",
        params: params,
        body: body
      }

      assert MessageBuilder.server_message(command, params, body) == expected
    end

    test "creates a server message struct with a string command" do
      command = "NOTICE"
      params = ["Global notice"]
      body = nil

      expected = %Message{
        source: "server.example.com",
        command: command,
        params: params,
        body: body
      }

      assert MessageBuilder.server_message(command, params, body) == expected
    end
  end

  describe "get_user_reply/1" do
    test "returns '*' when user identity is nil" do
      user = %User{identity: nil}
      assert MessageBuilder.get_user_reply(user) == "*"
    end

    test "returns user's nickname when identity is present" do
      nickname = "nickname123"
      user = %User{identity: "identity", nick: nickname}
      assert MessageBuilder.get_user_reply(user) == nickname
    end
  end
end
