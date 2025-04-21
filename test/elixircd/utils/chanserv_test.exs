defmodule ElixIRCd.Utils.ChanservTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Utils.Chanserv

  describe "notify/2" do
    test "sends a single notice message to a user" do
      hostname = Application.get_env(:elixircd, :server)[:hostname]
      user = build(:user, nick: "test_user")
      message = "This is a test message"

      Dispatcher
      |> expect(:broadcast, fn msg, target_user ->
        assert target_user == user
        assert msg.prefix == "ChanServ!service@#{hostname}"
        assert msg.command == "NOTICE"
        assert msg.params == ["test_user"]
        assert msg.trailing == message
        :ok
      end)

      assert Chanserv.notify(user, message) == :ok
    end

    test "sends multiple notice messages to a user" do
      hostname = Application.get_env(:elixircd, :server)[:hostname]
      user = build(:user, nick: "test_user")
      messages = ["Message 1", "Message 2", "Message 3"]

      Dispatcher
      |> expect(:broadcast, 3, fn msg, target_user ->
        assert target_user == user
        assert msg.prefix == "ChanServ!service@#{hostname}"
        assert msg.command == "NOTICE"
        assert msg.params == ["test_user"]
        assert msg.trailing in messages
        :ok
      end)

      assert Chanserv.notify(user, messages) == :ok
    end
  end
end
