defmodule ElixIRCd.Server.S2S.QueryEndpointTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.QueryEndpoint

  defp runtime(caller_uid, target_uid) do
    projection = fn uid, nick ->
      %{
        "uid" => uid,
        "home" => %{"sid" => "root", "boot" => Identity.boot()},
        "rev" => 1,
        "requested_nick" => nick,
        "effective_nick" => nick,
        "signon_ms" => 1_700_000_000_000,
        "ident" => String.downcase(nick),
        "realhost" => "client.example",
        "displayhost" => "client.example",
        "address" => "192.0.2.10",
        "secure_client" => true,
        "modes" => [],
        "realname" => nick <> " Example",
        "binding" => nil
      }
    end

    %{
      sid: "root",
      boot: Identity.boot(),
      case_mapping: :rfc1459,
      nodes: %{"root" => %{"sid" => "root", "name" => "root.example.test"}},
      users: %{caller_uid => projection.(caller_uid, "Alice"), target_uid => projection.(target_uid, "Bob")},
      policy: Policy.new(epoch: Identity.nonce(), revision: 1, ready?: true)
    }
  end

  test "returns a structured streamed VERSION query" do
    caller_uid = Identity.uid()

    frame = %{
      "actor" => %{"user" => caller_uid},
      "args" => %{"command" => "VERSION", "params" => [], "target_uid" => nil, "view" => "client"}
    }

    assert {:ok, {:stream, [%{"items" => [item], "result" => nil}]}} =
             QueryEndpoint.execute(frame, runtime(caller_uid, Identity.uid()), %{})

    assert item["command"] == "351"
    assert item["source"] == %{"server" => "root"}
  end

  test "uses UID projection for WHOIS instead of a local PID lookup" do
    caller_uid = Identity.uid()
    target_uid = Identity.uid()

    frame = %{
      "actor" => %{"user" => caller_uid},
      "args" => %{
        "command" => "WHOIS",
        "params" => ["Bob"],
        "target_uid" => target_uid,
        "view" => "client"
      }
    }

    assert {:ok, {:stream, parts}} = QueryEndpoint.execute(frame, runtime(caller_uid, target_uid), %{})
    commands = parts |> Enum.flat_map(& &1["items"]) |> Enum.map(& &1["command"])
    assert commands == ["311", "312", "318"]
  end

  test "returns bounded owner detail without exposing transport fields" do
    caller_uid = Identity.uid()
    target_uid = Identity.uid()

    frame = %{
      "actor" => %{"user" => caller_uid},
      "args" => %{
        "command" => "WHOIS",
        "params" => ["Bob"],
        "target_uid" => target_uid,
        "view" => "owner_detail"
      }
    }

    assert {:ok, %{"items" => [], "result" => result}} =
             QueryEndpoint.execute(frame, runtime(caller_uid, target_uid), %{})

    assert result["uid"] == target_uid
    assert result["secure_client"] == true
    refute Map.has_key?(result, "realhost")
  end

  test "resolves WHOIS targets with the runtime IRC case mapping" do
    caller_uid = Identity.uid()
    target_uid = Identity.uid()
    runtime = runtime(caller_uid, target_uid) |> Map.put(:case_mapping, :rfc1459)
    target = Map.put(runtime.users[target_uid], "effective_nick", "Foo{Bar")
    runtime = put_in(runtime.users[target_uid], target)

    frame = %{
      "actor" => %{"user" => caller_uid},
      "args" => %{
        "command" => "WHOIS",
        "params" => ["foo[bar"],
        "target_uid" => nil,
        "view" => "client"
      }
    }

    assert {:ok, {:stream, [%{"items" => [first | _]} | _]}} =
             QueryEndpoint.execute(frame, runtime, %{})

    assert first["command"] == "311"
    assert hd(first["params"]) == "Alice"
    assert Enum.at(first["params"], 1) == "Foo{Bar"
  end
end
