defmodule ElixIRCd.Command.TimeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Time
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles TIME command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "TIME", params: ["#anything"]}

        assert :ok = Time.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles TIME command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "TIME", params: []}

        assert :ok = Time.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ~r/^:server.example.com 391 #{user.nick} server.example.com :[A-Za-z]+ [A-Za-z]+ [0-9]{2} [0-9]{4} -- [0-9]{2}:[0-9]{2}:[0-9]{2} UTC\r\n$/}
        ])
      end)
    end
  end
end
