defmodule ElixIRCd.Server.S2S.RequestsTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Requests
  alias ElixIRCd.Server.S2S.Schema

  defp node_ref(sid), do: %{"sid" => sid, "boot" => Identity.boot()}

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

  defp query_frame do
    {:ok, frame} =
      Requests.build(
        node_ref("leaf"),
        node_ref("root"),
        Identity.nonce(),
        %{"server" => "leaf"},
        "query",
        %{"command" => "VERSION", "params" => [], "target_uid" => nil, "view" => "client"},
        guards(),
        1_000,
        1
      )

    frame
  end

  test "admission deduplicates equal request IDs and rejects contradictory reuse" do
    frame = query_frame()
    state = Requests.new(max_pending: 4)

    assert {:ok, state, _pending} = Requests.admit(state, frame, 100)
    assert {:duplicate_pending, state} = Requests.admit(state, frame, 101)
    assert {:ok, state} = Requests.complete(state, frame["request_id"], %{accepted: true}, 102)
    assert {:duplicate, _state, %{accepted: true}} = Requests.admit(state, frame, 103)

    contradictory = put_in(frame, ["args", "command"], "TRACE")
    assert {:error, :request_id_conflict} = Requests.admit(state, contradictory, 104)
  end

  test "request TTL changes do not turn a completed duplicate into a conflict" do
    frame = query_frame()
    state = Requests.new()

    assert {:ok, state, _pending} = Requests.admit(state, frame, 100)
    assert {:ok, state} = Requests.complete(state, frame["request_id"], %{accepted: true}, 102)

    forwarded = Map.put(frame, "ttl_ms", 900)
    assert {:duplicate, _state, %{accepted: true}} = Requests.admit(state, forwarded, 103)
  end

  test "bounds pending requests independently by origin and by node" do
    first = query_frame()
    second = Map.put(first, "request_id", Identity.nonce())
    third = Map.put(first, "request_id", Identity.nonce())
    other_origin = %{first | "origin" => node_ref("branch"), "request_id" => Identity.nonce()}

    state = Requests.new(max_pending: 3, max_pending_origin: 2)
    assert {:ok, state, _} = Requests.admit(state, first, 100)
    assert {:ok, state, _} = Requests.admit(state, second, 101)
    assert {:error, :request_origin_capacity} = Requests.admit(state, third, 102)
    assert {:ok, state, _} = Requests.admit(state, other_origin, 103)

    fourth = %{other_origin | "request_id" => Identity.nonce()}
    assert {:error, :request_capacity} = Requests.admit(state, fourth, 104)
  end

  test "replies preserve authenticated origin/target correlation" do
    frame = query_frame()
    state = Requests.new()
    {:ok, state, _pending} = Requests.admit(state, frame, 100)

    assert {:ok, ^state, reply} = Requests.reply(state, frame["request_id"], 0, true, "OK", Requests.ok_payload(), 2)
    assert reply["origin"] == frame["to"]
    assert reply["to"] == frame["origin"]
    assert reply["request_id"] == frame["request_id"]
  end

  test "accepts a reply whose origin is the remote executor" do
    frame = query_frame()
    state = Requests.new()
    {:ok, state, _pending} = Requests.admit(state, frame, 100)
    {:ok, reply} = Requests.build_reply_from_request(frame, "OK", Requests.ok_payload(), 0, true, 2)

    assert {:ok, completed, %{status: "OK", done: true}} = Requests.accept_reply(state, reply, 101)
    assert completed.pending == %{}
    assert map_size(completed.completed) == 1
  end

  test "releases the origin capacity after accepting a terminal remote reply" do
    first = query_frame()
    second = %{first | "request_id" => Identity.nonce()}
    state = Requests.new(max_pending: 2, max_pending_origin: 1)
    {:ok, state, _pending} = Requests.admit(state, first, 100)
    {:ok, reply} = Requests.build_reply_from_request(first, "OK", Requests.ok_payload(), 0, true, 2)

    assert {:ok, state, _result} = Requests.accept_reply(state, reply, 101)
    assert state.pending_by_origin == %{}
    assert {:ok, _state, _pending} = Requests.admit(state, second, 102)
  end

  test "rejects a method-incompatible reply received for an active request" do
    frame = query_frame()
    state = Requests.new()
    {:ok, state, _pending} = Requests.admit(state, frame, 100)
    {:ok, reply} = Requests.build_reply_from_request(frame, "OK", Requests.ok_payload(), 0, true, 2)

    invalid = put_in(reply, ["payload", "items"], [reply_item("200")])
    assert {:error, :invalid_query_reply_item} = Requests.accept_reply(state, invalid, 101)
  end

  test "authorization keeps service and admin authority local and explicit" do
    service = %{"method" => "service", "args" => %{"scope" => "global"}}
    assert :ok = Requests.authorize(service, %{local_sid: "root", services_authority: "root", policy_ready: true})

    assert {:error, "UNAVAILABLE"} =
             Requests.authorize(service, %{local_sid: "leaf", services_authority: "root", policy_ready: true})

    admin = %{"method" => "admin", "args" => %{"action" => "shutdown", "neighbor_sid" => nil}}

    context = %{
      remote_admin_enabled: true,
      remote_admin_actions: [:shutdown],
      remote_admin_origins: ["root"],
      remote_admin_roles: ["netadmin"],
      origin_sid: "root",
      operator_role: "netadmin",
      direct_neighbors: [],
      local_sid: "leaf"
    }

    assert :ok = Requests.authorize(admin, context)
    assert {:error, "REJECTED"} = Requests.authorize(put_in(admin["args"]["action"], "restart"), context)
    assert {:error, "REJECTED"} = Requests.authorize(admin, %{context | operator_role: "user"})
  end

  test "authorizes a channel-scoped service only at the ready authority" do
    service = %{"method" => "service", "args" => %{"scope" => "channel"}}

    assert :ok = Requests.authorize(service, %{local_sid: "root", services_authority: "root", policy_ready: true})

    assert {:error, "UNAVAILABLE"} =
             Requests.authorize(service, %{local_sid: "leaf", services_authority: "root", policy_ready: true})
  end

  test "admin schema requires a neighbor only for edge actions" do
    frame = %{
      "t" => "request",
      "n" => 1,
      "origin" => node_ref("root"),
      "to" => node_ref("leaf"),
      "request_id" => Identity.nonce(),
      "actor" => %{"server" => "root"},
      "method" => "admin",
      "args" => %{"action" => "shutdown", "neighbor_sid" => "leaf", "reason" => "maintenance"},
      "guards" => guards(),
      "ttl_ms" => 1_000
    }

    assert {:error, :invalid_admin_args} = Schema.validate_frame(frame)

    edge = put_in(frame["args"], %{"action" => "enable_edge", "neighbor_sid" => "leaf", "reason" => "maintenance"})
    assert :ok = Schema.validate_frame(edge)
  end

  test "expires pending requests at their local deadline" do
    frame = query_frame()
    state = Requests.new()
    {:ok, state, _} = Requests.admit(state, frame, 100)
    {expired, ids} = Requests.expire(state, 1_100)

    assert ids == [frame["request_id"]]
    assert expired.pending == %{}
  end

  test "SASL replies use the method payload and snapshot pages stay closed" do
    frame =
      build_request(
        "sasl",
        %{
          "uid" => Identity.uid(),
          "attempt_id" => Identity.nonce(),
          "step" => 0,
          "phase" => "start",
          "mechanism" => "PLAIN",
          "data" => nil,
          "client_info" => %{
            "secure_client" => true,
            "realhost" => "client.example.test",
            "address" => "192.0.2.1",
            "client_certfp" => nil
          }
        }
      )

    sasl = Requests.sasl_payload("continue", nil, nil, "CONTINUE")
    assert {:ok, reply} = Requests.build_reply_from_request(frame, "OK", sasl, 0, true, 1)
    assert reply["payload"]["sasl"] == "continue"

    snapshot = build_request("snapshot", %{"scope" => "channel", "channel" => "#elixir", "for_uid" => nil})
    page = %{"phase" => "begin", "scope" => "channel", "channel" => "#elixir"}
    assert {:ok, _reply} = Requests.build_reply_from_request(snapshot, "OK", page, 0, false, 1)

    assert {:error, :invalid_reply} =
             Requests.build_reply_from_request(snapshot, "OK", Requests.ok_payload(page), 0, false, 1)
  end

  test "SASL transport failures use the standard error payload" do
    frame = build_request("sasl", sasl_args())
    failure = Requests.failure_payload(frame, "BUSY", "authentication verification is busy")

    assert failure == %{
             "items" => [],
             "error" => %{"code" => "BUSY", "message" => "authentication verification is busy"}
           }

    assert {:ok, reply} = Requests.build_reply_from_request(frame, "BUSY", failure, 0, true, 1)
    assert :ok = Schema.validate_frame(reply)

    mechanism_failure = Requests.sasl_payload("failure", nil, nil, "REJECTED")
    assert {:ok, _reply} = Requests.build_reply_from_request(frame, "OK", mechanism_failure, 0, true, 1)
  end

  test "only successful replies may continue across multiple parts" do
    frame = query_frame()
    failure = Requests.failure_payload(frame, "BUSY", "try again later")

    assert {:error, :invalid_reply} =
             Requests.build_reply_from_request(frame, "BUSY", failure, 0, false, 1)

    assert {:ok, reply} = Requests.build_reply_from_request(frame, "BUSY", failure, 0, true, 1)
    assert :ok = Schema.validate_frame(reply)
  end

  test "terminal-only methods and snapshot boundaries use the done bit" do
    sasl = build_request("sasl", sasl_args())
    sasl_payload = Requests.sasl_payload("continue", nil, nil, "CONTINUE")

    assert {:error, :invalid_reply} =
             Requests.build_reply_from_request(sasl, "OK", sasl_payload, 0, false, 1)

    snapshot = build_request("snapshot", %{"scope" => "channel", "channel" => "#elixir", "for_uid" => nil})
    begin = %{"phase" => "begin", "scope" => "channel", "channel" => "#elixir"}
    ending = %{"phase" => "end", "scope" => "channel", "rows" => 0, "exists" => false}

    assert {:ok, _reply} = Requests.build_reply_from_request(snapshot, "OK", begin, 0, false, 1)

    assert {:error, :invalid_reply} =
             Requests.build_reply_from_request(snapshot, "OK", begin, 0, true, 1)

    assert {:error, :invalid_reply} =
             Requests.build_reply_from_request(snapshot, "OK", ending, 0, false, 1)

    assert {:ok, _reply} = Requests.build_reply_from_request(snapshot, "OK", ending, 0, true, 1)
  end

  test "method result payloads stay within their finite shapes" do
    query = query_frame()

    assert {:error, :invalid_reply} =
             Requests.build_reply_from_request(query, "OK", Requests.ok_payload(%{"accepted" => true}), 0, true, 1)

    action =
      build_request("user_action", %{
        "action" => "kill",
        "target_uid" => Identity.uid(),
        "value" => nil,
        "reason" => "test"
      })

    assert {:ok, _reply} =
             Requests.build_reply_from_request(action, "OK", Requests.ok_payload(%{"accepted" => true}), 0, true, 1)

    assert {:error, :invalid_reply} =
             Requests.build_reply_from_request(action, "OK", Requests.ok_payload(%{"accepted" => false}), 0, true, 1)
  end

  test "reply items follow the method-specific command and source allowlist" do
    valid = %{
      "items" => [
        %{
          "command" => "351",
          "params" => ["Rafael"],
          "trailing" => nil,
          "source" => %{"server" => "root"},
          "tags" => %{}
        }
      ],
      "result" => nil
    }

    assert {:ok, _reply} = Requests.build_reply_from_request(query_frame(), "OK", valid, 0, true, 1)

    rejected = put_in(valid, ["items", Access.at(0), "command"], "KILL")

    assert {:error, :invalid_reply} =
             Requests.build_reply_from_request(query_frame(), "OK", rejected, 0, true, 1)

    incompatible_numeric = put_in(valid, ["items", Access.at(0), "command"], "200")

    assert {:error, :invalid_reply} =
             Requests.build_reply_from_request(query_frame(), "OK", incompatible_numeric, 0, true, 1)

    action =
      build_request("user_action", %{
        "action" => "kill",
        "target_uid" => Identity.uid(),
        "value" => nil,
        "reason" => "test"
      })

    assert {:error, :invalid_reply} =
             Requests.build_reply_from_request(action, "OK", %{valid | "items" => [hd(valid["items"])]}, 0, true, 1)
  end

  defp build_request(method, args) do
    {:ok, frame} =
      Requests.build(
        node_ref("leaf"),
        node_ref("root"),
        Identity.nonce(),
        %{"server" => "leaf"},
        method,
        args,
        guards(),
        1_000,
        1
      )

    frame
  end

  defp sasl_args do
    %{
      "uid" => Identity.uid(),
      "attempt_id" => Identity.nonce(),
      "step" => 0,
      "phase" => "start",
      "mechanism" => "PLAIN",
      "data" => nil,
      "client_info" => %{
        "secure_client" => true,
        "realhost" => "client.example.test",
        "address" => "192.0.2.1",
        "client_certfp" => nil
      }
    }
  end

  defp reply_item(command) do
    %{
      "command" => command,
      "params" => [],
      "trailing" => nil,
      "source" => %{"server" => "root"},
      "tags" => %{}
    }
  end
end
