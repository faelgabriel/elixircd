defmodule ElixIRCd.Server.S2S.SessionTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Protocol
  alias ElixIRCd.Server.S2S.Session

  defp hello(sid, time_ms \\ 1_700_000_000_000) do
    %{
      "t" => "hello",
      "protocol" => "elixircd-native",
      "version" => 1,
      "network_id" => "test-net",
      "profile_hash" => String.duplicate("a", 64),
      "sid" => sid,
      "boot" => Identity.boot(),
      "name" => sid <> ".example.test",
      "nonce" => Identity.nonce(),
      "time_ms" => time_ms
    }
  end

  defp admit_remote(pid, remote) do
    assert :manager_pending = Session.receive_data(pid, Protocol.encode!(remote))
    assert_receive {:s2s_session, ^pid, _generation, {:hello, ^remote}}, 500
    assert :ok = Session.receive_data(pid, <<>>)
  end

  test "sends hello after TLS and responds to a sequenced ping" do
    local = hello("root")
    remote = hello("leaf")
    {:ok, pid} = Session.start_link(local_hello: local, notify: self(), clock_fun: fn -> 1_700_000_000_000 end)
    assert :ok = Session.tls_established(pid)
    assert_receive {:s2s_session, ^pid, _generation, {:send, ^local, _wire}}, 500

    admit_remote(pid, remote)

    ping = %{"t" => "ping", "n" => 1, "token" => Identity.nonce()}
    assert :ok = Session.receive_data(pid, Protocol.encode!(ping))
    assert_receive {:s2s_session, ^pid, _generation, {:send, %{"t" => "pong", "n" => 1, "token" => token}, _wire}}, 500
    assert token == ping["token"]
  end

  test "holds coalesced post-hello frames until the manager grants more receive demand" do
    local = hello("root")
    remote = hello("leaf")
    {:ok, pid} = Session.start_link(local_hello: local, notify: self(), clock_fun: fn -> 1_700_000_000_000 end)
    :ok = Session.tls_established(pid)
    assert_receive {:s2s_session, ^pid, _generation, {:send, ^local, _wire}}, 500

    ping = %{"t" => "ping", "n" => 1, "token" => Identity.nonce()}
    coalesced = Protocol.encode!(remote) <> Protocol.encode!(ping)

    assert :manager_pending = Session.receive_data(pid, coalesced)
    assert_receive {:s2s_session, ^pid, _generation, {:hello, ^remote}}, 500
    assert %{input_buffer_bytes: buffered} = Session.state(pid)
    assert buffered == byte_size(Protocol.encode!(ping))
    assert {:error, :manager_ack_required} = Session.receive_data(pid, Protocol.encode!(ping))
    refute_receive {:s2s_session, ^pid, _generation, {:send, %{"t" => "pong"}, _wire}}, 50

    assert :ok = Session.receive_data(pid, <<>>)
    assert_receive {:s2s_session, ^pid, _generation, {:send, %{"t" => "pong", "token" => token}, _wire}}, 500
    assert token == ping["token"]
    assert Session.state(pid).input_buffer_bytes == 0
  end

  test "accepts an authenticated close before the remote hello" do
    local = hello("root")
    {:ok, pid} = Session.start_link(local_hello: local, notify: self())
    Process.unlink(pid)
    monitor_ref = Process.monitor(pid)
    :ok = Session.tls_established(pid)
    assert_receive {:s2s_session, ^pid, _generation, {:send, ^local, _wire}}, 500

    close = %{"t" => "close", "n" => 1, "code" => "AUTH", "reason" => "peer certificate was not accepted"}
    assert {:error, :peer_close} = Session.receive_data(pid, Protocol.encode!(close))
    assert_receive {:s2s_session, ^pid, _generation, {:close, "AUTH"}}, 500
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, {:protocol, :peer_close}}, 500
  end

  test "requires exact per-direction n and fences a gap" do
    local = hello("root")
    remote = hello("leaf")
    {:ok, pid} = Session.start_link(local_hello: local, notify: self(), clock_fun: fn -> 1_700_000_000_000 end)
    Process.unlink(pid)
    monitor_ref = Process.monitor(pid)
    :ok = Session.tls_established(pid)
    assert_receive {:s2s_session, ^pid, _generation, {:send, ^local, _wire}}, 500
    admit_remote(pid, remote)

    gap = %{"t" => "ping", "n" => 2, "token" => Identity.nonce()}
    assert {:error, {:sequence_gap, 1, 2}} = Session.receive_data(pid, Protocol.encode!(gap))
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, {:protocol, {:sequence_gap, 1, 2}}}, 500
  end

  test "closes a partial frame after its bounded receive window" do
    local = hello("root")
    remote = hello("leaf")

    {:ok, pid} =
      Session.start_link(
        local_hello: local,
        notify: self(),
        clock_fun: fn -> 1_700_000_000_000 end,
        incomplete_frame_ms: 50
      )

    Process.unlink(pid)
    monitor_ref = Process.monitor(pid)
    :ok = Session.tls_established(pid)
    assert_receive {:s2s_session, ^pid, _generation, {:send, ^local, _wire}}, 500
    admit_remote(pid, remote)

    assert :ok = Session.receive_data(pid, <<0, 0, 0, 10, "{">>)

    assert_receive {:s2s_session, ^pid, _generation, {:send, %{"t" => "close", "code" => "TIMEOUT"}, _wire}},
                   500

    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, {:protocol, :incomplete_frame_timeout}}, 500
  end

  test "becomes active only after sent, applied and acknowledged snapshot facts" do
    local = hello("root")
    remote = hello("leaf")
    {:ok, pid} = Session.start_link(local_hello: local, notify: self(), clock_fun: fn -> 1_700_000_000_000 end)
    :ok = Session.tls_established(pid)
    assert_receive {:s2s_session, ^pid, _generation, {:send, ^local, _wire}}, 500
    admit_remote(pid, remote)

    :ok = Session.mark_sync(pid, :sent)
    :ok = Session.mark_sync(pid, :applied)
    :ok = Session.mark_sync(pid, :acknowledged)
    assert_receive {:s2s_session, ^pid, _generation, :active}, 500
    assert Session.state(pid).phase == :active
    assert %{outbound_frames: 0, outbound_bytes: 0, input_buffer_bytes: 0} = Session.state(pid)
  end

  test "rejects a frame before it can exceed the per-link byte budget" do
    local = hello("root")
    remote = hello("leaf")

    {:ok, pid} =
      Session.start_link(
        local_hello: local,
        notify: self(),
        max_outbound_bytes: 1,
        clock_fun: fn -> 1_700_000_000_000 end
      )

    :ok = Session.tls_established(pid)
    assert_receive {:s2s_session, ^pid, _generation, {:send, ^local, _wire}}, 500
    admit_remote(pid, remote)
    :ok = Session.mark_sync(pid, :sent)
    :ok = Session.mark_sync(pid, :applied)
    :ok = Session.mark_sync(pid, :acknowledged)
    assert_receive {:s2s_session, ^pid, _generation, :active}, 500

    assert {:error, :outbound_queue_capacity} =
             Session.enqueue_frame(pid, %{"t" => "ping", "token" => Identity.nonce()})
  end

  test "rejects an oversized hello length before receiving its payload" do
    local = hello("root")
    {:ok, pid} = Session.start_link(local_hello: local, notify: self())
    Process.unlink(pid)
    monitor_ref = Process.monitor(pid)

    :ok = Session.tls_established(pid)
    assert_receive {:s2s_session, ^pid, _generation, {:send, ^local, _wire}}, 500

    assert {:error, {:frame_too_large, 4_097, 4_096}} =
             Session.receive_data(pid, <<4_097::unsigned-big-32>>)

    assert_receive {:s2s_session, ^pid, _generation, {:send, %{"t" => "close", "code" => "FRAME"}, _wire}}, 500
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, {:protocol, {:frame_too_large, 4_097, 4_096}}}, 500
  end

  test "applies the configured body budget to outgoing frames" do
    local = hello("root")
    remote = hello("leaf")
    local_hello_size = byte_size(Protocol.encode!(local)) - 4
    remote_hello_size = byte_size(Protocol.encode!(remote)) - 4
    max_body = max(local_hello_size, remote_hello_size)

    message = %{
      "t" => "message",
      "n" => 1,
      "origin" => %{"sid" => local["sid"], "boot" => local["boot"]},
      "actor" => %{"server" => local["sid"]},
      "message_id" => Identity.nonce(),
      "sent_ms" => 1_700_000_000_000,
      "target" => %{"user" => Identity.nonce()},
      "command" => "PRIVMSG",
      "text" => String.duplicate("x", 1_000),
      "tags" => %{},
      "request_id" => nil
    }

    message_size = byte_size(Protocol.encode!(message)) - 4

    {:ok, pid} =
      Session.start_link(
        local_hello: local,
        notify: self(),
        max_body: max_body,
        clock_fun: fn -> 1_700_000_000_000 end
      )

    :ok = Session.tls_established(pid)
    assert_receive {:s2s_session, ^pid, _generation, {:send, ^local, _wire}}, 500
    admit_remote(pid, remote)
    :ok = Session.mark_sync(pid, :sent)
    :ok = Session.mark_sync(pid, :applied)
    :ok = Session.mark_sync(pid, :acknowledged)
    assert_receive {:s2s_session, ^pid, _generation, :active}, 500

    assert {:error, {:frame_too_large, ^message_size, ^max_body}} =
             Session.enqueue_frame(pid, message)
  end
end
