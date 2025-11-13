defmodule ElixIRCd.MessageTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Message

  describe "new/1" do
    test "creates a message" do
      args = %{prefix: "irc.example.com", command: "NOTICE", params: ["user"], trailing: "Server restarting"}

      expected = %Message{
        prefix: args.prefix,
        command: args.command,
        params: args.params,
        trailing: args.trailing
      }

      assert Message.build(args) == expected
    end

    test "creates a message with numeric reply atom command" do
      args = %{prefix: "irc.test", command: :rpl_welcome, params: ["user"], trailing: "Welcome!"}

      expected = %Message{
        prefix: args.prefix,
        command: "001",
        params: args.params,
        trailing: args.trailing
      }

      assert Message.build(args) == expected
    end
  end

  describe "parse/1" do
    test "parses a raw message with a prefix" do
      raw_message = ":irc.example.com NOTICE user :Server restarting"

      expected =
        {:ok,
         %Message{
           prefix: "irc.example.com",
           command: "NOTICE",
           params: ["user"],
           trailing: "Server restarting"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message without a prefix" do
      raw_message = "NOTICE user :Server restarting"

      expected =
        {:ok,
         %Message{
           prefix: nil,
           command: "NOTICE",
           params: ["user"],
           trailing: "Server restarting"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with a numeric command" do
      raw_message = ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"

      expected =
        {:ok,
         %Message{
           prefix: "Freenode.net",
           command: "001",
           params: ["user"],
           trailing: "Welcome to the freenode Internet Relay Chat Network user"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with no params" do
      raw_message = ":irc.example.com PING"

      expected =
        {:ok,
         %Message{
           prefix: "irc.example.com",
           command: "PING",
           params: [],
           trailing: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with no trailing" do
      raw_message = ":irc.example.com JOIN #channel"

      expected =
        {:ok,
         %Message{
           prefix: "irc.example.com",
           command: "JOIN",
           params: ["#channel"],
           trailing: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with no params or trailing" do
      raw_message = ":irc.example.com PING"

      expected =
        {:ok,
         %Message{
           prefix: "irc.example.com",
           command: "PING",
           params: [],
           trailing: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with no prefix, params, or trailing" do
      raw_message = "PING"

      expected =
        {:ok,
         %Message{
           prefix: nil,
           command: "PING",
           params: [],
           trailing: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with no prefix or trailing" do
      raw_message = "JOIN #channel"

      expected =
        {:ok,
         %Message{
           prefix: nil,
           command: "JOIN",
           params: ["#channel"],
           trailing: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with a complex trailing" do
      raw_message = ":user!nick@host PRIVMSG #channel :Some message: with multiple: colons"

      expected =
        {:ok,
         %Message{
           prefix: "user!nick@host",
           command: "PRIVMSG",
           params: ["#channel"],
           trailing: "Some message: with multiple: colons"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with multiple parameters" do
      raw_message = ":Nick!user@host MODE #channel +o User"

      expected =
        {:ok,
         %Message{
           prefix: "Nick!user@host",
           command: "MODE",
           params: ["#channel", "+o", "User"],
           trailing: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a raw message with colon inside a parameter" do
      raw_message = ":Nick!user@host MODE #channel +b nick:user@host"

      expected =
        {:ok,
         %Message{
           prefix: "Nick!user@host",
           command: "MODE",
           params: ["#channel", "+b", "nick:user@host"],
           trailing: nil
         }}

      assert Message.parse(raw_message) == expected
    end

    test "handles malformed raw messages" do
      assert Message.parse(":unexpected") ==
               {:error, "Invalid IRC message format on parsing command and params: \"\""}

      assert Message.parse(":") == {:error, "Invalid IRC message format on parsing command and params: \"\""}
      assert Message.parse(" ") == {:error, "Invalid IRC message format on parsing command and params: \"\""}
      assert Message.parse("") == {:error, "Invalid IRC message format on parsing command and params: \"\""}
    end
  end

  describe "parse!/1" do
    test "parses a raw message" do
      raw_message = ":irc.example.com NOTICE user :Server restarting"

      expected =
        %Message{
          prefix: "irc.example.com",
          command: "NOTICE",
          params: ["user"],
          trailing: "Server restarting"
        }

      assert Message.parse!(raw_message) == expected
    end

    test "raises an ArgumentError on a malformed raw message" do
      assert_raise ArgumentError, "Invalid IRC message format on parsing command and params: \"\"", fn ->
        Message.parse!(":unexpected")
      end

      assert_raise ArgumentError, "Invalid IRC message format on parsing command and params: \"\"", fn ->
        Message.parse!(":")
      end

      assert_raise ArgumentError, "Invalid IRC message format on parsing command and params: \"\"", fn ->
        Message.parse!(" ")
      end

      assert_raise ArgumentError, "Invalid IRC message format on parsing command and params: \"\"", fn ->
        Message.parse!("")
      end
    end
  end

  describe "unparse/1" do
    test "unparses a message with a prefix" do
      message = %Message{
        prefix: "irc.example.com",
        command: "NOTICE",
        params: ["user"],
        trailing: "Server restarting"
      }

      expected = {:ok, ":irc.example.com NOTICE user :Server restarting\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message without a prefix" do
      message = %Message{
        prefix: nil,
        command: "NOTICE",
        params: ["user"],
        trailing: "Server restarting"
      }

      expected = {:ok, "NOTICE user :Server restarting\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with a numeric command" do
      message = %Message{
        prefix: "Freenode.net",
        command: "001",
        params: ["user"],
        trailing: "Welcome to the freenode Internet Relay Chat Network user"
      }

      expected = {:ok, ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no params" do
      message = %Message{
        prefix: "irc.example.com",
        command: "PING",
        params: [],
        trailing: nil
      }

      expected = {:ok, ":irc.example.com PING\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no trailing" do
      message = %Message{
        prefix: "irc.example.com",
        command: "JOIN",
        params: ["#channel"],
        trailing: nil
      }

      expected = {:ok, ":irc.example.com JOIN #channel\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no params or trailing" do
      message = %Message{
        prefix: "irc.example.com",
        command: "PING",
        params: [],
        trailing: nil
      }

      expected = {:ok, ":irc.example.com PING\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no prefix, params, or trailing" do
      message = %Message{
        prefix: nil,
        command: "PING",
        params: [],
        trailing: nil
      }

      expected = {:ok, "PING\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no prefix or trailing" do
      message = %Message{
        prefix: nil,
        command: "JOIN",
        params: ["#channel"],
        trailing: nil
      }

      expected = {:ok, "JOIN #channel\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with a complex trailing" do
      message = %Message{
        prefix: "user!nick@host",
        command: "PRIVMSG",
        params: ["#channel"],
        trailing: "Some message: with multiple: colons"
      }

      expected = {:ok, ":user!nick@host PRIVMSG #channel :Some message: with multiple: colons\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with multiple parameters" do
      message = %Message{
        prefix: "Nick!user@host",
        command: "MODE",
        params: ["#channel", "+o", "User"],
        trailing: nil
      }

      expected = {:ok, ":Nick!user@host MODE #channel +o User\r\n"}

      assert Message.unparse(message) == expected
    end

    test "handles malformed IRC messages" do
      message = %Message{
        tags: %{},
        prefix: nil,
        command: "",
        params: [],
        trailing: nil
      }

      expected =
        {:error,
         "Invalid IRC message format on unparsing command: %ElixIRCd.Message{tags: %{}, prefix: nil, command: \"\", params: [], trailing: nil}"}

      assert Message.unparse(message) == expected
    end
  end

  describe "unparse!/1" do
    test "unparses a message" do
      message = %Message{
        prefix: "irc.example.com",
        command: "NOTICE",
        params: ["user"],
        trailing: "Server restarting"
      }

      expected = ":irc.example.com NOTICE user :Server restarting\r\n"

      assert Message.unparse!(message) == expected
    end

    test "raises an ArgumentError on a malformed IRC message" do
      message = %Message{
        tags: %{},
        prefix: nil,
        command: "",
        params: [],
        trailing: nil
      }

      assert_raise ArgumentError,
                   "Invalid IRC message format on unparsing command: %ElixIRCd.Message{tags: %{}, prefix: nil, command: \"\", params: [], trailing: nil}",
                   fn ->
                     Message.unparse!(message)
                   end
    end
  end

  describe "parse/1 - IRCv3 message tags" do
    test "parses a message with a single tag without value" do
      raw_message = "@bot :irc.example.com PRIVMSG #channel :hello"

      expected =
        {:ok,
         %Message{
           tags: %{"bot" => nil},
           prefix: "irc.example.com",
           command: "PRIVMSG",
           params: ["#channel"],
           trailing: "hello"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a message with a single tag with value" do
      raw_message = "@account=user123 :irc.example.com PRIVMSG #channel :hello"

      expected =
        {:ok,
         %Message{
           tags: %{"account" => "user123"},
           prefix: "irc.example.com",
           command: "PRIVMSG",
           params: ["#channel"],
           trailing: "hello"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a message with multiple tags" do
      raw_message = "@bot;account=user123;msgid=abc :irc.example.com PRIVMSG #channel :hello"

      expected =
        {:ok,
         %Message{
           tags: %{"bot" => nil, "account" => "user123", "msgid" => "abc"},
           prefix: "irc.example.com",
           command: "PRIVMSG",
           params: ["#channel"],
           trailing: "hello"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a message with tags without prefix" do
      raw_message = "@bot PRIVMSG #channel :hello"

      expected =
        {:ok,
         %Message{
           tags: %{"bot" => nil},
           prefix: nil,
           command: "PRIVMSG",
           params: ["#channel"],
           trailing: "hello"
         }}

      assert Message.parse(raw_message) == expected
    end

    test "parses a message with escaped tag values" do
      raw_message = "@msg=hello\\sworld\\:\\ntest\\r\\nvalue\\\\end :irc.example.com PRIVMSG #channel :hello"

      expected =
        {:ok,
         %Message{
           tags: %{"msg" => "hello world;\ntest\r\nvalue\\end"},
           prefix: "irc.example.com",
           command: "PRIVMSG",
           params: ["#channel"],
           trailing: "hello"
         }}

      assert Message.parse(raw_message) == expected
    end
  end

  describe "unparse/1 - IRCv3 message tags" do
    test "unparses a message with a single tag without value" do
      message = %Message{
        tags: %{"bot" => nil},
        prefix: "irc.example.com",
        command: "PRIVMSG",
        params: ["#channel"],
        trailing: "hello"
      }

      expected = {:ok, "@bot :irc.example.com PRIVMSG #channel :hello\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with a single tag with value" do
      message = %Message{
        tags: %{"account" => "user123"},
        prefix: "irc.example.com",
        command: "PRIVMSG",
        params: ["#channel"],
        trailing: "hello"
      }

      expected = {:ok, "@account=user123 :irc.example.com PRIVMSG #channel :hello\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with multiple tags" do
      message = %Message{
        tags: %{"bot" => nil, "account" => "user123"},
        prefix: "irc.example.com",
        command: "PRIVMSG",
        params: ["#channel"],
        trailing: "hello"
      }

      {:ok, result} = Message.unparse(message)

      # Tags can be in any order, so we just check that both are present
      assert String.contains?(result, "@")
      assert String.contains?(result, "bot")
      assert String.contains?(result, "account=user123")
      assert String.ends_with?(result, ":irc.example.com PRIVMSG #channel :hello\r\n")
    end

    test "unparses a message with tags without prefix" do
      message = %Message{
        tags: %{"bot" => nil},
        prefix: nil,
        command: "PRIVMSG",
        params: ["#channel"],
        trailing: "hello"
      }

      expected = {:ok, "@bot PRIVMSG #channel :hello\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with escaped tag values" do
      message = %Message{
        tags: %{"msg" => "hello world;\ntest\r\nvalue\\end"},
        prefix: "irc.example.com",
        command: "PRIVMSG",
        params: ["#channel"],
        trailing: "hello"
      }

      expected = {:ok, "@msg=hello\\sworld\\:\\ntest\\r\\nvalue\\\\end :irc.example.com PRIVMSG #channel :hello\r\n"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message without tags (empty map)" do
      message = %Message{
        tags: %{},
        prefix: "irc.example.com",
        command: "PRIVMSG",
        params: ["#channel"],
        trailing: "hello"
      }

      expected = {:ok, ":irc.example.com PRIVMSG #channel :hello\r\n"}

      assert Message.unparse(message) == expected
    end
  end
end
