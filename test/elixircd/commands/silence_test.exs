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

    test "handles literal + parameter by showing list" do
      Memento.transaction!(fn ->
        user = insert(:user)
        UserSilences.create(%{user_pid: user.pid, mask: "nick!user@host.com"})

        message = %Message{command: "SILENCE", params: ["+"], trailing: nil}

        Silence.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 271 #{user.nick} nick!user@host.com\r\n"},
          {user.pid, ":irc.test 272 #{user.nick} :End of silence list\r\n"}
        ])
      end)
    end

    test "handles literal - parameter by showing list" do
      Memento.transaction!(fn ->
        user = insert(:user)
        UserSilences.create(%{user_pid: user.pid, mask: "nick!user@host.com"})

        message = %Message{command: "SILENCE", params: ["-"], trailing: nil}

        Silence.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 271 #{user.nick} nick!user@host.com\r\n"},
          {user.pid, ":irc.test 272 #{user.nick} :End of silence list\r\n"}
        ])
      end)
    end

    test "adds silence masks and echoes list back" do
      Memento.transaction!(fn ->
        user = insert(:user)

        # Test with + prefix
        message1 = %Message{command: "SILENCE", params: ["+nick!user@host.com"], trailing: nil}
        Silence.handle(user, message1)

        assert_sent_messages([
          {user.pid, ":irc.test 271 #{user.nick} nick!user@host.com\r\n"},
          {user.pid, ":irc.test 272 #{user.nick} :End of silence list\r\n"}
        ])

        # Test without prefix
        message2 = %Message{command: "SILENCE", params: ["test!user@example.com"], trailing: nil}
        Silence.handle(user, message2)

        assert_sent_messages(
          [
            {user.pid, ":irc.test 271 #{user.nick} nick!user@host.com\r\n"},
            {user.pid, ":irc.test 271 #{user.nick} test!user@example.com\r\n"},
            {user.pid, ":irc.test 272 #{user.nick} :End of silence list\r\n"}
          ],
          validate_order?: false
        )

        # Test in trailing
        message3 = %Message{command: "SILENCE", params: [], trailing: "spam!*@*"}
        Silence.handle(user, message3)

        assert_sent_messages(
          [
            {user.pid, ":irc.test 271 #{user.nick} nick!user@host.com\r\n"},
            {user.pid, ":irc.test 271 #{user.nick} test!user@example.com\r\n"},
            {user.pid, ":irc.test 271 #{user.nick} spam!*@*\r\n"},
            {user.pid, ":irc.test 272 #{user.nick} :End of silence list\r\n"}
          ],
          validate_order?: false
        )

        silence_list = get_user_silence_masks(user.pid)
        assert "nick!user@host.com" in silence_list
        assert "test!user@example.com" in silence_list
        assert "spam!*@*" in silence_list
      end)
    end

    test "removes silence mask and echoes list back" do
      Memento.transaction!(fn ->
        user = insert(:user)
        UserSilences.create(%{user_pid: user.pid, mask: "nick!user@host.com"})
        UserSilences.create(%{user_pid: user.pid, mask: "spam!*@*"})

        message = %Message{command: "SILENCE", params: ["-nick!user@host.com"], trailing: nil}

        Silence.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 271 #{user.nick} spam!*@*\r\n"},
          {user.pid, ":irc.test 272 #{user.nick} :End of silence list\r\n"}
        ])

        silence_list = get_user_silence_masks(user.pid)
        assert "nick!user@host.com" not in silence_list
        assert "spam!*@*" in silence_list
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

        message = %Message{command: "SILENCE", params: ["+invalid<mask>"], trailing: nil}
        Silence.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 476 #{user.nick} invalid<mask> :Invalid silence mask\r\n"}
        ])
      end)
    end

    test "echoes list when adding duplicate mask" do
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

        # Should echo the list back
        assert_sent_messages([
          {user.pid, ":irc.test 271 #{user.nick} nick!user@host.com\r\n"},
          {user.pid, ":irc.test 272 #{user.nick} :End of silence list\r\n"}
        ])
      end)
    end

    test "echoes list when removing non-existent mask" do
      Memento.transaction!(fn ->
        user = insert(:user)
        UserSilences.create(%{user_pid: user.pid, mask: "existing!user@host.com"})
        non_existent_mask = "nick!user@host.com"

        message = %Message{command: "SILENCE", params: ["-#{non_existent_mask}"], trailing: nil}
        Silence.handle(user, message)

        # Should still have the existing mask
        silence_list = get_user_silence_masks(user.pid)
        assert "existing!user@host.com" in silence_list
        assert non_existent_mask not in silence_list

        # Should echo the list back
        assert_sent_messages([
          {user.pid, ":irc.test 271 #{user.nick} existing!user@host.com\r\n"},
          {user.pid, ":irc.test 272 #{user.nick} :End of silence list\r\n"}
        ])
      end)
    end
  end
end
