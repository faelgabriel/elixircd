defmodule ElixIRCd.Commands.LinksTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Links
  alias ElixIRCd.Message

  test "returns a topology-redacted LINKS response" do
    Memento.transaction!(fn ->
      user = insert(:user)

      assert :ok = Links.handle(user, %Message{command: "LINKS", params: []})

      assert_sent_messages([
        {user.pid, ":irc.test 365 #{user.nick} * :End of /LINKS list\r\n"}
      ])
    end)
  end

  test "requires registration" do
    Memento.transaction!(fn ->
      user = insert(:user, registered: false)
      assert :ok = Links.handle(user, %Message{command: "LINKS", params: []})
      assert_sent_messages([{user.pid, ":irc.test 451 * :You have not registered\r\n"}])
    end)
  end
end
