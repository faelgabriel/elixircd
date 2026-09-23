# Native S2S (ENP/1)

This directory documents ElixirCD's native server-to-server protocol defined by
[`ELIXIRCD_NATIVE_S2S_SPEC_EN.md`](../../ELIXIRCD_NATIVE_S2S_SPEC_EN.md).

ENP/1 is an application protocol over independently configured mutual-TLS
sockets. It is not IRC server-to-server linking, Erlang distribution, or a
Mnesia cluster. The native manager owns the protocol lifecycle, configured tree,
identity checks, synchronization, policy projection, request admission, and
message delivery. The existing IRC connection and service layers remain the
owners of local domain behavior.

The feature is disabled unless the `s2s` listener and at least one configured
peer are enabled. A deployment must provision a CA, a certificate and key for
each endpoint, and the configured peer pin/SNI values before enabling it.

The implementation is split into small boundaries under `lib/elixircd/server/s2s/`:

- `Identity`, `JSON`, `Schema`, and `Protocol` implement canonical IDs, bounded
  JSON, closed frame shapes, and length-prefixed ENP/1 framing.
- `Runtime`, `Tree`, `Sync`, `Projection`, and `Policy` own state, topology,
  reconciliation, tombstones, and policy images.
- `Manager`, `Session`, `TLS`, `Listener`, and `Connector` own independent
  socket lifecycles and the configured parent/child tree.
- `Requests`, `SASL`, `Delivery`, `Output`, and `Publication` enforce the
  finite request/reply and publication boundaries.

The implementation ledger records the status of every requirement, test case,
and release gate. It intentionally distinguishes code that is present from
evidence that has actually been executed and from production approval.

## Verification

Run the focused suite with:

```sh
MIX_ENV=test mix test test/elixircd/server/s2s --seed 0
```

Run the repository checks with:

```sh
mix format --check-formatted --no-compile
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test --seed 0
mix quality
```

The complete operational procedure is in [`OPERATIONS.md`](OPERATIONS.md), and
the first-release schema and dataset policy is in
[`MIGRATION.md`](MIGRATION.md). ENP/1 has not shipped an older native identity
schema, so a new deployment starts with the current project schema instead of
importing a pre-release Mnesia database.
