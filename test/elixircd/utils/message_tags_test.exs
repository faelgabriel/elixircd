defmodule ElixIRCd.Utils.MessageTagsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ElixIRCd.Factory

  alias ElixIRCd.Message
  alias ElixIRCd.Utils.MessageTags

  describe "maybe_add_bot_tag/2" do
    test "adds bot tag when user has +B mode" do
      user = build(:user, modes: ["B"])
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      result = MessageTags.maybe_add_bot_tag(message, user)

      assert result.tags == %{"bot" => nil}
    end

    test "does not add bot tag when user does not have +B mode" do
      user = build(:user, modes: [])
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      result = MessageTags.maybe_add_bot_tag(message, user)

      assert result.tags == %{}
    end

    test "does not add bot tag when user has other modes but not +B" do
      user = build(:user, modes: ["i", "w"])
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      result = MessageTags.maybe_add_bot_tag(message, user)

      assert result.tags == %{}
    end
  end

  describe "add_tag/3" do
    test "adds a tag with value to message" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      result = MessageTags.add_tag(message, "account", "user123")

      assert result.tags == %{"account" => "user123"}
    end

    test "adds a tag without value to message" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      result = MessageTags.add_tag(message, "bot", nil)

      assert result.tags == %{"bot" => nil}
    end

    test "adds multiple tags to message" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      result =
        message
        |> MessageTags.add_tag("bot", nil)
        |> MessageTags.add_tag("account", "user123")

      assert result.tags == %{"bot" => nil, "account" => "user123"}
    end

    test "overwrites existing tag with same key" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      result =
        message
        |> MessageTags.add_tag("account", "user123")
        |> MessageTags.add_tag("account", "user456")

      assert result.tags == %{"account" => "user456"}
    end
  end

  describe "remove_tag/2" do
    test "removes a tag from message" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})
      message_with_tag = MessageTags.add_tag(message, "bot", nil)

      result = MessageTags.remove_tag(message_with_tag, "bot")

      assert result.tags == %{}
    end

    test "removes specific tag and keeps others" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      message_with_tags =
        message
        |> MessageTags.add_tag("bot", nil)
        |> MessageTags.add_tag("account", "user123")

      result = MessageTags.remove_tag(message_with_tags, "bot")

      assert result.tags == %{"account" => "user123"}
    end

    test "does not error when removing non-existent tag" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      result = MessageTags.remove_tag(message, "nonexistent")

      assert result.tags == %{}
    end
  end

  describe "has_tag?/2" do
    test "returns true when tag exists with value" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})
      message_with_tag = MessageTags.add_tag(message, "account", "user123")

      assert MessageTags.has_tag?(message_with_tag, "account")
    end

    test "returns true when tag exists without value" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})
      message_with_tag = MessageTags.add_tag(message, "bot", nil)

      assert MessageTags.has_tag?(message_with_tag, "bot")
    end

    test "returns false when tag does not exist" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      refute MessageTags.has_tag?(message, "nonexistent")
    end
  end

  describe "get_tag/2" do
    test "returns tag value when tag exists with value" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})
      message_with_tag = MessageTags.add_tag(message, "account", "user123")

      assert MessageTags.get_tag(message_with_tag, "account") == "user123"
    end

    test "returns nil when tag exists without value" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})
      message_with_tag = MessageTags.add_tag(message, "bot", nil)

      assert MessageTags.get_tag(message_with_tag, "bot") == nil
    end

    test "returns nil when tag does not exist" do
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      assert MessageTags.get_tag(message, "nonexistent") == nil
    end
  end

  describe "filter_tags_for_recipient/2" do
    test "keeps tags when recipient has MESSAGE-TAGS capability" do
      user = build(:user, capabilities: ["MESSAGE-TAGS"])

      message =
        Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})
        |> MessageTags.add_tag("bot", nil)
        |> MessageTags.add_tag("account", "user123")

      result = MessageTags.filter_tags_for_recipient(message, user)

      assert result.tags == %{"bot" => nil, "account" => "user123"}
    end

    test "removes all tags when recipient does not have MESSAGE-TAGS capability" do
      user = build(:user, capabilities: [])

      message =
        Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})
        |> MessageTags.add_tag("bot", nil)
        |> MessageTags.add_tag("account", "user123")

      result = MessageTags.filter_tags_for_recipient(message, user)

      assert result.tags == %{}
    end

    test "keeps tags when recipient has MESSAGE-TAGS and other capabilities" do
      user = build(:user, capabilities: ["MESSAGE-TAGS", "UHNAMES"])

      message =
        Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})
        |> MessageTags.add_tag("bot", nil)

      result = MessageTags.filter_tags_for_recipient(message, user)

      assert result.tags == %{"bot" => nil}
    end

    test "removes tags when recipient has other capabilities but not MESSAGE-TAGS" do
      user = build(:user, capabilities: ["UHNAMES"])

      message =
        Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})
        |> MessageTags.add_tag("bot", nil)

      result = MessageTags.filter_tags_for_recipient(message, user)

      assert result.tags == %{}
    end
  end
end
