defmodule ElixIRCd.ServerLink.DirectMessageTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Factory
  alias ElixIRCd.Repositories.UserAcceptRemotes
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.ServerLink.DirectMessage
  alias ElixIRCd.ServerLink.DirectMessage.Accepted
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.UserPayload

  test "a remote sender reaches the real local connection with its public mask" do
    {projector, uid} = local_target([])
    sender = remote_sender(modes: [:r, :x], cloaked_hostname: "cloak.example")

    assert {:ok, %Accepted{away: nil}} = DirectMessage.deliver(projector, sender, frame(uid, "hello", sender))
    assert_receive {:broadcast, ":Remote!~username@cloak.example PRIVMSG Local :hello\r\n"}
  end

  test "destination enforces registered-only, CTCP, and SILENCE policy" do
    {projector, uid} = local_target([:R, :T])
    sender = remote_sender()

    assert {:error, :registered_only} = DirectMessage.deliver(projector, sender, frame(uid, "unregistered", sender))
    refute_receive {:broadcast, _}, 20

    registered_sender = remote_sender(modes: [:r])

    assert {:error, :silent} =
             DirectMessage.deliver(projector, registered_sender, frame(uid, <<1, "VERSION", 1>>, registered_sender))

    refute_receive {:broadcast, _}, 20

    assert {:ok, %Accepted{away: nil}} =
             DirectMessage.deliver(
               projector,
               registered_sender,
               frame(uid, <<1, "ACTION waves", 1>>, registered_sender)
             )

    assert_receive {:broadcast, ":Remote!~username@remote.example PRIVMSG Local :\x01ACTION waves\x01\r\n"}

    Memento.transaction!(fn ->
      Memento.Query.write(Factory.build(:user_silence, user_pid: self(), mask: "Remote!*@*"))
    end)

    assert {:error, :silent} =
             DirectMessage.deliver(projector, registered_sender, frame(uid, "silenced", registered_sender))

    refute_receive {:broadcast, _}, 20
  end

  test "missing local UID and unregistered recipient do not receive a message" do
    {projector, uid} = local_target([])

    sender = remote_sender()

    assert {:error, :unknown_target} =
             DirectMessage.deliver(projector, sender, frame(UserPayload.new_uid(), "missing", sender))

    refute_receive {:broadcast, _}, 20

    Memento.transaction!(fn ->
      {:ok, target} = Users.get_by_pid(self())
      Users.update(target, %{registered: false})
    end)

    assert {:error, :unknown_target} = DirectMessage.deliver(projector, sender, frame(uid, "unregistered", sender))
    refute_receive {:broadcast, _}, 20
  end

  test "a +g recipient accepts an exact remote UID and rejects other senders" do
    {projector, uid} = local_target([:g])
    sender = remote_sender()
    frame = frame(uid, "hello", sender)

    assert {:error, :accept_only} = DirectMessage.deliver(projector, sender, frame)
    refute_receive {:broadcast, _}, 20

    Memento.transaction!(fn -> UserAcceptRemotes.create(self(), {"east.example", sender["uid"]}) end)
    assert {:ok, %Accepted{away: nil}} = DirectMessage.deliver(projector, sender, frame)
    assert_receive {:broadcast, ":Remote!~username@remote.example PRIVMSG Local :hello\r\n"}

    wrong_home = %{frame | "origin" => "west.example"}
    assert {:error, :accept_only} = DirectMessage.deliver(projector, sender, wrong_home)
    refute_receive {:broadcast, _}, 20
  end

  defp local_target(modes) do
    target = Factory.build(:user, nick: "Local", pid: self(), modes: modes)
    Memento.transaction!(fn -> Memento.Query.write(target) end)
    projector = start_supervised!({Projector, [name: nil, id: "irc.test"]})
    {:ok, uid} = Projector.uid_for_pid(projector, self())
    {projector, uid}
  end

  defp remote_sender(attrs \\ []) do
    attrs = Keyword.merge([nick: "Remote", hostname: "remote.example"], attrs)
    Factory.build(:user, attrs) |> UserPayload.from_local(UserPayload.new_uid())
  end

  defp frame(uid, text, sender) do
    %{
      "type" => "direct_message",
      "origin" => "east.example",
      "epoch" => UserPayload.new_uid(),
      "from_uid" => sender["uid"],
      "to_origin" => "irc.test",
      "to_uid" => uid,
      "command" => "PRIVMSG",
      "text" => text,
      "tags" => %{},
      "ttl" => 64,
      "id" => UserPayload.new_uid(),
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    }
  end
end
