defmodule ElixIRCd.MessageTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Message

  @supported_numeric_replies [
    {:rpl_welcome, "001"},
    {:rpl_yourhost, "002"},
    {:rpl_created, "003"},
    {:rpl_myinfo, "004"},
    {:rpl_userhost, "302"},
    {:rpl_whoisuser, "311"},
    {:rpl_whoisserver, "312"},
    {:rpl_whoisidle, "317"},
    {:rpl_endofwhois, "318"},
    {:rpl_whoischannels, "319"},
    {:rpl_topic, "332"},
    {:rpl_namreply, "353"},
    {:rpl_endofnames, "366"},
    {:rpl_endofmotd, "376"},
    {:err_nosuchnick, "401"},
    {:err_nosuchchannel, "403"},
    {:err_unknowncommand, "421"},
    {:err_erroneusnickname, "432"},
    {:err_nicknameinuse, "433"},
    {:err_notonchannel, "442"},
    {:err_notregistered, "451"},
    {:err_needmoreparams, "461"},
    {:err_passwdmismatch, "464"},
    {:err_cannotjoinchannel, "473"}
  ]

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

    test "creates a message with :server atom prefix" do
      args = %{prefix: :server, command: "NOTICE", params: ["user"], trailing: "Server restarting"}

      expected = %Message{
        prefix: "server.example.com",
        command: args.command,
        params: args.params,
        trailing: args.trailing
      }

      assert Message.build(args) == expected
    end

    test "creates a message with numeric reply atom command" do
      @supported_numeric_replies
      |> Enum.each(fn {reply_code, numeric_reply} ->
        args = %{prefix: "server.example.com", command: reply_code, params: ["user"], trailing: "Welcome!"}

        expected = %Message{
          prefix: args.prefix,
          command: numeric_reply,
          params: args.params,
          trailing: args.trailing
        }

        assert Message.build(args) == expected
      end)
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

      expected = {:ok, ":irc.example.com NOTICE user :Server restarting"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message without a prefix" do
      message = %Message{
        prefix: nil,
        command: "NOTICE",
        params: ["user"],
        trailing: "Server restarting"
      }

      expected = {:ok, "NOTICE user :Server restarting"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with a numeric command" do
      message = %Message{
        prefix: "Freenode.net",
        command: "001",
        params: ["user"],
        trailing: "Welcome to the freenode Internet Relay Chat Network user"
      }

      expected = {:ok, ":Freenode.net 001 user :Welcome to the freenode Internet Relay Chat Network user"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no params" do
      message = %Message{
        prefix: "irc.example.com",
        command: "PING",
        params: [],
        trailing: nil
      }

      expected = {:ok, ":irc.example.com PING"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no trailing" do
      message = %Message{
        prefix: "irc.example.com",
        command: "JOIN",
        params: ["#channel"],
        trailing: nil
      }

      expected = {:ok, ":irc.example.com JOIN #channel"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no params or trailing" do
      message = %Message{
        prefix: "irc.example.com",
        command: "PING",
        params: [],
        trailing: nil
      }

      expected = {:ok, ":irc.example.com PING"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no prefix, params, or trailing" do
      message = %Message{
        prefix: nil,
        command: "PING",
        params: [],
        trailing: nil
      }

      expected = {:ok, "PING"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with no prefix or trailing" do
      message = %Message{
        prefix: nil,
        command: "JOIN",
        params: ["#channel"],
        trailing: nil
      }

      expected = {:ok, "JOIN #channel"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with a complex trailing" do
      message = %Message{
        prefix: "user!nick@host",
        command: "PRIVMSG",
        params: ["#channel"],
        trailing: "Some message: with multiple: colons"
      }

      expected = {:ok, ":user!nick@host PRIVMSG #channel :Some message: with multiple: colons"}

      assert Message.unparse(message) == expected
    end

    test "unparses a message with multiple parameters" do
      message = %Message{
        prefix: "Nick!user@host",
        command: "MODE",
        params: ["#channel", "+o", "User"],
        trailing: nil
      }

      expected = {:ok, ":Nick!user@host MODE #channel +o User"}

      assert Message.unparse(message) == expected
    end

    test "handles malformed IRC messages" do
      message = %Message{
        prefix: nil,
        command: "",
        params: [],
        trailing: nil
      }

      expected =
        {:error,
         "Invalid IRC message format on unparsing command: %ElixIRCd.Message{prefix: nil, command: \"\", params: [], trailing: nil}"}

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

      expected = ":irc.example.com NOTICE user :Server restarting"

      assert Message.unparse!(message) == expected
    end

    test "raises an ArgumentError on a malformed IRC message" do
      message = %Message{
        prefix: nil,
        command: "",
        params: [],
        trailing: nil
      }

      assert_raise ArgumentError,
                   "Invalid IRC message format on unparsing command: %ElixIRCd.Message{prefix: nil, command: \"\", params: [], trailing: nil}",
                   fn ->
                     Message.unparse!(message)
                   end
    end
  end
end
