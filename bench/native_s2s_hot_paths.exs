# Run with: mix run --no-start bench/native_s2s_hot_paths.exs
#
# This is a repeatable native ENP/1 hot-path measurement. It intentionally
# excludes TLS, sockets, Mnesia and OS-process scheduling; the result is a
# build baseline for comparing protocol/state work before a network load test.

alias ElixIRCd.Server.S2S.Identity
alias ElixIRCd.Server.S2S.JSON
alias ElixIRCd.Server.S2S.Protocol
alias ElixIRCd.Server.S2S.Requests
alias ElixIRCd.Server.S2S.Schema
alias ElixIRCd.Server.S2S.State
alias ElixIRCd.Server.S2S.Sync

defmodule ElixIRCd.NativeS2SBenchmark do
  @sample_count 9

  def run(name, fun, iterations) do
    warmup(fun, min(iterations, 100))

    samples =
      for _sample <- 1..@sample_count do
        :erlang.garbage_collect()
        {:reductions, before} = Process.info(self(), :reductions)
        {elapsed_us, result} = :timer.tc(fn -> repeat(fun, iterations, nil) end)
        {:reductions, after_reductions} = Process.info(self(), :reductions)
        :erlang.phash2(result)

        %{
          us_per_operation: elapsed_us / iterations,
          reductions_per_operation: (after_reductions - before) / iterations
        }
      end

    %{
      scenario: name,
      iterations: iterations,
      samples: @sample_count,
      median_us_per_operation: percentile(samples, :us_per_operation, 0.50),
      p95_us_per_operation: percentile(samples, :us_per_operation, 0.95),
      median_reductions_per_operation: percentile(samples, :reductions_per_operation, 0.50),
      p95_reductions_per_operation: percentile(samples, :reductions_per_operation, 0.95)
    }
  end

  defp warmup(fun, iterations), do: repeat(fun, iterations, nil)

  defp repeat(_fun, 0, last), do: last

  defp repeat(fun, remaining, _last), do: repeat(fun, remaining - 1, fun.())

  defp percentile(samples, field, percentile) do
    values = samples |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sort()
    index = min(length(values) - 1, trunc(Float.ceil(percentile * length(values))) - 1)
    Enum.at(values, max(index, 0))
  end
end

boot = Identity.boot()
uid = Identity.uid()
origin = %{"sid" => "root", "boot" => boot}
target = %{"user" => uid}

query_request =
  Requests.build(
    origin,
    %{"sid" => "leaf", "boot" => Identity.boot()},
    Identity.nonce(),
    target,
    "query",
    %{"command" => "WHOIS", "params" => ["Bench"], "target_uid" => uid, "view" => "client"},
    %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => nil,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => nil,
      "policy_revision" => nil
    },
    5_000,
    1
  )
  |> then(fn {:ok, request} -> request end)

encoded_request = Protocol.encode!(query_request)
<<_size::unsigned-big-32, request_body::binary>> = encoded_request

message_frame = %{
  "t" => "message",
  "n" => 1,
  "origin" => origin,
  "actor" => target,
  "message_id" => Identity.nonce(),
  "sent_ms" => Identity.now_ms(),
  "target" => target,
  "command" => "PRIVMSG",
  "text" => "native benchmark payload",
  "tags" => %{},
  "request_id" => nil
}

channels =
  for index <- 1..64 do
    %{
      "kind" => "channel.ensure",
      "channel" => %{
        "name" => "#bench-#{index}",
        "born_ms" => index,
        "cid" => Identity.cid()
      }
    }
  end

{:ok, snapshot} = Sync.capture(Identity.nonce(), 42, %{channels: channels}, page_size: 64)
old_memberships = for index <- 1..20, do: %{"channel" => "#old-#{index}", "join_id" => index, "joined_ms" => index}
new_memberships = for index <- 1..20, do: %{"channel" => "#new-#{index}", "join_id" => index + 1, "joined_ms" => index + 1}

state_frame = %{
  "t" => "state",
  "n" => 1,
  "origin" => origin,
  "actor" => %{"server" => "root"},
  "context" => %{"kind" => "live"},
  "changes" => Enum.take(channels, 8)
}

iterations = 1_000

results = [
  ElixIRCd.NativeS2SBenchmark.run("json_encode_request", fn -> JSON.encode(query_request) end, iterations),
  ElixIRCd.NativeS2SBenchmark.run("json_decode_request", fn -> JSON.decode_object(request_body) end, iterations),
  ElixIRCd.NativeS2SBenchmark.run("schema_validate_request", fn -> Schema.validate_frame(query_request) end, iterations),
  ElixIRCd.NativeS2SBenchmark.run("protocol_encode_request", fn -> Protocol.encode(query_request) end, iterations),
  ElixIRCd.NativeS2SBenchmark.run("protocol_decode_request", fn -> Protocol.decode_body(request_body) end, iterations),
  ElixIRCd.NativeS2SBenchmark.run("schema_validate_message", fn -> Schema.validate_frame(message_frame) end, iterations),
  ElixIRCd.NativeS2SBenchmark.run("schema_validate_state_batch", fn -> Schema.validate_frame(state_frame) end, iterations),
  ElixIRCd.NativeS2SBenchmark.run("sync_capture_64_channels", fn -> Sync.capture(Identity.nonce(), 42, %{channels: channels}, page_size: 64) end, 250),
  ElixIRCd.NativeS2SBenchmark.run("sync_frames_64_channels", fn -> Sync.frames(snapshot) end, 250),
  ElixIRCd.NativeS2SBenchmark.run("membership_replace_20_entries", fn -> State.replace_memberships(1, old_memberships, 2, new_memberships, case_mapping: :ascii) end, iterations)
]

metadata = %{
  date: Date.utc_today() |> Date.to_iso8601(),
  elixir: System.version(),
  otp: System.otp_release(),
  schedulers_online: System.schedulers_online(),
  total_memory_bytes: :erlang.memory(:total),
  description: "Pure native ENP/1 hot paths; no TLS, sockets, Mnesia or OS-process scheduling",
  results: results
}

IO.puts(Jason.encode!(metadata, pretty: true))
