defmodule ElixIRCd.Server.S2S.ActionTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Server.S2S.Action
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Output

  defmodule TestManager do
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent, name: ElixIRCd.Server.S2S.Manager)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_call(
          {:request_with_reply_context, _target, _actor, _method, _args, _guards, {_recipient, _uid, _context}, _ttl},
          _from,
          parent
        ) do
      send(parent, :manager_called)
      {:reply, {:ok, Identity.nonce()}, parent}
    end
  end

  test "originates a queued owner request only after the local transaction commits" do
    test_pid = self()
    {:ok, manager} = TestManager.start_link(test_pid)
    recipient = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(recipient), do: Process.exit(recipient, :kill) end)

    on_exit(fn ->
      if Process.alive?(manager) do
        try do
          GenServer.stop(manager)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    uid = Identity.uid()

    actor = insert(:user, uid: uid, pid: recipient, nick: "operator", registered: true, owner_rev: 1)

    assert {:ok, :committed, group} =
             Output.transaction_deferred(fn ->
               assert :queued =
                        Action.enqueue(
                          manager,
                          "remote",
                          actor,
                          "user_action",
                          %{"action" => "kill", "target_uid" => Identity.uid(), "value" => nil, "reason" => "test"},
                          %{
                            "actor_uid" => uid,
                            "actor_user_rev" => 1,
                            "actor_join_id" => nil,
                            "target_user_rev" => 1,
                            "target_join_id" => nil,
                            "channel" => nil,
                            "policy_epoch" => nil,
                            "policy_revision" => nil
                          }
                        )

               refute_receive :manager_called
               :committed
             end)

    assert [%{kind: :s2s_request} = intent] = group.intents
    refute Map.has_key?(intent, :manager)
    refute Map.has_key?(intent, :recipient)
    refute Map.has_key?(intent, :actor_user)

    assert :ok = Output.drain_pending(group, &ElixIRCd.Server.Dispatcher.drain_intent/1)
    assert_receive :manager_called
  end
end
