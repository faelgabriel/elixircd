defmodule ElixIRCd.Parsers.IrcMessageParserTest do
  @moduledoc """
  Tests for the `ElixIRCd.Parsers.IrcMessageParser` module.
  """

  use ExUnit.Case
  doctest ElixIRCd.Parsers.IrcMessageParser

  alias ElixIRCd.Structs.IrcMessage
  alias ElixIRCd.Parsers.IrcMessageParser

  describe "parse/1" do
    test "parses a message with a prefix" do
      message = ":irc.example.com NOTICE user :Server restarting"

      expected = %IrcMessage{
        prefix: "irc.example.com",
        command: "NOTICE",
        params: ["user"],
        body: "Server restarting"
      }

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message without a prefix" do
      message = "NOTICE user :Server restarting"

      expected = %IrcMessage{
        prefix: nil,
        command: "NOTICE",
        params: ["user"],
        body: "Server restarting"
      }

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with a numeric command" do
      message = ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"

      expected = %IrcMessage{
        prefix: "Freenode.net",
        command: "001",
        params: ["user"],
        body: "Welcome to the freenode Internet Relay Chat Network user"
      }

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with no params" do
      message = ":irc.example.com PING"

      expected = %IrcMessage{
        prefix: "irc.example.com",
        command: "PING",
        params: [],
        body: nil
      }

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with no body" do
      message = ":irc.example.com JOIN #channel"

      expected = %IrcMessage{
        prefix: "irc.example.com",
        command: "JOIN",
        params: ["#channel"],
        body: nil
      }

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with no params or body" do
      message = ":irc.example.com PING"

      expected = %IrcMessage{
        prefix: "irc.example.com",
        command: "PING",
        params: [],
        body: nil
      }

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with no prefix, params, or body" do
      message = "PING"

      expected = %IrcMessage{
        prefix: nil,
        command: "PING",
        params: [],
        body: nil
      }

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with no prefix or body" do
      message = "JOIN #channel"

      expected = %IrcMessage{
        prefix: nil,
        command: "JOIN",
        params: ["#channel"],
        body: nil
      }

      assert IrcMessageParser.parse(message) == expected
    end
  end

  describe "unparse/1" do
    test "unparses a message with a prefix" do
      message = %IrcMessage{
        prefix: "irc.example.com",
        command: "NOTICE",
        params: ["user"],
        body: "Server restarting"
      }

      expected = ":irc.example.com NOTICE user :Server restarting"

      assert IrcMessageParser.unparse(message) == expected
    end

    test "unparses a message without a prefix" do
      message = %IrcMessage{
        prefix: nil,
        command: "NOTICE",
        params: ["user"],
        body: "Server restarting"
      }

      expected = "NOTICE user :Server restarting"

      assert IrcMessageParser.unparse(message) == expected
    end

    test "unparses a message with a numeric command" do
      message = %IrcMessage{
        prefix: "Freenode.net",
        command: "001",
        params: ["user"],
        body: "Welcome to the freenode Internet Relay Chat Network user"
      }

      expected = ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"

      assert IrcMessageParser.unparse(message) == expected
    end

    test "unparses a message with no params" do
      message = %IrcMessage{
        prefix: "irc.example.com",
        command: "PING",
        params: [],
        body: nil
      }

      expected = ":irc.example.com PING"

      assert IrcMessageParser.unparse(message) == expected
    end

    test "unparses a message with no body" do
      message = %IrcMessage{
        prefix: "irc.example.com",
        command: "JOIN",
        params: ["#channel"],
        body: nil
      }

      expected = ":irc.example.com JOIN #channel"

      assert IrcMessageParser.unparse(message) == expected
    end

    test "unparses a message with no params or body" do
      message = %IrcMessage{
        prefix: "irc.example.com",
        command: "PING",
        params: [],
        body: nil
      }

      expected = ":irc.example.com PING"

      assert IrcMessageParser.unparse(message) == expected
    end

    test "unparses a message with no prefix, params, or body" do
      message = %IrcMessage{
        prefix: nil,
        command: "PING",
        params: [],
        body: nil
      }

      expected = "PING"

      assert IrcMessageParser.unparse(message) == expected
    end

    test "unparses a message with no prefix or body" do
      message = %IrcMessage{
        prefix: nil,
        command: "JOIN",
        params: ["#channel"],
        body: nil
      }

      expected = "JOIN #channel"

      assert IrcMessageParser.unparse(message) == expected
    end
  end
end
