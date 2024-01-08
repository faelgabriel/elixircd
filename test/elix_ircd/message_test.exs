defmodule ElixIRCd.MessageTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Message

  alias ElixIRCd.Message

  describe "new/1" do
    test "creates a message struct" do
      args = %{source: "irc.example.com", command: "NOTICE", params: ["user"], body: "Server restarting"}

      expected = %Message{
        source: args.source,
        command: args.command,
        params: args.params,
        body: args.body
      }

      assert Message.new(args) == expected
    end
  end

  describe "parse/1" do
    test "parses a raw message with a source" do
      raw_message = ":irc.example.com NOTICE user :Server restarting"

      expected =
        {:ok,
         %Message{
           source: "irc.example.com",
           command: "NOTICE",
           params: ["user"],
           body: "Server restarting"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message without a source" do
      raw_message = "NOTICE user :Server restarting"

      expected =
        {:ok,
         %Message{
           source: nil,
           command: "NOTICE",
           params: ["user"],
           body: "Server restarting"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with a numeric command" do
      raw_message = ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"

      expected =
        {:ok,
         %Message{
           source: "Freenode.net",
           command: "001",
           params: ["user"],
           body: "Welcome to the freenode Internet Relay Chat Network user"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with no params" do
      raw_message = ":irc.example.com PING"

      expected =
        {:ok,
         %Message{
           source: "irc.example.com",
           command: "PING",
           params: [],
           body: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with no body" do
      raw_message = ":irc.example.com JOIN #channel"

      expected =
        {:ok,
         %Message{
           source: "irc.example.com",
           command: "JOIN",
           params: ["#channel"],
           body: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with no params or body" do
      raw_message = ":irc.example.com PING"

      expected =
        {:ok,
         %Message{
           source: "irc.example.com",
           command: "PING",
           params: [],
           body: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with no source, params, or body" do
      raw_message = "PING"

      expected =
        {:ok,
         %Message{
           source: nil,
           command: "PING",
           params: [],
           body: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with no source or body" do
      raw_message = "JOIN #channel"

      expected =
        {:ok,
         %Message{
           source: nil,
           command: "JOIN",
           params: ["#channel"],
           body: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with a complex body" do
      raw_message = ":user!nick@host PRIVMSG #channel :Some message: with multiple: colons"

      expected =
        {:ok,
         %Message{
           source: "user!nick@host",
           command: "PRIVMSG",
           params: ["#channel"],
           body: "Some message: with multiple: colons"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with multiple parameters" do
      raw_message = ":Nick!user@host MODE #channel +o User"

      expected =
        {:ok,
         %Message{
           source: "Nick!user@host",
           command: "MODE",
           params: ["#channel", "+o", "User"],
           body: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "handles malformed raw messages" do
      assert Message.parse(":unexpected") ==
               {:error, "Invalid IRC message format on parsing command and params: \"\""}

      assert Message.parse(":") == {:error, "Invalid IRC message format on parsing command and params: \"\""}
      assert Message.parse(" ") == {:error, "Invalid IRC message format on parsing command and params: \" \""}
      assert Message.parse("") == {:error, "Invalid IRC message format on parsing command and params: \"\""}
    end
  end

  describe "unparse/1" do
    test "unparses a message with a source" do
      message = %Message{
        source: "irc.example.com",
        command: "NOTICE",
        params: ["user"],
        body: "Server restarting"
      }

      expected = {:ok, ":irc.example.com NOTICE user :Server restarting"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message without a source" do
      message = %Message{
        source: nil,
        command: "NOTICE",
        params: ["user"],
        body: "Server restarting"
      }

      expected = {:ok, "NOTICE user :Server restarting"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with a numeric command" do
      message = %Message{
        source: "Freenode.net",
        command: "001",
        params: ["user"],
        body: "Welcome to the freenode Internet Relay Chat Network user"
      }

      expected = {:ok, ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no params" do
      message = %Message{
        source: "irc.example.com",
        command: "PING",
        params: [],
        body: nil
      }

      expected = {:ok, ":irc.example.com PING"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no body" do
      message = %Message{
        source: "irc.example.com",
        command: "JOIN",
        params: ["#channel"],
        body: nil
      }

      expected = {:ok, ":irc.example.com JOIN #channel"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no params or body" do
      message = %Message{
        source: "irc.example.com",
        command: "PING",
        params: [],
        body: nil
      }

      expected = {:ok, ":irc.example.com PING"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no source, params, or body" do
      message = %Message{
        source: nil,
        command: "PING",
        params: [],
        body: nil
      }

      expected = {:ok, "PING"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no source or body" do
      message = %Message{
        source: nil,
        command: "JOIN",
        params: ["#channel"],
        body: nil
      }

      expected = {:ok, "JOIN #channel"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with a complex body" do
      message = %Message{
        source: "user!nick@host",
        command: "PRIVMSG",
        params: ["#channel"],
        body: "Some message: with multiple: colons"
      }

      expected = {:ok, ":user!nick@host PRIVMSG #channel :Some message: with multiple: colons"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with multiple parameters" do
      message = %Message{
        source: "Nick!user@host",
        command: "MODE",
        params: ["#channel", "+o", "User"],
        body: nil
      }

      expected = {:ok, ":Nick!user@host MODE #channel +o User"}

      assert Message.unparse(message) == expected
    end

    test "handles malformed IRC messages" do
      message = %Message{
        source: nil,
        command: nil,
        params: [],
        body: nil
      }

      expected =
        {:error,
         "Invalid IRC message format on unparsing command: %ElixIRCd.Message{source: nil, command: nil, params: [], body: nil}"}

      assert Message.unparse(message) == expected
    end
  end
end
