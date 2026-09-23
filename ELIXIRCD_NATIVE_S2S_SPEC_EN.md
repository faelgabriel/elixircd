---
title: "ElixIRCd Native Protocol 1 — Complete S2S Implementation Specification"
document_version: "1.0"
language: "en"
research_date: "2026-09-20"
status: "Proposed native protocol; static source review; not runtime-certified"
protocol: "elixircd-native"
protocol_version: 1
elixircd_baseline: "b48ac1387383b246aa2ce0c0149e19741be74108"
transport: "Independent mutually authenticated TLS sockets; no Erlang/Mnesia cluster"
requirements: 129
acceptance_test_cases: 144
release_gates: 12
---

# ElixIRCd Native Protocol 1
## Complete server-to-server design and implementation contract

**Purpose:** implement a native S2S layer directly on the existing ElixIRCd architecture, reusing its domain logic while explicitly handling distribution, security, synchronization and failure. This is the replacement native direction requested after the prior protocol-adapter studies; it is not a renamed or cumulative TS6/InspIRCd specification.

**Read first:** sections 1–5 explain the fixed design and code reuse; sections 6–22 define the complete protocol and behaviors; sections 23–29 define safety, implementation, tests, gates and sources. The protocol's compact vocabulary is not a promise of a tiny implementation: correctness still requires every described state transition and boundary.

**Normative language:** MUST/MUST NOT and numbered requirements are acceptance obligations. SHOULD permits an equivalent documented implementation that preserves the contract. Proposed component names may change; on-wire semantics and guarantees may not change without a profile/protocol revision. The author has not executed or performance-certified an ElixIRCd ENP implementation.

## Contents

