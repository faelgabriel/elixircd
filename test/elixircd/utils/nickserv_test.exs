defmodule ElixIRCd.Utils.NickservTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Utils.Nickserv

  describe "notify/2" do
    test "sends a single notice message to a user" do
      user = build(:user, nick: "test_user")
      message = "This is a test message"

      Dispatcher
      |> expect(:broadcast, fn msg, context, target_user ->
        assert context == :nickserv
        assert target_user == user
        assert msg.prefix == nil
        assert msg.command == "NOTICE"
        assert msg.params == ["test_user"]
        assert msg.trailing == message
        :ok
      end)

      assert Nickserv.notify(user, message) == :ok
    end

    test "sends multiple notice messages to a user" do
      user = build(:user, nick: "test_user")
      messages = ["Message 1", "Message 2", "Message 3"]

      Dispatcher
      |> expect(:broadcast, 3, fn msg, context, target_user ->
        assert context == :nickserv
        assert target_user == user
        assert msg.prefix == nil
        assert msg.command == "NOTICE"
        assert msg.params == ["test_user"]
        assert msg.trailing in messages
        :ok
      end)

      assert Nickserv.notify(user, messages) == :ok
    end
  end

  describe "email_required_format/1" do
    test "formats required email with angle brackets" do
      assert Nickserv.email_required_format(true) == "<email-address>"
    end

    test "formats optional email with square brackets" do
      assert Nickserv.email_required_format(false) == "[email-address]"
    end
  end
end
