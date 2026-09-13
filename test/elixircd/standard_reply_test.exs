defmodule ElixIRCd.StandardReplyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Message
  alias ElixIRCd.StandardReply

  describe "to_message/1" do
    for {type, verb} <- [fail: "FAIL", warn: "WARN", note: "NOTE"] do
      test "encodes #{verb} with unknown code and variable context" do
        for context <- [[], ["one"], ["one", "#two", "three"]] do
          reply = %StandardReply{
            type: unquote(type),
            command: "example",
            code: "vendor.example/unknown",
            context: context,
            description: "Details"
          }

          message = StandardReply.to_message(reply)
          assert message.command == unquote(verb)
          assert message.params == ["EXAMPLE", "VENDOR.EXAMPLE/UNKNOWN" | context]
          assert {:ok, ^message} = message |> Message.unparse!() |> Message.parse()
        end
      end
    end

    test "supports session replies and the full IRC parameter budget" do
      context = Enum.map(1..12, &Integer.to_string/1)
      reply = %StandardReply{type: :note, command: "*", code: "SESSION_INFO", context: context, description: "Details"}
      assert length(StandardReply.to_message(reply).params) == 14
      assert_raise ArgumentError, fn -> StandardReply.to_message(%{reply | context: context ++ ["13"]}) end
    end

    test "rejects malformed structural fields and message injection" do
      reply = %StandardReply{type: :fail, command: "SETNAME", code: "INVALID_REALNAME", description: "Invalid"}

      for command <- ["", "BAD COMMAND", "BAD\r\n", "123", <<255>>] do
        assert_raise ArgumentError, fn -> StandardReply.to_message(%{reply | command: command}) end
      end

      for code <- ["", ":bad", "BAD CODE", "BAD\n", <<0>>, <<255>>] do
        assert_raise ArgumentError, fn -> StandardReply.to_message(%{reply | code: code}) end
      end

      for param <- ["", ":bad", "two words", "bad\r", "bad\n", <<0>>, <<255>>] do
        assert_raise ArgumentError, fn -> StandardReply.to_message(%{reply | context: [param]}) end
      end

      for description <- ["", "bad\r\nINJECT", <<0>>, <<255>>] do
        assert_raise ArgumentError, fn -> StandardReply.to_message(%{reply | description: description}) end
      end
    end
  end

  describe "fit_message/1" do
    test "retains exact ASCII boundary and rejects oversized structured parameters" do
      message = %Message{
        prefix: "irc.test",
        command: "FAIL",
        params: ["*", "LONG"],
        trailing: String.duplicate("a", 600)
      }

      assert byte_size(message |> StandardReply.fit_message() |> Message.unparse!()) == 512

      assert_raise ArgumentError, fn ->
        StandardReply.fit_message(%{message | params: ["*", String.duplicate("A", 510)]})
      end
    end

    test "rejects missing, empty and invalid UTF-8 descriptions before fitting" do
      for {params, description} <- [{[], nil}, {["*", "CODE"], nil}, {["*", "CODE"], ""}, {["*", "CODE"], <<255>>}] do
        message = %Message{command: "FAIL", params: params, trailing: description}
        assert_raise ArgumentError, fn -> StandardReply.fit_message(message) end
      end
    end

    test "applies the same structural validation to messages sent without the builder" do
      message = %Message{prefix: "irc.test", command: "FAIL", params: ["*", "CODE"], trailing: "Details"}

      for params <- [
            [],
            ["*"],
            ["123", "CODE"],
            ["*", ":CODE"],
            ["*", "CODE", "two words"],
            ["*", "CODE" | List.duplicate("x", 13)]
          ] do
        assert_raise ArgumentError, fn -> StandardReply.fit_message(%{message | params: params}) end
      end

      for description <- ["bad\r\nINJECT", <<0>>] do
        assert_raise ArgumentError, fn -> StandardReply.fit_message(%{message | trailing: description}) end
      end
    end
  end
end