- [1. Decision, scope, and the meaning of simplicity](#native-section-01)
- [2. Verified checkout and reuse map](#native-section-02)
- [3. Small implementation structure and use of the BEAM](#native-section-03)
- [4. Ownership, identity, and the data migration](#native-section-04)
- [5. Transaction and output contract](#native-section-05)
- [6. Topology, trust, and session admission](#native-section-06)
- [7. Wire format, primitive types, and finite frame vocabulary](#native-section-07)
- [8. Version profile and operational configuration](#native-section-08)
- [9. Handshake and link state machine](#native-section-09)
- [10. Snapshots, causal output, and channel repair](#native-section-10)
- [11. Complete state-row catalog and routing](#native-section-11)
- [12. User projection, nickname conflicts, and full membership replacement](#native-section-12)
- [13. Channel incarnations, versioned fields, lists, and topics](#native-section-13)
- [14. Preserving current modes and local channel behavior](#native-section-14)
- [15. Messages, tags, echo, invitations, and logical services](#native-section-15)
- [16. Finite request/reply contract and remote authorization](#native-section-16)
- [17. Services authority, policy projections, and partition behavior](#native-section-17)
- [18. Every service operation and policy side effect](#native-section-18)
- [19. SASL, pre-registration, and authentication work](#native-section-19)
- [20. Existing C2S commands, queries, and operator control](#native-section-20)
- [21. Failure handling, cleanup, and lifecycle](#native-section-21)
- [22. Schema closure and processing rules](#native-section-22)
- [23. Security and resource obligations](#native-section-23)
- [24. Efficiency, measurements, and clean implementation boundaries](#native-section-24)
- [25. Implementation sequence, repository edits, and cleanup](#native-section-25)
- [26. Acceptance test catalog](#native-section-26)
- [27. Deterministic wire and model fixtures](#native-section-27)
- [28. Release gates and implementation-agent handoff](#native-section-28)
- [29. Source registry and evidence boundaries](#native-section-29)


<a id="native-section-01"></a>

## 1. Decision, scope, and the meaning of simplicity

**Implement ElixIRCd Native Protocol 1 (ENP/1), only between ElixIRCd instances.** This is a new design, not TS6, SpanningTree, an IRC client impersonating a server, or a compatibility adapter. Previous specifications are historical material, not additional requirements to combine with this one. The protocol identifier is `elixircd-native`, version `1`.

Keep the current IRC client interface and business rules. Add an explicit replication boundary around the existing domain operations. Use a standard bounded serialization format rather than another large command dialect. A smaller vocabulary reduces parser and adapter code; it does not remove the need for ownership, reconciliation, authorization, ordering, and failure recovery.

### Decisions fixed for this release

| Decision | Why it reduces implementation complexity | Explicit consequence |
|---|---|---|
| Independent daemons connected with mutually authenticated TLS sockets | Uses ordinary supported networking and keeps trust boundaries explicit | No distributed Erlang, shared cookie, node discovery, remote process addressing, or shared Mnesia cluster |
| A configured, acyclic tree; each non-root connects to one configured parent | No route election, duplicate-path convergence, flooding deduplication, or automatic reparenting | A failed hub partitions its branches until the configured path returns; reparenting is planned maintenance |
| Same versioned semantic profile on every node | No legacy protocol translation or dynamic cross-product module negotiation | Structural profile changes require a coordinated deployment |
| Bounded, length-prefixed JSON | Standard codec, typed fields, readable fixtures, no custom escaping language | More bytes than some compact IRC encodings; performance must be measured |
| A user's home server owns that user's session and complete membership set | Removes conflicting writers and membership-deletion histories | A remote kick/forced part is a request to the home server, with one round trip |
| Versioned individual channel fields | Concurrent changes to unrelated fields do not overwrite each other | A small version map and list-removal records remain necessary |
| One configured global services authority | Reuses integrated services without inventing distributed account consensus | Account/registration writes fail while that authority is unavailable; no automatic failover |
| Services remain logical application endpoints | Reuses the current `Service` dispatch model | Do not invent a separate services daemon, services server, or remote-user socket merely for linking |
| Reuse current tables and handlers wherever their assumptions remain valid | Avoids a parallel implementation of the IRC domain | PID identity, side-effect timing, and some repository APIs must change |

**N-REQ-001 — Scope closure.** Implement both link directions, arbitrary configured tree shapes, hubs and leaves, network and channel snapshots, live traffic, all currently implemented C2S/service behavior, remote queries/actions, service-policy replication, errors, migrations, cleanup, operational controls, and the acceptance tests in this document. A disabled feature must not be advertised or acknowledged as successful.

**N-REQ-002 — No borrowed wire contracts.** Do not implement TS6, SpanningTree, ENCAP, vendor SVS command families, or fallback dialects as hidden requirements. Familiar distributed-systems ideas are allowed; this document's schemas and rules define ENP/1.

**N-REQ-003 — Honest limits.** Do not describe this as globally linearizable, exactly-once chat delivery, Byzantine-safe federation, automatic account failover, or a guarantee of matching another daemon's throughput. Independent channel decisions remain available during splits; privileged account-dependent operations can become unavailable.

A configured tree is a deliberate supported topology, not unfinished mesh routing. All nodes can host clients. The root is a routing position, **not a global IRC state writer**. The services authority may be any configured node and is a separate role.

<a id="native-section-02"></a>

## 2. Verified checkout and reuse map

The connected GitHub API returned commit `b48ac1387383b246aa2ce0c0149e19741be74108` for the repository's latest default-branch commit during this review. This is newer than the earlier `417d934...` architecture review. It includes the finite-atom `ModeRegistry`, consolidated mode argument classes, a dedicated validated configuration loader, and expanded account/channel services including memos. [SRC01–SRC08]

This review examined the architecture and integration paths cited below; it did not execute ElixIRCd, certify every existing feature, or inspect unpublished work in an agent's checkout. README checkmarks are not substitutes for source or tests.

| Existing integration point | Reuse | Required change |
|---|---|---|
| `lib/elixircd.ex` | Boot sequence and supervisor | Start native-network state/output infrastructure before public work; preserve no-S2S startup |
| `command.ex` | Finite dispatch, `names/0`, C2S handler convention | Keep C2S trust checks; expose shared domain operations instead of a second set of client handlers |
| `message.ex`, `standard_reply.ex` | C2S parsing, structured messages, output budgets | Do not route ENP bytes through the C2S parser; reuse messages for final rendering only |
| `mode_registry.ex` | Existing finite atoms and conversions | Add or associate revision/merge descriptors; no duplicate mode registry |
| `commands/mode/channel_modes.ex` | Current mode classes and validation | Separate request authorization from committed field application |
| `tables/user.ex`, `repositories/users.ex` | One user model and repository | UID identity, home server/boot, revisions, explicit locality, nullable connection fields |
| `tables/user_channel.ex`, `repositories/user_channels.ex` | Membership relation and channel index | UID composite key, join generation, replace-set diff and status registers |
| Channel, topic, ban, exception, invex and invite tables | Domain storage and validators | Channel incarnation and field versions; list removals; expiry/session guards |
| `server/connection.ex` | C2S lifecycle/admission and limits | Extract post-commit effects; remote state never enters `handle_connect` |
| `server/dispatcher.ex` | Prefixes, capabilities, standard replies, batches, echoes | Local rendering behind a safe output boundary; UID destinations and trusted-origin handling |
| `server/response_context.ex` | Synchronous response grouping | Explicit asynchronous continuations; no process-dictionary state across tasks |
| `server/listeners.ex`, `server/tcp_listener.ex` | ThousandIsland/TLS infrastructure | Dedicated ENP listener/handler; separate framed limits and outbound connector |
| HTTP/WebSocket listeners | Existing client support | Keep client-only; no ENP over WebSocket in version 1 |
| `service.ex`, `services/nickserv/**`, `services/chanserv/**` | Existing service grammar/business rules | Route to authority or local-channel delegate; reuse business logic with explicit caller context |
| `utils/nickserv.ex`, `utils/chanserv/**` | Alias, privacy, ACL, MLOCK and settings rules | Policy view at non-authority nodes; no fake password-bearing registration records |
| `config/loader.ex`, `config/schema.ex`, `config/validator.ex`, `config/resources.ex` | Current validation/resource pipeline | Add native-network fields to this pipeline, not a second loader |
| `utils/mnesia.ex` | Local table setup and RAM/disk classification | Current-schema validation; preserve all six existing disk table classes on a new install |
| `job_queue.ex`, `jobs/**` | Persistent retryable maintenance/email | Global jobs only at authority; local jobs remain local; not a network writer |
| Existing message/data fixtures and quality checks | Regression harness | UID-aware identity, real sockets, cross-process assertions and failure injection |

The current `UserChannel` is a `bag` keyed by `user_pid`; the current user record is keyed by `pid`. The source still runs command processing inside `Memento.transaction!` and sends through the dispatcher. These are concrete migration points, not reasons to replace the stack. [SRC04, SRC09–SRC13]

**N-REQ-004 — Checkout-first implementation.** Inspect the actual branch, uncommitted changes, command inventory, table attributes and configuration schema before editing. Update path mappings when needed. Do not overwrite unrelated work or delete agent-created modules solely because this document proposes a different name.

**N-REQ-005 — Reuse boundary.** Keep the canonical `User`, `Channel` and membership tables. Do not create mirrored `NetworkUser`, `NetworkChannel`, duplicate mode engines, fake local PIDs for remote users, or another NickServ/ChanServ implementation. Extract small domain functions only where existing handlers combine incompatible responsibilities.

**N-REQ-006 — Preserve current fixes.** Retain finite-atom mode decoding, C2S length limits, current `+k` argument rules, account alias semantics, ECDSA SASL, memos, secure configuration loading and current regression tests. Do not restore assumptions from an older specification.

<a id="native-section-03"></a>

## 3. Small implementation structure and use of the BEAM

Treat the following as responsibility boundaries, not a requirement for one file, process, behaviour and factory per row.

| Responsibility | Suggested location | Process requirement |
|---|---|---|
| Peer lifecycle, configured parent, readiness and requests | `Server.S2S` context / manager | One manager per daemon is sufficient |
| TLS transport, frame buffers, connection generation and FIFO | `Server.S2S.Session` | One process per physical link; its socket owner can also be the writer |
| Frame encoding, validation and finite message dispatch | `Server.S2S.Protocol` | Pure functions; no process |
| Domain projections, merge rules and local effects | Existing repositories/helpers plus `Server.S2S.State` | No per-object process |
| Snapshot capture and bounded traversal | `Server.S2S.Sync` or functions alongside state | A bounded worker per outgoing snapshot if needed |
| Request routing and replies | Functions in manager or `Server.S2S.Requests` | No process for every request |
| Transaction/effect collection and ordered draining | Existing dispatcher plus a small transaction/output helper | One output drain per daemon initially |
| Durable account operations and hashing | Existing services plus bounded task supervision | Reuse the job queue only for genuinely durable maintenance work |

Use pattern matching, immutable projected values, process monitors, supervision and iodata. These are implementation advantages, not protocol guarantees. Erlang's ordering guarantee is between the same sender and receiver; it is not a total order across all connection processes. Mnesia transaction retries can repeat external effects. [OTP01, OTP02]

**N-REQ-007 — Minimal abstraction policy.** Prefer an explicit finite dispatch map and small functions. Do not add a generic event-sourcing framework, plugin loader, universal RPC engine, schema registry service, actor per channel, process per remote user or protocol adapter hierarchy. Split a module only for a clear, independently testable responsibility.

**N-REQ-008 — Existing handler convention.** Retain `handle(user, message)` at the C2S boundary where useful. Internally distinguish `local_request`, `remote_state`, `service_action`, `synchronization` and `maintenance` contexts. A `%User{pid: nil}` is a real remote user, not a permission bypass.

**N-REQ-009 — No cluster.** No `Node.connect`, shared Erlang cookie, cross-node `:rpc`, distributed registry, shared remote Mnesia tables, or use of serialized PIDs/references on ENP. The current loader's node-local lock must not become a federation mechanism. Each daemon has its own durable data directory and local database.

**N-REQ-010 — Bounded concurrency.** Parse and perform expensive preparation concurrently, but apply dependent state and publish output in a defined local order. Do not block that order on TLS writes, DNS, password hashing, emails or remote responses.

<a id="native-section-04"></a>

## 4. Ownership, identity, and the data migration

### First-release schema boundary

ENP/1 has not been released with an older native identity schema. The first
release therefore requires a new Mnesia directory initialized by the current
application and schema. This implementation does not import, translate, or
roll back a pre-release native UID/PID database. Those operations become a
separate versioned migration contract only after a released native schema
exists. Startup still validates the current table attributes, table types and
schema identity and aborts on an incompatible directory; “start clean” never
means silently deleting an existing directory to make startup succeed.

### Identity vocabulary

| Name | Exact representation | Lifetime |
|---|---|---|
| `sid` | 1–16 lowercase ASCII letters/digits/hyphens; starts with a letter | Configured server identity; unique in the roster |
| `boot` | 26 uppercase unpadded RFC 4648 Base32 characters encoding 16 random bytes | New at every daemon start or loss of authoritative transient network state |
| `uid` | Same canonical 128-bit Base32 format, generated independently | One client session; never reused |
| `join_id` | Integer 1 through 2^53−1, allocated monotonically per UID | One particular participation in one channel |
| `cid` | Same canonical random Base32 format | One channel creation, not a service registration |
| `born_ms` | Integer Unix milliseconds, 1 through 2^53−1 | Channel creation time |
| `request_id`, `sync_id`, `nonce` | Canonical 128-bit Base32 strings | One bounded operation or connection exchange |
| Field stamp | `[logical_counter, sid, boot]` | One versioned shared-field mutation |

Canonical Base32 requires successful decode to exactly 16 bytes and equality after re-encoding without padding. Checking only length/characters is insufficient because unused trailing bits must also be canonical. Duplicate live IDs are fatal identity errors, not nickname collisions.

A home server owns **user attributes, authentication binding updates after verified service results, and that user's complete global membership set**. Another node requests a kick, forced part, kill or forced nick from that home server. Channel modes, list entries, topic and membership status are multi-writer fields whose committed values carry stamps. Services policy is single-writer at the configured authority.

| Existing model | Required representation |
|---|---|
| `User` | UID key; home SID/boot; owner revision; requested and effective nick; membership revision/counter; existing public identity; effective account view; explicit local PID/connection generation or nil |
| `UserChannel` | `set` keyed by `{uid, normalized_channel}`; UID/channel indexes; join ID and origin join time; current channel association; status registers and materialized existing modes |
| `Channel` | Existing name/key; `cid`, `born_ms`; mode registers; compound topic register; existing materialized modes/topic; pending-repair state |
| Ban/exception/invex | Existing canonical mask identity and setter/time, plus present/deleted state and stamp tied to channel incarnation |
| Invite | Target UID, channel incarnation, absolute expiry, token and originating actor; owner-local grant |
| Server reachability | Configured SID plus actual boot and active edge nonces; reachability and next hop derived from the active tree |
| Network control | Local boot, Lamport counter, commit-output sequence, profile revision and readiness fences |
| Pending output | Bounded committed output groups, sequence, targets and link/session generations; transient |
| Service policy cache | Explicit non-secret account/nick/channel projections under authority epoch/revision; not duplicate private registration tables |

Connection-local fields may remain nullable on `User` to minimize migration; a separate local-connection table is not required. Remote rows must have no PID, socket, connection password, SASL buffer, CAP state, local rate-limit counters or local transport object. Keep home-attested client security separately from local socket transport.

**N-REQ-011 — UID migration.** Change key/index/delete operations consistently. Preserve `get_by_pid/1` and `get_by_pids/1` as local-only wrappers; add UID-oriented lookups for network semantics. Reject nil/non-PID arguments to PID APIs. Never let `nil == nil` make two remote users count as the same person.

**N-REQ-012 — Audit identity comparisons.** Replace PID equality in permission checks, self-message checks, account notifications, NICK, WHO/WHOIS privacy, monitors, invites, ACCEPT and cleanup with UID equality where session identity is meant. Calls to `send`, `Process.exit`, or socket APIs must require a proven local connection.

**N-REQ-013 — Counter separation.** Keep local connections, local registered clients, reachable network clients, operators and services endpoints distinct. `RateLimiter` IP counts must not include remote users. Never count a pre-registration SASL session as a globally present user.

**N-REQ-014 — Preserve origin data.** Store real/display host, effective ident, address and client-security attestation intentionally. Never recalculate a remote cloak with a local secret. Real IP/host data are visible to trusted peers but remain protected by the existing C2S privacy rules.

**N-REQ-015 — Safe first-release bootstrap.** For this unreleased feature, initialize a fresh directory with the current PID/UID-aware schema and validate its attributes and table types before opening listeners. Do not add an import or rollback path for a pre-release native identity database. Never run `recreate: true` against an existing production directory; an incompatible directory must fail with an operator-readable error.

<a id="native-section-05"></a>

## 5. Transaction and output contract

The reusable implementation is a short node-local commit boundary, not a globally replicated log.

Before a network-visible mutation reads mutable network state, acquire the local network-control row with a write lock. Compute and validate the transition in the same Mnesia transaction, allocate its local output sequence and required logical stamps, and write a bounded output group atomically with the state. Existing repositories remain the storage interface. The transaction body contains no irreversible effects.

An ordered drain reads committed groups and hands immutable C2S effects to local connections and ENP effects to the appropriate link queues. The global order is local to this daemon. It is not consensus between daemons, and there is no replay of old chat after a reconnect.

**N-REQ-016 — Transaction-safe effects.** Make dispatcher output, response-context flushes, disconnect requests, monitor notifications, service replies and job/email scheduling collect intents during a transaction. Reinitialize an attempt-local collector on every retry. Commit only the successful attempt's intents. Rollback must produce zero external messages and zero successful audits.

**N-REQ-017 — No unbounded critical section.** Perform Argon2/ECDSA work, DNS, certificate I/O, JSON encoding, large result rendering and external service work outside the network-control lock. Revalidate actor, connection, account/policy revision and target generations before applying the result. Acquire the ordering lock before network-state reads, not after a decision based on stale data.

**N-REQ-018 — Exactly one publication path.** Emit one domain state transition at commit. Do not derive replication from serialized C2S messages, table subscriptions, or one callback per recipient. Extended JOIN plus ordinary JOIN renderings are one join, not two state changes.

**N-REQ-019 — Per-destination FIFO.** One component assigns the order delivered to each link and local client. A channel message cannot overtake its sender/membership introduction. A quit cannot overtake the last accepted message from that session. CAP acknowledgements and their subsequent capability revision must respect the same local output barrier.

**N-REQ-020 — Immutable rendering context.** Preserve public source identity, message ID/time, recipient UID, local connection generation and relevant negotiated-capability revision in output intents. Validate the destination still names that connection before writing; do not look up a new nickname occupant. Do not re-sanitize received network tags as client input.

**N-REQ-021 — Crash boundary.** If the drain/session dies after a possible socket write, never guess whether to retransmit that output group. Tear down affected ENP link generations and rebuild by snapshot. If state/output ordering itself is lost, close all dependent links and invalidate the network boot. A successful local socket send is not end-to-end delivery.

**N-REQ-022 — Single-server regression.** With `s2s.enabled = false`, retain existing C2S behavior and avoid serializing ENP frames or traversing remote routes. The safe effect boundary may remain shared; no two conflicting implementations of local behavior may coexist.

This baseline serializes short network-visible commits. It intentionally trades some write parallelism for a small, testable ordering mechanism. Measure lock contention before sharding. A future optimization must preserve the contract, not bypass it with dirty writes. [OTP01]

<a id="native-section-06"></a>

## 6. Topology, trust, and session admission

### Configured tree

Every node receives the same public roster: server IDs, display names and one parent ID per non-root. The graph must contain exactly one root, no cycles, no duplicate IDs/names, and no more than 256 nodes in ENP/1. A forest is not a single network profile. Missing/running-offline nodes simply leave edges inactive.

Only a child initiates the connection to its configured parent. A parent accepts only configured children. `CONNECT` retries that declared edge; it never invents a different graph. Only one active session exists for an edge. A second accepted socket is rejected without deleting the first session. Automatic reconnect starts only after the old generation is fenced and cleaned up.

Version 1 intentionally does not negotiate a new parent or elect a substitute hub. Operators may choose any tree initially. Changing the roster/tree is a maintenance profile revision. This is a routing simplification, not an Erlang cluster and not a global leader.

### TLS authentication

Use a dedicated TCP/TLS endpoint, separate from C2S listeners. Require mutual TLS: a trusted CA, a usable non-expired peer certificate, and a locally configured allowlist of SHA-256 DER certificate fingerprints for each neighbor. Outbound SNI/hostname validation uses the configured peer hostname. Incoming certificate identity maps to an allowed child before accepting its claimed ID. Do not use a shared network password, an extra custom cryptographic handshake, or an IP allowlist as authentication.

**N-REQ-023 — Cryptographic peer binding.** Require peer certificate validation and the configured fingerprint mapping before processing a normal hello. Match hello SID/name to that certificate's configured peer. Use `peername`, not `sockname`, for the remote socket address. The reviewed listener calls `sockname`; the documented API identifies it as the local endpoint. Correct shared socket metadata where needed and test it. [SRC14, OTP03]

**N-REQ-024 — TLS lifecycle.** Handle TLS failure before session state exists; callbacks must not dereference absent fields. Rejected authentication publishes no server/user presence. No plaintext production fallback. Certificate rotation uses an explicit overlap of accepted pins; failed validation never disables verification.

**N-REQ-025 — Trust model.** Validate routing direction and configured subtree for every source. Peers are trusted network operators, not mutually hostile tenants. A compromised trusted hub can falsify parts of the subtree it carries; ENP/1 does not add end-to-end signatures or Byzantine consensus. Scope services/administration more narrowly than ordinary presence.

**N-REQ-026 — Independent resource limits.** S2S links do not consume client admission quotas or create `User` rows. Use separate connection/authentication/snapshot budgets and authenticate before allocating substantial state.

A fresh link nonce is derived from both hellos: SHA-256 of compact JSON encoding of `[[sid,boot,nonce],[sid,boot,nonce]]`, entries ordered by SID; output is lowercase hexadecimal. This is a connection identity, not authentication. TLS provides authentication.

<a id="native-section-07"></a>

## 7. Wire format, primitive types, and finite frame vocabulary

### Framing

Each record is `uint32-big-endian byte_length || UTF-8 JSON object`. There is no newline terminator, IRC prefix syntax, compression, Erlang External Term Format or socket-per-message. Decode the length before allocation. The JSON body has exactly one top-level object and no non-whitespace trailing data.

Use Elixir's built-in JSON encoder/OTP JSON decoder instead of adding a new codec dependency. OTP exposes object/array callbacks: use them to reject duplicate keys, bound depth/element counts and keep keys as binaries. No atom conversion from input, `binary_to_term`, dynamic struct construction or eval. [OTP04, OTP05]

The absolute body ceiling is 1,048,576 bytes. Additional type budgets are: hello 4,096; message 8,192; request/reply 65,536; ordinary state/sync page 65,536; topology page up to the absolute ceiling. These are protocol ceilings, not promises to accept unlimited totals. Maximum depth is 16; maximum 8,192 aggregate JSON values per ordinary frame and 65,536 for a topology frame; maximum 256 rows per ordinary page. Configuration may reduce aggregate queues, not reinterpret a valid field by silently truncating it.

### Primitives

`UInt` means an integer from 0 through 2^53−1; a `Positive` excludes zero. Fractions, exponent-form numbers used as counters, negative values, NaN and infinity are invalid. Counter encoders emit ordinary decimal integer tokens. Clock times use explicitly named `_ms` fields. Deadlines use local monotonic time.

`NodeRef` is `{"sid": SID, "boot": Boot}`. `Actor` is exactly one of `{"user": UID}`, `{"service": "NickServ"}`, `{"service": "ChanServ"}`, or `{"server": SID}`. User actors are resolved by UID; service/server actors require the authority of the particular operation. A display nickname is never an actor credential.

`Bytes` is normally a JSON string. If the original IRC bytes are not valid UTF-8 and the configured C2S policy permits them, use exactly `{"b64":"<standard padded Base64>"}`. Decode strictly, enforce decoded byte limits, and require re-encoding equality. Use this only for explicitly byte-capable fields: free text, reasons, tags' values, channel names where current validators permit byte names, and service arguments. Protocol keys, IDs, mode letters and host/IP syntax remain ordinary validated strings. Do not normalize, trim or Unicode-casefold content. CR/LF/NUL remain forbidden in raw IRC message fields; IRCv3 tag values use their proper escaping at C2S rendering. A JSON escape is not permission to inject an IRC line.

A `Stamp` is `[Positive, SID, Boot]`, compared lexicographically: numeric counter, then ASCII SID, then ASCII Boot. It orders versions, not permissions or physical time. A `ChannelRef` is `{"name": Bytes, "born_ms": Positive, "cid": ID}`; names are compared after existing IRC casemapping, while incarnation priority is `(born_ms,cid)`.

### Frames

| `t` | Body beyond `t` and, after hello, `n` | Direction / purpose |
|---|---|---|
| `hello` | `protocol`, `version`, `network_id`, `profile_hash`, `sid`, `boot`, `name`, `nonce`, `time_ms` | Exactly once each way after TLS; no `n` |
| `sync` | `phase`, `sync_id`, `scope`, phase-specific fields | One bounded snapshot transaction; section 10 |
| `state` | `origin:NodeRef`, `actor:Actor`, `context`, `changes:[Row...]` | Committed state or explicitly marked snapshot merge |
| `message` | `origin:NodeRef`, `actor:Actor`, `message_id`, `sent_ms`, `target`, `command`, `text`, `tags`, `request_id:ID\|null` | Transient PRIVMSG/NOTICE/TAGMSG or permitted server/oper notice |
| `request` | `origin:NodeRef`, `to:NodeRef`, `request_id`, `actor`, `method`, `args`, `guards`, `ttl_ms` | Owner/authority/query request; finite methods only |
| `reply` | `origin:NodeRef`, `to:NodeRef`, `request_id`, `part`, `done`, `status`, `payload` | Ordered bounded response; part starts at 0 |
| `ping` | `token` | Direct liveness only |
| `pong` | `token` | Echo exact outstanding ping token |
| `close` | `code`, `reason` | Direct graceful/error close; no forwarding |

All post-hello frames carry `n`, starting at 1 independently in each direction and increasing by exactly 1. Forwarders regenerate `n`; they preserve logical origin, versions and request/message IDs. A gap/repeat is an implementation/protocol fault, not an instruction to skip a frame or replay missing traffic.

**N-REQ-027 — Exact schema.** Reject unknown frame types, unknown mandatory fields, wrong types, duplicate keys and unsupported version/profile. In ENP/1 the schemas are closed, except the explicitly defined client-tag map and finite policy property payloads. Adding a meaning requires a profile revision, not silent optional interpretation.

**N-REQ-028 — Streaming and budgets.** Support arbitrary TCP/TLS fragmentation and multiple frames per read. Bound partial-frame bytes and assembly time. A length exceeding the current phase limit closes the connection before receiving the declared payload. Parsing failure never applies a partial object.

**N-REQ-029 — Representation safety.** Maintain canonical IDs/numeric tokens and byte-preserving text conversion. Serialize only explicit projections and message objects, never all fields of an existing struct. Reject wire PIDs, references, module names, secrets and unknown policy keys.

**N-REQ-030 — No compression or batching ambiguity.** ENP/1 has no compression negotiation and no C2S BATCH frame. A `state.changes` array is ordered protocol data, not an IRCv3 batch. Local batches remain presentation to individual clients.

<a id="native-section-08"></a>

## 8. Version profile and operational configuration

Use the existing configuration loader/schema/resources. Proposed keys belong under `s2s`; they do not already exist in the reviewed checkout. [SRC07]

| Group | Required content |
|---|---|
| `enabled`, `network_id`, `semantic_revision` | Default disabled; shared network identity; explicit implemented behavior revision |
| `server_id` | This node's SID, matching exactly one public roster entry |
| `roster` | Ordered/normalizable map of SID to server hostname and parent SID or nil; exactly one root |
| `listener` | Bind address/port, TLS CA/certificate/key references, required client certificate |
| `parent_connection` | Parent connect address, port, SNI, local bind address, approved certificate fingerprints |
| `children` | Incoming child SID to approved fingerprints and optional IP/CIDR admission checks |
| `services_authority` | SID or nil when global services are disabled; same value everywhere |
| `budgets` | Per-link/aggregate frame, queue, snapshot, pending request, metadata and state-slot budgets |
| `timeouts` | TLS/hello, snapshot, incomplete frame, request and heartbeat durations in milliseconds |
| `remote_admin` | Local allowlist of destructive actions/origin SIDs/operator roles; disabled by default |
| `reconnect` | Initial delay, max delay, jitter, error categories that suspend automatic retries |

The profile hash is SHA-256 of **compact UTF-8 JSON for a fixed-position array**, avoiding object-key serialization ambiguity. The array is:

`["elixircd-native",1,semantic_revision,network_id,roster_rows,services_authority,case_mapping,utf8_only,user_limits,channel_limits,mode_rows,policy_schema_revision]`.

`roster_rows` are `[sid,name,parent_or_null]`, sorted by ASCII SID. `user_limits` are `[max_nick_length,max_ident_length,max_realname_length,max_away_message_length]`. `channel_limits` are `[global_prefix,local_prefix,max_name_length,max_global_memberships,max_topic_length,max_kick_length,max_modes_per_command,max_b,max_e,max_I]`, with `#` and `&` as the ENP/1 global/local namespaces. Reject another shared namespace until a semantic revision defines it. `mode_rows` contain `[context,wire_letter,argument_class,meaning_revision]`, sorted by context then letter. Meaning revision includes the current registered-nick restrictions, visibility and admission semantics; it is not just a mode name. Numeric field ordering is fixed.

All account/channel policy schema fields in section 17 belong to `policy_schema_revision = 1`. C2S capability preferences, certificates, peer addresses, local ports, private passwords and queue sizes are not copied into this hash. A C2S capability can be disabled locally without disabling its required network representation. A setting changing network admission/interpretation must instead change the semantic revision.

**N-REQ-031 — Strict profile matching.** Complete hello profile matching before topology publication. No downgrade to earlier TS6-derived specs and no best-effort interpretation when a mode/profile differs. The software version remains honestly ElixIRCd, not an upstream daemon version.

**N-REQ-032 — Config lifecycle.** Validate the entire candidate configuration/resources before activation. Changes to SID, roster, authority role, casemapping, namespace, field semantics or protocol limits require maintenance restart of the affected network profile. Do not mutate the meaning of existing state while links remain active.

**N-REQ-033 — Suggested defaults.** Start with TLS/hello 15 s; incomplete-frame 15 s; network snapshot 120 s; idle ping 30 s; unanswered ping 60 s; normal request 15 s, hard maximum 60 s; outbound queue 16 MiB per link; snapshot-delta queue 16 MiB per link; aggregate output 128 MiB; snapshot staging 128 MiB per node; 128 pending requests per origin, 1,024 per node; 16 active repairs per node. These are initial project defaults to benchmark, not throughput claims.

**N-REQ-034 — Memory-state budgets.** Configure active lists separately from retained version slots. Default per channel/list: existing active limit (currently 100), 4,096 distinct active-or-deleted slots. Default maximum global memberships per user remains the current configuration (20); hard ENP/1 ceiling 128. A new operation exceeding retained-slot capacity is refused before commit; removal of an existing slot remains possible. Never silently evict a tombstone to admit a new ban.

### Certificate and configuration setup procedure

Provision one certificate/key per daemon from the trusted deployment CA, configure the matching hostname/SNI and neighbor certificate fingerprints, distribute the same public roster/profile, assign exactly one global services authority, give each daemon a distinct data directory, validate offline, then start the tree in any order. Children retry unavailable parents. Never copy another running node's data directory, boot, private key or UID allocator state.

<a id="native-section-09"></a>

## 9. Handshake and link state machine

| Phase | Allowed work | Exit condition |
|---|---|---|
| `disconnected` | Child backoff or incoming child accept | Transport created |
| `tls` | Certificate negotiation only | Valid mutual TLS and allowed peer identity |
| `hello` | One `hello` from each side; error close | Same protocol/version/network/profile, correct neighbor, unique live edge |
| `syncing` | Initial `sync`, allowed direct ping/pong/close, queued post-cut output | Both network snapshots ended, applied and acknowledged |
| `active` | All admitted frames, bounded repair/query snapshots | Close/failure/removal |
| `closing` | Fence generation; bounded final close output | Teardown completed; child backoff |

Both endpoints send hello immediately after valid TLS; neither waits for the other to send first. Hello time skew over 30 seconds refuses admission; over 5 seconds is an operator warning. These are ENP/1 policy thresholds, not inherited protocol constants. They detect operational clock faults; shared-field ordering uses logical clocks.

After validating both hellos, reserve the physical edge and exchange initial snapshots immediately in both directions. Sending one's snapshot never waits for receipt of the other's final acknowledgement. A network snapshot may be exported while the other direction is importing, but the local capture/delta boundary must be coherent.

**N-REQ-035 — Duplicate connection rule.** The configured child is the only initiator. Refuse a second session for an already live/reserved edge. Do not terminate the established connection to accept a racing retry. A stale server with the same SID and a different boot cannot coexist; finish old-edge teardown before accepting the replacement.

**N-REQ-036 — Separate readiness states.** Keep transport authenticated, snapshot received, snapshot sent, snapshot acknowledged, edge ready and policy cache ready as different facts. A pong does not complete synchronization. A known server descriptor does not mean its services endpoint is ready.

**N-REQ-037 — Fence every callback.** Carry the local link-generation token through DNS/connect results, parser tasks, timers, snapshot workers, queued writes and pending replies. An old callback cannot close or modify a new session with the same SID.

**N-REQ-038 — Reconnect policy.** For transient failures use exponential backoff starting at 1 s, capped at 60 s, with bounded jitter. Reset only after a stable active period. Stop automatic retries on identity/profile/certificate errors until configuration changes or an operator explicitly retries. Do not busy-loop on a protocol bug.

<a id="native-section-10"></a>

## 10. Snapshots, causal output, and channel repair

### The `sync` exchange

Initial network sync is direct-link-only. Its `scope` is `"network"`; smaller channel/policy snapshots use the bounded `snapshot` request/reply method later. `sync_id` is unique in the link generation.

| Phase | Exact additional fields | Meaning |
|---|---|---|
| `begin` | `scope:"network"`, `cut:UInt` | Sender captured one coherent export view at local output cut |
| `rows` | `page:UInt`, `rows:[Row...]` | Page index starts at 0 and increments; dependency-ordered records |
| `end` | `pages:UInt`, `rows:UInt`, `sha256:string` | Number of pages/rows and digest of the exact rows-page JSON bodies in order |
| `ack` | `sha256:string` | Receiver applied the snapshot and accepts the same digest; not a chat receipt |

Digest the UTF-8 JSON body bytes of each `sync/rows` frame exactly as received, including its `n`; length prefixes are excluded. The sender hashes exactly those same body bytes after assigning `n`. Frames are not relayed unchanged, so a new hop has its own digest. Use incremental hashing, not concatenation of the entire snapshot. TLS already gives integrity; this digest detects implementation mix-ups and incomplete pages.

### Capture and transfer

Take a local ordering barrier. In one protected view, copy explicit exportable projections, record output cut C, and register the new link's post-cut stream before releasing the barrier. Encoding happens afterward. Use a bounded copy initially; do not implement a distributed database snapshot. The local copy may briefly pause commits and must be measured at scale.

Skip output groups at or before C for the new link: their state is already represented in the snapshot, and old chat is not replayed. Enqueue snapshot pages and `end`, followed by output groups greater than C. Do not start normal state writes to that link from independent processes while its snapshot is being written. Other existing links keep their own ordered delivery.

### Row order

1. Complete export-side topology (nodes and active edges), excluding the receiver's component.
2. Cached complete policy descriptor and non-secret policy rows, if available, explicitly tagged as a cache and not an authority write.
3. User projections.
4. Channel headers and current mode/topic/list registers, including retained list deletions.
5. Complete global membership sets for the exported users.
6. Membership-status registers for active matching join IDs.
7. Any remaining typed policy readiness/merge markers; then `end`.

Do not export local `&` channels, private lists, unregistered sessions, passwords or jobs. A channel referenced by an exported membership must have its header/state exported first. Full registration data is never part of this snapshot.

**N-REQ-039 — Snapshot completeness.** Empty networks, users with no channels, zero active list entries with retained removals, topic clears and cached policy deletion state are valid cases. Check final counts/digest and phase order. An incomplete snapshot cannot make an edge active.

**N-REQ-040 — Snapshot/live boundary.** A user at the cut is introduced even if they quit later; their subsequent quit follows in deltas. A post-cut user appears only through deltas. Post-cut channel recreation, topic clear and service-policy changes cannot overtake their dependencies.

**N-REQ-041 — Existing-peer publication.** Applying imported rows produces normal normalized `state` changes to existing peers, preserving field/owner versions. Begin a bounded `merge.begin` marker before these changes and emit `merge.end` afterward; on failure emit `merge.abort` after route cleanup. These markers suppress automatic greets/fantasy/enforcement duplication, not source authorization. Initial `sync` frames themselves are not broadcast.

**N-REQ-042 — Service enforcement barrier.** An authority defers state-dependent automatic channel repair for a merging subtree until its merge ends and its connecting edge is ready. It may still serve unrelated existing users. A snapshot imported during another merge must carry the relevant not-ready topology/merge state, with completion delivered in later deltas.

**N-REQ-043 — Bounded failure.** If staging, delta queues or synchronization deadlines exceed their limits, close the link and discard its generation. Never drop selected state rows, mark ready early or silently turn a full snapshot into a partial view.

### Missing-channel repair

A complete owner membership set can reference a channel absent locally because the final old member left concurrently with a remote join. Do not publish an invented empty channel with guessed modes. Keep that membership reference pending, and issue `snapshot` with `scope:"channel"` to the membership owner's server. Coalesce by owner/channel/link generation.

The reply contains a coherent channel header/register/status snapshot plus the owner's latest membership set for that UID. `NOT_FOUND` still includes that latest membership set: it can demonstrate that the claimed join no longer exists. Apply both through ordinary validated merge functions. If the owner is gone, remove the pending dependency with its unreachable user. If the reply cannot resolve a still-live required dependency within the budget/deadline, close the responsible link rather than continuing inconsistent state.

**N-REQ-044 — Repair guards.** Do not turn a repair reply into arbitrary state injection. Bind it to the expected responder, request, UID and generation; accept user/membership state only for that owner. Ignore obsolete status joins and losing channel incarnations. Channel content remains multi-writer state with ordinary version comparisons.

<a id="native-section-11"></a>

## 11. Complete state-row catalog and routing

The `state.context` object is closed: `{"kind":"live"}` or `{"kind":"merge","id":ID}`. A merge ID must be open in the receiver's bounded merge registry. Rows are applied in array order in one local commit group. A large operation may produce several groups only at domain-safe boundaries; its output order is preserved.

`origin` is the node that authored a live operation or is exporting a marked merge. It must be reachable through the incoming neighbor. Forwarders preserve this origin. A field's historical stamp is not necessarily the current exporter and is not an authentication identity.

| Row `kind` | Exact fields besides `kind` | Authority / behavior |
|---|---|---|
| `topology.add` | `nodes:[Node...]`, `edges:[Edge...]` | Authenticated connecting component or established introducer; add validated reachable graph only |
| `topology.ready` | `edge_id`, `side:SID` | One endpoint declares its side synchronized; ready requires both sides |
| `topology.remove` | `edge_id`, `reporter:SID`, `reason:Bytes` | Either endpoint of that exact edge nonce; prune newly unreachable component |
| `merge.begin` | `id`, `via:NodeRef` | Known exporting node opens bounded merge scope |
| `merge.end` / `merge.abort` | `id` | Same exporter closes scope; no implicit rollback |
| `user.put` | `user:UserProjection` | Home route only; newer owner revision replaces owner fields |
| `user.quit` | `uid`, `home:NodeRef`, `rev:Positive`, `reason:Bytes`, `action:"quit"\|"kill"`, `by:Actor` | Home route only; remove once; `by` is verified attribution from owner's operation |
| `memberships.put` | `uid`, `home:NodeRef`, `rev:UInt`, `entries:[MembershipEntry...]`, `cause:MembershipCause` | Home route only; complete set replaces previous set, with generation-aware diff |
| `channel.ensure` | `channel:ChannelRef` | Introduce or select channel incarnation; no automatic mode/status grant |
| `channel.field` | `channel`, `field`, `value`, `stamp`, `setter:Actor` | Finite mode field or compound topic; stamped merge |
| `channel.list` | `channel`, `mode`, `mask`, `present:boolean`, `set_by:Bytes`, `set_ms:UInt`, `stamp` | Finite b/e/I list, canonical mask; stamped presence/removal |
| `member.status` | `channel`, `uid`, `join_id`, `mode`, `enabled:boolean`, `stamp`, `setter:Actor` | o/v only, current channel and membership; stamped merge |
| `policy.change` | `epoch`, `revision`, `changes:[{entity,key,value}...]\|null` | Global authority only; value null deletes an object; contiguous authority stream |
| `invite.notice` | `invite_id`, `target_uid`, `inviter_uid`, `channel`, `expires_ms` | Target owner after accepting an invite; notification only, never grant again |

`Node` is `{"sid":SID,"boot":Boot,"name":string,"description":Bytes}`. `Edge` is `{"id":64-lowercase-hex,"a":NodeRef,"b":NodeRef,"ready_sides":[SID...]}` with endpoints sorted by SID. It must be a declared roster edge and its boots must match the node descriptors. The fresh direct edge ID is derived from hellos; snapshot edges within a trusted exported subtree retain their IDs. A topology page describes at most the 256 configured nodes and their 255 edges. Its single topology row may use the larger topology frame ceiling.

An exported graph must be internally connected to the exporter, disjoint from the receiver component before adding the new physical edge, and consistent with the static roster. Validate the whole graph before publishing it. Existing vertices with identical boot/data are idempotent; a second live boot for one SID is rejected. The direct bridge edge is already authenticated locally; it is added to established peers with the validated new component.

**N-REQ-045 — Topology deletion fence.** Match edge ID and reporter endpoint before removal. An old failure report must not remove a new session between the same IDs. Derive unreachable users/memberships from paths; do not emit thousands of redundant home-owned quit rows for a split.

**N-REQ-046 — Origin checks.** A live user-owned row must come through its home route, even inside a merge. A live channel register's stamp SID/boot must match its original origin; its actor must belong to that origin or be an authorized logical service. Historical register stamps in an authenticated snapshot may name a server that has since left, but cannot authorize current service/account writes.

**N-REQ-047 — Commit versus request.** Check local C2S permissions before originating a channel change. A receiving hub validates the committed event's origin, finite schema and generation; it does not rerun local client admission and independently reject a change because the actor's privileges have since changed. Owner-directed requests have their own revalidation rules in section 16.

**N-REQ-048 — Relay rules.** Broadcast accepted global state changes to every active neighbor except input, not once per user. Directed request/reply/private message uses one next hop. Channel messages use only branches with actual recipients; transient invite notices use the permitted channel-notification audience. A fully duplicate state row generates no new relay or client event.

**N-REQ-049 — Unknown or stale state.** Malformed required rows close the link. Older/equal valid versions, obsolete membership status and obsolete edge removals are harmless no-ops. A missing required live owner/route is not fixed by fabricating a user. Stage only the explicitly defined channel-repair dependency; do not build an unbounded generic deferred-event system.

There is no generic `set(any_table, any_key, any_value)` operation. The small vocabulary carries a finite collection of domain schemas.

<a id="native-section-12"></a>

## 12. User projection, nickname conflicts, and full membership replacement

### UserProjection

All fields below are present. A nullable field uses JSON null, not an omitted key:

`uid`, `home:NodeRef`, `rev:Positive`, `requested_nick:string`, `signon_ms:Positive`, `ident:string`, `realhost:string`, `displayhost:string`, `address:string`, `secure_client:boolean`, `client_certfp:string|null`, `modes:[mode-letter...]`, `oper_role:string|null`, `away: {text:Bytes,since_ms:Positive}|null`, `realname:Bytes`, `binding: {account_id:ID,auth_epoch:Positive,policy_epoch:ID}|null`.

Addresses are canonical textual IPs accepted by the existing IP library. The projection includes no C2S password, local transport, PID, CAP state, recovery token or SASL buffer. Real/display hostname distinction is explicit; display host already reflects the home server's cloak policy. The public `modes` are finite current user modes excluding `r` and `Z`: these are derived locally from binding/nickname policy and `secure_client`, respectively. Reject transmitted `r`/`Z` in this array rather than accept contradictory state. `oper_role` is null for a non-oper and a finite owner-declared role name for an oper; its name never creates permissions at another node. The +s flag can be visible state, but individual snomask subscriptions remain home-local.

A full newer projection replaces owner fields; it does not replace channel status, private recipient lists, or authority-owned policy. Exact same revision/content is idempotent. Same revision/different owner content is a protocol fault. Home revisions are strictly increasing within a user session and do not depend on receipt time.

### Nickname conflict policy: requested versus effective name

ENP/1 resolves competing live nickname requests as a deterministic view rather than a collection of remote rename/KILL correction commands. Group users by the existing casemapping of `requested_nick`. The lexicographically smallest UID in a group gets that requested spelling; every other member uses **`G` followed by its entire UID**, a unique 27-character nickname. Reserve that generated namespace case-insensitively from ordinary clients and account registrations. The default current nickname limit is 30; network mode requires at least 27. [SRC15, SRC16]

The home server still rejects an ordinary local NICK request when another effective nickname currently occupies it, as the existing command does. The deterministic rule handles simultaneous requests and split joins that could not be rejected locally. Registered account ownership is a separate authorization/enforcement policy; it is not inferred from winning this contest.

Store requested name as owner data and effective name as a derived index/materialized view. A merge must not overwrite requested name with a temporary fallback. When the winner quits or relinquishes the request, the next remaining claimant automatically obtains the desired name. This automatic restoration is an intentional ENP/1 behavior; a loser who manually changes their request no longer claims the old name. Services can direct the owner to change the request when an account legitimately recovers a nickname.

**N-REQ-050 — Deterministic nickname projection.** Recompute affected nickname groups atomically on user introduction, request change or removal. Enforce one effective nickname per live UID and one UID per effective name. Use a reserved injective fallback, not a truncated hash with unhandled collisions. Reject duplicate UIDs independently.

**N-REQ-051 — Nickname client effects.** Emit NICK notifications from old to new effective masks to the affected user and legitimate local observers. Update MONITOR, WHOWAS and derived +r consistently. When two effective names need swapping, move vacating users to their reserved aliases before assigning the final contested names so C2S observers never see simultaneous ownership.

**N-REQ-052 — Registration and reserved names.** NickServ/ChanServ names are reserved logical endpoints even when temporarily unavailable. Fallback names may be selected only as the current user's own fallback, or generated internally. A pre-registration nickname reservation cannot defeat an already registered remote user; give the local unregistered client an ordinary conflict outcome without advertising a fake QUIT.

### MembershipEntry and MembershipCause

An entry is `{"channel":Bytes,"join_id":Positive,"joined_ms":Positive}`. Names must be global `#` channels; there is at most one entry per normalized name. `entries` is the **complete current global membership set for this UID**, maximum 128 entries and usually the current limit of 20. Empty means part all global channels, not user disconnect. Local `&` entries never appear.

`cause` is `{"action":"join"|"part"|"kick"|"sync", "channel":Bytes|null, "join_id":Positive|null, "by":Actor, "reason":Bytes}`. The home server emits it after applying the authorized action. It is attribution/presentation, not permission for a receiver to mutate another user's set. On snapshots use `sync` and derive differences, never replay old KICK reasons.

This is deliberately a little more data on each JOIN/PART than a delta-only protocol. At the existing small per-user membership limit, complete replacement eliminates lost-removal tombstones and a separate membership-operation compatibility layer. It is not transmitted on each chat message.

**N-REQ-053 — Membership authority.** Only the user's home route can replace their set. Store a monotonically increasing membership-set revision independently of the user projection revision. A newly introduced user starts at membership revision 0 with an empty set; revision 0 with nonempty entries is invalid. A first local join advances it to 1. Empty revision-0 sets are valid in snapshots. Ignore older sets; reject equal-revision contradictory sets. Diff the new set against the old in one transaction.

**N-REQ-054 — Membership identity.** Allocate a new monotonically increasing join ID for every rejoin by that UID. Preserve it during nickname changes and channel-incarnation arbitration. A changed join ID for the same channel is a real leave/rejoin, not a status update. Remove old status state before installing the new generation.

**N-REQ-055 — Remote removals.** KICK, forced PART and service removal execute at the target's home server after request guard checks. That owner publishes the resulting full set once and returns a receipt. A delayed request naming an old join ID cannot remove a newer join. Do not publish a speculative successful KICK at the requester before the owner acts.

**N-REQ-056 — Local membership facade.** Reuse `UserChannel` rows as the materialized membership set, with UID/channel composite keys and indexes. A locally created channel may give its creator +o through a separate status register in the same commit. An ordinary existing-channel join never creates +o merely because an intermediate replica had to repair a missing channel.

Home-owned quit removes the user, their memberships and associated transient state. A raw socket close, explicit QUIT, owner-applied KILL and timeout must converge to one removal. A split is reachability loss, not a forged home-owned quit. IDs are not restored after a daemon boot change.

<a id="native-section-13"></a>

## 13. Channel incarnations, versioned fields, lists, and topics

A channel's transient network identity is `(normalized name, born_ms, cid)`. It is not its ChanServ registration date. Independently created copies of the same name select the smaller `(born_ms,cid)` pair. This is a total comparison with millisecond time then ASCII ID; a valid birth cannot be zero. A local creator uses current UTC milliseconds and a fresh CID. Clock faults generate diagnostics; no remote party may rewrite the local clock.

| Case | Required action |
|---|---|
| Unknown channel | Create a header, but publish only after necessary member/state dependencies are available |
| Same incarnation | Merge each supplied field by stamp |
| Incoming smaller incarnation | Adopt it; clear losing runtime modes, lists, topic and status registers; invalidate invites; keep actual active memberships |
| Incoming larger incarnation | Keep the local incarnation and ignore its channel fields/status; still accept valid owner membership sets |
| Identical birth time, different CID | Smaller CID wins; no ambiguous equal-time branch |

Channel membership existence is independent of this arbitration. Existing users do not get kicked merely because another incarnation won; their losing statuses are cleared. The owners retain the same join IDs. Current channel references are supplied separately from authoritative membership-set bytes, so this local derivation does not change an owner's set without changing its revision.

### Stamp algorithm

Maintain one local logical counter L. On every accepted stamped input set `L = max(L, received_counter)`. Before creating each new shared-field mutation set `L = L + 1` and stamp it `[L,local_sid,local_boot]`. A single command may create several stamps in order. Counter overflow is fatal for originating work; never wrap. Past stamps carried by snapshots may refer to departed writers and remain comparable.

For one register in one channel incarnation: a greater stamp wins; equal stamp/equal value is a no-op; equal stamp/different value is a protocol fault. Never invent a numeric-limit-specific or key-lexicographic merge: all shared channel registers use the same rule. This orders concurrent updates deterministically, but is not proof one concurrent human action happened later in real time.

### Fields and values

`channel.field.field` is exactly `topic` or `mode:<letter>` for one currently supported non-list/non-membership mode. A simple mode value is a boolean; a parameter mode is its validated canonical string or null to unset. The compound topic value is `{"text":Bytes,"setter":Bytes,"set_ms":UInt}` or null for never-set state. Clearing a previously set topic uses the empty-text compound value with a newer stamp, not disappearance of its register.

The registered-channel `+r` projection derives from service policy, not a client-writable register. Locks constrain originating operations; they do not authorize arbitrary peers to set private registration state. MLOCK desired values and runtime mode registers are different data.

**N-REQ-057 — Register storage and reuse.** Add version metadata adjacent to existing channel/list/status data. Keep current mode formatting and validators, but use one shared version comparison function for incoming state and snapshots. If materialized `channel.modes` is retained for compatibility, update it atomically from the authoritative register values; it is not a second independently writable truth.

**N-REQ-058 — Local versus received validation.** Local commands use the existing authorization, canonicalization and argument consumption. Incoming committed values use finite type/range/incarnation validation and merge, not a second local authorization contest. A key remove/new-limit request must not be interpreted using another daemon's semantics.

**N-REQ-059 — Removal records.** A removed list entry remains an inactive slot with its last stamp while that channel incarnation remains retained. Snapshot it. Ordinary queries expose active entries only. Incoming older adds cannot resurrect it in that incarnation. Do not synchronize list data by unioning masks and forgetting removals.

**N-REQ-060 — Tombstone lifetime boundary.** Do not time-expire inactive slots while the channel remains live/retained. When a transient channel has no reachable members and no policy-defined presence, discard its entire incarnation. A later reappearance of an older still-live partitioned channel can restore its state: ENP/1 does not promise a globally durable history of channel-ban removals after local channel extinction. Durable service-policy deletions use full authority snapshots, not this rule.

**N-REQ-061 — Status guards.** Apply `member.status` only to a known active UID, current join ID and winning channel incarnation. Store separate stamped booleans for o and v, including false values. Removing/rejoining a membership discards status registers for the old generation. A missing transient target is a no-op, not a reason to grant authority to its nickname replacement.

**N-REQ-062 — Topic correctness.** Preserve text, setter and physical set time as one atomic register. Same-millisecond changes are permitted because stamps disambiguate them. An empty clear must survive a burst. A metadata-only change does not require a duplicate visible TOPIC if the text is unchanged. Do not reuse the local receipt time or apply a foreign protocol's topic rules.

**N-REQ-063 — No hidden channel persistence.** Registration alone does not make a runtime channel permanent. A configured logical GUARD presence may keep the registered channel projected as present; ordinary unguarded empty channels can disappear. Persistent saved topic and MLOCK stay at the appropriate services authority and can be reasserted by an authorized new operation on recreation.

Merge comparisons are deterministic for a fixed retained incarnation and its registers. Availability during partitions still permits concurrent admissions, missed transient messages, and the explicit channel-extinction limit above. Do not claim a full durable CRDT store or an unlimited conflict history.

<a id="native-section-14"></a>

## 14. Preserving current modes and local channel behavior

ENP/1 keeps ElixIRCd's meanings; it does not translate letters to another product. The current finite registry is authoritative when a README or old document disagrees. For example, the reviewed user-mode registry does not include the README's separately described user `+p`; do not claim or implement it accidentally as part of S2S. [SRC03, SRC04]

| Existing feature | Required network treatment |
|---|---|
| User B, i, H, o, R, w, x | Home-owned projection; shared query/delivery functions interpret existing meanings |
| User g / ACCEPT | Global flag, recipient-home private accept list keyed by UID; remote source matching supported |
| User s / snomasks | Home-owned flag; subscriptions and permissions remain home-local |
| User r | Derived ownership of current effective nickname, including grouped aliases; not merely any account login |
| User Z | Derived from the home-attested client connection, never from the ENP link's TLS |
| Channel C, c, T | Origin admission uses existing CTCP/format/NOTICE rules; forwarding is not an opportunity to rewrite accepted content |
| Channel d | Preserve origin membership join time; only the client's home server applies its speaking delay |
| Channel j | Preserve current parameter validation and admission behavior; incoming remote joins are not new local attempts |
| Channel i / I | Local admission with private invite grant and synchronized exception list |
| Channel b / e | Current canonical mask matching, synchronized present/deleted entry registers |
| Channel k / l | Current local parsing/permission rules; register-version merge on conflicting remote values |
| Channel m / n / t / O | Shared meaning; originating request validation plus committed-state replication |
| Channel M / R | Preserve current registered-nickname tests; do not silently replace them with any-account authentication |
| Channel p / s | Local queries filter the complete reachable view; hidden channels are not omitted from necessary server state |
| Channel u | Reuse auditorium visibility rules for local events/queries; hidden clients still exist in routing/membership state |
| Channel z | Check client-security attestation at admission, not `remote_user.transport` or peer TLS |
| Channel r | Service-policy projection; cannot be forged by a normal MODE |
| Membership o / v | Versioned booleans scoped to join ID and channel incarnation |

The current channel M/R checks and the registered-channel `restricted` setting are not interchangeable: one relies on the registered-nickname marker, the other on account identity. Preserve that distinction unless a separately reviewed application change intentionally changes it. [SRC17, SRC18]

The current join-throttle implementation counts recent *still-present* memberships, not a durable stream of all JOIN attempts. S2S must not silently replace that with another daemon's algorithm. Preserve the observed policy, use owner-provided joined time, and document its existing limitation; a throttle redesign is a separate change. [SRC18]

**N-REQ-064 — Mode reuse.** Reuse `ModeRegistry`, `ChannelModes.mode_types/0`, key/list validation, mask matching and current C2S formatters. Add a context/commit path rather than copy the mode engine into `S2S`. Unknown mode characters never create atoms or untyped register keys.

**N-REQ-065 — Distributed admission.** Accept valid home-owned membership sets even if the local count has since exceeded +l/+j. Those modes are not globally atomic quotas. Strict network-wide quotas would require another protocol and latency trade-off and are not claimed.

**N-REQ-066 — Local namespaces.** `&` channels, their memberships, invitations, topics, ACLs and visibility never leave their home daemon. A user quitting removes both their local and global memberships; a global `memberships.put` with an empty set does not part local channels. A local JOIN 0 must perform both scopes through their respective paths.

**N-REQ-067 — Domain visibility.** Keep one shared visibility/mask helper path. Network replication sees necessary hidden state; C2S output still enforces invisible, private, secret, auditorium, hide-oper and account privacy. A remote user's nil PID is never a reason to treat them as the viewer.

No extban, extra status rank, global history store or unimplemented C2S capability becomes a requirement merely because another IRCd has it. Extend ENP's semantic revision when this project actually adds such a feature.

<a id="native-section-15"></a>

## 15. Messages, tags, echo, invitations, and logical services

### Message frame completion

The `message` frame also includes `request_id:string|null`. For a user-originated private PRIVMSG, allocate a pending delivery context and supply its request ID so the recipient owner can return existing error numerics or a terminal OK. NOTICE/TAGMSG normally use null: they must not generate unsolicited automatic errors. A services reply uses null unless it is deliberately part of an existing request's response stream.

`command` is `PRIVMSG`, `NOTICE` or `TAGMSG`. Text is Bytes for PRIVMSG/NOTICE and null for TAGMSG. Tags are a bounded map of valid tag names to Bytes or null. `target` is exactly one of:

- `{"user":UID}`.
- `{"channel":ChannelRef,"minimum_status":null|"o"|"v"}`. Status targeting may be originated only if the application actually supports and advertises it.
- `{"audience":"wallops"|"operators"|"snomask","mask":string|null}` for authorized operator/server notifications, rendered through the existing corresponding command conventions.

Service commands are not ordinary private message delivery: the origin's existing service recognizer routes them through the `service` method. Outbound replies can use a service actor and ordinary target UID, with authority checked. Do not let a normal user called NickServ receive a service request.

**N-REQ-068 — Message routing.** Resolve a private nickname once to UID at its origin. Route to that UID's owner. For channels, send one copy per relevant branch, not one per remote member. Recipients must belong to the current channel incarnation and satisfy the explicit audience. Do not reflect into the input link.

**N-REQ-069 — Admission and recipient policy.** The sender home applies channel speaking permissions and content restrictions once. The recipient home applies private +g, ACCEPT, SILENCE and registered-only filters. Hubs perform structural/origin checks, not a second independent channel admission decision. A peer cannot spoof the source user or supply a private filter bypass.

**N-REQ-070 — Accepted-message echo.** Preserve the current ElixIRCd policy of echoing an accepted outgoing command locally. Echo is not remote delivery confirmation. A remote private recipient can still reject a message; route its legitimate error using the pending delivery context. Never echo both locally and again when a network result arrives. Self-delivery and labeled self-messages retain their existing distinct handling.

**N-REQ-071 — Message identity.** Generate the current message ID and server time once at origin, even if only remote recipients support the relevant C2S capability. Preserve them through forwarding and use the same data for the sender echo. Do not generate a different ID/time per link, local recipient or rendering branch. [SRC12]

**N-REQ-072 — Tag provenance.** Apply current client-only-tag acceptance to client input. Received trusted ENP message tags have already passed origin admission: validate them with the finite network/C2S provider rules, not the client-input sanitizer that would delete server-generated tags. Account/bot facts derive from accepted source state. Internal request IDs, link identities, versions and permission fields never become C2S tags.

**N-REQ-073 — Transient delivery semantics.** Do not persist or replay chat after reconnect. On missing/wrong-incarnation channel or unavailable user, use the defined error/no-error policy. A message queued behind a pending state dependency is bounded; timeout does not justify delivering it to an unrelated replacement channel/user.

### Invitations

The `invite` method targets the invitee's owner. It carries inviter UID, target UID, exact channel reference, absolute `expires_ms` (zero means no time expiry), and a fresh invitation ID. The owner checks requester/target/session and local authoritative invitation policy, stores the grant, emits the target C2S INVITE and publishes one `invite.notice` for eligible channel observers. It replies only after commit. Other nodes never store that grant or execute the invitation again.

Use the existing exceptions for an invite that can validly target a not-yet-existing channel only for local `&` behavior. For global ENP invitations, require a current channel incarnation; a channel recreated after an invite does not inherit the old grant. This is an explicit network-admission safety rule, with a clear C2S error for a missing global channel.

### Services endpoints and GUARD

NickServ and ChanServ remain reserved logical endpoints of the application, not fake network `User` rows or a separate service server. Their global availability is derived from the authority's ready reachability. Service requests are routed once to that authority and dispatched through existing handlers after validation.

When GUARD is enabled, represent ChanServ's visible channel presence as a **derived logical service membership** backed by channel policy, not a client PID. Render it consistently in NAMES/WHOIS/ISON/MONITOR where appropriate, exclude it from ordinary client limits and prevent normal kick/deop/kill of that endpoint. The derived presence can keep a runtime channel visible. It does not create a service transport or another user registration. In `&` channels the same logical role is a local delegate; no virtual membership is exported.

**N-REQ-074 — Logical endpoint security.** Service-origin output on global links must originate at the configured authority. Local-channel delegated replies are rendered locally and never forwarded as global authority actions. A bot flag, nickname, hostname text or source-provided service label does not grant service privileges.

**N-REQ-075 — Fantasy commands.** Run recognition/admission at the client's home server, preserving the existing GUARD/FANTASY settings and current consumed-command behavior. Route one recognized command to the channel's service authority. Do not also broadcast it as chat and execute it independently on each receiver. [SRC19]

<a id="native-section-16"></a>

## 16. Finite request/reply contract and remote authorization

A request's target is an exact NodeRef. It cannot silently follow a restarted server with the same SID. Resolve the target when creating the request and cancel it if that boot/route goes away. Request IDs are unique random IDs scoped to the source boot; never reuse one for a different operation. Only one automatic transmission is allowed for a mutating operation. TCP reconnect does not retry it.

The finite method set is:

| Method | Required args | Execution point / result |
|---|---|---|
| `query` | `command`, `params`, `target_uid` or null, `view` | Exact queried server; permitted structured C2S response items |
| `service` | `service`, `arguments`, `scope:"global"\|"local"`, `channel` or null | Global authority; local scope is never sent remotely |
| `sasl` | `attempt_id`, `uid`, `step`, `phase`, `mechanism`, `data`, `client_info` | Global authentication authority; section 19 |
| `user_action` | `action`, `target_uid`, `value`, `reason` | Target home server only |
| `invite` | `inviter_uid`, `target_uid`, `channel`, `expires_ms`, `invite_id` | Invitee home server |
| `snapshot` | `scope:"channel"\|"policy"`, `channel` or null, `for_uid` or null | Known state provider or exact policy authority |
| `admin` | `action`, `neighbor_sid` or null, `reason` | Exact server; disabled-by-default remote administrative ACL |

Allowed `user_action.action` values are `kill`, `kick`, `part`, `join`, `nick`, `host`, `ident`, `account`, and `oper`. Each uses the exact value schema in section 22. Host changes affect displayed host only. Account binding installation is exclusively an authority-to-owner operation. This is not an arbitrary user patch. Each action must correspond to an implemented operation; a disabled originating UI is not permission to advertise a successful no-op handler.

`guards` is a closed object with nullable `actor_uid`, `actor_user_rev`, `actor_join_id`, `target_user_rev`, `target_join_id`, `channel`, `policy_epoch` and `policy_revision`. Include exactly those relevant to the action, explicitly null for the others. Guard values identify state evaluated by the requester. The owner checks required identity/incarnation guards, current actor presence and applicable policy; it may reject stale authorization. These requests have not yet committed, unlike received channel state.

`ttl_ms` is 1–60,000. Forwarders subtract elapsed local monotonic queue time and never increase it. Expiry returns TIMEOUT only while a valid response route remains; an already executed operation can instead have an unknown outcome if its reply is lost. No global clock-synchronized request expiry is assumed.

A reply's `part` starts at 0 and increases by 1; one part has `done:true`. `status` is one of `OK`, `REJECTED`, `NOT_FOUND`, `STALE`, `UNAVAILABLE`, `UNSUPPORTED`, `BUSY`, `TIMEOUT`, `CANCELLED`, `UNKNOWN_OUTCOME`. Intermediate parts use OK. The payload is a method-specific result, snapshot rows, SASL result, or a list of structured C2S reply items. An error status must never be reported as success by a UI.

A C2S reply item has `command:string`, `params:[Bytes...]`, `trailing:Bytes|null`, `source:{server:SID}|{service:string}`, and `tags:map`. It is **not raw IRC bytes**. A method has a whitelist of valid commands/numerics and sources; a query cannot smuggle a client KILL, CAP change or service login. Substitute the recipient's actual current effective nick where the method defines the requester slot; never trust a supplied destination PID/nickname. Apply C2S size and tag rules normally.

**N-REQ-076 — Request origin.** User actors must belong to the originating node. Pre-registration SASL uses the home server actor and a separately reserved UID, not a fabricated registered user. Logical service actors must be the configured authority. Remote +o alone does not override target-server administrative ACLs.

**N-REQ-077 — Owner execution.** A forwarding node never executes a user_action on a user it does not own. The owner validates, commits once, emits its authoritative user/membership update, then replies. Deliver the update toward the requester before its success receipt. Do not await a network response while holding the database ordering lock.

**N-REQ-078 — Duplicate and uncertain outcomes.** Cache accepted request IDs/results within the bounded request horizon; identical duplicates return the cached result, contradictory reuse fails. Do not promise durable exactly-once execution across crashes. If a persistent service action may have committed but its response was lost, report UNKNOWN_OUTCOME and require explicit inspection/retry, not silent retry by the transport.

**N-REQ-079 — Bounded correlation.** Match source/target boots, request ID, expected responder, method, UID, connection generation and monotonically increasing part number. Reject an unexpected response source or part gap. Limit response bytes/parts, queued work and deadlines. A reply cannot be delivered to a new user with the old nickname.

**N-REQ-080 — No generic remote dispatch.** `query` and `admin` use explicit allowlists; do not call arbitrary command handlers, module names or MFAs supplied by a peer. `service` may reuse existing service dispatch only after authenticated caller/authority/scope setup. It does not bypass service account ACLs.

### Labeled response and async integration

Capture the requesting connection's response identity explicitly. Let synchronous handlers keep the current ResponseContext. When a remote reply is needed, return a pending result, without prematurely finalizing a successful C2S ACK. Feed permitted reply items into a connection-owned bounded continuation and finalize once on terminal result/timeout. Preserve the preexisting CAP flush barrier and nested local batches; no process-dictionary context is copied to workers or other sockets. [SRC20]

Cancellation on QUIT, CAP withdrawal, route loss or timeout prevents late local delivery. Cancellation cannot undo an already committed remote mutation. For mutating operations distinguish known rejection from unknown outcome in both logs and user replies.

<a id="native-section-17"></a>

## 17. Services authority, policy projections, and partition behavior

Global nickname/account data, global registered channels, aliases, access rules, memos and email workflow remain in the existing persistent tables at **one configured authority**. Local `&` channel registration data remains on its owning daemon; local channel services can use the global account's authenticated public identity without owning its password database. Do not merge two independent preexisting account databases merely because their daemons link.

### Public-to-peers policy schema

“Public” below means visible to trusted network daemons, not necessarily visible to IRC clients. These projections are explicit schemas, not serialized registration structs.

| Entity / key | Allowed value fields |
|---|---|
| `account` / stable account ID | `account_id`, `canonical_name`, `display_name`, `auth_epoch`, `verified`, `aliases:[nickname]`, and `settings` containing only `enforce`, `enforce_time`, `kill`, `hide_status`, `hide_usermask`, `hide_quit`, `never_op`, `no_greet`, `quiet_chg`, `secure` |
| `nick` / normalized nickname | `nickname`, `account_id`, `reserved_until_ms` (0 means no reservation) |
| `channel` / normalized global channel | `name`, `founder_account_id`, `successor_account_id\|null`, `access:[[account_id,flags]...]`, `settings`, `saved_topic` |

Each policy object must fit 32,768 compact JSON bytes and at most 1,024 aggregate values. Set a network-mode ceiling of 512 aliases per account and 512 access entries per registered channel; the encoded-object/value-count limit can impose a lower effective bound. Validate existing data before enabling ENP and refuse a new mutation before commit if it exceeds these explicit representation bounds. Never silently truncate an object. These are declared network-mode resource limits, not assertions about old standalone limits. Snapshot page builders group whole policy objects within the reply/page budget.

Channel `settings` includes only `entrymsg`, `keeptopic`, `persistent_topic`, `opnotice`, `peace`, `private`, `restricted`, `secure`, `fantasy`, `guard`, `topiclock`, `mlock`. A saved topic is null or exactly `{text:Bytes,setter:Bytes,set_ms:UInt}`; entrymsg, persistent_topic and mlock are Bytes-or-null, the other listed channel settings are booleans. Account aliases are strings; enforce_time is UInt seconds, kill is on/quick/immed/off, and the other listed account settings are booleans. Account auth_epoch is Positive, verified is boolean, canonical_name/display_name follow current name validators, and all account references are IDs. Empty ACL flags mean no permission. Description, URL/contact/email are queried from the authority with existing privacy checks rather than universally copied. Access flags use the existing `VAFST` domain and helpers; numeric ACCESS levels remain the existing compatibility UI. [SRC21–SRC24]

Account password hashes, verification/recovery secrets, emails, memos, raw ACCESS hostmask lists, public-key authentication material, arbitrary PROPERTY data, language/reply preferences and internal job payloads remain at the authority. Language and MSG preferences are applied where the service actually generates its reply. A leaf needs only the explicitly listed policy to enforce ordinary IRC behavior.

Assign a stable random account ID to each canonical account during migration and share it across grouped aliases. Do not derive it from the current display nickname. Keep existing canonical names and persisted references through existing migration helpers; do not rename accounts merely to introduce IDs.

### Authority revisions and full images

Maintain a persistent random policy `epoch` and persistent monotonically increasing policy `revision`. An authority transaction that changes public policy updates its private records and projection, increments the public revision once and records the corresponding batch of outgoing changes together. Transactions affecting private data only do not advance public revision. Consecutive `policy.change` batches are broadcast to the entire network, including nodes with no users. Deletion uses an item with `value:null` inside the batch. A batch whose `changes` is null invalidates grant readiness and requires a full image, as section 22 defines. Every node tracks one complete policy revision; a gap requires a full snapshot before applying later revisions.

A full policy image has an epoch, a cut revision and the complete set of account/nick/channel objects. In a `snapshot` reply, use:

- First payload: `{"snapshot":"policy","phase":"begin","epoch":ID,"revision":UInt,"objects":UInt}`.
- Row payloads: `{"snapshot":"policy","phase":"rows","rows":[{"entity":string,"key":string,"value":object}...]}`.
- Final payload: `{"snapshot":"policy","phase":"end","epoch":ID,"revision":UInt,"objects":UInt}` with `done:true`.

Stage by the request ID (or outer sync_id for cache rows), with unique entity/key pairs and exact object count, validate all finite fields, then atomically switch the policy view. **Objects absent from the new complete image are deleted**, not left behind by a merge. Queue newer authority deltas during staging, then apply contiguous revisions greater than the cut. Ignore older duplicate revisions; same revision with contradictory content is a fault.

The initial network `sync` may carry the same image as snapshot-only rows `policy.cache.begin`, `policy.cache.rows`, `policy.cache.end`, with fields `{kind,epoch,revision,objects}` for begin/end and `{kind,rows:[{entity,key,value}...]}` for rows. Their outer sync_id is the staging identity. These rows are prohibited in ordinary state frames. They establish a complete **cached** view from a trusted peer, not new authority writes. Never overwrite the actual authority database with a peer cache. A cached image of another epoch or a higher revision than the active authority's restored database requires operator investigation, not automatic acceptance of a stale authority.

**N-REQ-081 — Policy deletion recovery.** Do not use per-key last-write-wins for the account namespace or omit deleted registrations when a split peer returns. Refresh the complete image on reconnect, then resume contiguous deltas. Abort incomplete staging without replacing the previous complete view.

**N-REQ-082 — Snapshot access.** Only the configured authority produces a fresh authoritative policy snapshot. A channel snapshot is a different method result and cannot inject account objects. Cache import is accepted only from an authenticated network sync, with explicit cached status and profile-bound authority ID.

**N-REQ-083 — Role-safe reuse.** Add policy-view accessors beside existing repositories/helpers. At the authority they can project private records; at leaves they read the non-secret cache. Do not build fake RegisteredNick/RegisteredChannel structs with missing password hashes and feed them into mutating private-store code. Maintain the same pure ACL/flag/mask functions where possible.

**N-REQ-084 — Partition contract.** Preserve existing authenticated sessions and the last complete policy while authority is unreachable; normal chat and current channel permissions can continue using that view. No new global authentication, account/channel registration mutation, memo write or authority-dependent action may succeed. Revocations made on the other side of a partition are necessarily delayed; do not promise instantaneous revocation without communication.

**N-REQ-085 — Cold-start policy safety.** A network node with global services enabled and no complete policy image must not open ordinary global admission using an empty pretend registry. It may accept peer links, local management diagnostics and bounded C2S pre-registration while acquiring a complete cache/image; it must not announce those clients as globally registered users before admission is safe. If global services are disabled in the shared profile, the empty policy is explicitly valid. After reconnect to a reachable authority, refresh before allowing new account-dependent grants.

**N-REQ-086 — Binding validation.** A user binding is home-attested evidence of a previously successful authority authentication. Its policy epoch/account ID/auth epoch must match the local complete policy. Deleted or epoch-mismatched accounts lose effective authorization and derived +r. The `verified` flag follows the existing service rules; do not invent a blanket unverified-account authentication prohibition that the reviewed password path does not apply. Suspended or stale identities are not upgraded by a source-supplied account tag.

**N-REQ-087 — Failover and restore.** Do not auto-elect a new authority. Planned replacement requires fencing the old instance, restoring the private store and policy revision, then starting a unique authority boot. If revision rollback is detected, stop new authority actions; an intentional epoch reset requires coordinated maintenance and invalidation/revalidation of old bindings. Do not restore old authorization silently.

<a id="native-section-18"></a>

## 18. Every service operation and policy side effect

The service handlers keep their existing grammar, translations, canonical account rules and settings. Network placement changes; business semantics should not be forked.

| Family | Authoritative execution and resulting effects |
|---|---|
| NickServ REGISTER / VERIFY | Authority verifies requirements, stores credentials/verification once, allocates account ID, publishes eligible policy; never broadcast secrets |
| IDENTIFY / LOGOUT | Authority validates or owner clears binding; owner user projection updates; emit existing 900/901/ACCOUNT/+r effects exactly once |
| GROUP / UNGROUP / DROP | Mutate canonical aliases/records, publish account/nick projections or deletions; recompute all affected active sessions and +r |
| GHOST / RECOVER / REGAIN / RELEASE | Authority checks account ownership and current occupant; sends guarded user_action to owner; updates reservation policy with absolute expiry |
| SET and ACCESS | Private account mutation at authority; publish only changed allowed policy fields; no global password/hostmask-list dump |
| LIST / INFO / STATUS / ALIST / LISTCHANS / HELP | Authority or eligible local-channel delegate performs existing privacy-aware query and replies once |
| MEMO | Authority reads/writes persistent memos and sender/recipient limits; email delivery through existing durable jobs; no memo contents in burst/cache |
| ChanServ REGISTER / DROP / TRANSFER | Appropriate scope authority updates ownership, IDs and policy; no reinterpretation of runtime channel birth |
| ACCESS / FLAGS / ALIST | Reuse existing flags and role helpers; public-to-peers projection supports local enforcement, not public disclosure |
| OP / DEOP / VOICE / DEVOICE | Authority validates requester and current membership, emits guarded stamped status changes |
| BAN / UNBAN | Channel list register updates, not network-wide bans |
| KICK / CLEAR users | Guarded owner requests; outcome tied to UID/join ID; no speculative removal at each hub |
| INVITE | Owner-delivery method plus one notification, as section 15 |
| TOPIC / KEEPTOPIC / TOPICLOCK | Private saved policy and stamped runtime topic are distinct; restore only through an authorized new update |
| MLOCK / SYNC / CLEAR modes | Compute ordered current-state changes through reused mode operations; do not broadcast corrective loops from every node |
| ENTRYMSG / OPNOTICE / GUARD / FANTASY | Deterministic projection and one responsible emitter; no replayed greets or fantasy commands during snapshot |
| PEACE / PRIVATE / RESTRICTED / SECURE | Enforce through public policy at origin/current owner, including remote clients; missing cache is not an allow |

**N-REQ-088 — One authority action.** A global service command is executed exactly once in its authority context, not once by every node forwarding the request. All outcomes return through the original bounded request context. Preserve current multi-line HELP/LIST output through streamed reply parts.

**N-REQ-089 — Global versus local channel services.** A command on `&` stays at its home daemon, using local registered-channel tables and global authenticated account policy. Never send local-channel names/ACLs in global requests, policy images, NAMES, or topology diagnostic payloads. Local delegated ChanServ replies are not global authority writes.

**N-REQ-090 — Account setting semantics.** Reuse secure-connection, no-greet, never-op, hide-status/usermask/quit, enforcement, reservations and grouped-nickname logic. Replace direct dependence on `user.transport` for a remote caller with verified home-attested client security. A TLS ENP hop does not make a plaintext client secure. [SRC21]

**N-REQ-091 — Nick and account updates.** Check current UID and expected user revision/effective nickname at recovery execution. If the occupant changes, return STALE rather than killing the replacement. An account DROP can invalidate multiple home bindings through policy; it must not require the authority to directly access remote sockets.

**N-REQ-092 — Automatic service effects.** Home servers emit welcome/entry and local C2S notices for their own joins; the authority alone emits global policy-repair mutations. Snapshots and status re-materialization are not fresh user joins. Keep a clear effect classification so a retry, merge or same-value policy image cannot resend email, memos, greetings or enforcement.

**N-REQ-093 — MLOCK correction.** Extend the existing reconcile helper into decision plus committed domain changes. Do not call `reconcile_and_broadcast` during a retryable transaction with real sends. When a winning channel incarnation invalidates previous runtime fields, the authority may reassert current persistent policy after the merge barrier, with fresh stamps. [SRC25]

A registered-user IDENTIFY result is applied by an authority-origin `user_action/account` request at the user home. The authority waits outside the state lock for that owner receipt before final service completion. The owner generates account numerics, ACCOUNT notifications and its UserProjection; the service reply must not generate a duplicate 900/901. LOGOUT may be executed by the owner directly. Policy invalidation removes effective grants immediately in each reachable node; the home clears an obsolete stored binding and publishes its new revision when appropriate. New grants never originate from a peer cache or client tag.

### Startup data consolidation

Before enabling global services on previously independent servers, choose the authoritative dataset and explicitly migrate/deduplicate registrations, grouped aliases, access entries, channel ownership and memos. Do not make a network link itself perform account database merge. Preserve displaced datasets as backups until an operator has reviewed the migration. Non-authority nodes may retain their local `&` registration records, but must not execute stale global service jobs.

<a id="native-section-19"></a>

## 19. SASL, pre-registration, and authentication work

Keep the currently implemented PLAIN and ECDSA-NIST256P-CHALLENGE mechanisms and their actual validators. Move the reusable authentication engine out of a purely local command path; do not reimplement their cryptography as an ENP feature. [SRC26]

Reserve UID at local connection admission but do not export a user before IRC registration completes. The local SASL session is identified by local connection generation, reserved UID, attempt ID, mechanism and exact authority NodeRef. It is not a globally visible UserProjection.

The `sasl` method uses `phase` equal to `start`, `step` or `abort`. `mechanism` is present on every request and must equal the attempt's original mechanism. `data` is null for start/abort and the concatenated C2S SASL Base64 text for step, excluding the final `+` terminator. The authority runs the existing mechanism decoder exactly once; JSON adds no second authentication encoding. `client_info` contains `secure_client`, `realhost`, `address` and configured client-certificate fingerprint or null; it is supplied only by the home server and never copied from an untrusted client tag.

The home server applies existing C2S 400-byte fragment handling, final `+`, abort, retry count and 16,384-byte aggregate bound. It forwards complete logical mechanism messages rather than requiring an ENP round trip for each 400-byte C2S fragment. The authority keeps bounded per-attempt mechanism state and answers with a method payload:

`{"sasl":"continue"|"success"|"failure"|"aborted","data":string|null,"binding":Binding|null,"code":string}`. Continuation data is the Base64 mechanism challenge text, or the empty string for an empty challenge rendered as C2S `AUTHENTICATE +`; terminal replies use data null.

Only success with a real validated binding can authenticate. A continuation's challenge is fragmented back to C2S by existing rules. The JSON `reply.done` closes that method call, not necessarily the entire SASL attempt. Unknown SASL result values are rejected, never mapped to success.

**N-REQ-094 — Authentication gate.** Advertise SASL/mechanisms according to actual authority reachability, configured mechanism enablement and the local client's transport policy. CAP state remains local. On authority loss cancel affected attempts and publish capability changes through the existing CAP machinery without inventing login success.

**N-REQ-095 — Attempt isolation.** Reject wrong authority boot, unknown UID/attempt, stale step, mismatched mechanism, response after abort/QUIT/CAP END, or data beyond the limits. Each accepted attempt terminates at most once. Reserved UID data is not announced by the network snapshot.

**N-REQ-096 — Success commit.** Revalidate connection, attempt and relevant account/policy revision after slow hashing/challenge work, then update the owner's binding and emit current C2S numerics. Publish a UserProjection only if IRC registration is complete; otherwise include the established binding in the eventual first introduction. Never emit duplicate 900/903 from two independent code paths.

**N-REQ-097 — Sensitive transport.** Every hop is TLS, but a trusted forwarding daemon can see routed SASL/service credentials. ENP/1 is not end-to-end encrypted between the client home and authority. Do not log, trace or retain authentication payloads in persistent outboxes or generic request error dumps. Use transient sensitive queues and erase them on termination.

**N-REQ-098 — Bounded expensive work.** Use a bounded worker pool for password/public-key verification, outside the network state lock. Return BUSY rather than allowing unlimited CPU/memory jobs. Persistent maintenance retries are not authentication retries.

Abort signals may be lost in a split; the authority's attempt deadline still frees the state. A late successful worker result must recheck its now-cancelled attempt before changing any user or policy.

<a id="native-section-20"></a>

## 20. Existing C2S commands, queries, and operator control

The pinned `Command.names/0` is the source of the implemented C2S inventory. Every name must map to one row below and to regression tests; this table does not permit dropping a current feature during migration. [SRC02]

| Commands | ENP integration |
|---|---|
| PASS, USER, CAP, WEBIRC | Remain local connection admission/negotiation. Never forward connection passwords or gateway secrets. Publish only validated effective identity |
| AUTHENTICATE | Local framing/attempt limits plus authority authentication, as section 19 |
| NICK | Owner requested-name update, deterministic effective-name projection, notifications and registered-mode recomputation |
| JOIN, PART | Shared admission and complete owner global membership replacement; `&` scope remains local |
| MODE | Existing parser/rules, typed stamped channel/status fields or owner user update; preserve all current modes |
| TOPIC | Local query or stamped compound update; persistent topic policy separate |
| NAMES, LIST | Query the local reachable view, including logical GUARD presentation and existing privacy; never fan out and concatenate duplicate results |
| WHO / WHOX, USERHOST, ISON | Local reachable view; appropriate privacy and computed identity, with explicit service endpoints |
| WHOIS | Replicated public attributes locally; query target owner for truly local idle/security/detail. Keep one end marker and valid labeling |
| WHOWAS | Current local historical view or explicit server query; no global history replication claim |
| PRIVMSG, NOTICE, TAGMSG | Origin admission, routing, recipient-home private filters, tags, echo and error correlation |
| INVITE, KICK | Owner-directed guarded operation, then authoritative effect/receipt; invitation notification separate |
| AWAY, SETNAME | Owner projection update; generate C2S notifications only for negotiated capabilities |
| CHGHOST | Authorize existing C2S operation, route owner-directed identity change where target is remote; never overwrite source real identity accidentally |
| ACCEPT, SILENCE | Recipient-home state; resolve network identities and clean up unreachable references; no private-list burst |
| MONITOR | Subscriptions stay local; derived network nickname/service-presence changes trigger notifications |
| PING, PONG | Client heartbeat remains local; ENP heartbeat is a different session protocol |
| QUIT, KILL | Home teardown; remote kill is a guarded owner request; split teardown removes reachability instead of forging quits |
| LUSERS, USERS | Separate local connection and network presence counts, per existing command meaning |
| ADMIN, INFO, MOTD, STATS, TIME, TRACE, VERSION | Local behavior retained; explicit server-target forms use `query`, subject to target permissions/limits |
| OPER | Authenticate against local operator configuration; publish global oper state, not its password or a new remote login account |
| WALLOPS, OPERWALL, GLOBOPS | One audience-scoped network message; existing local recipient filtering and formatting |
| REHASH, RESTART, DIE | Local controls retained; remote method exists only under explicit target-server ACL; no raw code execution |

**N-REQ-099 — Query allowlist.** The `query` method permits ADMIN, INFO, MOTD, STATS, TIME, TRACE, VERSION, WHOIS and WHOWAS, plus internal owner-only idle/detail variants of WHOIS. It must not accept mutating commands. Public WHO/NAMES/LIST/ISON/USERHOST stay local unless a separately documented C2S form requires a particular server.

**N-REQ-100 — Source and numeric safety.** Remote response items may display the responding server/service, not an arbitrary spoofed known server. Whitelist numerics/commands by query. The requester connection is resolved from the pending operation, not any target name in reply parameters. Unknown/late numerics never create automatic error loops.

**N-REQ-101 — Current-context authorization.** Private STATS/TRACE/WHOIS detail is authorized at the responding server. A remote oper is not automatically a local administrator. Return only the fields permitted by current privacy/ACL policy; forwarding nodes do not enrich a reply with hidden data.

**N-REQ-102 — Remote admin.** Allowed admin actions are `rehash`, `restart`, `shutdown`, `enable_edge`, and `disable_edge`. Default deny. Exact NodeRef, original authenticated operator UID, current privilege and origin SID allowlist are required. `restart`/`shutdown` acknowledge acceptance before closing, not successful completion of a future boot. No file path, shell command or arbitrary module/MFA is accepted.

### Small intentional operator additions

Add local operator `LINKS`, `CONNECT <configured-neighbor>` and `SQUIT <direct-neighbor> [reason]` if not already present in the implementation checkout. LINKS reports actual reachable topology with the application's privacy policy. CONNECT enables/retries the existing configured edge: a child connects to its parent; a parent enables admission and reports that it is awaiting its child, not that it initiated a socket. SQUIT disables/closes that direct edge until explicitly re-enabled. Remote enable/disable uses the finite admin method and the target's ACL. These commands never create a different parent or arbitrary outbound destination.

Extending the C2S numeric registry for these operator replies is legitimate new functionality. It does not justify copying another daemon's entire remote-administration command set.

<a id="native-section-21"></a>

## 21. Failure handling, cleanup, and lifecycle

| Failure | Required outcome |
|---|---|
| Bad TLS/hello/profile | Close without publishing any reachable state; suspend retries for permanent faults |
| Invalid frame/schema/owner direction | Fence link, log a redacted protocol fault, prune disconnected component |
| Link EOF/timeout/writer error | Remove exact edge nonce and all newly unreachable sessions; preserve local clients and reachable peers |
| Failure during snapshot | Remove partial imported component, abort staging and merge markers; no rollback of unrelated committed changes |
| Old callback after reconnect | Ignore because generation/nonce/boot no longer match |
| Slow output queue | Backpressure, then explicit link close at hard budget; never drop a state update selectively |
| User local socket crash | One home-owned quit and all relevant cleanup; other clients remain |
| Output drain crash with uncertain writes | Close affected ENP sessions before restarting/draining; never replay uncertain chat |
| Ordering/state-owner integrity lost | Stop dependent links, invalidate boot, rebuild safe transient state; disconnect sessions that cannot be reconstructed |
| Services authority lost | Cancel pending authority operations; keep last complete policy and existing sessions under the explicit partition contract |
| Interrupted persistent service action | Recover existing durable data/jobs; return unknown outcome when success cannot be established |

**N-REQ-103 — Terminal teardown.** Mark closing before processing more queued frames. A process monitor, socket callback, admin split and timeout may race, but cleanup and local departure happen at most once per edge/UID generation. Clear pending repairs, requests, SASL work, private lists and indexes according to their ownership.

**N-REQ-104 — Split propagation.** The detector sends one `topology.remove` for the exact failed edge to its still-reachable neighbors. Each receiver validates the endpoint/edge and recomputes reachability. Generate local C2S departures, optionally grouped with existing client BATCH support; do not leak these C2S batches onto ENP.

**N-REQ-105 — Counter and channel cleanup.** Update local/global counts and nickname projections consistently. Removing unreachable memberships can empty a channel; apply its lifetime/guard policy. Expire invites and local ACCEPT references safely. Never operate on a new connection because a nickname/PID field was reused.

**N-REQ-106 — Reconnect starts over.** Fresh TLS, hello nonce, edge ID, sequence numbers and full snapshot. No parser buffers, pending replies, retry journal of chat or old session state are inherited. Node boot changes invalidate every home-owned UID from the old boot.

**N-REQ-107 — Graceful shutdown.** Stop new admissions and new origin work, drain already committed bounded output in order, close links/clients within a configured deadline and stop jobs. Neighbor edge loss is the authoritative network removal even if the final close frame is lost. Do not wait indefinitely for peer/client acknowledgements.

**N-REQ-108 — Current schema on restart.** Validate the expected table attributes, table types and current schema identity before listeners. An incompatible schema aborts startup with an operator-readable error. This first release has no pre-release native database migration path. Never silently clear persistent tables to make a boot pass.

Logs and telemetry must distinguish authentication, configuration, protocol, resource, operator and transport failures. A reconnect loop is not recovery from a reproducible protocol bug.

<a id="native-section-22"></a>

## 22. Schema closure and processing rules

This section completes the field-level contract. It is normative, not a list of decisions left to the implementation agent. All examples and the machine-readable index are subordinate to these schemas.

### Field presence and identifiers

A listed field is required unless explicitly stated otherwise; nullable means the key remains present with JSON null. No arbitrary `options`, `extra`, `metadata`, nested table record, executable expression or unknown field is accepted. `network_id` is 1–64 ASCII letters/digits/dot/underscore/hyphen. `profile_hash` and edge IDs are 64 lowercase hexadecimal characters. Names and masks follow the application's finite validators and the profile's decoded-byte bounds. A request's `request_id`, a message's `message_id`, a ping's `token` and a `sync_id` use the 128-bit ID format in section 4. The C2S `msgid` tag may retain the current separate message-ID representation: generate it once, do not confuse it with the ENP routing message ID.

`semantic_revision` and `policy_schema_revision` are positive integers. Profile mode `context` is `user`, `channel` or `membership`; `argument_class` is `a`, `b`, `c`, `d` or `prefix`, following the current registry classes. User modes use `d`; membership status uses `prefix`. Hostnames are validated ASCII strings of at most 255 bytes; protocol error/method/role strings are at most 64 bytes. Byte-capable individual values have a hard 4,096 decoded-byte limit, in addition to their current C2S/business validator and aggregate frame bound; SASL is the explicit separately bounded exception. Existing Unicode text limits retain their application's counting semantics, not a silently changed byte-count meaning. Preexisting persistent values outside these ENP bounds require explicit validation/cleanup before network admission, never implicit truncation.

Hello has no optional capabilities map. Version, semantic profile and roster establish exactly which schemas are supported. There is no per-message downgrade or arbitrary unknown-optional-field rule in version 1.

### Request argument schemas

| Method | Exact `args` keys | Additional constraints |
|---|---|---|
| query | `command:string`, `params:[Bytes]`, `target_uid:ID\|null`, `view:"client"\|"owner_detail"` | At most 15 params; owner_detail is WHOIS only and requires a target UID owned by `to` |
| service | `service:"NickServ"\|"ChanServ"`, `arguments:[Bytes]`, `scope:"global"`, `channel:Bytes\|null` | First argument is the existing service verb; at most 512 logical arguments; local scope never sent on ENP |
| sasl | `uid:ID`, `attempt_id:ID`, `step:UInt`, `phase:"start"\|"step"\|"abort"`, `mechanism:string`, `data:string\|null`, `client_info:ClientInfo` | Start step 0; each subsequent accepted step increments by 1; abort is terminal, never a new mechanism |
| user_action | `action:string`, `target_uid:ID`, `value:ActionValue`, `reason:Bytes` | The closed action/value table below applies |
| invite | `invite_id:ID`, `inviter_uid:ID`, `target_uid:ID`, `channel:ChannelRef`, `expires_ms:UInt` | User actor must equal inviter; a service invite uses an authorized service actor and the authorizing requester as inviter |
| snapshot | `scope:"channel"\|"policy"`, `channel:Bytes\|null`, `for_uid:ID\|null` | Channel scope requires channel; policy requires both other keys null; channel repair target is the appropriate owner/current route |
| admin | `action:"rehash"\|"restart"\|"shutdown"\|"enable_edge"\|"disable_edge"`, `neighbor_sid:SID\|null`, `reason:Bytes` | Neighbor only for edge actions; must be a configured direct neighbor |

`ClientInfo` is exactly `secure_client:boolean`, `realhost:string`, `address:string`, `client_certfp:string|null`. A client certificate fingerprint, when present, is lowercase SHA-256 DER hex; it is not the certificate of the ENP link. SASL `data` is the assembled Base64 text described in section 19, with the existing aggregate limits. Mechanism-defined NUL bytes may appear only after the existing SASL decoder runs privately at the authority. They never enter a raw IRC text serializer or a generic public policy field.

| user_action.action | Exact value | Execution and guards |
|---|---|---|
| kill | null | Target home terminates the exact session; reason required, requester must have current explicit kill authority |
| kick | `{"channel":ChannelRef,"join_id":Positive}` | Target home rechecks current membership ID and requester's channel privilege/policy, then removes it |
| part | `{"channel":ChannelRef,"join_id":Positive}` | Privileged forced part, not a foreign user pretending to issue PART |
| join | `{"channel":Bytes,"key":Bytes\|null}` | Service/admin permission required; home runs the explicit forced-join domain path; allocate a fresh join ID |
| nick | `{"nick":string}` | Owner checks target revision and requested/effective-name conditions; ordinary local collision rejection still applies unless a preceding authorized recovery removed the occupant |
| host | `{"displayhost":string}` | Authorized visible-host change only; not permission to rewrite real address/realhost |
| ident | `{"ident":string}` | Authorized effective-ident change using the same validator; no transport modification |
| account | `{"binding":Binding\|null,"response_request_id":ID\|null}` | Only the configured NickServ authority can install a new binding. The owner validates current policy/attempt, changes its projection and generates login/logout effects. A response ID must belong to that same UID and initiating service request |
| oper | `{"enabled":boolean,"role":string\|null}` | Grant only an existing locally allowed role; disable requires role null; no remote credential/account creation |

`guards` is always an object with these nullable keys: `actor_uid`, `actor_user_rev`, `actor_join_id`, `target_user_rev`, `target_join_id`, `channel`, `policy_epoch`, `policy_revision`. UID/revisions must match their actor/args when used. Required guards for kick/part are exact ChannelRef and target join ID. User identity/kill/oper actions require current target user revision; source authorization must be revalidated even if that revision still matches. Service-recovery operations also supply policy epoch/revision. Values absent from an operation's guard contract are null, not a wildcard bypass. Revision checks can reject conservatively after an unrelated state change; that is a safe STALE result, not grounds for silently removing the guard.

A global service performing an operation based on a user's request must revalidate its original requester before originating the trusted service action. Service actor privileges do not retroactively authorize the originating user. User commands submitted directly by a user actor are revalidated at the execution point.

### Reply schemas and correlation

Non-streamed action receipts use `payload = {"items":[],"result":object|null}`. `items` contain only structured C2S replies defined in section 16; result is a method-specific finite object. Query/service replies can stream items across contiguous parts, with `done` true only on the last part. Failure payloads use `{"items":[],"error":{"code":string,"message":Bytes}}`, or include the specific permitted C2S error items instead of a duplicate generic client error. Do not send both formats as two independent terminal results.

For query owner_detail, result is `{"uid":ID,"signon_ms":Positive,"idle_ms":UInt|null,"secure_client":boolean}`; null idle means hidden/unavailable according to policy. This does not expose realhost/address without an independently permitted client query. For user_action/invite/admin, result is `{"accepted":true}` or, after a synchronous state mutation, `{"accepted":true,"owner_rev":UInt}`. Restart/shutdown acceptance is not proof that the restart/shutdown completed. Private-message OK uses items empty/result null; a rejection contains only applicable message-error items.

SASL uses its exact method payload in section 19 instead of items/result. Snapshot replies use the explicit stream below. A peer cannot choose a payload type unrelated to the pending method. An unsolicited reply is discarded with bounded diagnostics; a malformed reply to an active request is a protocol fault, never interpreted as another command.

Channel snapshot reply payloads have phases:

1. `{"phase":"begin","scope":"channel","channel":Bytes}`.
2. `{"phase":"rows","rows":[Row...]}` for that channel's header, fields, list slots and current status. At most 256 rows per page. A specifically requested `for_uid` may add that home's current `user.put` and full `memberships.put`; it may not mutate a different user's owner data.
3. `{"phase":"end","scope":"channel","rows":UInt,"exists":boolean}` as final part. `exists=false` still permits the latest owner membership set to reconcile an in-flight removal. Count rows and validate dependencies before declaring repair complete.

Only the reply's authenticated request context admits historical shared register stamps. A channel reply cannot import topology, account policy, other channels' register state, or arbitrary user-owned data. If the latest full membership set references another legitimately missing channel, coalesce another bounded repair; a cycle or repeated inability to satisfy dependencies is a fault, not infinite buffering.

Policy snapshot phases and cache rows use the exact shapes in section 17. The snapshot's revision is a consistent cut, not the revision observed after formatting all pages. `done` is false for begin/rows and true for end. A successful transport or single page is not snapshot completion.

### Policy transaction batches

`policy.change` is a **single authority transaction batch** with `epoch`, `revision`, and `changes`. `changes` is an array of `{entity,key,value}` objects, where value null deletes. All objects in this batch apply atomically and revision advances once. This replaces any temptation to publish a partially updated account/alias/channel transaction. A private-store change that produces no public policy difference does not advance this public revision.

Up to 256 changed objects may fit in one normal state frame. If an authority transaction's projection exceeds either count or byte budget, `changes` is null: an invalidation of the cached revision, requiring a new complete policy image. Keep the old complete view for existing sessions, mark it not grant-ready, and fetch an image at least as new as the invalidation. Do not emit partially applied oversized deltas or silently split a transaction into independently usable policy versions. Later contiguous deltas are bounded and queued behind this image; budget exhaustion triggers a fresh request or explicit unavailability, never a permissive empty view.

**N-REQ-109 — Atomic public policy.** Change the private store, stable account IDs/auth epochs, public-policy revision and output intent together. A failed transaction exposes neither new authorization nor a revision gap. Apply all small-batch objects together at receivers. Oversized invalidations cannot confer new privileges until a complete current image is installed.

### Row equality, provenance, and stale presentation

For equal `user.put.rev`, compare the complete owner projection after canonical validation. For equal `memberships.put.rev`, compare **the membership entries**, not `cause`: a snapshot may replace the historical cause with `sync`. A duplicate does not replay presentation. For channel registers, compare stamped values, including list setter/time or compound topic where they are part of that value. Local last-received timestamps, caches, counters, effective nick and rendering output are not owner payload equality fields.

A valid committed channel change can arrive after its user actor disappeared on another branch. If the actor is known, validate that it belongs to the asserted source route. If it is no longer known, an authenticated origin may carry its already-committed channel field/status/list change with that actor retained only as attribution; render an origin-server fallback when a safe public mask is unavailable. This narrow rule never permits unknown-user requests, new authentication, service impersonation, private message spoofing or unrestricted metadata grants.

Merge markers are authenticated exporter annotations, not permissions. `merge.begin` is itself a live state row; following replay rows carry the matching merge context, and `merge.end`/`abort` close it. Historical owner rows still require a known matching home reachable through the sender's exported component. Historical channel stamps need not name a still-live server, but their data are restricted to the requested/imported state scope. Bound active merge contexts and clear them on split.

**N-REQ-110 — Dependencies and staging.** User introduction precedes its owner membership set; channel headers precede fields/status in a supplied snapshot. Live cross-origin ordering can leave a membership/field/status dependency briefly missing: retain only a bounded per-channel repair context and associated event order. Do not create blank channels, discard accepted removals, or expose unresolved state as synchronized. A missing owner user that cannot be explained by a valid teardown race is a link fault.

**N-REQ-111 — Atomic frame application.** Validate a state frame's schema and all allowed source classes before mutations. Apply its coupled changes in one short transaction or reject the entire malformed frame. Logically stale rows can be no-ops within a valid frame; malformed rows cannot leave the other rows partially committed.

A ChannelRef with a well-formed old birth time is not rejected merely because it is old. A new locally created birth uses the clock policy. Check excessive future times against the configured skew bound, but do not normalize a rejected time to zero or select a new winner unilaterally.

### Logical service availability

GUARD policy may retain a runtime channel while its authority is unavailable, but it does not make the logical ChanServ endpoint online. Render presence/ISON/MONITOR according to actual ready availability. Restore visible service presence once, without creating a fake UID/PID, when the authority returns. This distinguishes channel retention from transport-backed user presence.

<a id="native-section-23"></a>

## 23. Security and resource obligations

The trust boundary is an authenticated daemon and its declared subtree, not a claim that every received field is safe. A peer bug must not exhaust the BEAM, turn data into code, grant service authority, or silently corrupt a table.

**N-REQ-112 — Closed decoding.** Reject duplicate JSON keys before map construction; reject invalid UTF-8, trailing JSON values, depth/element overflow, invalid integer tokens, invalid Base64, forbidden characters and noncanonical identities. The maximum JSON-value count is 8,192 for ordinary frames and 65,536 for a permitted topology frame. The topology exception changes neither recursion depth nor the 256-node roster limit.

**N-REQ-113 — Aggregate quotas.** Account for parser buffers, JSON expansion, output groups, socket mailboxes, snapshot rows, delta queues, policy staging, pending requests, duplicate-result caches, authentication work and repair contexts. Per-frame limits alone are insufficient. Distinguish protocol maxima from lower local operational capacity; a capacity refusal is explicit.

**N-REQ-114 — Backpressure before allocation.** Use bounded admission and demand for the socket-owner and output-drain mailboxes. A GenServer mailbox is not automatically bounded. Avoid decoding a large next frame when accepted work cannot be queued; pause reads where the transport permits it. At the hard limit close/prune the link rather than skip required state.

**N-REQ-115 — Failure codes.** ENP close/error codes are finite: AUTH, PROFILE, TOPOLOGY, FRAME, SCHEMA, ORIGIN, VERSION_CONFLICT, DEPENDENCY, CLOCK, RESOURCE, TIMEOUT, OPERATOR, TRANSPORT, INTERNAL. Text is bounded and secret-safe. Authentication errors must not reveal which private credential/account exists. Codes classify faults; they do not authorize automatic retry of mutating requests.

**N-REQ-116 — Secret-safe output.** Never log full incoming/outgoing frames by default. Redact service/SASL arguments, memo/private messages, certificate keys, channel keys, tokens, private account settings and raw error dumps. Existing debug output in shared paths must be audited even when input logging was already hardened. Use command/method, lengths, source SID and failure category, not secrets.

**N-REQ-117 — Local credentials stay local.** An OPER request verifies only at the client's home. A global +o flag describes active operator state but does not create an operator credential on another node. Remote destructive permission uses the receiving node's explicit ACL. Peer configuration, private Mnesia paths and executable config files cannot be modified by generic ENP data.

**N-REQ-118 — Side effects at their authority.** Global email/expiration/memo jobs execute at the configured services authority; local channel jobs execute only locally. Do not replicate the job queue. Recheck ownership and stable IDs after a retry, and do not send a notification to a newly created account/user that reused a name.

**N-REQ-119 — Clock and version safety.** Use monotonic time for local timers and UTC milliseconds for explicitly physical fields. Logical stamps use the observed max counter and local increment, not wall-clock last-write-wins. Reject counter overflow and fail closed before wrap. A malicious peer can send large well-formed clocks; impose diagnostics/admission policy without rewriting an accepted version into a different order.

The network can lose messages during a split and must not automatically replay them. A service mutation can commit before a response is lost; return UNKNOWN_OUTCOME rather than falsely claiming rollback. These are intentional distributed-system limits, not bugs to hide with retries.

<a id="native-section-24"></a>

## 24. Efficiency, measurements, and clean implementation boundaries

**There is no benchmark-based claim that this design is faster than TS6 or SpanningTree.** Its expected engineering benefit is less compatibility code and clearer ownership on this repository. JSON size, complete membership replacement, node-local commit serialization and remote-action round trips are measurable costs.

| Mechanism | Expected benefit | Cost / measurement |
|---|---|---|
| Per-link supervised process and bounded queue | Independent connection failure and manageable transport state | Mailbox/backpressure, scheduler reductions and large binary lifetime |
| Existing Mnesia indexes | Reuse data access and atomic updates | Index maintenance and write-lock contention |
| Complete per-user membership replacement | Simple removals/rejoin recovery, no membership tombstone protocol | O(current memberships) serialization on JOIN/PART; bounded by profile |
| Versioned field maps | One reusable merge operation for modes/topic/lists/status | Retained version/tombstone memory |
| Configured tree | Unique routes, no mesh deduplication/election | Hub availability and network distance |
| Typed JSON | Safe standard codec and useful diagnostics | Bytes, encode/decode CPU and allocation relative to line protocols |
| Single short local ordering section | Clear snapshot/commit/output correctness | Limits parallel mutation throughput; parsing and workers remain concurrent |
| Logical services endpoints | Preserve existing application structure | Explicit non-user presence/query handling and one authority dependency |

**N-REQ-120 — No per-remote-user process.** A remote user is data with an origin route, not a socket-owning process. Keep processes for genuine ownership/lifecycle: connections, connector tasks, output drain and bounded slow work. Do not make every row, frame type, field or pure helper a GenServer.

**N-REQ-121 — Reuse before abstraction.** Prefer a few cohesive modules under the existing server boundary. A finite dispatch map and ordinary functions are sufficient for frame/row types. Do not create an adapter framework for unimplemented protocols, a plugin system, a generic event bus, a replicated database, or a separate C2S copy merely because this document has multiple sections.

**N-REQ-122 — Profile hot paths.** Measure steady private/channel message routing, local rendering, JSON codec, register merge, membership replacement and snapshot under churn. Use realistic recipient capabilities, tags, channel lists and service policies. Count bytes/link, allocations, p50/p95/p99 latency, throughput, mailbox and queue peaks, table sizes, GC and scheduler/lock contention.

**N-REQ-123 — Regression baseline.** Run existing single-server tests/benchmarks with network mode off and on without peers. Establish a recorded baseline before optimizing. Set project acceptance budgets from those measurements; do not invent a universal maximum users/second in the spec or normalize performance failures away.

**N-REQ-124 — Burst isolation.** Encode immutable chunks outside locks; do not rescan the entire user/channel database for each peer message. Cache next-hop and per-channel branch membership as derived state with correct invalidation. A burst cannot permanently starve live client output, auth cancellation or heartbeat handling.

**N-REQ-125 — Complexity review.** Each new production module/table/process must have a short reason identifying what existing component cannot own that responsibility. A new small handler file is not inherently bad, but duplicated permission/mode/account logic or two authoritative state copies is a rejection criterion. Prefer deleting obsolete experimental adapters only after verified replacement and an explicit diff review.

Use bounded binaries/iodata at transport output where the existing stack supports them. Do not retain a tiny sub-binary that unnecessarily pins a huge snapshot buffer indefinitely. These are implementation optimizations, not a new wire format. Changing codecs or compression requires evidence and a new protocol/profile version, not a premature second path.

<a id="native-section-25"></a>

## 25. Implementation sequence, repository edits, and cleanup

This sequence is an execution plan, not permission to stop at a partial handshake. Preserve unrelated work in the agent's branch, and finish all applicable release gates before claiming ENP/1 support.

| Stage | Main existing areas | Deliverable and evidence |
|---|---|---|
| 0. Inventory | command/mode registry, config schema, tables, services, tests | Record checkout SHA, actual command/setting inventory and current test baseline; compare unpublished changes |
| 1. Identity | User/UserChannel and associated repositories/helpers | UID/locality migration, composite membership keys, local PID wrappers, nil-identity regression tests |
| 2. Shared commit/effects | Connection, Dispatcher, ResponseContext, mode/service helpers | One transaction/effect boundary and ordered output path, with forced retry/abort tests and C2S regression coverage |
| 3. Domain versions | Channel/list/topic/membership models and pure operations | Typed stamps, incarnation reset, owner revisions, deterministic nickname projection; permutation/idempotence tests |
| 4. Config/transport | Existing Config.Loader/Schema/Resources, listeners | Strict roster/profile/TLS, dedicated framed listener and outbound connector sharing one session engine |
| 5. Basic network | Small native Network/Session/Codec/Sync responsibilities | Topology, bidirectional snapshots, live state, exact generation teardown and multi-hop routing |
| 6. Client delivery | Existing command helpers/Dispatcher/privacy/filter modules | Private/channel delivery, tags, echoes, global view queries, invitations and owner-directed operations |
| 7. Services | Existing service handlers/private tables/jobs plus policy view | Authority routing, full cache/revision updates, all account/channel/memo settings, local & delegation, no secret replication |
| 8. Authentication | Authenticate and existing PLAIN/ECDSA helpers | Bounded remote engine calls, pre-registration identity, cancellation, unavailable authority and race tests |
| 9. Operations | REHASH/admin/lifecycle/test support | Safe config changes, backup/restore, shutdown, recovery, diagnostics and operator guide |
| 10. Release | Tests/bench/CI/docs | Multi-process tree fixtures, fault injection, resource/performance report, schema-boundary guide and requirement coverage |

### Concrete integration rules

Retain `handle(user,message)` at the C2S boundary. Where a handler mixes admission, mutation and sending, extract a narrowly named domain function with an origin context and an effect result. The S2S path invokes committed state application or a separately authorized owner request, not the original client handler with a fabricated PID. Existing formatters continue to build local `%Message{}`/`StandardReply` values.

Retain the single `ModeRegistry`; attach semantic descriptors where its existing finite maps can drive both configuration and ENP validation. Keep list/key parsing consistent with C2S. Public register application should be a typed function beside the existing mode engine, not a second parser that disagrees on parameter consumption.

Retain the configured loader entry point and resource preparation. Add all ENP options to its existing schema and update offline validation/reload restrictions. Never accept an ENP JSON object as an executable Elixir configuration file. Certificate private keys and Mnesia files remain local filesystem resources.

Retain the current private service stores. Introduce a small policy-view facade whose read methods explicitly return public policy types. Do not silently redirect mutating `RegisteredNicks`/`RegisteredChannels` repository calls to a cache. Separate `#` global authority from `&` local authority at the command boundary and inside maintenance job eligibility.

Update `DataCase` teardown to kill only validated local connection processes; remote rows have no PID. Update `MessageCase` helpers to observe committed output and asynchronous completion without removing order assertions. Use independent OS processes and independent database directories for integration daemons; do not use a shared Mnesia cluster as the test harness. [SRC28]

**N-REQ-126 — Existing experimental code.** Inspect any TS6/InspIRCd/native work already generated by the agent. Reuse proven generic transport/domain/test code when it satisfies this contract. Remove or disable superseded negotiation/command paths so the listener cannot accept multiple ambiguous dialects. Do not delete unrelated repository features or tests to reduce file count.

**N-REQ-127 — First-release schema boundary.** Document that ENP/1 starts with the current schema in a fresh Mnesia directory, validates the directory before listeners, and refuses an incompatible existing directory. There is no pre-release native UID/PID import, table replacement, or rollback procedure to exercise. Once a native schema has shipped, a later version must add a separate offline backup, validation, migration, and rollback contract before changing its persistent identity representation.

**N-REQ-128 — Requirement evidence.** Maintain a compact implementation ledger mapping every N-REQ, N-TEST and release gate to code/test locations and results. A missing dependency or discovered source bug is recorded with a corrective test, not hidden by a successful no-op. The agent may change proposed module names, not protocol semantics, without an explicit versioned decision.

**N-REQ-129 — Documentation deliverables.** Include operator configuration, certificate provisioning/rotation, topology limitations, service dataset consolidation, privacy boundaries, policy partition behavior, the first-release schema boundary and debugging instructions. State which tests were actually executed, which performance workloads were measured and any remaining failures. A future released schema change must add its own tested upgrade and rollback procedure.

<a id="native-section-26"></a>

## 26. Acceptance test catalog

These are required **implementation acceptance cases**, not test results from preparing this document. Each case needs state assertions, correct wire effects, C2S assertions, cleanup checks and negative/security assertions where applicable. A two-node handshake does not replace multi-hop or failure tests. Run with actual independent daemons and the current C2S regression suite.

### Transport and topology

| ID | Case | Required evidence |
|---|---|---|
| N-TEST-001 | Mutual TLS success | Two configured neighbors with valid CA, pins and names authenticate; no client User row is created. |
| N-TEST-002 | Wrong certificate identity | Wrong CA, pin, hostname, expired certificate or missing client certificate fails before publishing state. |
| N-TEST-003 | Handshake input role | A normal IRC client sending PASS/USER/CAP to ENP never becomes a server; ENP frames on C2S are not elevated. |
| N-TEST-004 | Remote endpoint | peername supplies actual peer address; sockname supplies local bind address; quotas/logs use the correct one. |
| N-TEST-005 | Partial TLS initialization | Early TLS failure, close and timeout callbacks safely handle uninitialized session data. |
| N-TEST-006 | Tree profile validation | Reject cycles, multiple roots, missing parent, duplicate SID/name and more than 256 nodes before listeners. |
| N-TEST-007 | Child-only initiation | Only child connects to parent; parent CONNECT enables/waits for that declared child without creating another edge. |
| N-TEST-008 | Concurrent connection attempts | A second live/reserved edge is refused without deleting the established generation. |
| N-TEST-009 | Duplicate live boot | A different boot for a still-reachable SID is rejected; old generation is pruned before replacement. |
| N-TEST-010 | Stale edge removal | An old edge nonce removal cannot affect a new socket between the same SIDs. |
| N-TEST-011 | Arbitrary configured shapes | Exercise chain, star and balanced branching tree, with clients at root, hubs and leaves. |
| N-TEST-012 | No implicit failover | Hub loss partitions precisely its downstream reachability; no code silently reparents or forms a cycle. |
| N-TEST-013 | Hello order | Both endpoints send hello independently; neither waits for a reciprocal sync ACK before sending its own snapshot. |
| N-TEST-014 | Clock boundaries | 5 seconds is not an over-5 warning; over 5 warns; over 30 refuses; no clock is rewritten. |
| N-TEST-015 | Profile hash determinism | Different map/roster iteration orders produce the identical fixed-array hash; semantic differences reject. |
| N-TEST-016 | Secret exclusion from profile | Pins, passwords, private keys and address/local-capability preferences do not appear in shared profile data. |
| N-TEST-017 | Certificate rotation | Explicit overlap succeeds; wrong/removed pin fails; no verification bypass on retry. |
| N-TEST-018 | Reconnection backoff | Transient error backs off and is bounded; permanent profile/auth faults pause until explicit corrective action. |

### Codec and schema

| ID | Case | Required evidence |
|---|---|---|
| N-TEST-019 | Split frame at every byte | Every boundary of length header/body produces exactly the same frames as unsplit input. |
| N-TEST-020 | Coalesced frames | Multiple complete frames and an incomplete tail preserve order without decoding a partial frame. |
| N-TEST-021 | Oversized length before body | A disallowed length is rejected before allocation/receipt of its advertised payload. |
| N-TEST-022 | Phase-specific budgets | Hello, message, request, ordinary state and topology limits are independently enforced. |
| N-TEST-023 | Duplicate object keys | Reject duplicate t, origin, guard, binding and nested policy keys before map overwrite. |
| N-TEST-024 | JSON shape and trailing data | Reject arrays/scalars at top level, second JSON values, missing required keys and extra fields. |
| N-TEST-025 | Depth and aggregate counts | Ordinary/topology value ceilings and depth limits fail boundedly without process-wide exhaustion. |
| N-TEST-026 | Numeric grammar | Reject fractional/exponent counters, negative values, overflow, invalid zero and numeric strings where integer required. |
| N-TEST-027 | Canonical IDs | Reject wrong alphabet, lowercase, padding, bad unused Base32 bits and IDs not decoding to exactly 16 bytes. |
| N-TEST-028 | Byte-preserving text | UTF-8 text, literal spaces and allowed non-UTF-8 Base64 wrappers round-trip exactly. |
| N-TEST-029 | Base64 input safety | Reject noncanonical padding/alphabet, huge decoded data and forbidden raw IRC CR/LF/NUL injection. |
| N-TEST-030 | SASL data boundary | SASL assembled Base64 is decoded once in the mechanism engine; decoded NUL never passes as raw IRC text. |
| N-TEST-031 | Per-link sequence | A gap/repeat n closes the faulty link; a forwarded valid frame gets a new local n, retaining semantic version. |
| N-TEST-032 | No atom/module creation | Fuzz command/type/key/ID values; atom count does not grow from unknown wire input and no code is loaded. |
| N-TEST-033 | Closed row schemas | Each row rejects wrong type, missing field and unauthorized target without partially applying sibling rows. |
| N-TEST-034 | No compression/ETF escape | Unadvertised compressed payload, Erlang external term and foreign IRC wire dialect fail explicitly. |

### Transactions and synchronization

| ID | Case | Required evidence |
|---|---|---|
| N-TEST-035 | Forced transaction retry | One accepted operation commits once; aborted attempts send no messages, disconnects, timers or email. |
| N-TEST-036 | Commit then drain crash | Uncertain outputs are not replayed blindly; affected link generations close and rebuild. |
| N-TEST-037 | Local output ordering | JOIN/introduction precedes chat, accepted last chat precedes QUIT and CAP ACK precedes capability transition. |
| N-TEST-038 | Snapshot coherent cut | Concurrent NICK/JOIN/PART/TOPIC/QUIT produces one consistent snapshot followed by every post-cut delta. |
| N-TEST-039 | Old output excluded | A newly attached link does not replay pre-cut chat or duplicate snapshot entities from an undrained old group. |
| N-TEST-040 | Simultaneous inbound/outbound sync | Both directions finish independently and track their own IDs/digests/ACKs. |
| N-TEST-041 | Page digest and counts | Wrong page index/count/raw-body digest fails; no ready declaration follows a partial snapshot. |
| N-TEST-042 | Snapshot dependency order | Topology before users; channel headers before fields; memberships before their status records. |
| N-TEST-043 | Empty and zero-member cases | Empty component, user without channels and guarded empty channel synchronize without invented users. |
| N-TEST-044 | Snapshot interruption | Cut transport at each stage; prune partial imported subtree, clear staging, preserve unrelated committed changes. |
| N-TEST-045 | Snapshot resource pressure | Exhaust staging/delta budgets and deadlines; close explicitly rather than declare partial state ready. |
| N-TEST-046 | Multi-hop merge annotations | Existing peers receive a bounded merge context before normalized rows and exactly one end/abort. |
| N-TEST-047 | Nested merge timing | A subtree joining while another link syncs does not trigger premature authority repair or missing completion. |
| N-TEST-048 | Missing-channel race | Last member leaves while another home joins; bounded channel repair supplies real state rather than blank channel. |
| N-TEST-049 | Repair target disappeared | Latest membership set/NOT_FOUND resolves absence; missing owner removes staged dependency. |
| N-TEST-050 | Invalid repair injection | A channel reply cannot import policy, topology or a foreign owner user/membership set. |
| N-TEST-051 | Repair amplification | Repeated requests coalesce under exact owner/channel/generation and enforce aggregate limits. |
| N-TEST-052 | Historical version import | An extinct historical register writer is allowed in scoped snapshot data, not as authority for new live grants. |

### Identity and membership

| ID | Case | Required evidence |
|---|---|---|
| N-TEST-053 | UID key migration | All lookups/deletes/indexes use UID for network identity; PID wrappers are explicitly local only. |
| N-TEST-054 | Nil PID self-check | Two different remote users with pid nil are never equal in privacy/self/permission checks. |
| N-TEST-055 | UID duplicate | A duplicate live UID is a fault, not an overwrite, nickname merge or implicit reconnect. |
| N-TEST-056 | Owner projection revision | Newer wins, older ignores, equal identical no-ops and equal contradictory fails. |
| N-TEST-057 | Pre-registration privacy | Reserved SASL UID/password/CAP state never appears in snapshots or global counts. |
| N-TEST-058 | Nickname concurrent claims | All arrival permutations of simultaneous claimants select smallest UID with injective fallback for others. |
| N-TEST-059 | Nickname automatic restoration | Winner leaves/changes; next claimant regains desired name only if still requesting it. |
| N-TEST-060 | Nickname case mapping | All configured equivalences group correctly; case-only spelling changes do not duplicate presence. |
| N-TEST-061 | Fallback namespace | Reject ordinary use/account registration of another generated name; own current fallback remains safe. |
| N-TEST-062 | Name swaps and local events | Notify vacating aliases before assignments; NAMES/MONITOR/+r agree and no simultaneous duplicate names appear. |
| N-TEST-063 | Pre-registration conflict | A pre-registered reservation cannot block a registered remote claimant; no fictitious global quit is emitted. |
| N-TEST-064 | Complete membership replacement | Omitted entries remove membership; empty set parts globals only; no old deletion log required. |
| N-TEST-065 | Membership equal revision cause | Snapshot cause sync with identical entries is idempotent and never replays a historical KICK. |
| N-TEST-066 | Rejoin generation | Same UID/channel after leave receives a strictly new join_id; old status/requests do not apply. |
| N-TEST-067 | Membership bound | Existing configured per-user limits and hard 128 ceiling are enforced before local admission/remote allocation. |
| N-TEST-068 | Remote KICK owner | Only target home commits removal, revalidating guards; requester waits before successful client notification. |
| N-TEST-069 | Delayed forced change | User nick/revision changes before a delayed kill/recovery request; return STALE, never target replacement session. |
| N-TEST-070 | Quit races | Socket close, explicit QUIT, kill and split crossing generate at most one local departure and correct counters. |

### Channels, modes and messages

| ID | Case | Required evidence |
|---|---|---|
| N-TEST-071 | Incarnation order | Older born_ms then smaller cid wins in both orders; losing modes/list/topic/status/invites reset as specified. |
| N-TEST-072 | Field merge algebra | All arrival permutations choose the same Stamp winner; unrelated fields never overwrite one another. |
| N-TEST-073 | Equal Stamp contradiction | Same version with different value fails; same value produces no relay or duplicate client event. |
| N-TEST-074 | Local clock regression | Topic/mode logical stamp still increases after a wall-clock step back; physical displayed time is separate. |
| N-TEST-075 | List deletion preservation | A retained newer removal defeats a stale add on reconnect; setter/time and canonical masks remain correct. |
| N-TEST-076 | Tombstone budget | Capacity rejects a new distinct slot before commit, still allows removal of an existing slot and never evicts silently. |
| N-TEST-077 | List lifetime limitation | After entire transient incarnation is forgotten, returning retained partition state can be accepted; no durable deletion promise. |
| N-TEST-078 | Status join guards | A mode for old cid/UID/join_id cannot grant op to a later membership. |
| N-TEST-079 | Topic clear | Explicit empty text is retained as a stamped value and survives snapshot/rejoin. |
| N-TEST-080 | Key and mode argument reuse | C2S +k/-k classes and validation remain current; ENP field application does not shift mode parameters. |
| N-TEST-081 | Registered nickname vs account | M/R checks use existing semantics distinct from settings.restricted; no grants from forged +r. |
| N-TEST-082 | Client TLS not peer TLS | Plaintext client behind TLS ENP fails secure-only policy; genuine TLS/WSS identity stays attested. |
| N-TEST-083 | Cloak import | Remote display host is preserved without recomputation using local secret; realhost privacy remains enforced. |
| N-TEST-084 | Delay and throttle semantics | Remote burst is not fresh local JOIN history; current +d/+j behavior is not replaced by another daemon algorithm. |
| N-TEST-085 | Distributed limits | Concurrent allowed joins can exceed local instantaneous count; replicas accept owner membership instead of diverging. |
| N-TEST-086 | Local ampersand channels | No & names, members, invitations, topics, ACLs or local service actions appear on ENP. |
| N-TEST-087 | Channel fanout | One ENP message per relevant branch irrespective of recipient count; no reflection or duplicate echo. |
| N-TEST-088 | Private recipient filters | Recipient-home ACCEPT/SILENCE/+g/R apply once; supported PRIVMSG errors return to correct context. |
| N-TEST-089 | NOTICE and TAGMSG errors | Do not create automatic error loops; TAGMSG with no deliverable tags is suppressed. |
| N-TEST-090 | Message identity and tags | Origin msgid/time identical across sender echo and all recipients; internal protocol data never becomes C2S tag. |
| N-TEST-091 | Trusted vs client tags | Client cannot supply account/bot authority; trusted network tags are not wiped by client-only sanitization. |
| N-TEST-092 | Labeled self-message | Existing self-delivery/echo distinctions remain, with one final labeled response and no premature ACK. |
| N-TEST-093 | Audience privacy | Private/secret/invisible/auditorium/status filtering protects local clients without omitting required network state. |
| N-TEST-094 | Invitation lifetime | Expiry is absolute, bind target/channel instance, notify once; no grant inherited by recreated channel. |
| N-TEST-095 | Stale source attribution | Committed channel update from a departed actor can apply under bounded origin fallback; unknown-user requests cannot. |

### Services and policy

| ID | Case | Required evidence |
|---|---|---|
| N-TEST-096 | Authority uniqueness | Global REGISTER/SET/MEMO runs at one authority; a leaf never writes a separate global account database. |
| N-TEST-097 | Public policy projection | Cache has exactly allowed fields; no password/hash/email/memo/pubkey/access-secret/PROPERTY/job dump. |
| N-TEST-098 | Stable account aliases | GROUP/UNGROUP share stable account ID; display name changes do not identify another account. |
| N-TEST-099 | Atomic policy transaction | Account/alias/channel updates for one public revision apply together or not at all. |
| N-TEST-100 | Private-only policy change | Private mutation without projection difference produces no unexplained public revision gap. |
| N-TEST-101 | Oversized policy invalidation | Null changes marks cache not grant-ready; complete newer image restores readiness without partial privilege exposure. |
| N-TEST-102 | Policy revision gap | Hold later deltas and fetch complete image; no permissive empty policy or silently skipped revision. |
| N-TEST-103 | Full image deletion | Object absent from complete image disappears; partial/duplicate-key/count-invalid image never replaces active view. |
| N-TEST-104 | Policy change during image | Queue bounded post-cut deltas, atomically switch image, then apply contiguous revisions. |
| N-TEST-105 | Peer cache vs authority | A peer cannot overwrite actual private authority data; different epoch/higher-than-restored rev triggers investigation. |
| N-TEST-106 | Authority partition | Existing sessions use declared cached view, new global writes/auth fail and pending operations cancel. |
| N-TEST-107 | Delayed revocation | Document/test revocation delay across partition; apply revocation on current policy without falsely promising instant global invalidation. |
| N-TEST-108 | Cold cache boot | No empty-registry admission when services enabled; peer synchronization/diagnostics can still bootstrap. |
| N-TEST-109 | Verified flag behavior | Preserve current service verification semantics; no blanket login ban invented by transport. |
| N-TEST-110 | IDENTIFY owner grant | Authority validates, owner installs binding, emits projection and one 900/account effect, then service completes. |
| N-TEST-111 | Logout and DROP | Invalidate effective binding/aliases and +r consistently across reachable users; no stale authorization after DROP. |
| N-TEST-112 | Nick recovery sequence | Authority validates ownership and current occupant; remote action receipt precedes reservation/recovery success. |
| N-TEST-113 | ChanServ ACLs | VAFST permissions, ACCESS levels and PEACE are reused at correct execution authority. |
| N-TEST-114 | MLOCK and topic policy | Pure decision plus fresh committed repair after merge, not correction loops on every replica. |
| N-TEST-115 | Fantasy exactly one origin | Existing consumed !command is not also broadcast and rerun at every server. |
| N-TEST-116 | GUARD availability | Logical service visible only while authority ready; policy channel retention does not falsely show online service. |
| N-TEST-117 | Local channel delegate | & registration/ACL/service jobs remain local and never acquire global account-writer privileges. |
| N-TEST-118 | MEMO and email | Persistent content is private; no duplicate creation/delivery caused by snapshot/retry/remote response loss. |
| N-TEST-119 | Language and reply preference | Existing translations/MSG settings applied at authority; no full preference database required at leaves. |
| N-TEST-120 | Dataset consolidation | Independent preexisting databases require explicit migration; link admission does not choose/merge passwords automatically. |

### Requests, SASL and operations

| ID | Case | Required evidence |
|---|---|---|
| N-TEST-121 | Method allowlists | query/service/admin cannot execute arbitrary commands, modules, shell strings or configuration paths. |
| N-TEST-122 | Remote privileges | +o or source service text alone cannot bypass target ACL or the exact configured authority identity. |
| N-TEST-123 | Request duplicate | Same ID/content within horizon is one operation/result; contradictory reuse fails; expired/crashed horizon does not claim durable exactly once. |
| N-TEST-124 | Uncertain mutating result | Commit then lose reply; report UNKNOWN_OUTCOME and do not auto-retry on reconnect. |
| N-TEST-125 | TTL and queue time | Elapsed forwarding/queue time reduces budget; a stale request cannot execute after its local deadline. |
| N-TEST-126 | Reply sequence and boot | Wrong responder/part/boot/context fails or discards as specified; new nickname occupant never receives it. |
| N-TEST-127 | Streamed response limits | Large HELP/LIST/query result streams contiguous bounded parts and one terminator, with backpressure. |
| N-TEST-128 | SASL PLAIN success | Current credential decoder/policy used, correct binding and one C2S terminal result, no duplicate numerical side effects. |
| N-TEST-129 | SASL ECDSA success | Existing challenge/key/signature checks retained; invalid signature never gains binding. |
| N-TEST-130 | SASL fragments | 400-byte exact multiples/final plus/aggregate 16384 bounds are handled locally without one ENP round trip per fragment. |
| N-TEST-131 | SASL cancellation | CAP END, abort, disconnect, authority split and timeout cancel attempt; late worker success cannot log in. |
| N-TEST-132 | SASL wrong attempt | Wrong UID/attempt/step/mechanism/authority/boot and malformed terminal token cannot confer account state. |
| N-TEST-133 | Hashing concurrent change | Credential/policy changed while Argon2/ECDSA ran; revalidate and refuse stale grant outside critical section. |
| N-TEST-134 | Unavailable authority CAP | SASL/mechanism advertisement and CAP notifications reflect actual eligible auth availability. |
| N-TEST-135 | Admin shutdown acknowledgement | Report acceptance before closing when possible, not successful future restart; no infinite drain wait. |
| N-TEST-136 | Atomic REHASH | Invalid config leaves prior revision intact; structural changes require planned transition, not reinterpretation midlink. |
| N-TEST-137 | Released-schema persistence | Deferred until ENP/1 has a released persistent schema; it does not require importing a pre-release native database. |
| N-TEST-138 | Real independent daemons | Integration tests use separate OS processes/database directories/TLS sockets, never a hidden shared cluster. |
| N-TEST-139 | Supervision generation fencing | Crash socket, connector, writer, drain, state and worker separately; old callbacks cannot act on replacements. |
| N-TEST-140 | Resource abuse | Slow peer, huge policy, stalled partial frame, repair storm, queued queries and auth flood remain bounded. |
| N-TEST-141 | No S2S regression | With network disabled, current transports/services/client tests still pass without ENP serialization overhead. |
| N-TEST-142 | Performance evidence | Report measured workloads and queue/latency/CPU/memory/lock data; do not substitute hypothetical star ratings. |
| N-TEST-143 | Long-running churn | Repeated splits/reconnects/nick changes/modes/service activity leaves no ghost entities, leaked requests or growing stale queues. |
| N-TEST-144 | Release audit | Every required frame/row/method has an implementation and failure test; no successful no-op or undocumented dialect survives. |

<a id="native-section-27"></a>

## 27. Deterministic wire and model fixtures

The following are deterministic, public **wire/model fixtures**, not production secrets or a captured running-daemon transcript. IDs are canonical 128-bit Base32. Example addresses/domains are documentation values. The n sequence illustrates one already-synchronized output stream; a real session has sent its preceding sync frames and must continue their sequence instead of resetting to 1.

### Profile fingerprint and edge identity

For the example two-node roster, the fixed-position profile array is:

```json
[
  "elixircd-native",
  1,
  1,
  "example-net",
  [
    [
      "alpha",
      "alpha.example.test",
      null
    ],
    [
      "beta",
      "beta.example.test",
      "alpha"
    ]
  ],
  "alpha",
  "rfc1459",
  true,
  [
    30,
    10,
    50,
    200
  ],
  [
    "#",
    "&",
    64,
    20,
    300,
    255,
    20,
    100,
    100,
    100
  ],
  [
    [
      "channel",
      "C",
      "d",
      1
    ],
    [
      "channel",
      "I",
      "a",
      1
    ],
    [
      "channel",
      "M",
      "d",
      1
    ],
    [
      "channel",
      "O",
      "d",
      1
    ],
    [
      "channel",
      "R",
      "d",
      1
    ],
    [
      "channel",
      "T",
      "d",
      1
    ],
    [
      "channel",
      "b",
      "a",
      1
    ],
    [
      "channel",
      "c",
      "d",
      1
    ],
    [
      "channel",
      "d",
      "c",
      1
    ],
    [
      "channel",
      "e",
      "a",
      1
    ],
    [
      "channel",
      "i",
      "d",
      1
    ],
    [
      "channel",
      "j",
      "c",
      1
    ],
    [
      "channel",
      "k",
      "b",
      1
    ],
    [
      "channel",
      "l",
      "c",
      1
    ],
    [
      "channel",
      "m",
      "d",
      1
    ],
    [
      "channel",
      "n",
      "d",
      1
    ],
    [
      "channel",
      "o",
      "prefix",
      1
    ],
    [
      "channel",
      "p",
      "d",
      1
    ],
    [
      "channel",
      "r",
      "d",
      1
    ],
    [
      "channel",
      "s",
      "d",
      1
    ],
    [
      "channel",
      "t",
      "d",
      1
    ],
    [
      "channel",
      "u",
      "d",
      1
    ],
    [
      "channel",
      "v",
      "prefix",
      1
    ],
    [
      "channel",
      "z",
      "d",
      1
    ],
    [
      "membership",
      "o",
      "prefix",
      1
    ],
    [
      "membership",
      "v",
      "prefix",
      1
    ],
    [
      "user",
      "B",
      "d",
      1
    ],
    [
      "user",
      "H",
      "d",
      1
    ],
    [
      "user",
      "R",
      "d",
      1
    ],
    [
      "user",
      "Z",
      "d",
      1
    ],
    [
      "user",
      "g",
      "d",
      1
    ],
    [
      "user",
      "i",
      "d",
      1
    ],
    [
      "user",
      "o",
      "d",
      1
    ],
    [
      "user",
      "r",
      "d",
      1
    ],
    [
      "user",
      "s",
      "d",
      1
    ],
    [
      "user",
      "w",
      "d",
      1
    ],
    [
      "user",
      "x",
      "d",
      1
    ]
  ],
  1
]
```

Its compact UTF-8 encoding uses no indentation or spaces after punctuation. SHA-256 is `47a7ebcd0fd1185a3d1570fc743776da7a6df442097b988d391adca8d0726b74`. Alpha and beta have their own boot/nonces; the example edge ID is `30bb851f1fe161ce2a90d4977d8368cc268f1390340f0e5ec0800da46e158db2`.

### Hello and ordinary output

#### Alpha hello

```json
{
  "t": "hello",
  "protocol": "elixircd-native",
  "version": 1,
  "network_id": "example-net",
  "profile_hash": "47a7ebcd0fd1185a3d1570fc743776da7a6df442097b988d391adca8d0726b74",
  "sid": "alpha",
  "boot": "AAAAAAAAAAAAAAAAAAAAAAAAAE",
  "name": "alpha.example.test",
  "nonce": "AAAAAAAAAAAAAAAAAAAAAAAAMQ",
  "time_ms": 1789948801000
}
```

#### Registered user introduction

```json
{
  "t": "state",
  "n": 1,
  "origin": {
    "sid": "alpha",
    "boot": "AAAAAAAAAAAAAAAAAAAAAAAAAE"
  },
  "actor": {
    "server": "alpha"
  },
  "context": {
    "kind": "live"
  },
  "changes": [
    {
      "kind": "user.put",
      "user": {
        "uid": "AAAAAAAAAAAAAAAAAAAAAAAABI",
        "home": {
          "sid": "alpha",
          "boot": "AAAAAAAAAAAAAAAAAAAAAAAAAE"
        },
        "rev": 1,
        "requested_nick": "Rafael",
        "signon_ms": 1789948801100,
        "ident": "rafael",
        "realhost": "client.example.test",
        "displayhost": "elixir-abc.example.test",
        "address": "192.0.2.10",
        "secure_client": true,
        "client_certfp": null,
        "modes": [
          "x"
        ],
        "oper_role": null,
        "away": null,
        "realname": "Rafael",
        "binding": null
      }
    }
  ]
}
```

#### First channel join and explicit creator status

```json
{
  "t": "state",
  "n": 2,
  "origin": {
    "sid": "alpha",
    "boot": "AAAAAAAAAAAAAAAAAAAAAAAAAE"
  },
  "actor": {
    "user": "AAAAAAAAAAAAAAAAAAAAAAAABI"
  },
  "context": {
    "kind": "live"
  },
  "changes": [
    {
      "kind": "channel.ensure",
      "channel": {
        "name": "#elixir",
        "born_ms": 1789948800000,
        "cid": "AAAAAAAAAAAAAAAAAAAAAAAADY"
      }
    },
    {
      "kind": "memberships.put",
      "uid": "AAAAAAAAAAAAAAAAAAAAAAAABI",
      "home": {
        "sid": "alpha",
        "boot": "AAAAAAAAAAAAAAAAAAAAAAAAAE"
      },
      "rev": 1,
      "entries": [
        {
          "channel": "#elixir",
          "join_id": 1,
          "joined_ms": 1789948801200
        }
      ],
      "cause": {
        "action": "join",
        "channel": "#elixir",
        "join_id": 1,
        "by": {
          "user": "AAAAAAAAAAAAAAAAAAAAAAAABI"
        },
        "reason": ""
      }
    },
    {
      "kind": "member.status",
      "channel": {
        "name": "#elixir",
        "born_ms": 1789948800000,
        "cid": "AAAAAAAAAAAAAAAAAAAAAAAADY"
      },
      "uid": "AAAAAAAAAAAAAAAAAAAAAAAABI",
      "join_id": 1,
      "mode": "o",
      "enabled": true,
      "stamp": [
        1,
        "alpha",
        "AAAAAAAAAAAAAAAAAAAAAAAAAE"
      ],
      "setter": {
        "user": "AAAAAAAAAAAAAAAAAAAAAAAABI"
      }
    }
  ]
}
```

#### Channel message

```json
{
  "t": "message",
  "n": 3,
  "origin": {
    "sid": "alpha",
    "boot": "AAAAAAAAAAAAAAAAAAAAAAAAAE"
  },
  "actor": {
    "user": "AAAAAAAAAAAAAAAAAAAAAAAABI"
  },
  "message_id": "AAAAAAAAAAAAAAAAAAAAAAAAZA",
  "sent_ms": 1789948801300,
  "target": {
    "channel": {
      "name": "#elixir",
      "born_ms": 1789948800000,
      "cid": "AAAAAAAAAAAAAAAAAAAAAAAADY"
    },
    "minimum_status": null
  },
  "command": "PRIVMSG",
  "text": "Hello from ElixIRCd.",
  "tags": {},
  "request_id": null
}
```

#### Ping

```json
{
  "t": "ping",
  "n": 4,
  "token": "AAAAAAAAAAAAAAAAAAAAAAAAZE"
}
```

The compact ping body is **55 bytes**. Its four-byte length prefix is hex `00000037`. Do not include a line terminator in this body or length.

### Required model outcomes

| Inputs | Expected result |
|---|---|
| Same requested nickname, UIDs `AAAAAAAAAAAAAAAAAAAAAAAABI` and `AAAAAAAAAAAAAAAAAAAAAAAACQ` | `AAAAAAAAAAAAAAAAAAAAAAAABI` wins requested name; the other uses `GAAAAAAAAAAAAAAAAAAAAAAAACQ` |
| Winner later quits, loser still requests the name | Remaining claimant obtains requested name; notify once and recompute +r |
| Channel field stamps `[7,"alpha",bootA]` and `[8,"beta",bootB]` | Counter 8 wins independently of arrival order |
| Equal counters, different SIDs | Lexicographically greater SID wins the field register |
| Old list add stamp 4, removal stamp 5 | Removal remains materialized after old add is received again |
| Same name, smaller born_ms, different cid | Earlier channel incarnation wins and resets losing channel-specific state |
| Target rejoined with join_id 8; delayed kick expected 7 | Return STALE; new membership remains |
| Equal membership revision/entries, snapshot cause sync | No membership change or historical KICK replay |
| Partial policy image missing final page | Previous complete policy remains; no new grant readiness |

Model checks demonstrate specific algorithm/encoding properties only. They do not prove the full distributed implementation correct, test OTP sockets, or measure ElixIRCd performance.

<a id="native-section-28"></a>

## 28. Release gates and implementation-agent handoff

The document is a proposed contract. The implementation is complete only when these gates have evidence, not because all modules compile or the parser has high coverage.

| Gate | Acceptance condition |
|---|---|
| N-GATE-01 | All current C2S commands, modes, services, settings and transports are mapped to implemented native behavior; no hidden feature deletion or successful no-op. |
| N-GATE-02 | Every frame, row, request method/action and policy object has a closed schema, real authorization/application path, bounded encoding and negative tests. |
| N-GATE-03 | Local transaction retries/aborts and output-order tests pass; no socket/email/job effect escapes an aborted attempt. |
| N-GATE-04 | Current-schema bootstrap, composite membership indexes and nil-PID safety are exercised; backup/restore and offline migration are required only after a native schema has shipped. |
| N-GATE-05 | Independent TLS-linked daemons pass initial burst, concurrent churn, channel repair, graph split/rejoin and stale-generation tests in branching trees. |
| N-GATE-06 | Account/SASL/private service operations, owner binding grants, policy full-image deletion recovery and authority partition/fencing tests pass. |
| N-GATE-07 | Message privacy, origin identity, tags, echo, queries, labeled responses and exactly one logical service execution pass cross-node tests. |
| N-GATE-08 | Parser/resource/fuzz/authentication/authorization tests cannot cause unbounded memory/atoms, forged source grants, generic remote code execution or silent accepted-state loss. |
| N-GATE-09 | Performance and single-server regression measurements are recorded with real workloads, bounds and machine/build configuration; limits are reported honestly. |
| N-GATE-10 | Each new component has a responsibility/reuse justification; duplicate domain engines, experimental ambiguous adapters and fake remote PIDs are absent. |
| N-GATE-11 | Operators have tested configuration/TLS/topology/service-consolidation/upgrade/recovery documentation and know the fixed-tree and partition limitations. |
| N-GATE-12 | The conformance report maps requirement/test IDs to evidence and lists failures; compatibility is declared only as ENP/1 between tested ElixIRCd builds, never other IRCds. |

### Instructions to the implementation agent

Read sections 1–5 before editing the protocol. Inspect the actual checkout and keep existing changes. Use this document as the standalone ENP/1 contract; do not combine it with earlier TS6/InspIRCd specifications. Preserve the existing project architecture unless a concrete boundary described here needs refactoring.

Implement in the stages in section 25 and keep the requirement ledger current. Reuse canonical data, mode registry, configuration loader, pure permission helpers, service business logic, client renderers and tests. Add new code only for genuinely new ownership, transport, synchronization, routing, versioning and asynchronous completion responsibilities. Do not implement automatic clustering, foreign protocol compatibility, a generic plugin system, speculative durable messaging or extra IRC features to satisfy an imagined upstream requirement.

Run the current test suite plus the native cases. Test failures cannot be resolved by removing required behavior, weakening origin guards, disabling TLS, enabling a permissive compatibility mode, or changing the expected merge winner without a reviewed semantic revision. Stop a deployment on corrupt state or an unsupported profile rather than preserving a misleading healthy link.

Deliver code, current-schema bootstrap, automated tests/fixtures, operator documentation, a measured performance report and a precise completion report. No automated certificate setup, database migration, daemon execution or production deployment is implied by receiving this specification.

<a id="native-section-29"></a>

## 29. Source registry and evidence boundaries

Repository statements refer to the pinned commit below. ENP/1 schemas, algorithms, limits and topology choices are **proposed project decisions**, not claims about an existing implementation or an external IRCd protocol. Static review covered the cited integration paths and selected handlers, not an executed certification of the entire repository.

External library documentation is current reference material, not an implicit instruction to upgrade dependencies. During implementation use the repository's lockfile/runtime versions and record the OTP/Elixir versions actually tested. Source registry paths may be integration locations even when only their surrounding entry-point behavior was reviewed; do not infer unseen code from this index. No private account data or repository modifications were performed to prepare this specification.

### [SRC01] Reviewed default-branch commit and feature inventory

https://api.github.com/repos/faelgabriel/elixircd/commits?per_page=1

https://github.com/faelgabriel/elixircd/commit/b48ac1387383b246aa2ce0c0149e19741be74108

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/README.md

### [SRC02] Finite C2S command registry

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/command.ex

### [SRC03] Existing finite mode registry

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/mode_registry.ex

### [SRC04] Current canonical User model

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/tables/user.ex

### [SRC05] Current channel mode classes and application

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/commands/mode/channel_modes.ex

### [SRC06] Local Mnesia setup and persistent/transient classification

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/utils/mnesia.ex

### [SRC07] Current validated configuration entry point and integration paths

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/config/loader.ex

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/config/schema.ex

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/config/validator.ex

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/config/resources.ex

### [SRC08] Current service/memo feature inventory

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/README.md

### [SRC09] Current PID-keyed membership table

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/tables/user_channel.ex

### [SRC10] User and membership repositories

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/repositories/users.ex

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/repositories/user_channels.ex

### [SRC11] C2S lifecycle, transactions and output

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/server/connection.ex

### [SRC12] Current C2S dispatcher, tag and echo handling

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/server/dispatcher.ex

### [SRC13] Application and listener supervision

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd.ex

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/server/listeners.ex

### [SRC14] ThousandIsland C2S socket handler and endpoint lookup

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/server/tcp_listener.ex

### [SRC15] Current deployment settings and limits

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/config/elixircd.exs

### [SRC16] Local nick admission, aliases and presence effects

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/commands/nick.ex

### [SRC17] Message privacy, auditorium and registered-only helper

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/utils/message_filter.ex

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/utils/protocol.ex

### [SRC18] JOIN, policy restoration and current throttle behavior

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/commands/join.ex

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/repositories/user_channels.ex

### [SRC19] Private/channel messaging and fantasy command dispatch

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/commands/privmsg.ex

### [SRC20] Current process-local synchronous response context

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/server/response_context.ex

### [SRC21] Canonical account, security, preferences and notification helpers

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/utils/nickserv.ex

### [SRC22] Registered account settings

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/tables/registered_nick/settings.ex

### [SRC23] Registered channel settings

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/tables/registered_channel/settings.ex

### [SRC24] Channel account ACLs and VAFST permissions

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/utils/chanserv/flags.ex

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/tables/registered_channel_access.ex

### [SRC25] Existing mode-lock decision and broadcast helper

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/utils/chanserv/mode_lock.ex

### [SRC26] Current SASL mechanisms, limits and credential verification

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/commands/authenticate.ex

### [SRC27] Elixir version, stack and quality tooling

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/mix.exs

### [SRC28] Existing test support and setup

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/test/support/data_case.ex

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/test/support/message_case.ex

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/test/test_helper.exs

### [SRC29] Persistent polled job queue

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/job_queue.ex

### [SRC30] Integrated logical service dispatcher

https://github.com/faelgabriel/elixircd/blob/b48ac1387383b246aa2ce0c0149e19741be74108/lib/elixircd/service.ex

### [OTP01] Mnesia transactions, retry semantics and side effects

https://www.erlang.org/doc/apps/mnesia/mnesia_chap4.html

### [OTP02] Erlang processes and signal ordering

https://www.erlang.org/doc/system/ref_man_processes.html

### [OTP03] ThousandIsland socket APIs, peername and sockname

https://hexdocs.pm/thousand_island/ThousandIsland.Socket.html

### [OTP04] Built-in Elixir JSON API

https://hexdocs.pm/elixir/JSON.html

### [OTP05] OTP JSON decoding callbacks and binary-key representation

https://www.erlang.org/doc/apps/stdlib/json.html

### [OTP06] OTP TLS/SSL connection and certificate validation APIs

https://www.erlang.org/doc/apps/ssl/ssl.html
