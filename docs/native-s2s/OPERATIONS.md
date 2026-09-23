# ENP/1 operations

This guide covers provisioning and operating the native S2S tree. It assumes
that all endpoints run the same ENP/1 implementation and that network policy
allows only the configured peer addresses and TLS ports.

## Provisioning

1. Create a private CA for the native S2S trust domain.
2. Issue one client/server certificate and private key per endpoint. Include
   the configured SNI name in the certificate SAN.
3. Record the CA file, certificate, key, SNI, and expected peer certificate
   pin for every endpoint. Keep private keys readable only by the service user.
4. Configure each endpoint's stable `sid`, `boot`, peer `sid`, parent/child
   relationship, address, port, SNI, and certificate pin.
5. Enable the listener only after the peer configuration describes an acyclic
   rooted tree. A child may dial its configured parent; a parent accepts only
   its configured children.
6. Start the listener and connector. Confirm TLS authentication, ENP/1 hello,
   snapshot transfer, snapshot acknowledgement, and topology readiness before
   routing traffic through the edge.

The listener and connector use separate SSL options and separate socket
lifecycles. Do not replace them with Erlang distribution or an Mnesia node
connection. ENP/1 does not trust an endpoint merely because it is reachable:
the certificate chain, peer identity, SNI, pin, configured edge, and hello
metadata must all agree.

## Runtime inspection and control

From an IRC operator session with the required local privileges:

- `LINKS` reports the native topology view and readiness state.
- `CONNECT <peer>` asks the local S2S manager to connect a configured edge.
- `SQUIT <peer> [reason]` asks the manager to close the configured edge.

The same operations are exposed through the local manager API for supervision
and tests. A successful TCP/TLS connection is only an active transport. The
edge becomes ready after both sides have applied the required synchronization
state and acknowledged it. A disconnected or unacknowledged edge must not be
used as a ready route.

The TLS receive path uses active-once reads and waits for the Manager's
generation-fenced acknowledgement before parsing the next protocol event. If
the event queue or receive-byte budget is exhausted, the affected link closes
instead of dropping state. Keep `max_connections_per_acceptor`, inbound queue
limits, and aggregate pending-state budgets aligned with the node's memory
capacity.

## Failure and partition procedure

On a failed edge, inspect the local manager state in this order:

1. TLS chain, SNI, certificate pin, and peer SID/boot.
2. Configured parent/child relationship and duplicate edge identity.
3. ENP/1 hello and frame-size/schema errors.
4. Sync digest, row validation, sequence gaps, and acknowledgement state.
5. Request correlation and the reason attached to the close/reconnect event.

The connector applies bounded reconnect backoff with jitter. A transient edge
failure must not create a second parent or bypass the configured tree. During a
partition, local state remains usable, remote-derived state expires or is
pruned according to the runtime rules, and stale memberships, users, channels,
lists, and policy rows must not be revived by an old boot or sequence.

## Security and recovery

Connection and SASL debug logs record byte counts or generic outcome categories;
they do not print IRC payloads, account names, or credentials. Do not enable
custom frame logging around authentication, service requests, or private
messages.

Rotate certificates by issuing the replacement certificate from the trusted CA,
deploying the new pin/peer material in a coordinated maintenance window, then
reconnecting the edge. Revoke or remove the old pin after all affected edges
have rotated. Treat a private-key disclosure as a trust-domain incident: revoke
the certificate and replace the corresponding peer pin.

If a node has lost its persistent native identity, stop it before restoring the
backup. Do not start it with a newly generated SID while old rows may still be
served. Restore the identity and boot material, validate the tree configuration,
and reconnect one edge at a time.

## Validation commands

```sh
MIX_ENV=test mix test test/elixircd/server/s2s --seed 0
mix format --check-formatted --no-compile
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test --seed 0
mix quality
```

The focused tests are useful for protocol and state changes. The full suite,
quality command, independent multi-process TLS test, and production canary are
separate evidence categories in the implementation ledger.
