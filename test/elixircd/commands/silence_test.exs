defmodule ElixIRCd.Commands.SilenceTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Silence
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserSilences

  defp get_user_silence_masks(user_pid) do
    UserSilences.get_by_user_pid(user_pid)
    |> Enum.map(& &1.mask)
  end

  describe "handle/2" do
    test "requires registration" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "SILENCE", params: [], trailing: nil}

        Silence.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "shows empty silence list" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "SILENCE", params: [], trailing: nil}

        Silence.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 272 #{user.nick} :End of silence list\r\n"}
        ])
      end)
    end

    test "shows silence list with entries" do
      Memento.transaction!(fn ->
        user = insert(:user)
        UserSilences.create(%{user_pid: user.pid, mask: "nick!user@host.com"})
        UserSilences.create(%{user_pid: user.pid, mask: "spam!*@*"})

        message = %Message{command: "SILENCE", params: [], trailing: nil}

        Silence.handle(user, message)

        assert_sent_messages(
          [
            {user.pid, ":irc.test 271 #{user.nick} nick!user@host.com\r\n"},
            {user.pid, ":irc.test 271 #{user.nick} spam!*@*\r\n"},
            {user.pid, ":irc.test 272 #{user.nick} :End of silence list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "adds silence masks in various valid formats" do
      Memento.transaction!(fn ->
        user = insert(:user)

        # Test with + prefix
        message1 = %Message{command: "SILENCE", params: ["+nick!user@host.com"], trailing: nil}
        Silence.handle(user, message1)

        # Test without prefix
        message2 = %Message{command: "SILENCE", params: ["test!user@example.com"], trailing: nil}
        Silence.handle(user, message2)

        # Test in trailing
        message3 = %Message{command: "SILENCE", params: [], trailing: "spam!*@*"}
        Silence.handle(user, message3)

        silence_list = get_user_silence_masks(user.pid)
        assert "nick!user@host.com" in silence_list
        assert "test!user@example.com" in silence_list
        assert "spam!*@*" in silence_list
      end)
    end

    test "removes silence mask with - prefix" do
      Memento.transaction!(fn ->
        user = insert(:user)
        UserSilences.create(%{user_pid: user.pid, mask: "nick!user@host.com"})

        message = %Message{command: "SILENCE", params: ["-nick!user@host.com"], trailing: nil}

        Silence.handle(user, message)

        silence_list = get_user_silence_masks(user.pid)
        assert "nick!user@host.com" not in silence_list
      end)
    end

    test "rejects when silence list is full" do
      Memento.transaction!(fn ->
        user = insert(:user)

        # Add 15 entries (the maximum)
        for i <- 1..15 do
          UserSilences.create(%{user_pid: user.pid, mask: "nick#{i}!user@host.com"})
        end

        message = %Message{command: "SILENCE", params: ["nick16!user@host.com"], trailing: nil}

        Silence.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 511 #{user.nick} :Silence list is full\r\n"}
        ])
      end)
    end

    test "shows need more params error for invalid message" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "SILENCE", params: [""], trailing: nil}

        Silence.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} SILENCE :Not enough parameters\r\n"}
        ])
      end)
    end

    test "rejects invalid masks" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "SILENCE", params: ["+"], trailing: nil}
        Silence.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 512 #{user.nick} :Invalid silence mask\r\n"}
        ])
      end)
    end

    test "ignores duplicate mask additions" do
      Memento.transaction!(fn ->
        user = insert(:user)
        mask = "nick!user@host.com"
        UserSilences.create(%{user_pid: user.pid, mask: mask})

        message = %Message{command: "SILENCE", params: [mask], trailing: nil}
        Silence.handle(user, message)

        silence_list = get_user_silence_masks(user.pid)
        # Should still only have one instance of the mask
        assert length(silence_list) == 1
        assert mask in silence_list

        # No error message should be sent
        assert_sent_messages([])
      end)
    end

    test "ignores removal of non-existent mask" do
      Memento.transaction!(fn ->
        user = insert(:user)
        non_existent_mask = "nick!user@host.com"

        message = %Message{command: "SILENCE", params: ["-#{non_existent_mask}"], trailing: nil}
        Silence.handle(user, message)

        # Should still be empty
        silence_list = get_user_silence_masks(user.pid)
        assert Enum.empty?(silence_list)

        # No error message should be sent
        assert_sent_messages([])
      end)
    end
  end
end
