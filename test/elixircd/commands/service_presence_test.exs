defmodule ElixIRCd.Commands.ServicePresenceTest.FakeManager do
  @moduledoc false

  use GenServer

  alias ElixIRCd.Server.S2S.Manager

  def start_link(runtime), do: GenServer.start_link(__MODULE__, runtime, name: Manager)

  @impl true
  def init(runtime), do: {:ok, runtime}

  @impl true
  def handle_call(:runtime_view, _from, runtime), do: {:reply, runtime, runtime}
end

defmodule ElixIRCd.Commands.ServicePresenceTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Ison
  alias ElixIRCd.Commands.Monitor
  alias ElixIRCd.Commands.Names
  alias ElixIRCd.Commands.ServicePresenceTest.FakeManager
  alias ElixIRCd.Commands.Userhost
  alias ElixIRCd.Commands.Who
  alias ElixIRCd.Commands.Whois
  alias ElixIRCd.Message
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.Runtime
  alias ElixIRCd.Utils.Monitor, as: MonitorUtils

  defp runtime do
    {:ok, runtime} =
      Runtime.new(
        s2s: [
          server_id: "root",
          roster: [[sid: "root", name: "root.example.test", parent: nil]],
          policy_epoch: Identity.nonce()
        ],
        settings: [case_mapping: :ascii]
      )

    policy =
      Policy.new(
        epoch: runtime.policy.epoch,
        revision: 1,
        ready?: true,
        objects: %{{"channel", "#guarded"} => %{"settings" => %{"guard" => true}}}
      )

    channel = %{
      ref: %{"name" => "#guarded", "born_ms" => 1_700_000_000_000, "cid" => Identity.cid()},
      registers: %{},
      list_slots: %{},
      statuses: %{}
    }

    %{runtime | services_authority: "root", policy: policy, channels: %{"#guarded" => channel}}
  end

  setup do
    assert Process.whereis(Manager) == nil
    {:ok, manager} = FakeManager.start_link(runtime())
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    :ok
  end

  test "renders the derived ChanServ endpoint in network queries" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Viewer")

      assert :ok = Names.handle(user, %Message{command: "NAMES", params: ["#guarded"]})
      assert_sent_message_contains(user.pid, ~r/ 353 .*#guarded :ChanServ\r\n/)
      assert_sent_messages_count_containing(user.pid, ~r/ 366 /, 1)

      assert :ok = Who.handle(user, %Message{command: "WHO", params: ["#guarded"]})
      assert_sent_message_contains(user.pid, ~r/ 352 .* ChanServ .*ChanServ\r\n/)
      assert_sent_messages_count_containing(user.pid, ~r/ 315 /, 1)

      assert :ok = Whois.handle(user, %Message{command: "WHOIS", params: ["ChanServ"]})
      assert_sent_message_contains(user.pid, ~r/ 311 .* ChanServ service irc\.test /)
      assert_sent_message_contains(user.pid, ~r/ 318 .* ChanServ /)
    end)
  end

  test "reports logical ChanServ through ISON, USERHOST and MONITOR" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Viewer")

      assert :ok = Ison.handle(user, %Message{command: "ISON", params: ["ChanServ"]})
      assert_sent_message_contains(user.pid, ~r/ 303 .* :ChanServ\r\n/)

      assert :ok = Userhost.handle(user, %Message{command: "USERHOST", params: ["ChanServ"]})
      assert_sent_message_contains(user.pid, ~r/ 302 .*ChanServ=\+service@irc\.test\r\n/)

      assert :ok = Monitor.handle(user, %Message{command: "MONITOR", params: ["+ChanServ"]})
      assert_sent_message_contains(user.pid, ~r/ 730 .*ChanServ!service@irc\.test\r\n/)
    end)
  end

  test "notifies MONITOR subscribers when the service authority changes reachability" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Viewer")
      insert(:user_monitor, user: user, target_nick: "ChanServ")
      available = runtime()
      unavailable = %{available | services_authority: "leaf"}

      assert :ok = MonitorUtils.notify_service_presence_change(unavailable, available)
      assert_sent_message_contains(user.pid, ~r/ 730 .*ChanServ!service@irc\.test\r\n/)
      assert_sent_messages_amount(user.pid, 1)

      assert :ok = MonitorUtils.notify_service_presence_change(available, unavailable)
      assert_sent_messages([{user.pid, ":irc.test 731 #{user.nick} :ChanServ\r\n"}])
    end)
  end
end
