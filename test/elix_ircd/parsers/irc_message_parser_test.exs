defmodule ElixIRCd.Parsers.IrcMessageParserTest do
  @moduledoc """
  Tests for the `ElixIRCd.Parsers.IrcMessageParser` module.
  """

  use ExUnit.Case
  doctest ElixIRCd.Parsers.IrcMessageParser

  alias ElixIRCd.Parsers.IrcMessageParser
  alias ElixIRCd.Structs.IrcMessage

  describe "parse/1" do
    test "parses a message with a prefix" do
      message = ":irc.example.com NOTICE user :Server restarting"

      expected =
        {:ok,
         %IrcMessage{
           prefix: "irc.example.com",
           command: "NOTICE",
           params: ["user"],
           body: "Server restarting"
         }}

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message without a prefix" do
      message = "NOTICE user :Server restarting"

      expected =
        {:ok,
         %IrcMessage{
           prefix: nil,
           command: "NOTICE",
           params: ["user"],
           body: "Server restarting"
         }}

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with a numeric command" do
      message = ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"

      expected =
        {:ok,
         %IrcMessage{
           prefix: "Freenode.net",
           command: "001",
           params: ["user"],
           body: "Welcome to the freenode Internet Relay Chat Network user"
         }}

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with no params" do
      message = ":irc.example.com PING"

      expected =
        {:ok,
         %IrcMessage{
           prefix: "irc.example.com",
           command: "PING",
           params: [],
           body: nil
         }}

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with no body" do
      message = ":irc.example.com JOIN #channel"

      expected =
        {:ok,
         %IrcMessage{
           prefix: "irc.example.com",
           command: "JOIN",
           params: ["#channel"],
           body: nil
         }}

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with no params or body" do
      message = ":irc.example.com PING"

      expected =
        {:ok,
         %IrcMessage{
           prefix: "irc.example.com",
           command: "PING",
           params: [],
           body: nil
         }}

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with no prefix, params, or body" do
      message = "PING"

      expected =
        {:ok,
         %IrcMessage{
           prefix: nil,
           command: "PING",
           params: [],
           body: nil
         }}

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with no prefix or body" do
      message = "JOIN #channel"

      expected =
        {:ok,
         %IrcMessage{
           prefix: nil,
           command: "JOIN",
           params: ["#channel"],
           body: nil
         }}

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with a complex body" do
      message = ":user!nick@host PRIVMSG #channel :Some message: with multiple: colons"

      expected =
        {:ok,
         %IrcMessage{
           prefix: "user!nick@host",
           command: "PRIVMSG",
           params: ["#channel"],
           body: "Some message: with multiple: colons"
         }}

      assert IrcMessageParser.parse(message) == expected
    end

    test "parses a message with multiple parameters" do
      message = ":Nick!user@host MODE #channel +o User"

      expected =
        {:ok,
         %IrcMessage{
           prefix: "Nick!user@host",
           command: "MODE",
           params: ["#channel", "+o", "User"],
           body: nil
         }}

      assert IrcMessageParser.parse(message) == expected
    end

    test "handles malformed messages" do
      expected = {:error, "Invalid IRC message format"}

      assert IrcMessageParser.parse(":unexpected") == expected
      assert IrcMessageParser.parse(":") == expected
      assert IrcMessageParser.parse(" ") == expected
      assert IrcMessageParser.parse("") == expected
    end
  end

  describe "unparse/1" do
    test "unparses a message with a prefix" do
      irc_message = %IrcMessage{
        prefix: "irc.example.com",
        command: "NOTICE",
        params: ["user"],
        body: "Server restarting"
      }

      expected = {:ok, ":irc.example.com NOTICE user :Server restarting"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end

    test "unparses a message without a prefix" do
      irc_message = %IrcMessage{
        prefix: nil,
        command: "NOTICE",
        params: ["user"],
        body: "Server restarting"
      }

      expected = {:ok, "NOTICE user :Server restarting"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with a numeric command" do
      irc_message = %IrcMessage{
        prefix: "Freenode.net",
        command: "001",
        params: ["user"],
        body: "Welcome to the freenode Internet Relay Chat Network user"
      }

      expected = {:ok, ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with no params" do
      irc_message = %IrcMessage{
        prefix: "irc.example.com",
        command: "PING",
        params: [],
        body: nil
      }

      expected = {:ok, ":irc.example.com PING"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with no body" do
      irc_message = %IrcMessage{
        prefix: "irc.example.com",
        command: "JOIN",
        params: ["#channel"],
        body: nil
      }

      expected = {:ok, ":irc.example.com JOIN #channel"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with no params or body" do
      irc_message = %IrcMessage{
        prefix: "irc.example.com",
        command: "PING",
        params: [],
        body: nil
      }

      expected = {:ok, ":irc.example.com PING"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with no prefix, params, or body" do
      irc_message = %IrcMessage{
        prefix: nil,
        command: "PING",
        params: [],
        body: nil
      }

      expected = {:ok, "PING"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with no prefix or body" do
      irc_message = %IrcMessage{
        prefix: nil,
        command: "JOIN",
        params: ["#channel"],
        body: nil
      }

      expected = {:ok, "JOIN #channel"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with a complex body" do
      irc_message = %IrcMessage{
        prefix: "user!nick@host",
        command: "PRIVMSG",
        params: ["#channel"],
        body: "Some message: with multiple: colons"
      }

      expected = {:ok, ":user!nick@host PRIVMSG #channel :Some message: with multiple: colons"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with multiple parameters" do
      irc_message = %IrcMessage{
        prefix: "Nick!user@host",
        command: "MODE",
        params: ["#channel", "+o", "User"],
        body: nil
      }

      expected = {:ok, ":Nick!user@host MODE #channel +o User"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end

    test "handles malformed IRC messages" do
      irc_message = %IrcMessage{
        prefix: nil,
        command: nil,
        params: [],
        body: nil
      }

      expected = {:error, "Invalid IRC message format"}

      assert IrcMessageParser.unparse(irc_message) == expected
    end
  end
end
