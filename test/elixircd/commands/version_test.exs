defmodule ElixIRCd.Commands.VersionTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Version
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles VERSION command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "VERSION", params: ["#anything"]}

        assert :ok = Version.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles VERSION command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "VERSION", params: []}
        elixircd_version = Application.spec(:elixircd, :vsn)

        assert :ok = Version.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 351 #{user.nick} ElixIRCd-#{elixircd_version} irc.test\r\n"}
        ])
      end)
    end
  end
end
