defmodule ElixIRCd.Server.S2S.ProcessIntegrationTest do
  use ExUnit.Case, async: false

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Protocol
  alias ElixIRCd.Server.S2S.TLS

  @moduletag timeout: 60_000
  @cwd File.cwd!()
  @daemon_script Path.join(@cwd, "test/support/native_s2s_daemon.exs")

  test "rejects a CA-valid peer whose certificate fingerprint is outside the configured pin" do
    tls = create_test_certificates()
    wrong_tls = create_test_node_certificate(tls, "wrong-leaf")
    trusted_certfp = certificate_fingerprint(tls.certfile)
    wrong_certfp = certificate_fingerprint(wrong_tls.certfile)

    root = start_daemon("root", tls, trusted_certfp, nil, 0, "two", nil, %{"leaf" => trusted_certfp})

    try do
      leaf =
        start_daemon(
          "leaf",
          wrong_tls,
          wrong_certfp,
          root.port_number,
          0,
          "two",
          nil,
          %{"root" => trusted_certfp}
        )

      try do
        Process.sleep(1_000)
        assert reachable_exact?(root, ["root"])
        assert reachable_exact?(leaf, ["leaf"])
        assert status_contains?(leaf, ~r/retry_blocked: true/)
        assert status_contains?(root, ~r/users: 0/)
        assert status_contains?(leaf, ~r/users: 0/)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "rejects an independent peer signed by an untrusted CA" do
    tls = create_test_certificates()
    untrusted_tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", nil, %{"leaf" => certfp})

    try do
      case connect_raw_peer(root, untrusted_tls, tls, 1_000) do
        {:error, _reason} ->
          :ok

        {:ok, socket} ->
          try do
            assert eventually(fn -> ssl_closed?(socket) end, 20)
          after
            :ssl.close(socket)
          end
      end

      assert reachable_exact?(root, ["root"])
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
      File.rm_rf!(untrusted_tls.dir)
    end
  end

  test "rejects expired, missing-client, and hostname-mismatched certificates before hello" do
    tls = create_test_certificates()
    expired_tls = create_test_node_certificate(tls, "expired", "localhost", 0)
    expired_certfp = certificate_fingerprint(expired_tls.certfile)

    root =
      start_daemon("root", tls, certificate_fingerprint(tls.certfile), nil, 0, "two", nil, %{"leaf" => expired_certfp})

    try do
      assert_raw_tls_rejected(fn -> connect_raw_peer(root, expired_tls, tls, 1_000) end)
      assert_raw_tls_rejected(fn -> connect_without_client_certificate(root, tls, 1_000) end)
      assert reachable_exact?(root, ["root"])
    after
      stop_if_alive(root)
    end

    wrong_hostname_tls = create_test_node_certificate(tls, "wrong-host", "wrong.example.test")
    wrong_hostname_certfp = certificate_fingerprint(wrong_hostname_tls.certfile)

    wrong_hostname_root =
      start_daemon(
        "root",
        wrong_hostname_tls,
        wrong_hostname_certfp,
        nil,
        0,
        "two",
        nil,
        %{"leaf" => certificate_fingerprint(tls.certfile)}
      )

    try do
      assert_raw_tls_rejected(fn -> connect_raw_peer(wrong_hostname_root, tls, tls, 1_000) end)
      assert reachable_exact?(wrong_hostname_root, ["root"])
    after
      stop_if_alive(wrong_hostname_root)
      File.rm_rf!(tls.dir)
    end
  end

  test "rotates a neighbor certificate through an explicit pin overlap" do
    tls = create_test_certificates()
    old_leaf_tls = create_test_node_certificate(tls, "leaf-old")
    new_leaf_tls = create_test_node_certificate(tls, "leaf-new")
    root_certfp = certificate_fingerprint(tls.certfile)
    old_leaf_certfp = certificate_fingerprint(old_leaf_tls.certfile)
    new_leaf_certfp = certificate_fingerprint(new_leaf_tls.certfile)

    root =
      start_daemon(
        "root",
        tls,
        root_certfp,
        nil,
        0,
        "two",
        nil,
        %{"leaf" => [old_leaf_certfp, new_leaf_certfp]}
      )

    try do
      old_leaf =
        start_daemon("leaf", old_leaf_tls, old_leaf_certfp, root.port_number, 0, "two", nil, %{"root" => root_certfp})

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
      after
        stop_if_alive(old_leaf)
      end

      rotated_leaf =
        start_daemon("leaf", new_leaf_tls, new_leaf_certfp, root.port_number, 0, "two", nil, %{"root" => root_certfp})

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
        assert eventually(fn -> reachable_exact?(rotated_leaf, ["leaf", "root"]) end)
      after
        stop_if_alive(rotated_leaf)
      end
    after
      stop_if_alive(root)
    end

    strict_root =
      start_daemon(
        "root",
        tls,
        root_certfp,
        nil,
        0,
        "two",
        nil,
        %{"leaf" => old_leaf_certfp}
      )

    try do
      rejected_leaf =
        start_daemon("leaf", new_leaf_tls, new_leaf_certfp, strict_root.port_number, 0, "two", nil, %{
          "root" => root_certfp
        })

      try do
        Process.sleep(1_000)
        assert reachable_exact?(strict_root, ["root"])
        assert reachable_exact?(rejected_leaf, ["leaf"])
      after
        stop_if_alive(rejected_leaf)
      end
    after
      stop_if_alive(strict_root)
      File.rm_rf!(tls.dir)
    end
  end

  test "refuses a duplicate live SID without evicting the established generation" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", nil, %{"leaf" => certfp})

    try do
      established = start_daemon("leaf", tls, certfp, root.port_number, 0, "two")

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
        assert eventually(fn -> reachable_exact?(established, ["leaf", "root"]) end)

        duplicate = start_daemon("leaf", tls, certfp, root.port_number, 0, "two")

        try do
          assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
          assert eventually(fn -> reachable_exact?(established, ["leaf", "root"]) end)
          assert eventually(fn -> status_contains?(duplicate, ~r/retry_blocked: false/) end)
          assert status_contains?(root, ~r/sessions: \[\{/)
          assert status_contains?(root, ~r/users: 0/)
        after
          stop_if_alive(duplicate)
        end
      after
        stop_if_alive(established)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "closes an independent TLS peer that sends malformed or permanently partial ENP frames" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", nil, %{"leaf" => certfp})

    try do
      {:ok, malformed_socket} = connect_raw_peer(root, tls)

      try do
        assert :ok = :ssl.send(malformed_socket, <<0, 0, 0, 2, "{]">>)
        assert eventually(fn -> ssl_closed?(malformed_socket) end, 80)
      after
        :ssl.close(malformed_socket)
      end

      {:ok, partial_socket} = connect_raw_peer(root, tls)

      try do
        assert :ok = :ssl.send(partial_socket, <<0, 0, 0, 4, "{">>)
        assert eventually(fn -> ssl_closed?(partial_socket) end, 100)
      after
        :ssl.close(partial_socket)
      end

      {:ok, oversized_socket} = connect_raw_peer(root, tls)

      try do
        assert :ok = :ssl.send(oversized_socket, <<0, 16, 0, 1>>)
        assert eventually(fn -> ssl_closed?(oversized_socket) end, 100)
      after
        :ssl.close(oversized_socket)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "does not elevate an IRC client line sent to the native endpoint" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", nil, %{"leaf" => certfp})

    try do
      {:ok, socket} = connect_raw_peer(root, tls)

      try do
        assert :ok = :ssl.send(socket, "PASS secret\r\n")
        assert eventually(fn -> ssl_closed?(socket) end, 80)
        assert reachable_exact?(root, ["root"])
        assert status_contains?(root, ~r/users: 0/)
      after
        :ssl.close(socket)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "enforces the listener connection budget before admitting a second neighbor" do
    tls = create_test_certificates()
    left_tls = create_test_node_certificate(tls, "left")
    right_tls = create_test_node_certificate(tls, "right")
    root_certfp = certificate_fingerprint(tls.certfile)
    left_certfp = certificate_fingerprint(left_tls.certfile)
    right_certfp = certificate_fingerprint(right_tls.certfile)

    root =
      start_daemon(
        "root",
        tls,
        root_certfp,
        nil,
        0,
        "star",
        nil,
        %{"left" => left_certfp, "right" => right_certfp},
        0,
        max_connections_per_acceptor: 1
      )

    try do
      {:ok, left_socket} = connect_raw_peer(root, left_tls)

      try do
        assert eventually(fn -> status_contains?(root, ~r/peer_sid: "left"/) end)

        case connect_raw_peer(root, right_tls, 1_000) do
          {:error, _reason} ->
            :ok

          {:ok, right_socket} ->
            :ssl.close(right_socket)
            refute eventually(fn -> status_contains?(root, ~r/peer_sid: "right"/) end, 10)
        end
      after
        :ssl.close(left_socket)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "closes an authenticated syncing peer when the aggregate state queue is full" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)

    root =
      start_daemon(
        "root",
        tls,
        certfp,
        nil,
        0,
        "two",
        nil,
        %{"leaf" => certfp},
        0,
        aggregate_pending_frames: 4,
        aggregate_pending_bytes: 32_768,
        max_pending_frames: 128,
        snapshot_delta_queue_bytes: 32_768
      )

    try do
      {:ok, socket} = connect_raw_peer(root, tls)

      try do
        {:ok, root_hello_wire} = :ssl.recv(socket, 0, 2_000)
        assert {:ok, [root_hello], <<>>} = Protocol.feed(<<>>, root_hello_wire)

        remote_hello =
          root_hello
          |> Map.put("sid", "leaf")
          |> Map.put("name", "leaf.example.test")
          |> Map.put("boot", ElixIRCd.Server.S2S.Identity.boot())
          |> Map.put("nonce", ElixIRCd.Server.S2S.Identity.nonce())
          |> Map.put("time_ms", System.system_time(:millisecond))

        assert :ok = :ssl.send(socket, Protocol.encode!(remote_hello))
        assert eventually(fn -> status_contains?(root, ~r/status: :syncing/) end)

        Enum.each(1..8, fn index ->
          assert {:ok, _user, _next} = command(root, "add_user QueueUser#{index}\n", "USER ")
        end)

        assert eventually(fn -> ssl_closed?(socket) end, 100)
        assert eventually(fn -> reachable_exact?(root, ["root"]) end)
        assert status_contains?(root, ~r/pending_sync_frames: 0/)
      after
        :ssl.close(socket)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "bounds manager mailbox growth to one pending event per TLS peer" do
    tls = create_test_certificates()
    peer_count = 12
    peer_tls =
      Map.new(1..peer_count, fn index ->
        sid = "leaf#{index}"
        {sid, create_test_node_certificate(tls, sid)}
      end)

    peer_certfps = Map.new(peer_tls, fn {sid, peer} -> {sid, certificate_fingerprint(peer.certfile)} end)
    root_certfp = certificate_fingerprint(tls.certfile)

    root =
      start_daemon(
        "root",
        tls,
        root_certfp,
        nil,
        0,
        "fanout",
        nil,
        peer_certfps,
        0,
        [max_connections_per_acceptor: peer_count],
        tls_hello_ms: 60_000
      )

    try do
      with_raw_peers(root, peer_tls, tls, fn sockets_and_frames ->
        assert {:ok, "MANAGER_SUSPENDED", root} = command(root, "manager_suspend\n", "MANAGER_SUSPENDED")
        assert {:ok, baseline_line, root} = command(root, "manager_queue\n", "MANAGER_QUEUE ")
        baseline = baseline_line |> String.replace_prefix("MANAGER_QUEUE ", "") |> String.to_integer()

        Enum.each(sockets_and_frames, fn {socket, remote_hello} ->
          burst =
            [Protocol.encode!(remote_hello) | List.duplicate(Protocol.encode!(remote_hello), 32)]
            |> IO.iodata_to_binary()

          assert :ok = :ssl.send(socket, burst)
        end)

        assert {:ok, queued, _root} = await_manager_queue(root, baseline + peer_count, 5_000)
        assert queued <= baseline + peer_count + 2
        Enum.each(sockets_and_frames, fn {socket, _hello} -> refute ssl_closed?(socket) end)
      end)
    after
      _ = command(root, "manager_resume\n", "MANAGER_RESUMED")
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "executes remote NickServ IDENTIFY and LOGOUT at the owner daemon" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
        assert eventually(fn -> reachable_exact?(leaf, ["leaf", "root"]) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, _account, _next} = command(root, "seed_account NativeAccount native-password\n", "ACCOUNT ")
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, client, _next} = command(leaf, "add_client NativeAccount\n", "CLIENT ")
        uid = client_uid(client)
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)

        assert {:ok, identify, _next} =
                 command(leaf, "request_service #{uid} NickServ IDENTIFY native-password\n", "SERVICE_REPLY ")

        assert identify =~ "status: \"OK\""
        assert eventually(fn -> delivered_message?(leaf, "You are now logged in as NativeAccount") end)
        assert eventually(fn -> user_info_contains?(leaf, "NativeAccount", ~r/identified_as: \"NativeAccount\"/) end)
        assert eventually(fn -> user_info_contains?(root, "NativeAccount", ~r/identified_as: \"NativeAccount\"/) end)

        assert {:ok, logout, _next} =
                 command(leaf, "request_service #{uid} NickServ LOGOUT\n", "SERVICE_REPLY ")

        assert logout =~ "status: \"OK\""

        assert eventually(fn -> user_info_contains?(leaf, "NativeAccount", ~r/identified_as: nil/) end),
               inspect(command(leaf, "user_info NativeAccount\n", "USER_INFO "))
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "forwards C2S PLAIN SASL to the remote authority and installs the owner binding" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert {:ok, _account, _next} = command(root, "seed_account RemoteSasl remote-password\n", "ACCOUNT ")
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, client, _next} = command(leaf, "add_client RemoteSaslUser\n", "CLIENT ")
        uid = client_uid(client)
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)

        assert {:ok, sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE PLAIN\n", "AUTH_SENT ")
        assert sent =~ "AUTH_SENT"
        assert eventually(fn -> delivered_message?(leaf, "AUTHENTICATE +") end)

        credentials = Base.encode64(<<0, "RemoteSasl", 0, "remote-password">>)
        assert {:ok, sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE #{credentials}\n", "AUTH_SENT ")
        assert sent =~ "AUTH_SENT"
        assert eventually(fn -> delivered_message?(leaf, "You are now logged in as RemoteSasl") end)
        assert eventually(fn -> user_info_contains?(leaf, "RemoteSaslUser", ~r/identified_as: "RemoteSasl"/) end)
        assert eventually(fn -> user_info_contains?(root, "RemoteSaslUser", ~r/identified_as: "RemoteSasl"/) end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "rejects remote PLAIN credentials without installing an account binding" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert {:ok, _account, _next} = command(root, "seed_account RemoteFailure remote-password\n", "ACCOUNT ")
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, client, _next} = command(leaf, "add_client RemoteFailureUser\n", "CLIENT ")
        uid = client_uid(client)
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)
        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE PLAIN\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "AUTHENTICATE +") end)

        credentials = Base.encode64(<<0, "RemoteFailure", 0, "wrong-password">>)
        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE #{credentials}\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "SASL authentication failed") end)
        assert eventually(fn -> status_contains?(root, ~r/pending_sasl_attempts: 0/) end)
        assert user_info_contains?(leaf, "RemoteFailureUser", ~r/identified_as: nil/)
        assert user_info_contains?(root, "RemoteFailureUser", ~r/identified_as: nil/)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "returns bounded SASL BUSY under independent authority worker pressure" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)

    root =
      start_daemon(
        "root",
        tls,
        certfp,
        nil,
        0,
        "two",
        "root",
        %{},
        1_000,
        sasl_workers: 1
      )

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(leaf, ["leaf", "root"]) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert {:ok, _account, _next} = command(root, "seed_account PressureAccount pressure-password\n", "ACCOUNT ")
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, first, _next} = command(leaf, "add_client PressureFirst\n", "CLIENT ")
        first_uid = client_uid(first)
        assert {:ok, second, _next} = command(leaf, "add_client PressureSecond\n", "CLIENT ")
        second_uid = client_uid(second)

        assert {:ok, _sent, _next} = command(leaf, "client_auth #{first_uid} AUTHENTICATE PLAIN\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "AUTHENTICATE +") end)
        assert {:ok, _sent, _next} = command(leaf, "client_auth #{second_uid} AUTHENTICATE PLAIN\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "AUTHENTICATE +") end)

        credentials = Base.encode64(<<0, "PressureAccount", 0, "pressure-password">>)

        assert {:ok, _sent, _next} =
                 command(leaf, "client_auth #{first_uid} AUTHENTICATE #{credentials}\n", "AUTH_SENT ")

        assert eventually(fn -> status_contains?(root, ~r/pending_sasl_jobs: 1/) end)

        assert {:ok, _sent, _next} =
                 command(leaf, "client_auth #{second_uid} AUTHENTICATE #{credentials}\n", "AUTH_SENT ")

        assert eventually(fn -> delivered_message?(leaf, "SASL authentication failed: BUSY") end)
        assert eventually(fn -> status_contains?(root, ~r/pending_sasl_attempts: 1/) end)
        assert eventually(fn -> status_contains?(root, ~r/pending_sasl_jobs: 0/) end, 100)
        assert eventually(fn -> status_contains?(root, ~r/pending_sasl_attempts: 0/) end, 100)
        assert eventually(fn -> delivered_message?(leaf, "You are now logged in as PressureAccount") end, 100)
        assert eventually(fn -> user_info_contains?(root, "PressureFirst", ~r/identified_as: "PressureAccount"/) end)
        assert user_info_contains?(root, "PressureSecond", ~r/identified_as: nil/)
        assert eventually(fn -> status_contains?(root, ~r/pending_requests: 0/) end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "fails closed when the configured SASL authority is unreachable" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(leaf, ["leaf", "root"]) end)
        assert {:ok, client, _next} = command(leaf, "add_client UnavailableAuthorityUser\n", "CLIENT ")
        uid = client_uid(client)
        assert {:ok, advertised, _next} = command(leaf, "client_capabilities #{uid}\n", "CAPABILITIES ")
        assert advertised =~ "sasl=PLAIN,ECDSA-NIST256P-CHALLENGE"
        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE PLAIN\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "AUTHENTICATE +") end)

        assert {:ok, _stopped} = stop_daemon(root)
        assert eventually(fn -> reachable_exact?(leaf, ["leaf"]) end)

        assert eventually_messages?(leaf, [
                 "SASL authentication authority is unavailable",
                 " CAP UnavailableAuthorityUser DEL :sasl"
               ])

        assert {:ok, unavailable, _next} = command(leaf, "client_capabilities #{uid}\n", "CAPABILITIES ")
        refute unavailable =~ "sasl="

        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE PLAIN\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "You must negotiate SASL capability first") end)
        assert user_info_contains?(leaf, "UnavailableAuthorityUser", ~r/identified_as: nil/)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "keeps a pre-registration client private until local registration completes" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number)

      try do
        assert eventually(fn -> reachable_exact?(leaf, ["leaf", "root"]) end)
        assert {:ok, pending, _next} = command(leaf, "add_pending_client PendingUser\n", "PENDING_CLIENT ")
        uid = client_uid(String.replace_prefix(pending, "PENDING_CLIENT ", "CLIENT "))
        assert eventually(fn -> status_contains?(root, ~r/users: 0/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/users: 0/) end)

        assert {:ok, completed, _next} = command(leaf, "complete_client #{uid}\n", "COMPLETED ")
        assert completed =~ ":ok"
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/users: 1/) end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "forwards C2S ECDSA SASL to the remote authority and verifies the challenge" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")
    {public_key, private_key} = :crypto.generate_key(:ecdh, :secp256r1)
    compressed_public_key = compress_public_key(public_key)
    encoded_public_key = Base.encode64(compressed_public_key, padding: false)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, _account, _next} =
                 command(root, "seed_account RemoteKey remote-password #{encoded_public_key}\n", "ACCOUNT ")

        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert {:ok, client, _next} = command(leaf, "add_client RemoteKeyUser\n", "CLIENT ")
        uid = client_uid(client)
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)

        assert {:ok, sent, _next} =
                 command(leaf, "client_auth #{uid} AUTHENTICATE ECDSA-NIST256P-CHALLENGE\n", "AUTH_SENT ")

        assert sent =~ "AUTH_SENT"
        assert eventually(fn -> delivered_message?(leaf, "AUTHENTICATE +") end)

        account_data = Base.encode64("RemoteKey")
        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE #{account_data}\n", "AUTH_SENT ")

        challenge =
          eventually_value(fn ->
            case command(leaf, "read_message\n", "MESSAGE ") do
              {:ok, line, _next} ->
                case Regex.run(~r/AUTHENTICATE ([A-Za-z0-9+\/=]+)/, line, capture: :all_but_first) do
                  [encoded] when encoded != "+" -> {:ok, encoded}
                  _ -> :retry
                end

              _ ->
                :retry
            end
          end)

        signature = :crypto.sign(:ecdsa, :sha256, {:digest, Base.decode64!(challenge)}, [private_key, :secp256r1])
        signature = Base.encode64(signature)

        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE #{signature}\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "You are now logged in as RemoteKey") end)
        assert eventually(fn -> user_info_contains?(leaf, "RemoteKeyUser", ~r/identified_as: "RemoteKey"/) end)
        assert eventually(fn -> user_info_contains?(root, "RemoteKeyUser", ~r/identified_as: "RemoteKey"/) end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "cancels a remote SASL attempt before a late authority result can bind the user" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert {:ok, _account, _next} = command(root, "seed_account CancelAccount cancel-password\n", "ACCOUNT ")
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, client, _next} = command(leaf, "add_client CancelUser\n", "CLIENT ")
        uid = client_uid(client)
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)
        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE PLAIN\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "AUTHENTICATE +") end)

        assert {:ok, sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE *\n", "AUTH_SENT ")
        assert sent =~ "AUTH_SENT"
        assert eventually(fn -> delivered_message?(leaf, "SASL authentication aborted") end)
        assert eventually(fn -> status_contains?(root, ~r/pending_sasl_attempts: 0/) end)

        assert eventually(fn -> status_contains?(root, ~r/pending_requests: 0/) end)

        assert user_info_contains?(leaf, "CancelUser", ~r/identified_as: nil/)
        assert user_info_contains?(root, "CancelUser", ~r/identified_as: nil/)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "disconnect cancels the remote SASL request before a late authority result" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root", %{}, 1_000)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, _account, _next} =
                 command(root, "seed_account DisconnectAccount disconnect-password\n", "ACCOUNT ")

        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, client, _next} = command(leaf, "add_client DisconnectUser\n", "CLIENT ")
        uid = client_uid(client)
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)
        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE PLAIN\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "AUTHENTICATE +") end)

        credentials = Base.encode64(<<0, "DisconnectAccount", 0, "disconnect-password">>)
        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE #{credentials}\n", "AUTH_SENT ")
        assert {:ok, disconnected, _next} = command(leaf, "disconnect_client #{uid}\n", "CLIENT_DISCONNECTED ")
        assert disconnected =~ uid

        assert eventually(fn -> status_contains?(root, ~r/pending_sasl_attempts: 0/) end)
        assert eventually(fn -> status_contains?(root, ~r/pending_sasl_jobs: 0/) end)

        assert eventually(fn -> status_contains?(root, ~r/pending_requests: 0/) end),
               inspect({status_line(root), status_line(leaf)})

        assert eventually(fn -> status_contains?(root, ~r/users: 0/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/pending_requests: 0/) end)
        assert user_missing?(root, "DisconnectUser")
        assert user_missing?(leaf, "DisconnectUser")
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "times out remote SASL under authority pressure and ignores the late result" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)

    root =
      start_daemon(
        "root",
        tls,
        certfp,
        nil,
        0,
        "two",
        "root",
        %{},
        2_000,
        [],
        request_ms: 250
      )

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert {:ok, _account, _next} = command(root, "seed_account TimeoutAccount timeout-password\n", "ACCOUNT ")
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, client, _next} = command(leaf, "add_client TimeoutUser\n", "CLIENT ")
        uid = client_uid(client)
        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE PLAIN\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "AUTHENTICATE +") end)

        credentials = Base.encode64(<<0, "TimeoutAccount", 0, "timeout-password">>)
        assert {:ok, _sent, _next} = command(leaf, "client_auth #{uid} AUTHENTICATE #{credentials}\n", "AUTH_SENT ")
        assert eventually(fn -> delivered_message?(leaf, "SASL authentication failed: TIMEOUT") end, 30)
        assert eventually(fn -> status_contains?(root, ~r/pending_sasl_attempts: 0/) end, 30)
        assert eventually(fn -> status_contains?(root, ~r/pending_sasl_jobs: 0/) end, 30)
        assert eventually(fn -> status_contains?(leaf, ~r/pending_requests: 0/) end, 30)

        Process.sleep(2_200)
        assert user_info_contains?(leaf, "TimeoutUser", ~r/identified_as: nil/)
        assert user_info_contains?(root, "TimeoutUser", ~r/identified_as: nil/)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "links independent OS daemons over mTLS, publishes state, splits, and reconnects" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number)

      try do
        {:ok, _leaf_line, _leaf_state} = command(leaf, "status\n", "STATUS ")
        assert eventually(fn -> reachable?(leaf, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "root"\]/) end)

        assert {:ok, _user_line, _next} = command(root, "add_user ProcessUser\n", "USER ")
        assert eventually(fn -> status_contains?(leaf, ~r/users: 1/) end)

        assert {:ok, _stopped} = stop_daemon(leaf)
        assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["root"\]/) end)

        restarted_leaf = start_daemon("leaf", tls, certfp, root.port_number)

        try do
          assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "root"\]/) end)
          assert eventually(fn -> reachable?(restarted_leaf, ~r/reachable_sids: \["leaf", "root"\]/) end)
          assert eventually(fn -> status_contains?(restarted_leaf, ~r/users: 1/) end)
        after
          stop_if_alive(restarted_leaf)
        end
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "removes remote users across repeated leaf restart cycles" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      Enum.each(1..10, fn cycle ->
        leaf = start_daemon("leaf", tls, certfp, root.port_number)

        try do
          assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "root"\]/) end),
                 "root did not reach the leaf on churn cycle #{cycle}; root=#{inspect(status_line(root))}, leaf=#{inspect(status_line(leaf))}"

          assert {:ok, client, _next} = command(leaf, "add_client ChurnUser#{cycle}\n", "CLIENT ")
          uid = client_uid(client)
          assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)

          assert {:ok, disconnected, _next} = command(leaf, "disconnect_client #{uid}\n", "CLIENT_DISCONNECTED ")
          assert disconnected =~ uid
          assert eventually(fn -> status_contains?(root, ~r/users: 0/) end)
        after
          stop_if_alive(leaf)
        end

        assert eventually(
                 fn ->
                   reachable_exact?(root, ["root"]) and status_contains?(root, ~r/sessions: \[\]/)
                 end,
                 200
               ),
               "root did not fully prune the stopped leaf generation after churn cycle #{cycle}"
      end)

      assert eventually(fn -> status_contains?(root, ~r/users: 0/) end)
      assert status_contains?(root, ~r/pending_requests: 0/)
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "routes state through an independent hub and rebuilds the branch after hub restart" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "three")

    try do
      middle = start_daemon("middle", tls, certfp, root.port_number, 0, "three")

      try do
        leaf = start_daemon("leaf", tls, certfp, middle.port_number, 0, "three")

        try do
          assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "middle", "root"\]/) end)
          assert eventually(fn -> reachable?(middle, ~r/reachable_sids: \["leaf", "middle", "root"\]/) end)
          assert eventually(fn -> reachable?(leaf, ~r/reachable_sids: \["leaf", "middle", "root"\]/) end)

          assert {:ok, _user_line, _next} = command(root, "add_user HubUser\n", "USER ")
          assert eventually(fn -> status_contains?(middle, ~r/users: 1/) end)
          assert eventually(fn -> status_contains?(leaf, ~r/users: 1/) end)

          assert {:ok, _stopped} = stop_daemon(middle)
          assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["root"\]/) end)
          assert eventually(fn -> reachable?(leaf, ~r/reachable_sids: \["leaf"\]/) end)

          restarted_middle =
            start_daemon("middle", tls, certfp, root.port_number, middle.port_number, "three")

          try do
            assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "middle", "root"\]/) end)
            assert eventually(fn -> reachable?(leaf, ~r/reachable_sids: \["leaf", "middle", "root"\]/) end)
            assert eventually(fn -> status_contains?(restarted_middle, ~r/users: 1/) end)
            assert eventually(fn -> status_contains?(leaf, ~r/users: 1/) end)
          after
            stop_if_alive(restarted_middle)
          end
        after
          stop_if_alive(leaf)
        end
      after
        stop_if_alive(middle)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "keeps sibling branches independent in an independent star topology" do
    tls = create_test_certificates()
    left_tls = create_test_node_certificate(tls, "left")
    right_tls = create_test_node_certificate(tls, "right")

    peer_certfps = %{
      "root" => certificate_fingerprint(tls.certfile),
      "left" => certificate_fingerprint(left_tls.certfile),
      "right" => certificate_fingerprint(right_tls.certfile)
    }

    root = start_daemon("root", tls, peer_certfps["root"], nil, 0, "star", nil, peer_certfps)

    try do
      left = start_daemon("left", left_tls, peer_certfps["left"], root.port_number, 0, "star", nil, peer_certfps)
      right = start_daemon("right", right_tls, peer_certfps["right"], root.port_number, 0, "star", nil, peer_certfps)

      try do
        assert eventually(fn -> reachable_exact?(root, ["left", "right", "root"]) end),
               inspect({reachable_sids(root), status_line(root), status_line(right)})

        assert eventually(fn -> reachable_exact?(left, ["left", "right", "root"]) end),
               inspect(reachable_sids(left))

        assert eventually(fn -> reachable_exact?(right, ["left", "right", "root"]) end),
               inspect(reachable_sids(right))

        assert {:ok, _user_line, _next} = command(root, "add_user StarUser\n", "USER ")
        assert eventually(fn -> status_contains?(left, ~r/users: 1/) end)
        assert eventually(fn -> status_contains?(right, ~r/users: 1/) end)

        assert {:ok, _stopped} = stop_daemon(left)
        assert eventually(fn -> reachable_exact?(root, ["right", "root"]) end), inspect(reachable_sids(root))
        assert eventually(fn -> reachable_exact?(right, ["right", "root"]) end), inspect(reachable_sids(right))
        assert status_contains?(right, ~r/users: 1/)

        restarted_left =
          start_daemon(
            "left",
            left_tls,
            peer_certfps["left"],
            root.port_number,
            0,
            "star",
            nil,
            peer_certfps
          )

        try do
          assert eventually(fn -> reachable_exact?(root, ["left", "right", "root"]) end),
                 inspect(reachable_sids(root))

          assert eventually(fn -> status_contains?(restarted_left, ~r/users: 1/) end)
          assert eventually(fn -> status_contains?(right, ~r/users: 1/) end)
        after
          stop_if_alive(restarted_left)
        end
      after
        stop_if_alive(right)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "converges a balanced tree with independent branch certificates" do
    tls = create_test_certificates()

    node_tls =
      ["branch-a", "branch-b", "leaf-a", "leaf-b"]
      |> Map.new(&{&1, create_test_node_certificate(tls, &1)})

    certs =
      node_tls
      |> Map.put("root", tls)
      |> Map.new(fn {sid, node} -> {sid, certificate_fingerprint(node.certfile)} end)

    root = start_daemon("root", tls, certs["root"], nil, 0, "balanced", nil, certs)

    try do
      branch_a =
        start_daemon("branch-a", node_tls["branch-a"], certs["branch-a"], root.port_number, 0, "balanced", nil, certs)

      branch_b =
        start_daemon("branch-b", node_tls["branch-b"], certs["branch-b"], root.port_number, 0, "balanced", nil, certs)

      try do
        leaf_a =
          start_daemon("leaf-a", node_tls["leaf-a"], certs["leaf-a"], branch_a.port_number, 0, "balanced", nil, certs)

        leaf_b =
          start_daemon("leaf-b", node_tls["leaf-b"], certs["leaf-b"], branch_b.port_number, 0, "balanced", nil, certs)

        try do
          expected = ["branch-a", "branch-b", "leaf-a", "leaf-b", "root"]

          assert eventually(fn -> reachable_exact?(root, expected) end),
                 inspect(
                   {status_line(root), status_line(branch_a), status_line(branch_b), status_line(leaf_a),
                    status_line(leaf_b)}
                 )

          assert eventually(fn -> reachable_exact?(branch_a, expected) end), inspect(reachable_sids(branch_a))
          assert eventually(fn -> reachable_exact?(branch_b, expected) end), inspect(reachable_sids(branch_b))
          assert eventually(fn -> reachable_exact?(leaf_a, expected) end), inspect(reachable_sids(leaf_a))
          assert eventually(fn -> reachable_exact?(leaf_b, expected) end), inspect(reachable_sids(leaf_b))

          assert {:ok, _user_line, _next} = command(root, "add_user BalancedUser\n", "USER ")
          assert eventually(fn -> status_contains?(leaf_a, ~r/users: 1/) end)
          assert eventually(fn -> status_contains?(leaf_b, ~r/users: 1/) end)

          assert {:ok, _stopped} = stop_daemon(branch_a)
          assert eventually(fn -> reachable_exact?(root, ["branch-b", "leaf-b", "root"]) end)
          assert eventually(fn -> reachable_exact?(branch_b, ["branch-b", "leaf-b", "root"]) end)
          assert eventually(fn -> reachable_exact?(leaf_b, ["branch-b", "leaf-b", "root"]) end)
          assert eventually(fn -> reachable_exact?(leaf_a, ["leaf-a"]) end)

          restarted_branch_a =
            start_daemon(
              "branch-a",
              node_tls["branch-a"],
              certs["branch-a"],
              root.port_number,
              branch_a.port_number,
              "balanced",
              nil,
              certs
            )

          try do
            assert eventually(fn -> reachable_exact?(root, expected) end, 200),
                   inspect({status_line(root), status_line(leaf_a), status_line(restarted_branch_a)})

            assert eventually(fn -> reachable_exact?(leaf_a, expected) end, 200)
            assert eventually(fn -> status_contains?(leaf_a, ~r/users: 1/) end)
          after
            stop_if_alive(restarted_branch_a)
          end
        after
          stop_if_alive(leaf_a)
          stop_if_alive(leaf_b)
        end
      after
        stop_if_alive(branch_b)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "admits a local client onto a channel learned from another daemon" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number)

      try do
        assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "root"\]/) end)

        assert {:ok, _channel, _next} = command(root, "create_channel #remote-room\n", "CHANNEL ")
        assert {:ok, root_client, _next} = command(root, "add_client RootClient\n", "CLIENT ")
        root_uid = client_uid(root_client)
        assert {:ok, _joined, _next} = command(root, "join_client RootClient #remote-room\n", "JOINED ")
        assert eventually(fn -> status_contains?(root, ~r/local_memberships: 1/) end)

        assert eventually(fn -> status_contains?(leaf, ~r/channels: 1/) end)
        assert {:ok, leaf_client, _next} = command(leaf, "add_client LeafClient\n", "CLIENT ")
        leaf_uid = client_uid(leaf_client)
        assert {:ok, joined, _next} = command(leaf, "join_client LeafClient #remote-room\n", "JOINED ")
        assert joined =~ "true"
        assert eventually(fn -> status_contains?(leaf, ~r/local_memberships: 1/) end)
        assert eventually(fn -> status_contains?(root, ~r/users: 2/) end)
        assert eventually(fn -> status_contains?(root, ~r/memberships: 2/) end)
        assert eventually(fn -> status_contains?(root, ~r/local_memberships: 1/) end)

        assert {:ok, _sent, _next} = command(root, "send_user #{root_uid} #{leaf_uid} private-message\n", "SENT ")
        assert eventually(fn -> delivered_message?(leaf, "private-message") end)

        assert {:ok, sent, _next} = command(root, "send_channel #{root_uid} #remote-room channel-message\n", "SENT ")
        assert sent =~ ":ok"
        assert eventually(fn -> delivered_message?(leaf, "channel-message") end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "keeps local ampersand channels and memberships out of the native view" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number)

      try do
        assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert {:ok, client, _next} = command(root, "add_client LocalAmpersand\n", "CLIENT ")
        uid = client_uid(client)
        assert {:ok, _channel, _next} = command(root, "create_channel &local-room\n", "CHANNEL ")
        assert {:ok, joined, _next} = command(root, "join_client LocalAmpersand &local-room\n", "JOINED ")
        assert joined =~ "true"
        assert eventually(fn -> status_contains?(root, ~r/local_memberships: 1/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/users: 1/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/channels: 0/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/memberships: 0/) end)
        assert eventually(fn -> user_info_contains?(leaf, "LocalAmpersand", ~r/uid: \"#{Regex.escape(uid)}\"/) end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "returns a remote private-message rejection to the originating client" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number)

      try do
        assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert {:ok, sender, _next} = command(root, "add_client Sender\n", "CLIENT ")
        sender_uid = client_uid(sender)
        assert {:ok, _target, _next} = command(leaf, "add_client Target\n", "CLIENT ")
        assert eventually(fn -> status_contains?(root, ~r/users: 2/) end)

        assert {:ok, _restricted, _next} = command(leaf, "restrict_client Target\n", "RESTRICTED ")
        assert eventually(fn -> user_info_contains?(root, "Target", ~r/modes: \[:R\]/) end)

        assert {:ok, _sent, _next} =
                 command(root, "client_command #{sender_uid} PRIVMSG Target :hello\n", "CLIENT_COMMAND ")

        assert eventually(fn -> delivered_message?(root, "477 Sender Target") end, 100)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "routes NOTICE and TAGMSG across daemons without automatic errors" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number)

      try do
        assert eventually(fn -> reachable?(root, ~r/reachable_sids: \[\"leaf\", \"root\"\]/) end)
        assert {:ok, sender, _next} = command(root, "add_client NoticeSender\n", "CLIENT ")
        sender_uid = client_uid(sender)
        assert {:ok, _target, _next} = command(leaf, "add_client NoticeTarget\n", "CLIENT ")
        assert eventually(fn -> status_contains?(root, ~r/users: 2/) end)

        assert {:ok, _notice, _next} =
                 command(
                   root,
                   "client_command #{sender_uid} @+draft=notice NOTICE NoticeTarget :quiet-notice\n",
                   "CLIENT_COMMAND "
                 )

        assert eventually(fn -> delivered_message?(leaf, "NOTICE NoticeTarget :quiet-notice") end)

        assert {:ok, _tagmsg, _next} =
                 command(
                   root,
                   "client_command #{sender_uid} @+draft=tag TAGMSG NoticeTarget\n",
                   "CLIENT_COMMAND "
                 )

        assert eventually(fn -> delivered_message?(leaf, "TAGMSG NoticeTarget") end)
        refute delivered_message?(root, "401 NoticeSender NoticeTarget")
        refute delivered_message?(root, "477 NoticeSender NoticeTarget")
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "routes an operator audience message to remote operators once" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number)

      try do
        assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert {:ok, root_oper, _next} = command(root, "add_client RootOper\n", "CLIENT ")
        root_uid = client_uid(root_oper)
        assert {:ok, _root_mode, _next} = command(root, "make_oper RootOper\n", "OPER ")
        assert {:ok, _leaf_oper, _next} = command(leaf, "add_client LeafOper\n", "CLIENT ")
        assert {:ok, _leaf_mode, _next} = command(leaf, "make_oper LeafOper\n", "OPER ")
        assert eventually(fn -> user_info_contains?(root, "RootOper", ~r/modes: \[:o\]/) end)
        assert eventually(fn -> user_info_contains?(root, "LeafOper", ~r/modes: \[:o\]/) end)
        assert eventually(fn -> user_info_contains?(leaf, "RootOper", ~r/modes: \[:o\]/) end)

        assert {:ok, _sent, _next} =
                 command(root, "client_command #{root_uid} GLOBOPS :network-maintenance\n", "CLIENT_COMMAND ")

        assert eventually(fn -> delivered_message?(leaf, "NOTICE @operators :network-maintenance") end, 100)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "routes query and global service streams across independent mTLS daemons" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable?(leaf, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, client, _next} = command(leaf, "add_client RemoteQuery\n", "CLIENT ")
        uid = client_uid(client)
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)

        assert {:ok, query, _next} = command(leaf, "request_query #{uid} VERSION\n", "QUERY_REPLY ")
        assert query =~ "\"command\" => \"351\""
        assert query =~ "\"server\" => \"root\""

        assert {:ok, service, _next} =
                 command(leaf, "request_service #{uid} NickServ HELP\n", "SERVICE_REPLY ")

        assert service =~ "\"command\" => \"NOTICE\""
        assert service =~ "\"service\" => \"NickServ\""
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "executes the global NickServ and ChanServ read-only matrix at one authority" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(leaf, ["leaf", "root"]) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert {:ok, _account, _next} = command(root, "seed_account MatrixAccount matrix-password\n", "ACCOUNT ")
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, client, _next} = command(leaf, "add_client MatrixAccount\n", "CLIENT ")
        uid = client_uid(client)

        assert {:ok, identify, _next} =
                 command(
                   leaf,
                   "request_service #{uid} NickServ IDENTIFY MatrixAccount matrix-password\n",
                   "SERVICE_REPLY "
                 )

        assert identify =~ "status: \"OK\""
        assert eventually(fn -> user_info_contains?(leaf, "MatrixAccount", ~r/identified_as: \"MatrixAccount\"/) end)

        assert {:ok, _registered, _next} =
                 command(root, "seed_registered_channel #matrix-room MatrixAccount\n", "REGISTERED_CHANNEL ")

        assert {:ok, _channel, _next} = command(root, "create_channel #matrix-room\n", "CHANNEL ")
        assert eventually(fn -> status_contains?(leaf, ~r/channels: 1/) end)
        assert {:ok, joined, _next} = command(leaf, "join_client MatrixAccount #matrix-room\n", "JOINED ")
        assert joined =~ "true"

        nickserv_commands = [
          ["ALIST"],
          ["ACCESS", "LIST"],
          ["HELP"],
          ["INFO"],
          ["LIST"],
          ["LISTCHANS"],
          ["MEMO", "LIST"],
          ["STATUS", "MatrixAccount"],
          ["SET", "NOGREET"]
        ]

        leaf =
          Enum.reduce(nickserv_commands, leaf, fn arguments, daemon ->
            assert {:ok, response, next_leaf} =
                     command(
                       daemon,
                       "request_service #{uid} NickServ #{Enum.join(arguments, " ")}\n",
                       "SERVICE_REPLY "
                     )

            assert response =~ "status: \"OK\"", "NickServ #{inspect(arguments)} returned #{response}"
            next_leaf
          end)

        chanserv_commands = [
          ["ACCESS", "#matrix-room", "LIST"],
          ["ALIST"],
          ["FLAGS", "#matrix-room"],
          ["HELP"],
          ["INFO", "#matrix-room"],
          ["SET", "#matrix-room", "PRIVATE"],
          ["STATUS", "#matrix-room"]
        ]

        Enum.reduce(chanserv_commands, leaf, fn arguments, daemon ->
          assert {:ok, response, next_leaf} =
                   command(
                     daemon,
                     "request_service #{uid} ChanServ #{Enum.join(arguments, " ")}\n",
                     "SERVICE_REPLY "
                   )

          assert response =~ "status: \"OK\"", "ChanServ #{inspect(arguments)} returned #{response}"
          next_leaf
        end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "executes global registration, settings, and memos only at the services authority" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(root, ["leaf", "root"]) end)
        assert eventually(fn -> reachable_exact?(leaf, ["leaf", "root"]) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, _account, root} = command(root, "seed_account AuthorityUser authority-password\n", "ACCOUNT ")

        assert {:ok, _recipient, root} =
                 command(root, "seed_account MemoRecipient recipient-password\n", "ACCOUNT ")

        assert {:ok, _registered_channel, root} =
                 command(root, "seed_registered_channel #authority-room AuthorityUser\n", "REGISTERED_CHANNEL ")

        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert eventually(fn -> global_counts_match?(root, ~r/registered_nicks: 2/) end)
        assert global_counts_match?(root, ~r/registered_channels: 1/)
        assert global_counts_match?(leaf, ~r/registered_nicks: 0/)
        assert global_counts_match?(leaf, ~r/registered_channels: 0/)

        assert {:ok, registering_client, leaf} = command(leaf, "add_client RemoteRegistered\n", "CLIENT ")
        registering_uid = client_uid(registering_client)

        assert {:ok, registration, leaf} =
                 command(
                   leaf,
                   "request_service #{registering_uid} NickServ REGISTER remote-register-password\n",
                   "SERVICE_REPLY "
                 )

        assert registration =~ "status: \"OK\""
        counts = command(root, "global_counts\n", "GLOBAL_COUNTS ")

        assert eventually(fn -> global_counts_match?(root, ~r/registered_nicks: 3/) end),
               "registration=#{registration} counts=#{inspect(counts)}"

        assert global_counts_match?(leaf, ~r/registered_nicks: 0/)

        assert {:ok, authority_client, leaf} = command(leaf, "add_client AuthorityUser\n", "CLIENT ")
        authority_uid = client_uid(authority_client)

        assert {:ok, identify, leaf} =
                 command(
                   leaf,
                   "request_service #{authority_uid} NickServ IDENTIFY authority-password\n",
                   "SERVICE_REPLY "
                 )

        assert identify =~ "status: \"OK\""
        assert eventually(fn -> user_info_contains?(leaf, "AuthorityUser", ~r/identified_as: \"AuthorityUser\"/) end)

        {:ok, before_set_line, root} = command(root, "status\n", "STATUS ")
        before_set_revision = extract_policy_revision!(before_set_line)

        assert {:ok, setting, leaf} =
                 command(
                   leaf,
                   "request_service #{authority_uid} NickServ SET NOGREET ON\n",
                   "SERVICE_REPLY "
                 )

        assert setting =~ "status: \"OK\""
        assert eventually(fn -> policy_revision_greater_than?(root, before_set_revision) end)
        {:ok, after_set_line, root} = command(root, "status\n", "STATUS ")
        after_set_revision = extract_policy_revision!(after_set_line)
        assert after_set_revision > before_set_revision

        assert {:ok, channel_setting, leaf} =
                 command(
                   leaf,
                   "request_service #{authority_uid} ChanServ SET #authority-room PRIVATE ON\n",
                   "SERVICE_REPLY "
                 )

        assert channel_setting =~ "status: \"OK\""

        assert {:ok, access, leaf} =
                 command(
                   leaf,
                   "request_service #{authority_uid} ChanServ ACCESS #authority-room ADD MemoRecipient 1\n",
                   "SERVICE_REPLY "
                 )

        assert access =~ "status: \"OK\""

        assert {:ok, flags, leaf} =
                 command(
                   leaf,
                   "request_service #{authority_uid} ChanServ FLAGS #authority-room MemoRecipient +v\n",
                   "SERVICE_REPLY "
                 )

        assert flags =~ "status: \"OK\""

        {:ok, before_memo_line, root} = command(root, "status\n", "STATUS ")
        before_memo_revision = extract_policy_revision!(before_memo_line)

        assert {:ok, memo, leaf} =
                 command(
                   leaf,
                   "request_service #{authority_uid} NickServ MEMO SEND MemoRecipient hello-from-leaf\n",
                   "SERVICE_REPLY "
                 )

        assert memo =~ "status: \"OK\""
        assert eventually(fn -> global_counts_match?(root, ~r/memos: 1/) end)
        assert global_counts_match?(leaf, ~r/registered_nicks: 0/)
        assert global_counts_match?(leaf, ~r/memos: 0/)

        {:ok, after_memo_line, _root} = command(root, "status\n", "STATUS ")
        assert extract_policy_revision!(after_memo_line) == before_memo_revision
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "waits for the nickname owner before completing remote NickServ recovery and release" do
    tls = create_test_certificates()
    owner_tls = create_test_node_certificate(tls, "left")
    caller_tls = create_test_node_certificate(tls, "right")

    certfps = %{
      "root" => certificate_fingerprint(tls.certfile),
      "left" => certificate_fingerprint(owner_tls.certfile),
      "right" => certificate_fingerprint(caller_tls.certfile)
    }

    root = start_daemon("root", tls, certfps["root"], nil, 0, "star", "root", certfps)

    try do
      owner = start_daemon("left", owner_tls, certfps["left"], root.port_number, 0, "star", "root", certfps)

      try do
        caller = start_daemon("right", caller_tls, certfps["right"], root.port_number, 0, "star", "root", certfps)

        try do
          nodes = ["left", "right", "root"]
          assert eventually(fn -> reachable_exact?(root, nodes) end)
          assert eventually(fn -> reachable_exact?(owner, nodes) end)
          assert eventually(fn -> reachable_exact?(caller, nodes) end)
          assert {:ok, _account, root} = command(root, "seed_account GhostTarget ghost-password\n", "ACCOUNT ")
          assert eventually(fn -> status_contains?(owner, ~r/policy_ready: true/) end)
          assert eventually(fn -> status_contains?(caller, ~r/policy_ready: true/) end)

          assert {:ok, target_client, owner} = command(owner, "add_client GhostTarget\n", "CLIENT ")
          target_uid = client_uid(target_client)
          assert {:ok, caller_client, caller} = command(caller, "add_client GhostCaller\n", "CLIENT ")
          caller_uid = client_uid(caller_client)
          assert eventually(fn -> status_contains?(root, ~r/users: 2/) end)
          assert eventually(fn -> status_contains?(owner, ~r/users: 2/) end)
          assert eventually(fn -> status_contains?(caller, ~r/users: 2/) end)

          assert {:ok, recovered, caller} =
                   command(
                     caller,
                     "request_service #{caller_uid} NickServ RECOVER GhostTarget ghost-password\n",
                     "SERVICE_REPLY "
                   )

          assert recovered =~ "status: \"OK\""
          assert user_missing?(owner, "GhostTarget")
          assert user_missing?(root, "GhostTarget")
          assert policy_nick_reserved_until_ms(root, "GhostTarget") > Identity.now_ms()
          assert eventually(fn -> user_missing?(caller, "GhostTarget") end)
          assert status_contains?(root, ~r/users: 1/)
          assert status_contains?(owner, ~r/users: 1/)
          assert status_contains?(caller, ~r/users: 1/)
          assert user_info_contains?(caller, "GhostCaller", ~r/uid: \"#{Regex.escape(caller_uid)}\"/)
          assert global_counts_match?(root, ~r/registered_nicks: 1/)
          assert global_counts_match?(owner, ~r/registered_nicks: 0/)
          assert global_counts_match?(caller, ~r/registered_nicks: 0/)

          assert eventually(fn -> policy_nick_reserved_until_ms(caller, "GhostTarget") > Identity.now_ms() end)

          assert {:ok, released, caller} =
                   command(
                     caller,
                     "request_service #{caller_uid} NickServ RELEASE GhostTarget ghost-password\n",
                     "SERVICE_REPLY "
                   )

          assert released =~ "status: \"OK\""
          assert policy_nick_reserved_until_ms(root, "GhostTarget") == 0
          assert eventually(fn -> policy_nick_reserved_until_ms(caller, "GhostTarget") == 0 end)
          assert target_uid != caller_uid
        after
          stop_if_alive(caller)
        end
      after
        stop_if_alive(owner)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "keeps the cached policy while global service writes fail during an authority partition" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(leaf, ["leaf", "root"]) end)
        assert {:ok, _account, root} = command(root, "seed_account PartitionUser partition-password\n", "ACCOUNT ")
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert {:ok, client, leaf} = command(leaf, "add_client PartitionUser\n", "CLIENT ")
        uid = client_uid(client)

        assert {:ok, identify, leaf} =
                 command(
                   leaf,
                   "request_service #{uid} NickServ IDENTIFY partition-password\n",
                   "SERVICE_REPLY "
                 )

        assert identify =~ "status: \"OK\""
        assert eventually(fn -> user_info_contains?(leaf, "PartitionUser", ~r/identified_as: \"PartitionUser\"/) end)

        assert {:ok, _stopped} = stop_daemon(root)
        assert eventually(fn -> reachable_exact?(leaf, ["leaf"]) end)
        assert status_contains?(leaf, ~r/policy_ready: true/)

        assert {:ok, error, leaf} =
                 command(
                   leaf,
                   "request_service #{uid} NickServ SET NOGREET OFF\n",
                   "REQUEST_ERROR "
                 )

        assert error =~ "target_unreachable" or error =~ "unreachable"
        assert global_counts_match?(leaf, ~r/registered_nicks: 0/)
        assert global_counts_match?(leaf, ~r/memos: 0/)
        assert status_contains?(leaf, ~r/pending_requests: 0/)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "keeps grouped nickname identity stable and applies ungroup and DROP revocation across daemons" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable_exact?(leaf, ["leaf", "root"]) end)
        assert {:ok, _primary, root} = command(root, "seed_account GroupPrimary primary-password\n", "ACCOUNT ")
        assert {:ok, _alias, root} = command(root, "seed_account GroupAlias alias-password\n", "ACCOUNT ")
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        primary_account_id = eventually_policy_nick_id(leaf, "GroupPrimary")
        alias_account_id = eventually_policy_nick_id(leaf, "GroupAlias")
        assert primary_account_id != alias_account_id

        assert {:ok, alias_client, leaf} = command(leaf, "add_client GroupAlias\n", "CLIENT ")
        alias_uid = client_uid(alias_client)

        assert {:ok, identify_primary, leaf} =
                 command(
                   leaf,
                   "request_service #{alias_uid} NickServ IDENTIFY GroupPrimary primary-password\n",
                   "SERVICE_REPLY "
                 )

        assert identify_primary =~ "status: \"OK\""
        assert eventually(fn -> user_info_contains?(leaf, "GroupAlias", ~r/identified_as: \"GroupPrimary\"/) end)

        assert {:ok, grouped, leaf} =
                 command(
                   leaf,
                   "request_service #{alias_uid} NickServ GROUP alias-password\n",
                   "SERVICE_REPLY "
                 )

        assert grouped =~ "status: \"OK\""
        assert eventually(fn -> policy_nick_account_id(leaf, "GroupAlias") == primary_account_id end)
        assert policy_nick_account_id(leaf, "GroupPrimary") == primary_account_id
        assert global_counts_match?(root, ~r/registered_nicks: 2/)
        assert global_counts_match?(leaf, ~r/registered_nicks: 0/)

        assert {:ok, alias_list, leaf} =
                 command(leaf, "request_service #{alias_uid} NickServ ALIST\n", "SERVICE_REPLY ")

        assert alias_list =~ "GroupAlias"
        assert alias_list =~ "GroupPrimary"

        assert {:ok, ungrouped, leaf} =
                 command(leaf, "request_service #{alias_uid} NickServ UNGROUP\n", "SERVICE_REPLY ")

        root_alias_info = command(root, "user_info GroupAlias\n", "USER_INFO ")
        leaf_alias_info = command(leaf, "user_info GroupAlias\n", "USER_INFO ")

        assert ungrouped =~ "status: \"OK\"",
               "root_user=#{inspect(root_alias_info)} leaf_user=#{inspect(leaf_alias_info)}"

        assert eventually(fn -> user_info_contains?(leaf, "GroupAlias", ~r/identified_as: \"GroupAlias\"/) end)
        alias_detached_id = eventually_policy_nick_id(leaf, "GroupAlias")
        assert alias_detached_id != primary_account_id
        assert policy_nick_account_id(leaf, "GroupPrimary") == primary_account_id

        assert {:ok, primary_client, leaf} = command(leaf, "add_client GroupPrimary\n", "CLIENT ")
        primary_uid = client_uid(primary_client)

        assert {:ok, identify_account, leaf} =
                 command(
                   leaf,
                   "request_service #{primary_uid} NickServ IDENTIFY GroupPrimary primary-password\n",
                   "SERVICE_REPLY "
                 )

        assert identify_account =~ "status: \"OK\""
        assert eventually(fn -> user_info_contains?(leaf, "GroupPrimary", ~r/identified_as: \"GroupPrimary\"/) end)

        assert {:ok, primary_peer_client, leaf} = command(leaf, "add_client GroupPrimaryPeer\n", "CLIENT ")
        primary_peer_uid = client_uid(primary_peer_client)

        assert {:ok, peer_identify, leaf} =
                 command(
                   leaf,
                   "request_service #{primary_peer_uid} NickServ IDENTIFY GroupPrimary primary-password\n",
                   "SERVICE_REPLY "
                 )

        assert peer_identify =~ "status: \"OK\""
        assert eventually(fn -> user_info_contains?(leaf, "GroupPrimaryPeer", ~r/identified_as: \"GroupPrimary\"/) end)

        assert {:ok, dropped, leaf} =
                 command(leaf, "request_service #{primary_uid} NickServ DROP GroupPrimary\n", "SERVICE_REPLY ")

        assert dropped =~ "status: \"OK\""
        assert eventually(fn -> user_info_contains?(leaf, "GroupPrimary", ~r/identified_as: nil/) end)
        assert eventually(fn -> user_info_contains?(root, "GroupPrimary", ~r/identified_as: nil/) end)
        assert eventually(fn -> user_info_contains?(leaf, "GroupPrimaryPeer", ~r/identified_as: nil/) end)
        assert eventually(fn -> user_info_contains?(root, "GroupPrimaryPeer", ~r/identified_as: nil/) end)
        assert user_info_contains?(leaf, "GroupAlias", ~r/identified_as: \"GroupAlias\"/)
        assert eventually(fn -> global_counts_match?(root, ~r/registered_nicks: 1/) end)
        assert global_counts_match?(leaf, ~r/registered_nicks: 0/)
        assert eventually(fn -> policy_nick_account_id(leaf, "GroupPrimary") == nil end)
        assert policy_nick_account_id(leaf, "GroupAlias") == alias_detached_id
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "delivers a global NickServ reply through an actual leaf C2S PRIVMSG" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable?(leaf, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert {:ok, client, leaf} = command(leaf, "add_client RemoteServiceClient\n", "CLIENT ")
        uid = client_uid(client)
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)

        assert {:ok, accepted, leaf} =
                 command(
                   leaf,
                   "client_command_async #{uid} PRIVMSG NickServ :HELP\n",
                   "CLIENT_COMMAND_ASYNC "
                 )

        assert accepted =~ uid

        assert {:ok, message_lines} =
                 eventually_message_lines?(leaf, ["NOTICE", "NickServ", "The following commands are available:"])

        rendered_messages = Enum.join(message_lines, "\n")
        assert count_occurrences(rendered_messages, "NOTICE") >= 1
        assert count_occurrences(rendered_messages, "NickServ") >= 1

        assert {:ok, accepted, leaf} =
                 command(
                   leaf,
                   "client_command_async #{uid} PRIVMSG NickServ :NOT_A_NICKSERV_COMMAND\n",
                   "CLIENT_COMMAND_ASYNC "
                 )

        assert accepted =~ uid

        assert {:ok, error_lines} =
                 eventually_message_lines?(leaf, ["UNSUPPORTED: service command is not enabled"])

        assert count_occurrences(Enum.join(error_lines, "\n"), "UNSUPPORTED: service command is not enabled") == 1
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "routes one global fantasy command from a leaf to the ChanServ authority" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable?(leaf, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)

        assert {:ok, _account, _next} = command(root, "seed_account FantasyOperator fantasy-password\n", "ACCOUNT ")

        assert {:ok, _registered, _next} =
                 command(root, "seed_registered_channel #fantasy-room FantasyOperator\n", "REGISTERED_CHANNEL ")

        assert {:ok, _channel, _next} = command(root, "create_channel #fantasy-room\n", "CHANNEL ")
        assert eventually(fn -> status_contains?(leaf, ~r/channels: 1/) end)

        assert {:ok, actor, _next} = command(leaf, "add_client FantasyActor\n", "CLIENT ")
        actor_uid = client_uid(actor)
        assert {:ok, target, _next} = command(leaf, "add_client FantasyTarget\n", "CLIENT ")
        target_uid = client_uid(target)

        assert {:ok, joined_actor, _next} = command(leaf, "join_client FantasyActor #fantasy-room\n", "JOINED ")
        assert joined_actor =~ "true"
        assert {:ok, joined_target, _next} = command(leaf, "join_client FantasyTarget #fantasy-room\n", "JOINED ")
        assert joined_target =~ "true"
        assert eventually(fn -> status_contains?(root, ~r/memberships: 2/) end)

        assert {:ok, identify, _next} =
                 command(
                   leaf,
                   "request_service #{actor_uid} NickServ IDENTIFY FantasyOperator fantasy-password\n",
                   "SERVICE_REPLY "
                 )

        assert identify =~ "status: \"OK\""
        assert eventually(fn -> user_info_contains?(leaf, "FantasyActor", ~r/identified_as: \"FantasyOperator\"/) end)

        assert {:ok, result, _next} =
                 command(
                   leaf,
                   "client_command_async #{actor_uid} PRIVMSG #fantasy-room :!op FantasyTarget\n",
                   "CLIENT_COMMAND_ASYNC "
                 )

        assert result =~ actor_uid

        assert {:ok, message_lines} =
                 eventually_message_lines?(leaf, ["Operator status granted", " MODE #fantasy-room +o FantasyTarget"])

        rendered_messages = Enum.join(message_lines, "\n")
        assert count_occurrences(rendered_messages, "Operator status granted") == 1
        assert count_occurrences(rendered_messages, " MODE #fantasy-room +o FantasyTarget") == 2

        assert eventually(fn ->
                 user_info_contains?(leaf, "FantasyTarget", ~r/uid: \"#{Regex.escape(target_uid)}\"/)
               end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "executes a cross-daemon ChanServ KICK at the remote target owner" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp, nil, 0, "two", "root")

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number, 0, "two", "root")

      try do
        assert eventually(fn -> reachable?(leaf, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/policy_ready: true/) end)
        assert {:ok, _account, _next} = command(root, "seed_account ServiceOperator service-password\n", "ACCOUNT ")

        assert {:ok, _registered, _next} =
                 command(root, "seed_registered_channel #service-room ServiceOperator\n", "REGISTERED_CHANNEL ")

        assert {:ok, _channel, _next} = command(root, "create_channel #service-room\n", "CHANNEL ")
        assert eventually(fn -> status_contains?(leaf, ~r/channels: 1/) end)

        assert {:ok, actor, _next} = command(leaf, "add_client ServiceActor\n", "CLIENT ")
        actor_uid = client_uid(actor)
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)

        assert {:ok, identify, _next} =
                 command(
                   leaf,
                   "request_service #{actor_uid} NickServ IDENTIFY ServiceOperator service-password\n",
                   "SERVICE_REPLY "
                 )

        assert identify =~ "status: \"OK\"", inspect(identify)
        assert eventually(fn -> delivered_message?(leaf, "You are now logged in as ServiceOperator") end)
        assert eventually(fn -> user_info_contains?(leaf, "ServiceActor", ~r/identified_as: \"ServiceOperator\"/) end)

        assert {:ok, _target, _next} = command(leaf, "add_client ServiceTarget\n", "CLIENT ")
        assert {:ok, joined, _next} = command(leaf, "join_client ServiceTarget #service-room\n", "JOINED ")
        assert joined =~ "true"
        assert eventually(fn -> status_contains?(leaf, ~r/local_memberships: 1/) end)
        assert eventually(fn -> status_contains?(root, ~r/users: 2/) end)

        assert {:ok, kicked, _next} =
                 command(
                   leaf,
                   "request_service #{actor_uid} ChanServ KICK #service-room ServiceTarget service-reason\n",
                   "SERVICE_REPLY "
                 )

        assert kicked =~ "status: \"OK\""
        assert eventually(fn -> status_contains?(leaf, ~r/local_memberships: 0/) end)
        assert eventually(fn -> delivered_message?(leaf, "KICK") end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "executes a remote KICK at the target home and publishes the owner membership" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number)

      try do
        assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert {:ok, _root_client, _next} = command(root, "add_client KickOperator\n", "CLIENT ")
        assert {:ok, _joined, _next} = command(root, "join_client KickOperator #kick-room\n", "JOINED ")
        assert eventually(fn -> status_contains?(root, ~r/local_memberships: 1/) end)

        assert {:ok, _leaf_client, _next} = command(leaf, "add_client KickTarget\n", "CLIENT ")
        assert {:ok, joined, _next} = command(leaf, "join_client KickTarget #kick-room\n", "JOINED ")
        assert joined =~ "true"
        assert eventually(fn -> status_contains?(leaf, ~r/local_memberships: 1/) end)
        assert eventually(fn -> status_contains?(root, ~r/memberships: 2/) end)

        assert {:ok, kicked, _next} =
                 command(root, "kick_client KickOperator #kick-room KickTarget remote-reason\n", "KICKED ")

        assert kicked =~ "status: \"OK\""

        assert eventually(fn -> status_contains?(leaf, ~r/local_memberships: 0/) end)
        assert eventually(fn -> status_contains?(root, ~r/memberships: 1/) end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "executes a remote INVITE at the target home and notifies the invited client" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number)

      try do
        assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert {:ok, _root_client, _next} = command(root, "add_client InviteOperator\n", "CLIENT ")
        assert {:ok, _joined, _next} = command(root, "join_client InviteOperator #invite-room\n", "JOINED ")
        assert eventually(fn -> status_contains?(root, ~r/local_memberships: 1/) end)

        assert {:ok, _leaf_client, _next} = command(leaf, "add_client InviteTarget\n", "CLIENT ")
        assert eventually(fn -> status_contains?(root, ~r/users: 2/) end)
        assert eventually(fn -> status_contains?(leaf, ~r/channels: 1/) end)

        assert {:ok, invited, _next} =
                 command(root, "invite_client InviteOperator #invite-room InviteTarget\n", "INVITED ")

        assert invited =~ "status: \"OK\""
        assert eventually(fn -> delivered_message?(leaf, "INVITE") end)
        assert eventually(fn -> delivered_message?(root, "INVITE InviteTarget #invite-room") end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  test "routes remote operator CHGHOST and KILL through the target home" do
    tls = create_test_certificates()
    certfp = certificate_fingerprint(tls.certfile)
    root = start_daemon("root", tls, certfp)

    try do
      leaf = start_daemon("leaf", tls, certfp, root.port_number)

      try do
        assert eventually(fn -> reachable?(root, ~r/reachable_sids: \["leaf", "root"\]/) end)
        assert {:ok, _operator, _next} = command(root, "add_client RemoteOper\n", "CLIENT ")
        assert {:ok, _oper, _next} = command(root, "make_oper RemoteOper\n", "OPER ")
        assert {:ok, _target, _next} = command(leaf, "add_client RemoteTarget\n", "CLIENT ")
        assert eventually(fn -> user_info_contains?(leaf, "RemoteOper", ~r/modes: \[:o\]/) end)
        assert eventually(fn -> status_contains?(root, ~r/users: 2/) end)

        assert {:ok, changed, _next} =
                 command(root, "chghost_client RemoteOper RemoteTarget remoteid remote.example.test\n", "CHGHOSTED ")

        assert changed =~ "CHGHOSTED"

        assert eventually(fn -> user_info_contains?(leaf, "RemoteTarget", ~r/ident: \"remoteid\"/) end)

        assert eventually(fn ->
                 user_info_contains?(leaf, "RemoteTarget", ~r/cloaked_hostname: \"remote.example.test\"/)
               end)

        assert {:ok, killed, _next} =
                 command(root, "kill_client RemoteOper RemoteTarget killed-by-remote-oper\n", "KILLED ")

        assert killed =~ "status: \"OK\""
        assert eventually(fn -> user_missing?(leaf, "RemoteTarget") end)
        assert eventually(fn -> delivered_message?(leaf, "DISCONNECT") end)
        assert eventually(fn -> status_contains?(root, ~r/users: 1/) end)
      after
        stop_if_alive(leaf)
      end
    after
      stop_if_alive(root)
      File.rm_rf!(tls.dir)
    end
  end

  defp start_daemon(
         sid,
         tls,
         certfp,
         parent_port \\ nil,
         listener_port \\ 0,
         topology \\ "two",
         services_authority \\ nil,
         peer_certfps \\ %{},
         sasl_delay_ms \\ 0,
         budget_overrides \\ [],
         timeout_overrides \\ []
       ) do
    mnesia_dir = Path.join(System.tmp_dir!(), "elixircd-native-s2s-#{sid}-#{System.unique_integer([:positive])}")
    File.rm_rf!(mnesia_dir)

    args =
      [
        "run",
        "--no-start",
        @daemon_script,
        "--",
        "--sid",
        sid,
        "--port",
        Integer.to_string(listener_port),
        "--mnesia-dir",
        mnesia_dir,
        "--certfp",
        certfp,
        "--certfile",
        tls.certfile,
        "--keyfile",
        tls.keyfile,
        "--cacertfile",
        tls.cacertfile,
        "--peer-certfps",
        encode_peer_certfps(peer_certfps)
      ] ++
        if(is_integer(parent_port), do: ["--parent-port", Integer.to_string(parent_port)], else: []) ++
        ["--topology", topology] ++
        if(is_binary(services_authority), do: ["--services-authority", services_authority], else: []) ++
        if(is_integer(sasl_delay_ms) and sasl_delay_ms > 0,
          do: ["--sasl-delay-ms", Integer.to_string(sasl_delay_ms)],
          else: []
        ) ++
        budget_argument(budget_overrides) ++
        timeout_argument(timeout_overrides)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("mix")},
        [:binary, :exit_status, {:args, args}, {:cd, @cwd}]
      )

    daemon = %{port: port, mnesia_dir: mnesia_dir, buffer: ""}

    case read_line(daemon, "READY ", 15_000) do
      {:ok, line, next} ->
        [_ready, ^sid, port_string] = String.split(line, " ", parts: 3)
        Map.merge(next, %{sid: sid, port_number: String.to_integer(port_string)})

      {:error, reason} ->
        if Port.info(port) != nil, do: Port.close(port)
        flunk("native S2S daemon #{sid} did not start: #{inspect(reason)}")
    end
  end

  defp stop_daemon(daemon) do
    case command(daemon, "stop\n", "STOPPED") do
      {:ok, line, next} ->
        _ = wait_for_exit(next.port, 5_000)
        File.rm_rf(next.mnesia_dir)
        {:ok, line}

      {:error, reason} ->
        File.rm_rf(daemon.mnesia_dir)
        {:error, reason}
    end
  end

  defp stop_if_alive(daemon) do
    if is_map(daemon) and Port.info(daemon.port) != nil do
      _ = stop_daemon(daemon)
    else
      if is_map(daemon), do: File.rm_rf(daemon.mnesia_dir)
    end
  rescue
    _ ->
      if is_map(daemon), do: File.rm_rf(daemon.mnesia_dir)
      :ok
  end

  defp reachable?(daemon, regex) do
    case command(daemon, "status\n", "STATUS ") do
      {:ok, line, _next} ->
        Regex.match?(regex, line)

      _error ->
        false
    end
  end

  defp reachable_exact?(daemon, sids) do
    Enum.sort(reachable_sids(daemon)) == Enum.sort(sids)
  end

  defp reachable_sids(daemon) do
    case status_line(daemon) do
      {:ok, line} ->
        case Regex.run(~r/reachable_sids: \[([^\]]*)\]/, line, capture: :all_but_first) do
          [raw] -> Regex.scan(~r/\"([^\"]+)\"/, raw, capture: :all_but_first) |> List.flatten()
          _ -> []
        end

      _ ->
        []
    end
  end

  defp status_line(daemon) do
    case command(daemon, "status\n", "STATUS ") do
      {:ok, line, _next} -> {:ok, line}
      error -> error
    end
  end

  defp status_contains?(daemon, regex) do
    case command(daemon, "status\n", "STATUS ") do
      {:ok, line, _next} -> Regex.match?(regex, line)
      _ -> false
    end
  end

  defp policy_revision_greater_than?(daemon, revision) do
    case command(daemon, "status\n", "STATUS ") do
      {:ok, line, _next} ->
        case Regex.run(~r/policy_revision: (\d+)/, line, capture: :all_but_first) do
          [value] -> String.to_integer(value) > revision
          _ -> false
        end

      _ ->
        false
    end
  end

  defp extract_policy_revision!(line) do
    case Regex.run(~r/policy_revision: (\d+)/, line, capture: :all_but_first) do
      [value] -> String.to_integer(value)
      _ -> flunk("policy revision missing from status: #{line}")
    end
  end

  defp global_counts_match?(daemon, regex) do
    case command(daemon, "global_counts\n", "GLOBAL_COUNTS ") do
      {:ok, line, _next} -> Regex.match?(regex, line)
      _ -> false
    end
  end

  defp policy_nick_account_id(daemon, nickname) do
    case command(daemon, "policy_nick #{nickname}\n", "POLICY_NICK ") do
      {:ok, line, _next} ->
        case Regex.run(~r/account_id: "([^\"]+)"/, line, capture: :all_but_first) do
          [account_id] -> account_id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp policy_nick_reserved_until_ms(daemon, nickname) do
    case command(daemon, "policy_nick #{nickname}\n", "POLICY_NICK ") do
      {:ok, line, _next} ->
        case Regex.run(~r/reserved_until_ms: (\d+)/, line, capture: :all_but_first) do
          [value] -> String.to_integer(value)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp eventually_policy_nick_id(daemon, nickname) do
    eventually_value(fn ->
      case policy_nick_account_id(daemon, nickname) do
        account_id when is_binary(account_id) -> {:ok, account_id}
        _ -> :retry
      end
    end)
  end

  defp connect_raw_peer(daemon, tls, timeout_ms \\ 10_000) do
    connect_raw_peer(daemon, tls, tls, timeout_ms)
  end

  defp connect_raw_peer(daemon, client_tls, trust_tls, timeout_ms) do
    options =
      TLS.client_options(
        [
          listener: [
            cacertfile: trust_tls.cacertfile,
            certfile: client_tls.certfile,
            keyfile: client_tls.keyfile
          ]
        ],
        address: "localhost",
        sni: "localhost"
      )

    :ssl.connect(~c"localhost", daemon.port_number, options, timeout_ms)
  end

  defp with_raw_peers(daemon, peers_tls, trust_tls, fun) do
    peers =
      Enum.map(peers_tls, fn {sid, client_tls} ->
        {:ok, socket} = connect_raw_peer(daemon, client_tls, trust_tls)
        {:ok, root_hello_wire} = :ssl.recv(socket, 0, 2_000)
        assert {:ok, [root_hello], <<>>} = Protocol.feed(<<>>, root_hello_wire)
        assert root_hello["t"] == "hello"

        remote_hello =
          root_hello
          |> Map.put("sid", sid)
          |> Map.put("name", "#{sid}.example.test")
          |> Map.put("boot", ElixIRCd.Server.S2S.Identity.boot())
          |> Map.put("nonce", ElixIRCd.Server.S2S.Identity.nonce())
          |> Map.put("time_ms", System.system_time(:millisecond))

        {socket, remote_hello}
      end)

    try do
      fun.(peers)
    after
      Enum.each(peers, fn {socket, _hello} -> :ssl.close(socket) end)
    end
  end

  defp connect_without_client_certificate(daemon, trust_tls, timeout_ms) do
    options = [
      mode: :binary,
      active: false,
      verify: :verify_peer,
      cacertfile: trust_tls.cacertfile,
      server_name_indication: ~c"localhost",
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      reuse_sessions: false
    ]

    :ssl.connect(~c"localhost", daemon.port_number, options, timeout_ms)
  end

  defp assert_raw_tls_rejected(connect_fun) do
    case connect_fun.() do
      {:error, _reason} ->
        :ok

      {:ok, socket} ->
        try do
          assert eventually(fn -> ssl_closed?(socket) end, 20)
        after
          :ssl.close(socket)
        end
    end
  end

  defp ssl_closed?(socket) do
    case :ssl.recv(socket, 0, 100) do
      {:ok, _data} -> false
      {:error, :timeout} -> false
      {:error, _reason} -> true
    end
  end

  defp user_missing?(daemon, nick) do
    case command(daemon, "user_info #{nick}\n", "USER_INFO ") do
      {:ok, line, _next} -> String.contains?(line, "{:error, :user_not_found}")
      _ -> false
    end
  end

  defp user_info_contains?(daemon, nick, regex) do
    case command(daemon, "user_info #{nick}\n", "USER_INFO ") do
      {:ok, line, _next} -> Regex.match?(regex, line)
      _ -> false
    end
  end

  defp client_uid("CLIENT " <> uid), do: String.trim(uid)

  defp delivered_message?(daemon, text) do
    case command(daemon, "read_message\n", "MESSAGE ") do
      {:ok, line, _next} ->
        String.contains?(line, text)

      _ ->
        false
    end
  end

  defp eventually_messages?(daemon, texts, attempts \\ 100, seen \\ MapSet.new())

  defp eventually_messages?(_daemon, texts, 0, seen), do: Enum.all?(texts, &MapSet.member?(seen, &1))

  defp eventually_messages?(daemon, texts, attempts, seen) do
    seen =
      case command(daemon, "read_message\n", "MESSAGE ") do
        {:ok, line, _next} ->
          Enum.reduce(texts, seen, fn text, acc ->
            if String.contains?(line, text), do: MapSet.put(acc, text), else: acc
          end)

        _ ->
          seen
      end

    if Enum.all?(texts, &MapSet.member?(seen, &1)),
      do: true,
      else:
        (
          Process.sleep(100)
          eventually_messages?(daemon, texts, attempts - 1, seen)
        )
  end

  defp eventually_message_lines?(daemon, texts, attempts \\ 100, lines \\ [])

  defp eventually_message_lines?(_daemon, _texts, 0, lines), do: {:error, Enum.reverse(lines)}

  defp eventually_message_lines?(daemon, texts, attempts, lines) do
    {lines, daemon} =
      case command(daemon, "read_message\n", "MESSAGE ") do
        {:ok, line, next} -> {[line | lines], next}
        _ -> {lines, daemon}
      end

    if Enum.all?(texts, fn text -> Enum.any?(lines, &String.contains?(&1, text)) end) do
      {:ok, Enum.reverse(lines)}
    else
      Process.sleep(100)
      eventually_message_lines?(daemon, texts, attempts - 1, lines)
    end
  end

  defp count_occurrences(text, needle) do
    text
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end

  defp command(daemon, input, prefix) do
    Port.command(daemon.port, input)

    case read_line(daemon, prefix, 5_000) do
      {:ok, line, next} -> {:ok, line, next}
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, {:port_command, error}}
  end

  defp await_manager_queue(daemon, target, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_manager_queue_until(daemon, target, deadline)
  end

  defp await_manager_queue_until(daemon, target, deadline) do
    case command(daemon, "manager_queue\n", "MANAGER_QUEUE ") do
      {:ok, line, next} ->
        queue_length = line |> String.replace_prefix("MANAGER_QUEUE ", "") |> String.to_integer()

        cond do
          queue_length >= target ->
            {:ok, queue_length, next}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error, {:queue_timeout, queue_length}}

          true ->
            Process.sleep(20)
            await_manager_queue_until(next, target, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_line(daemon, prefix, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    read_line_until(daemon, prefix, deadline)
  end

  defp read_line_until(%{buffer: buffer} = daemon, prefix, deadline) do
    case take_line(buffer) do
      {:ok, line, rest} when is_binary(line) ->
        if String.starts_with?(line, prefix) do
          {:ok, line, %{daemon | buffer: rest}}
        else
          read_line_until(%{daemon | buffer: rest}, prefix, deadline)
        end

      :more ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {port, {:data, data}} when port == daemon.port ->
            read_line_until(%{daemon | buffer: buffer <> data}, prefix, deadline)

          {port, {:exit_status, status}} when port == daemon.port ->
            {:error, {:exit_status, status, buffer}}
        after
          remaining -> {:error, :timeout}
        end
    end
  end

  defp take_line(buffer) do
    case :binary.match(buffer, "\n") do
      {index, 1} ->
        line = binary_part(buffer, 0, index) |> String.trim_trailing("\r")
        rest = binary_part(buffer, index + 1, byte_size(buffer) - index - 1)
        {:ok, line, rest}

      :nomatch ->
        :more
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually_value(fun, attempts \\ 100)

  defp eventually_value(fun, 0) do
    case fun.() do
      {:ok, value} -> value
      _ -> flunk("timed out waiting for a value")
    end
  end

  defp eventually_value(fun, attempts) do
    case fun.() do
      {:ok, value} ->
        value

      _ ->
        Process.sleep(100)
        eventually_value(fun, attempts - 1)
    end
  end

  defp compress_public_key(<<_prefix, x::binary-size(32), y::binary-size(32)>>) do
    prefix = if rem(:binary.decode_unsigned(y), 2) == 0, do: 2, else: 3
    <<prefix, x::binary>>
  end

  defp wait_for_exit(port, timeout_ms) do
    receive do
      {^port, {:exit_status, status}} -> status
    after
      timeout_ms -> :timeout
    end
  end

  defp create_test_certificates do
    dir = Path.join(System.tmp_dir!(), "elixircd-native-s2s-tls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    ca_config = Path.join(dir, "ca.cnf")
    node_config = Path.join(dir, "node.cnf")
    ca_key = Path.join(dir, "ca.key")
    cacertfile = Path.join(dir, "ca.pem")
    node_key = Path.join(dir, "node.key")
    node_csr = Path.join(dir, "node.csr")
    certfile = Path.join(dir, "node.pem")
    ca_serial = Path.join(dir, "ca.srl")

    File.write!(ca_config, """
    [req]
    distinguished_name = req_dn
    x509_extensions = v3_ca
    prompt = no

    [req_dn]
    CN = ElixIRCd Native S2S Test CA

    [v3_ca]
    basicConstraints = critical,CA:TRUE
    keyUsage = critical,keyCertSign,cRLSign
    subjectKeyIdentifier = hash
    """)

    File.write!(node_config, """
    [req]
    distinguished_name = req_dn
    prompt = no

    [req_dn]
    CN = localhost

    [v3_node]
    basicConstraints = critical,CA:FALSE
    keyUsage = critical,digitalSignature,keyEncipherment
    extendedKeyUsage = serverAuth,clientAuth
    subjectAltName = DNS:localhost
    subjectKeyIdentifier = hash
    """)

    run_openssl!("req", [
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      ca_key,
      "-out",
      cacertfile,
      "-days",
      "365",
      "-sha256",
      "-config",
      ca_config
    ])

    run_openssl!("req", ["-newkey", "rsa:2048", "-nodes", "-keyout", node_key, "-out", node_csr, "-config", node_config])

    run_openssl!("x509", [
      "-req",
      "-in",
      node_csr,
      "-CA",
      cacertfile,
      "-CAkey",
      ca_key,
      "-CAserial",
      ca_serial,
      "-CAcreateserial",
      "-out",
      certfile,
      "-days",
      "365",
      "-sha256",
      "-extfile",
      node_config,
      "-extensions",
      "v3_node"
    ])

    %{
      dir: dir,
      certfile: certfile,
      keyfile: node_key,
      cacertfile: cacertfile,
      ca_key: ca_key,
      ca_serial: ca_serial,
      node_config: node_config
    }
  end

  defp create_test_node_certificate(tls, name, hostname \\ "localhost", days \\ 365) do
    node_key = Path.join(tls.dir, "#{name}.key")
    node_csr = Path.join(tls.dir, "#{name}.csr")
    certfile = Path.join(tls.dir, "#{name}.pem")
    node_config = Path.join(tls.dir, "#{name}.cnf")

    tls.node_config
    |> File.read!()
    |> String.replace("CN = localhost", "CN = #{hostname}")
    |> String.replace("subjectAltName = DNS:localhost", "subjectAltName = DNS:#{hostname}")
    |> then(&File.write!(node_config, &1))

    run_openssl!("req", [
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      node_key,
      "-out",
      node_csr,
      "-config",
      node_config
    ])

    run_openssl!("x509", [
      "-req",
      "-in",
      node_csr,
      "-CA",
      tls.cacertfile,
      "-CAkey",
      tls.ca_key,
      "-CAserial",
      tls.ca_serial,
      "-out",
      certfile,
      "-days",
      Integer.to_string(days),
      "-sha256",
      "-extfile",
      node_config,
      "-extensions",
      "v3_node"
    ])

    %{tls | certfile: certfile, keyfile: node_key, node_config: node_config}
  end

  defp encode_peer_certfps(peer_certfps) do
    Enum.map_join(peer_certfps, ",", fn {sid, certfps} ->
      encoded = if is_list(certfps), do: Enum.join(certfps, "|"), else: certfps
      sid <> "=" <> encoded
    end)
  end

  defp budget_argument([]), do: []

  defp budget_argument(budget_overrides) do
    encoded =
      budget_overrides
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, value} -> "#{key}=#{value}" end)

    ["--budget", encoded]
  end

  defp timeout_argument([]), do: []

  defp timeout_argument(timeout_overrides) do
    encoded =
      timeout_overrides
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, value} -> "#{key}=#{value}" end)

    ["--timeout", encoded]
  end

  defp run_openssl!(subcommand, args) do
    case System.cmd("openssl", [subcommand | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("openssl #{subcommand} failed with #{status}: #{output}")
    end
  end

  defp certificate_fingerprint(certfile) do
    {:ok, pem} = File.read(certfile)

    der =
      pem
      |> :public_key.pem_decode()
      |> Enum.find_value(fn
        {:Certificate, certificate, _} -> certificate
        _ -> nil
      end)

    TLS.fingerprint(der)
  end
end
