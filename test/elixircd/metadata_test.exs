defmodule ElixIRCd.MetadataTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Metadata
  alias ElixIRCd.Repositories.Metadata, as: MetadataRepository
  alias ElixIRCd.Repositories.MetadataSubscriptions

  test "resolves user and channel targets with privacy and write policy" do
    Memento.transaction!(fn ->
      alice = insert(:user, nick: "Alice")
      bob = insert(:user, nick: "Bob")
      oper = insert(:user, nick: "Oper", modes: [:o])
      public = insert(:channel, name: "&public")
      private = insert(:channel, name: "#private", modes: [{:i, "key"}])

      assert {:ok, %{type: :session, entity: ^alice}} = Metadata.resolve_target(alice, "Alice")
      assert {:error, :invalid_target} = Metadata.resolve_target(alice, "Missing")
      assert {:ok, %{entity: ^public}} = Metadata.resolve_target(alice, "&public")
      assert {:error, :no_permission} = Metadata.resolve_target(alice, "#private")
      assert {:ok, %{entity: ^private}} = Metadata.resolve_target(oper, "#private")
      assert {:error, :invalid_target} = Metadata.resolve_target(alice, "#missing")

      {:ok, alice_target} = Metadata.resolve_target(alice, "*")
      assert Metadata.writable?(alice, alice_target)
      assert Metadata.writable?(oper, alice_target)
      refute Metadata.writable?(bob, alice_target)

      {:ok, private_target} = Metadata.resolve_target(oper, "#private")
      refute Metadata.writable?(alice, private_target)
      insert(:user_channel, user: alice, channel: private, modes: [:o])
      assert Metadata.writable?(alice, private_target)
    end)
  end

  test "deletes, clears, migrates and disconnects durable and session metadata" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice")
      {:ok, target} = Metadata.resolve_target(user, "*")

      assert :not_found = Metadata.delete(target, "missing")
      entry = Metadata.put(target, "one", "1")
      assert ^entry = Metadata.delete(target, "one")

      Metadata.put(target, "two", "2")
      assert [_] = Metadata.clear(target)

      Metadata.put(target, "three", "3")
      assert %{} = Metadata.subscribe(user, "three")
      assert MetadataSubscriptions.subscribed?(user.pid, "three")
      assert ["three"] = Metadata.subscriptions(user)
      assert :ok = Metadata.unsubscribe(user, "three")
      assert [] = Metadata.subscriptions(user)
      assert :ok = Metadata.disconnect(user)
      assert [] = Metadata.list(target)

      identified = insert(:user, nick: "Identified", identified_as: "Account")
      session_key = identified.pid |> :erlang.pid_to_list() |> to_string()
      MetadataRepository.put(:session, session_key, "migrated", "yes")
      assert MetadataRepository.get(:session, session_key, "migrated").value == "yes"
      assert :ok = Metadata.migrate_to_account(identified)
      {:ok, account_target} = Metadata.resolve_target(identified, "*")
      assert Metadata.get(account_target, "migrated").value == "yes"
      assert :ok = Metadata.disconnect(identified)
      assert Metadata.get(account_target, "migrated").value == "yes"
      assert :ok = Metadata.rename_channel("same", "same")
    end)
  end

  test "synchronizes registration, joins, explicit targets and WHOIS" do
    Memento.transaction!(fn ->
      alice = insert(:user, nick: "Alice", identified_as: "Alice", capabilities: ["batch", "draft/metadata-3"])
      bob = insert(:user, nick: "Bob", capabilities: ["batch", "draft/metadata-2"])
      channel = insert(:channel, name: "#test")
      insert(:user_channel, user: alice, channel: channel, modes: [:o])
      insert(:user_channel, user: bob, channel: channel)

      {:ok, alice_target} = Metadata.resolve_target(alice, "*")
      {:ok, channel_target} = Metadata.resolve_target(alice, "#test")
      Metadata.put(alice_target, "avatar", "alice.png")
      Metadata.put(channel_target, "topic-color", "blue")
      Metadata.subscribe(bob, "avatar")
      Metadata.subscribe(bob, "topic-color")

      assert :ok = Metadata.sync_registration(alice)
      assert_sent_message_contains(alice.pid, ~r/ 761 Alice Alice avatar \* :alice\.png/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Metadata.sync_join(bob, channel, [alice])
      assert_sent_message_contains(bob.pid, ~r/ METADATA Alice avatar \* :alice\.png/)
      assert_sent_message_contains(bob.pid, ~r/ METADATA #test topic-color \* :blue/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Metadata.sync_target(bob, alice_target)
      assert_sent_message_contains(bob.pid, ~r/ METADATA Alice avatar \* :alice\.png/)

      assert [%{command: "760", trailing: "alice.png"}] = Metadata.whois_messages(bob, alice)
      assert [] = Metadata.whois_messages(%{bob | capabilities: []}, alice)

      incapable = %{bob | capabilities: []}
      assert :ok = Metadata.sync_join(incapable, channel, [alice])
      assert :ok = Metadata.sync_registration(incapable)
    end)
  end

  test "notifies channel subscribers on both metadata protocol generations" do
    Memento.transaction!(fn ->
      alice = insert(:user, nick: "Alice", capabilities: ["draft/metadata-3"])
      bob = insert(:user, nick: "Bob", capabilities: ["draft/metadata-3"])
      carol = insert(:user, nick: "Carol", capabilities: ["draft/metadata-2"])
      channel = insert(:channel, name: "#test")
      Enum.each([alice, bob, carol], &insert(:user_channel, user: &1, channel: channel))
      Enum.each([bob, carol], &Metadata.subscribe(&1, "color"))
      {:ok, target} = Metadata.resolve_target(alice, "#test")

      Metadata.put(target, "color", "green")
      assert_sent_message_contains(bob.pid, ~r/ 761 Bob #test color \* :green/)
      assert_sent_message_contains(carol.pid, ~r/ METADATA #test color \* :green/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert %{} = Metadata.delete(target, "color")
      assert_sent_message_contains(bob.pid, ~r/ 766 Bob #test color :key not set/)
      assert_sent_message_contains(carol.pid, ~r/ METADATA #test color \*/)
    end)
  end
end
