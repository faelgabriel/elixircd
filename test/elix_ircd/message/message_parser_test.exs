defmodule ElixIRCd.Message.MessageParserTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Message.MessageParser

  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageParser

  describe "parse/1" do
    test "parses a message with a source" do
      message = ":irc.example.com NOTICE user :Server restarting"

      expected =
        {:ok,
         %Message{
           source: "irc.example.com",
           command: "NOTICE",
           params: ["user"],
           body: "Server restarting"
         }}

      assert MessageParser.parse(message) == expected
    end

    test "parses a message without a source" do
      message = "NOTICE user :Server restarting"

      expected =
        {:ok,
         %Message{
           source: nil,
           command: "NOTICE",
           params: ["user"],
           body: "Server restarting"
         }}

      assert MessageParser.parse(message) == expected
    end

    test "parses a message with a numeric command" do
      message = ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"

      expected =
        {:ok,
         %Message{
           source: "Freenode.net",
           command: "001",
           params: ["user"],
           body: "Welcome to the freenode Internet Relay Chat Network user"
         }}

      assert MessageParser.parse(message) == expected
    end

    test "parses a message with no params" do
      message = ":irc.example.com PING"

      expected =
        {:ok,
         %Message{
           source: "irc.example.com",
           command: "PING",
           params: [],
           body: nil
         }}

      assert MessageParser.parse(message) == expected
    end

    test "parses a message with no body" do
      message = ":irc.example.com JOIN #channel"

      expected =
        {:ok,
         %Message{
           source: "irc.example.com",
           command: "JOIN",
           params: ["#channel"],
           body: nil
         }}

      assert MessageParser.parse(message) == expected
    end

    test "parses a message with no params or body" do
      message = ":irc.example.com PING"

      expected =
        {:ok,
         %Message{
           source: "irc.example.com",
           command: "PING",
           params: [],
           body: nil
         }}

      assert MessageParser.parse(message) == expected
    end

    test "parses a message with no source, params, or body" do
      message = "PING"

      expected =
        {:ok,
         %Message{
           source: nil,
           command: "PING",
           params: [],
           body: nil
         }}

      assert MessageParser.parse(message) == expected
    end

    test "parses a message with no source or body" do
      message = "JOIN #channel"

      expected =
        {:ok,
         %Message{
           source: nil,
           command: "JOIN",
           params: ["#channel"],
           body: nil
         }}

      assert MessageParser.parse(message) == expected
    end

    test "parses a message with a complex body" do
      message = ":user!nick@host PRIVMSG #channel :Some message: with multiple: colons"

      expected =
        {:ok,
         %Message{
           source: "user!nick@host",
           command: "PRIVMSG",
           params: ["#channel"],
           body: "Some message: with multiple: colons"
         }}

      assert MessageParser.parse(message) == expected
    end

    test "parses a message with multiple parameters" do
      message = ":Nick!user@host MODE #channel +o User"

      expected =
        {:ok,
         %Message{
           source: "Nick!user@host",
           command: "MODE",
           params: ["#channel", "+o", "User"],
           body: nil
         }}

      assert MessageParser.parse(message) == expected
    end

    test "handles malformed messages" do
      assert MessageParser.parse(":unexpected") ==
               {:error, "Invalid IRC message format on parsing command and params: \"\""}

      assert MessageParser.parse(":") == {:error, "Invalid IRC message format on parsing command and params: \"\""}
      assert MessageParser.parse(" ") == {:error, "Invalid IRC message format on parsing command and params: \" \""}
      assert MessageParser.parse("") == {:error, "Invalid IRC message format on parsing command and params: \"\""}
    end
  end

  describe "unparse/1" do
    test "unparses a message with a source" do
      irc_message = %Message{
        source: "irc.example.com",
        command: "NOTICE",
        params: ["user"],
        body: "Server restarting"
      }

      expected = {:ok, ":irc.example.com NOTICE user :Server restarting"}

      assert MessageParser.unparse(irc_message) == expected
    end

    test "unparses a message without a source" do
      irc_message = %Message{
        source: nil,
        command: "NOTICE",
        params: ["user"],
        body: "Server restarting"
      }

      expected = {:ok, "NOTICE user :Server restarting"}

      assert MessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with a numeric command" do
      irc_message = %Message{
        source: "Freenode.net",
        command: "001",
        params: ["user"],
        body: "Welcome to the freenode Internet Relay Chat Network user"
      }

      expected = {:ok, ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"}

      assert MessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with no params" do
      irc_message = %Message{
        source: "irc.example.com",
        command: "PING",
        params: [],
        body: nil
      }

      expected = {:ok, ":irc.example.com PING"}

      assert MessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with no body" do
      irc_message = %Message{
        source: "irc.example.com",
        command: "JOIN",
        params: ["#channel"],
        body: nil
      }

      expected = {:ok, ":irc.example.com JOIN #channel"}

      assert MessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with no params or body" do
      irc_message = %Message{
        source: "irc.example.com",
        command: "PING",
        params: [],
        body: nil
      }

      expected = {:ok, ":irc.example.com PING"}

      assert MessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with no source, params, or body" do
      irc_message = %Message{
        source: nil,
        command: "PING",
        params: [],
        body: nil
      }

      expected = {:ok, "PING"}

      assert MessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with no source or body" do
      irc_message = %Message{
        source: nil,
        command: "JOIN",
        params: ["#channel"],
        body: nil
      }

      expected = {:ok, "JOIN #channel"}

      assert MessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with a complex body" do
      irc_message = %Message{
        source: "user!nick@host",
        command: "PRIVMSG",
        params: ["#channel"],
        body: "Some message: with multiple: colons"
      }

      expected = {:ok, ":user!nick@host PRIVMSG #channel :Some message: with multiple: colons"}

      assert MessageParser.unparse(irc_message) == expected
    end

    test "unparses a message with multiple parameters" do
      irc_message = %Message{
        source: "Nick!user@host",
        command: "MODE",
        params: ["#channel", "+o", "User"],
        body: nil
      }

      expected = {:ok, ":Nick!user@host MODE #channel +o User"}

      assert MessageParser.unparse(irc_message) == expected
    end

    test "handles malformed IRC messages" do
      irc_message = %Message{
        source: nil,
        command: nil,
        params: [],
        body: nil
      }

      expected =
        {:error,
         "Invalid IRC message format on unparsing command: %ElixIRCd.Message.Message{source: nil, command: nil, params: [], body: nil}"}

      assert MessageParser.unparse(irc_message) == expected
    end
  end
end
