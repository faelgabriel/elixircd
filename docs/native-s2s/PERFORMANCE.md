# Native S2S performance baseline

This report records a reproducible baseline for the pure ENP/1 hot paths. It
does not claim a production capacity limit: the benchmark excludes TLS,
sockets, Mnesia, supervision and OS-process scheduling.

Run it from the repository root with:

```sh
mix run --no-start bench/native_s2s_hot_paths.exs
```

The script runs nine samples per scenario, reports the median and sample p95
of the per-operation batch average, and records reductions per operation. The
`sync_*` scenarios use 64 channel rows and the membership scenario replaces 20
entries. JSON and protocol scenarios use a valid WHOIS request; state
validation uses eight channel changes.

The 2026-09-22 run used the working tree at base revision `4592002` on WSL2
Linux 6.18.33.2, x86_64, AMD Ryzen 5 5600GT, 10 online schedulers, Elixir
1.20.4 and OTP 29:

| Scenario | Median us/op | Sample p95 us/op | Median reductions/op |
| --- | ---: | ---: | ---: |
| JSON encode request | 4.109 | 4.450 | 881.633 |
| JSON decode request | 29.356 | 38.112 | 5742.781 |
| Request schema validation | 19.291 | 21.314 | 766.396 |
| Protocol encode request | 23.405 | 24.782 | 1641.244 |
| Protocol decode request | 84.347 | 90.706 | 11560.782 |
| Message schema validation | 14.578 | 17.305 | 570.435 |
| State batch schema validation | 35.730 | 42.102 | 1632.685 |
| Snapshot capture, 64 channels | 264.140 | 280.160 | 12291.068 |
| Snapshot frames, 64 channels | 372.428 | 388.996 | 25744.352 |
| Membership replacement, 20 entries | 27.676 | 28.808 | 1757.831 |

These numbers are a comparison baseline for later changes. They are not an
acceptance budget and cannot establish network throughput, queue latency,
memory growth, lock contention or behavior under concurrent churn. The release
gate still needs a network-enabled workload with independent daemons, TLS,
Mnesia, queue pressure and long-running split/reconnect activity.

## Network smoke baseline

The repository also contains a small end-to-end workload:

```sh
MIX_ENV=test mix run --no-start bench/native_s2s_network.exs 200
```

It starts two independent daemon OS processes with separate Mnesia directories,
connects them over mutual TLS, creates one client on each side, publishes 200
private messages across the link, waits for the final delivery, and samples
daemon memory, process count, run queue and scheduler count. A 2026-09-22 run
on the same WSL2/OTP environment reported:

| Messages | Send p50 | Send p95 | Send max | Final delivery wait | Root memory | Leaf memory |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 200 | 513 us | 1,533 us | 3,699 us | 102 ms | 83,608,960 B | 84,372,552 B |
| 2,000 | 526 us | 844 us | 8,570 us | 1,259 ms | 83,908,520 B | 86,239,392 B |

The 2,000-message run extends the smoke baseline into a short sustained burst;
it still uses one route and one client per daemon, with no repair storm,
stalled peer, reconnect churn or forced queue pressure. It does not set a
release capacity budget. Those measurements remain part of the release audit.
