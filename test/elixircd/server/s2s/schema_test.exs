defmodule ElixIRCd.Server.S2S.SchemaTest do
  use ExUnit.Case, async: false

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Schema

  defp node_ref(sid), do: %{"sid" => sid, "boot" => Identity.boot()}

  defp hello(sid) do
    %{
      "t" => "hello",
      "protocol" => "elixircd-native",
      "version" => 1,
      "network_id" => "test-network",
      "profile_hash" => String.duplicate("a", 64),
      "sid" => sid,
      "boot" => Identity.boot(),
      "name" => sid,
      "nonce" => Identity.nonce(),
      "time_ms" => 1_700_000_000_000
    }
  end

  defp guards do
    %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => nil,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => nil,
      "policy_revision" => nil
    }
  end

  test "preserves valid UTF-8 and permits only canonical binary wrappers" do
    assert Schema.valid_bytes?("literal spaces and acentuação")
    refute Schema.valid_bytes?("line\nfeed")
    refute Schema.valid_bytes?("nul\0byte")

    encoded = %{"b64" => Base.encode64(<<255, 1, 2>>)}
    assert Schema.valid_bytes?(encoded)
    refute Schema.valid_bytes?(%{"b64" => "/wEC" <> "="})
    refute Schema.valid_bytes?(%{"b64" => Base.encode64(<<0, 1>>)}, max: 1)
  end

  test "keeps hello schema exact and rejects unsupported values" do
    frame = hello("root")
    assert :ok = Schema.validate_frame(frame)
    assert {:error, {:field_set, _, _}} = Schema.validate_frame(Map.put(frame, "unexpected", true))
    assert {:error, :invalid_hello} = Schema.validate_frame(%{frame | "version" => 2})
    assert {:error, :invalid_hello} = Schema.validate_frame(%{frame | "time_ms" => -1})
  end

  test "accepts channel-scoped ChanServ status requests and rejects mismatched scope" do
    request = %{
      "t" => "request",
      "n" => 1,
      "origin" => node_ref("leaf"),
      "to" => node_ref("root"),
      "request_id" => Identity.nonce(),
      "actor" => %{"user" => Identity.uid()},
      "method" => "service",
      "args" => %{
        "service" => "ChanServ",
        "arguments" => ["OP", "#native", "Target"],
        "scope" => "channel",
        "channel" => "#native"
      },
      "guards" => guards(),
      "ttl_ms" => 1_000
    }

    assert :ok = Schema.validate_frame(request)

    assert {:error, :invalid_service_args} =
             Schema.validate_frame(put_in(request, ["args", "channel"], "&local"))

    assert {:error, :invalid_service_args} =
             Schema.validate_frame(put_in(request, ["args", "scope"], "global"))
  end

  test "rejects policy cache rows in ordinary state and invalid zero memberships" do
    state = %{
      "t" => "state",
      "n" => 1,
      "origin" => node_ref("root"),
      "actor" => %{"server" => "root"},
      "context" => %{"kind" => "live"},
      "changes" => [%{"kind" => "policy.cache.rows", "rows" => []}]
    }

    assert {:error, :policy_cache_only_in_sync} = Schema.validate_frame(state)

    row = %{
      "kind" => "memberships.put",
      "uid" => Identity.uid(),
      "home" => node_ref("root"),
      "rev" => 0,
      "entries" => [
        %{"channel" => "#elixir", "join_id" => 1, "joined_ms" => 1}
      ],
      "cause" => %{
        "action" => "sync",
        "channel" => nil,
        "join_id" => nil,
        "by" => %{"server" => "root"},
        "reason" => "sync"
      }
    }

    assert {:error, :invalid_zero_membership_revision} = Schema.validate_row(row)

    assert {:error, :invalid_memberships_put} =
             Schema.validate_row(
               put_in(row, ["rev"], 1)
               |> put_in(["cause", "action"], "join")
               |> put_in(["cause", "channel"], nil)
             )
  end

  test "closes topology node and edge identity without accepting ambiguous graphs" do
    nodes = [
      %{"sid" => "hub", "boot" => Identity.boot(), "name" => "hub.example.test", "description" => ""},
      %{"sid" => "root", "boot" => Identity.boot(), "name" => "root.example.test", "description" => ""}
    ]

    edge = %{
      "id" => String.duplicate("a", 64),
      "a" => node_ref("hub"),
      "b" => node_ref("root"),
      "ready_sides" => ["hub"]
    }

    row = %{"kind" => "topology.add", "nodes" => nodes, "edges" => [edge]}
    assert :ok = Schema.validate_row(row)

    assert {:error, :invalid_topology_add} =
             Schema.validate_row(%{row | "edges" => [%{edge | "a" => edge["b"], "b" => edge["a"]}]})

    assert {:error, :invalid_topology_add} = Schema.validate_row(%{row | "nodes" => nodes ++ [hd(nodes)]})
  end

  test "enforces message text and actor target shapes" do
    base = %{
      "t" => "message",
      "n" => 1,
      "origin" => node_ref("root"),
      "actor" => %{"server" => "root"},
      "message_id" => Identity.nonce(),
      "sent_ms" => 1,
      "target" => %{"user" => Identity.uid()},
      "command" => "TAGMSG",
      "text" => nil,
      "tags" => %{},
      "request_id" => nil
    }

    assert :ok = Schema.validate_frame(base)
    assert {:error, :invalid_message} = Schema.validate_frame(%{base | "text" => "unexpected"})
    assert {:error, :invalid_actor} = Schema.validate_frame(%{base | "actor" => %{"user" => nil}})
    assert {:error, :invalid_target} = Schema.validate_frame(%{base | "target" => %{"channel" => "#elixir"}})
  end

  test "enforces SASL phase data and rejects local channel snapshots" do
    base = %{
      "t" => "request",
      "n" => 1,
      "origin" => node_ref("leaf"),
      "to" => node_ref("root"),
      "request_id" => Identity.nonce(),
      "actor" => %{"user" => Identity.uid()},
      "method" => "sasl",
      "args" => %{
        "uid" => Identity.uid(),
        "attempt_id" => Identity.nonce(),
        "step" => 0,
        "phase" => "start",
        "mechanism" => "PLAIN",
        "data" => nil,
        "client_info" => %{
          "secure_client" => true,
          "realhost" => "client.example",
          "address" => "192.0.2.1",
          "client_certfp" => nil
        }
      },
      "guards" => guards(),
      "ttl_ms" => 1_000
    }

    assert :ok = Schema.validate_frame(base)
    assert {:error, :invalid_sasl_args} = Schema.validate_frame(put_in(base, ["args", "data"], "YQ=="))
    assert {:error, :invalid_sasl_args} = Schema.validate_frame(put_in(base, ["args", "phase"], "step"))

    snapshot = %{
      "t" => "request",
      "n" => 1,
      "origin" => node_ref("leaf"),
      "to" => node_ref("root"),
      "request_id" => Identity.nonce(),
      "actor" => %{"user" => Identity.uid()},
      "method" => "snapshot",
      "args" => %{"scope" => "channel", "channel" => "&local", "for_uid" => nil},
      "guards" => guards(),
      "ttl_ms" => 1_000
    }

    assert {:error, :invalid_snapshot_args} = Schema.validate_frame(snapshot)
  end

  test "requires structured reply items to use safe commands and sources" do
    item = %{
      "command" => "351",
      "params" => ["nick"],
      "trailing" => "version",
      "source" => %{"server" => "root"},
      "tags" => %{}
    }

    assert :ok = Schema.validate_reply_payload("OK", %{"items" => [item], "result" => nil})

    assert {:error, :invalid_success_payload} =
             Schema.validate_reply_payload("OK", %{"items" => [Map.put(item, "command", "KILL")], "result" => nil})

    assert {:error, :invalid_success_payload} =
             Schema.validate_reply_payload("OK", %{
               "items" => [Map.put(item, "source", %{"server" => "ROOT"})],
               "result" => nil
             })

    assert :ok = Schema.validate_reply_payload("REJECTED", %{"items" => [Map.put(item, "command", "477")]})
  end

  test "wire-controlled values do not create atoms or modules" do
    assert {:module, Schema} = Code.ensure_loaded(Schema)
    before = :erlang.system_info(:atom_count)

    for index <- 1..200 do
      key = "unknown_key_" <> Integer.to_string(index)
      frame = %{"t" => "unknown_" <> Integer.to_string(index), key => "ElixIRCd.Server.Unknown"}
      assert {:error, _reason} = Schema.validate_frame(frame)
    end

    after_count = :erlang.system_info(:atom_count)
    assert after_count == before
  end

  test "foreign ETF and compressed payloads are rejected by the JSON boundary" do
    alias ElixIRCd.Server.S2S.JSON
    alias ElixIRCd.Server.S2S.Protocol

    etf = :erlang.term_to_binary(%{"t" => "ping"})
    compressed = :zlib.gzip(JSON.encode(%{"t" => "ping"}))

    assert {:error, _reason} = Protocol.decode_body(etf)
    assert {:error, _reason} = Protocol.decode_body(compressed)
    assert {:error, _reason} = Protocol.decode_body(":ping example")
  end
end
