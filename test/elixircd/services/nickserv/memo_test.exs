defmodule ElixIRCd.Services.Nickserv.MemoTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Jobs.MemoEmailDelivery
  alias ElixIRCd.Repositories.Memos
  alias ElixIRCd.Services.Nickserv.Memo
  alias ElixIRCd.Tables.Memo, as: MemoTable
  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "handle/2" do
    test "sends, lists, reads, deletes, and clears account memos" do
      Memento.transaction!(fn ->
        insert(:registered_nick, nickname: "Sender")
        recipient = insert(:registered_nick, nickname: "Recipient")
        sender = insert(:user, nick: "Sender", identified_as: "Sender")
        recipient_user = insert(:user, nick: "Recipient", identified_as: "Recipient")

        assert :ok = Memo.handle(sender, ["MEMO", "SEND", recipient.nickname, "hello", "world"])
        assert_sent_messages([{sender.pid, ~r/memo was delivered to the NickServ inbox/}])

        [memo] = Memos.get_by_recipient(recipient.account_name)
        assert memo.body == "hello world"
        assert is_nil(memo.read_at)

        assert :ok = Memo.handle(recipient_user, ["MEMO", "LIST"])

        assert_sent_messages([
          {recipient_user.pid, ~r/NickServ memos for/},
          {recipient_user.pid, ~r/#{memo.id} unread from Sender/},
          {recipient_user.pid, ~r/End of memo list/}
        ])

        assert :ok = Memo.handle(recipient_user, ["MEMO", "READ", memo.id])

        assert_sent_messages([
          {recipient_user.pid, ~r/Memo #{memo.id} from Sender/},
          {recipient_user.pid, ":NickServ!service@irc.test NOTICE #{recipient_user.nick} :hello world\r\n"}
        ])

        {:ok, read_memo} = Memos.get_by_id(memo.id)
        assert %DateTime{} = read_memo.read_at

        assert :ok = Memo.handle(recipient_user, ["MEMO", "DEL", memo.id])
        assert Memos.get_by_recipient(recipient.account_name) == []
        assert_sent_messages([{recipient_user.pid, ~r/Memo .* has been deleted/}])

        Memos.create(%{recipient_account: recipient.account_name, sender_account: sender.identified_as, body: "one"})
        Memos.create(%{recipient_account: recipient.account_name, sender_account: sender.identified_as, body: "two"})
        assert :ok = Memo.handle(recipient_user, ["MEMO", "CLEAR"])
        assert Memos.get_by_recipient(recipient.account_name) == []
        assert_sent_messages([{recipient_user.pid, ~r/Deleted 2 memos/}])
      end)
    end

    test "supports email delivery modes" do
      Memento.transaction!(fn ->
        insert(:registered_nick, nickname: "Sender")

        only_recipient =
          insert(:registered_nick,
            nickname: "OnlyRecipient",
            email: "only@example.com",
            settings: Settings.new(%{email_memos: :only})
          )

        sender = insert(:user, nick: "Sender", identified_as: "Sender")
        parent = self()

        expect(JobQueue, :enqueue, fn MemoEmailDelivery, payload, opts ->
          send(parent, {:memo_email, payload, opts})
          :queued
        end)

        assert :ok = Memo.handle(sender, ["MEMO", "SEND", only_recipient.nickname, "email only"])
        assert_receive {:memo_email, %{"email" => "only@example.com", "body" => "email only"}, opts}
        assert opts[:max_attempts] == 3
        assert Memos.get_by_recipient(only_recipient.account_name) == []
        assert_sent_messages([{sender.pid, ~r/forwarded to the recipient's email/}])
      end)
    end

    test "stores an ON memo when the recipient has no email" do
      Memento.transaction!(fn ->
        insert(:registered_nick, nickname: "Sender")

        recipient =
          insert(:registered_nick, nickname: "Recipient", email: nil, settings: Settings.new(%{email_memos: :on}))

        sender = insert(:user, nick: "Sender", identified_as: "Sender")

        assert :ok = Memo.handle(sender, ["MEMO", "SEND", recipient.nickname, "stored"])
        assert [%{body: "stored"}] = Memos.get_by_recipient(recipient.account_name)
      end)
    end

    test "validates recipient, message, authentication, and command syntax" do
      Memento.transaction!(fn ->
        sender_nick = insert(:registered_nick, nickname: "Sender")
        sender = insert(:user, nick: sender_nick.nickname, identified_as: sender_nick.account_name)
        anonymous = insert(:user)

        assert :ok = Memo.handle(anonymous, ["MEMO", "LIST"])

        assert_sent_messages([
          {anonymous.pid, ~r/You must identify to NickServ before using MEMO/},
          {anonymous.pid, ~r/IDENTIFY/}
        ])

        assert :ok = Memo.handle(sender, ["MEMO", "SEND", "Missing", "hello"])
        assert_sent_messages([{sender.pid, ~r/Nick .*Missing.* is not registered/}])

        assert :ok = Memo.handle(sender, ["MEMO", "SEND", sender.nick])
        assert_sent_messages([{sender.pid, ~r/Insufficient parameters for.*MEMO SEND/}, {sender.pid, ~r/Syntax:/}])

        assert :ok = Memo.handle(sender, ["MEMO", "UNKNOWN"])
        assert_sent_messages([{sender.pid, ~r/Unknown MEMO operation/}, {sender.pid, ~r/Syntax:/}])
      end)
    end

    test "supports help, case-insensitive operations, and invalid bodies" do
      Memento.transaction!(fn ->
        sender_nick = insert(:registered_nick, nickname: "Sender")
        recipient = insert(:registered_nick, nickname: "Recipient")
        sender = insert(:user, nick: sender_nick.nickname, identified_as: sender_nick.account_name)

        assert :ok = Memo.handle(sender, ["MEMO"])
        assert_sent_message_contains(sender.pid, ~r/NickServ MEMO help/)

        assert :ok = Memo.handle(sender, ["MEMO", "send", recipient.nickname, "lowercase"])
        assert_sent_message_contains(sender.pid, ~r/Your memo was delivered to the NickServ inbox/)

        assert :ok = Memo.handle(sender, ["MEMO", "unknown"])
        assert_sent_message_contains(sender.pid, ~r/Unknown MEMO operation/)

        assert :ok = Memo.handle(sender, ["MEMO", "SEND", recipient.nickname, "\n"])
        assert_sent_message_contains(sender.pid, ~r/Insufficient parameters for.*MEMO SEND/)

        assert :ok = Memo.handle(sender, ["MEMO", "SEND", recipient.nickname, String.duplicate("x", 401)])
        assert_sent_message_contains(sender.pid, ~r/Memo is too long/)

        assert :ok = Memo.handle(sender, ["MEMO", "SEND", recipient.nickname, <<255>>])
        assert_sent_message_contains(sender.pid, ~r/Memo is too long/)
      end)
    end

    test "queues ON memos and rejects email-only delivery without an email" do
      Memento.transaction!(fn ->
        insert(:registered_nick, nickname: "Sender")

        on_recipient =
          insert(:registered_nick,
            nickname: "OnRecipient",
            email: "on@example.com",
            settings: Settings.new(%{email_memos: :on})
          )

        only_recipient =
          insert(:registered_nick,
            nickname: "OnlyRecipient",
            email: nil,
            settings: Settings.new(%{email_memos: :only})
          )

        sender = insert(:user, nick: "Sender", identified_as: "Sender")
        parent = self()

        expect(JobQueue, :enqueue, fn MemoEmailDelivery, payload, opts ->
          send(parent, {:memo_email, payload, opts})
          :queued
        end)

        assert :ok = Memo.handle(sender, ["MEMO", "SEND", on_recipient.nickname, "queued"])
        assert_receive {:memo_email, %{"email" => "on@example.com", "body" => "queued"}, opts}
        assert opts[:retry_delay_ms] == 30_000

        assert :ok = Memo.handle(sender, ["MEMO", "SEND", only_recipient.nickname, "missing email"])
        assert_sent_message_contains(sender.pid, ~r/email-only memos but has no email/)
      end)
    end

    test "reports empty and unauthorized memo operations" do
      Memento.transaction!(fn ->
        recipient = insert(:registered_nick, nickname: "Recipient")
        other = insert(:registered_nick, nickname: "Other")
        recipient_user = insert(:user, nick: recipient.nickname, identified_as: recipient.account_name)
        memo = Memos.create(%{recipient_account: other.account_name, sender_account: "Sender", body: "private"})

        assert :ok = Memo.handle(recipient_user, ["MEMO", "LIST"])
        assert_sent_message_contains(recipient_user.pid, ~r/Your NickServ memo inbox is empty/)

        assert :ok = Memo.handle(recipient_user, ["MEMO", "READ", memo.id])
        assert :ok = Memo.handle(recipient_user, ["MEMO", "DEL", memo.id])
        assert :ok = Memo.handle(recipient_user, ["MEMO", "DELETE", memo.id])
        assert_sent_message_contains(recipient_user.pid, ~r/was not found in your inbox/)
        assert Memos.get_by_id("missing-memo") == {:error, :memo_not_found}
      end)
    end

    test "preserves an explicitly supplied normalized account key" do
      memo =
        MemoTable.new(%{
          recipient_account_key: "AccountKey",
          recipient_account: "Account",
          sender_account: "Sender",
          body: "body"
        })

      assert memo.recipient_account_key == "AccountKey"
    end
  end
end
