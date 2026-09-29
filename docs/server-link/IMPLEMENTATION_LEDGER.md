# Native server linking: implementation ledger

This ledger tracks the user-requested network federation started from `main`
at `3327f93`. It does not define a smaller release target. The S2S
implementation is incomplete until separate ElixIRCd servers can share one
coherent IRC network and `mix quality` passes.

## Pause handoff (2026-09-29)

The user paused implementation after this snapshot and asked for a local WIP
branch and commit, without a push. Resume only on a new request. The
`server_links` configuration remains disabled by default; this work is not
approved for production use. Do not substitute Erlang distribution or shared
Mnesia for the authenticated socket protocol, and do not read the older local
S2S branch when resuming this implementation.

This incomplete snapshot belongs on the local
`feature/native-server-link-wip` branch, created from `main` at `3327f93`.
It is a WIP handoff, not a release; do not enable server links by default or
push it without a separate request.

Implemented in this worktree: a separate mutual-TLS listener and peer
handshake; a bounded, versioned JSON frame codec; origin routes, UID-based
remote users, staged snapshots and sequenced deltas; selected channel
identities, modes, lists and membership views; local-to-remote projection and
remote-to-local client events; network-aware user/channel queries; direct
messages with correlated results; channel messages; routed TOPIC, MODE, KICK
and INVITE mutations; replay windows and pressure guards. The details and
their limits are itemized below. Internal coordination and pending records
use typed structs where practical; JSON wire payloads remain maps at the
codec boundary.

Latest local evidence before pause:

- A no-listener run of server-link tests (excluding socket-dependent Hub and
  independent-process files) plus KICK, INVITE, PRIVMSG, NOTICE and BATCH
  command tests passed **344 tests**. The focused channel-message and BATCH
  slice passed **146 tests** after the last refactor. These runs do not prove
  TLS links or separate VM behavior.
- `MIX_OS_CONCURRENCY_LOCK=0 mix quality` passed formatting, Credo (no
  issues), Sobelow, dependency audit (no vulnerabilities reported), Doctor
  (100% documentation and spec coverage) and Dialyzer (zero errors). It then
  failed while starting the IRC listener with `:eperm`. The audit also
  reported a denied write to read-only `.git/FETCH_HEAD`. Therefore the
  full test and coverage gates are unproven and `mix quality` is **not green**.
- An earlier independent-process test had shown bidirectional user/channel
  propagation, direct messages and split cleanup through mutual TLS. Its
  subsequently added JOIN/PART, channel-message, adoption and netsplit
  assertions have not run under the current socket restriction. No current
  multi-VM claim rests on the no-listener harness.

The next coding target was an **atomic channel multiline wire envelope**.
The current client multiline collector waits until the whole local batch
validates before queuing outbound lines, but each line is still a separate
S2S frame. Capable remote recipients cannot reconstruct one atomic batch,
and a late Hub rejection can follow an already delivered local batch.
No multiline protocol edit was made after the pause request.

## Required boundary

- Every server owns its own Erlang VM and Mnesia database. The link uses only
  authenticated network sockets; it never joins Erlang nodes or shares Mnesia.
- A remote user has a home server and a stable network UID. It is data on other
  servers, never a fabricated local client PID, socket, CAP state, or timer.
- A channel retains its creator identity when another server adopts its
  timestamp. Metadata selection prefers that creator while it is present.
- Local Mnesia transactions may retry. Outgoing federation effects must happen
  only after commit and must be fenced by the current link generation.
- Reconnect must discard stale partial snapshots, messages, and route state.

## Current implementation

| Area | State | Evidence |
| --- | --- | --- |
| Separate S2S configuration, listener port, peer IDs and certificate pins | Partial | `server_links` schema, validator, loader and resource checks |
| TLS listener, outbound dial, peer authentication, single direct socket and retry | Partial | `ServerLink.Hub`, `ServerLink.Peer`, real TLS tests; pending handshakes capped at 32; a stalled peer is dropped at 1,024 queued outbound messages; old sockets close on coordinator restart |
| Bounded, versioned wire framing | Partial | Protocol version 14 validates control, route, PID-free user snapshots/events, channel state, identity-bound channel-message frames, correlated direct results for both PRIVMSG and NOTICE, routed TOPIC and metadata/list MODE requests/results, KICK and INVITE requests/results with target UID and closed result codes, and accepted INVITE notices with channel identity; peer greetings require matching case mapping. A snapshot declaration is capped at 100,000 aggregate records |
| Network topology and cycle rejection | Partial | Typed path-vector routes propagate direct and transitive users; a three-coordinator network test covers three-hop delivery and withdrawal. Initial and relayed snapshots are withheld from any neighbor already in the origin path, while deltas and user events use the same path guard. Topology rejections carry a wire reason and suppress reconnects until restart. One link coordinator accepts at most 4,096 remote origins; mesh convergence remains open |
| UID ownership, nick collision and global user directory | Partial | `UserPayload` and `Projector` assign local UIDs; projector state and local UID entries are typed structs. `Replica` retains cross-origin collisions by UID, rejects a live UID changing its registration time, and selects a deterministic nickname winner by registration time, server ID and UID. `NickReconciler` renames a local loser after committed remote snapshots and changes; the PID-free ETS directory exposes the selected remote claim. The winner and remote directory entries use typed structs. Concurrent local/remote claims still lack an atomic network-wide admission fence and independent-server convergence proof |
| Channel state, membership, modes, bans, topic, invites and timestamps | Partial | `ChannelPayload`, typed `ChannelState` snapshots and `Replica` stage and commit PID-free channel snapshots, including members, lists and invites. A local `ChannelIdentity` record preserves the creator on adopted channels and through rename; protocol version 14 carries it. `ChannelAuthority` returns a typed winner, selects the oldest creation timestamp and prefers the active creator on a tie; the named Hub publishes a committed read view with typed remote member and list/invite records. The view suppresses status and list authority from contributions with a different channel identity, follows remote profile changes and clears on split. `JOIN` adopts a remote-only channel with its selected creator, timestamp, topic and modes, without local creator +o. It checks effective network bans/exceptions, invite exceptions, remote member count for +l and recent remote members for +j, and sends NAMES with remote members. An aligned local adoption receives later selected remote mode and topic changes after replica commit and announces them to local members. When an older remote creation wins a collision, one Mnesia transaction replaces local identity and metadata, strips losing local member privileges and lists/invites, and announces the removals after commit. A newer remote creation does not overwrite an older local one; admission still races concurrent remote commits |
| Transaction-safe local event capture and delivery | Partial | `Projector` consumes committed Mnesia User and channel table events; abort was verified to emit no event. UID lookup refreshes committed user state, and delayed stale user events cannot restore an older profile. Channel changes send ordered atomic delta batches. A typed subscription limits queued projector messages to a consumer at 256 by default; overflow sends one typed signal and removes that subscription, and the Hub restarts its links for a fresh snapshot. The typed projector state also stops and restarts at more than 4,096 queued inbound messages by default, creating a new epoch and snapshot. Each channel change still scans all local channel tables; message counts do not impose an aggregate byte budget |
| Full burst, ordering, acknowledgement and replay after reconnect | Partial | User and channel snapshots stage atomically; live user events and channel delta batches require exact epoch/sequence. The remote replica limits each origin to 100,000 records and 64 MiB of estimated record payload, with a 256 MiB total across committed and staged origins; rejected changes leave committed state intact. A typed local `Snapshot` is checked against the same count and per-origin byte limits before link admission. A relay forwards deltas after commit; stream acknowledgement, byte-bounded projector and relay queues, and multi-origin replay remain open |
| IRC command and query behavior across servers | Partial | `NICK`, `ISON`, `USERHOST`, and `MONITOR` status check committed remote nicknames; `MONITOR` online/offline notifications follow remote arrival, rename, departure and snapshot replacement. `NAMES` merges remote members for named and all-channel queries, with secret/private and invisible-user filtering, cloaked hostmasks and timestamp-qualified status prefixes. `WHO` and `WHOX` include committed remote users in named, remote-only channel and mask queries, using replicated account, away, home-server and effective status data while respecting secret channels, invisibility, hidden operator status and auditorium visibility; remote IP and idle time are not synchronized. `WHOIS` reports a remote user's replicated identity, account, away status, home server and visible channels; remote idle time and metadata are not synchronized. `TOPIC` reads selected network metadata for remote-only and colliding channels while preserving local and selected secret restrictions. Remote authority writes now send a typed pending request over the authenticated UID route; the selected authority rechecks membership and +t status, applies the update transactionally, and returns a correlated result. TOPICLOCK still rejects remote users until global account authority exists; socket-level and independent-VM mutation tests remain open. Direct `PRIVMSG` and `NOTICE` reach real remote client PIDs over authenticated UID routes. A permitted remote `PRIVMSG` returns the recipient's replicated away message; destination `+R`, `+T`, and SILENCE restrictions have local enforcement tests. Committed member deltas and replacement snapshots emit remote JOIN, PART and status MODE to local channel clients, with extended-join and auditorium visibility. Remote and local channel metadata deltas recalculate status and auditorium visibility from the old and new selected views; the Hub strips losing local privileges before delivering new remote membership events and retains the prior membership view long enough to send the required PART to clients whose visibility was lost. MODE queries read selected network modes and creation time for local members, failing closed when the enabled directory is unavailable. MODE +b/+e/+I lists merge identity-matched local and committed remote entries into typed list records and fail closed when the enabled network directory is unavailable. MODE metadata and +b/+e/+I list writes on a remote selected authority now use typed request and pending records, send only parsed mutations (answering list queries and invalid characters locally), authenticate the UID route, recheck effective +o membership and channel identity at the authority, and apply bounded changes transactionally. List entries retain the remote actor mask as setter and leave the projector as PID-free records. Registered channels and status/service modes are rejected conservatively pending global services and membership authority. Synthetic Hub tests cover route authentication, TTL, correlation, timeout and immediate pending TOPIC/MODE rejection when the selected route disappears. Committed list deltas and replacement snapshots announce effective +b/+e/+I changes to local clients, suppressing duplicate masks already held locally; route loss announces their removal. Socket-level and independent-VM MODE mutation proof remains open. Local `PART` uses all actual local memberships to decide channel deletion and always acknowledges the departing user in auditorium mode. Remote user events emit deduplicated NICK, AWAY and QUIT to visible shared-channel clients; AWAY also reaches extended MONITOR watchers, and route loss sends a QUIT. The wire user removal lacks the client's original quit reason, so clients receive a generic reason. Remaining remote MODE status mutations, other commands, channel echo against stale authority, and full history/tag semantics remain open |
| Channel message delivery | Partial | Ordinary `PRIVMSG` and `NOTICE` queue a typed outbound message after local transaction commit. The Hub rechecks the sender UID, channel identity, current selected modes, mute lists and local recipients before sending a frame, local delivery or echo. An invalidated queued message sends a PRIVMSG error and leaves NOTICE silent. Local delivery checks the local Mnesia channel identity. Status targets accept case-equivalent channel names; selected channel modes and `+U` recipient filtering apply. The typed multiline collector queues linked lines only after the whole local batch succeeds and the Hub skips duplicate local delivery; remote peers still receive separate line frames without atomic multiline semantics. Multiline local delivery and echo still precede the Hub's final check, so a late view change can invalidate an already echoed batch. A bounded 4,096-ID/120-second replay window suppresses duplicate and stale frames. A concurrent local mutation after the Hub's final Mnesia read can still race delivery. Atomic cross-server multiline, channel history and complete tag semantics, authoritative permissions on every home server, stronger replay ordering, and the new independent-VM message assertions remain open |
| Services authority, account/SASL and persistence policy | Open | Current services operate on local Mnesia only |
| Split cleanup, recovery, pressure bounds and hostile-peer tests | Partial | Split cleanup, wrong network/case mapping/certificate, topology cycles, an unannounced message sender, and a stalled outbound peer have focused tests; burst recovery and memory bounds remain open |
| Independent-process integration and complete quality gate | Partial | `IndependentProcessTest` starts a second Elixir VM with its own Mnesia directory and proves bidirectional user/channel propagation, direct `PRIVMSG` delivery both ways, `NOTICE`, `ISON`, `USERHOST`, transaction abort, and split cleanup over mutual TLS. JOIN/PART, bidirectional channel-message, adopted remote JOIN and netsplit QUIT assertions were added but have not run under the current socket restriction; `mix quality` is not green |

KICK now resolves a remote nickname to its authenticated origin and UID and
queues a typed request only after the observed local transaction commits. The
Hub now holds its route, replica, pending mutation, replay and read-index
fields in typed `State` and `Indexes` structs, including the KICK pending and
replay records. The
target home rechecks the remote actor's effective +o membership, the channel
identity, the target's real local membership, and registered-channel policy
before deleting that membership in Mnesia. Its correlated result is checked
against the pending actor, target UID, channel, home epoch and route; a bounded
typed replay cache retains the first decision. Both local and remote KICKs
attach a committed, membership-scoped cause to the member-removal delta, so
other servers announce KICK instead of PART. Marker deletion checks the exact
record to avoid deleting a newer KICK. Marker keys include the target's join
time; the projector removes obsolete records at startup and after each channel
refresh. A removal followed by a rejoin before projection emits separate KICK
and JOIN events. Both the source and target home reject a remote KICK on a
locally registered channel pending a shared services authority. Real socket
delivery and concurrent cross-server KICK
ordering remain to be proved.

INVITE now routes a typed request to the recipient home after the source
transaction commits. The recipient home verifies the selected channel identity,
the remote inviter's effective membership and invite-only privilege, and the
real local recipient before writing a local invitation and delivering INVITE.
The source sends IRC 341 and current AWAY only after the authenticated,
correlated result. A bounded typed replay cache, timeout and route-loss cleanup
protect this flow. Both homes announce accepted invitations to their local
invite-notify members; the recipient home captures its recipients inside the
invite transaction, and the source suppresses notifications if the selected
channel identity changed while awaiting the result. A typed accepted-invite
notice now reaches members on third-party servers after the correlated result,
or after a local-to-local invitation commits. The notice is route- and epoch-
authenticated, bounded by TTL and a replay window, and qualified by the
selected channel creator and timestamp. The recipient home skips its own
notification when relaying the notice. A remote-only invitation appears in the recipient's
INVITE list before JOIN adopts the channel. Invitations to registered channels
fail closed until services authority is shared. The legacy parameter order and
socket-level multi-VM behavior remain open.

Direct `PRIVMSG` and `NOTICE` now use typed outbound and pending records.
The recipient home returns a version 14 result for an accepted message, a
policy rejection, or a missing local UID. An accepted `PRIVMSG` result carries
the recipient's current AWAY text; the source sends IRC 301 only after that
result arrives. The source validates the result's route, epoch, UID and request
ID before clearing the pending entry. A missing `PRIVMSG` recipient returns IRC
401; no route, queue capacity, route loss or a 30-second timeout returns IRC
437. A late result after expiry is ignored. `NOTICE` uses the same internal
correlation and timeout cleanup but sends no IRC error or AWAY reply. A `silent`
result suppresses SILENCE and CTCP errors. A `+R` rejection returns IRC 477,
while a `+g` rejection returns IRC 716 for `PRIVMSG`. An `ok` result means the
recipient home dispatched the message; it is not an acknowledgement from the
recipient socket. Source-side echo now waits for that authenticated `ok` for
both commands. The recipient home stores a dispatched direct message, and the
source stores it after an authenticated `ok` while its sender remains connected.
Both use a typed remote home/UID identity rather than a nickname or untrusted
local account. A live remote nickname resolves to that UID for
CHATHISTORY, and both homes use the authenticated message ID and send time for
storage and delivery. Offline remote nickname lookup, account continuity,
reconnect replay and complete tag semantics remain open. These cases and
three-server result transit have synthetic Hub tests. A typed, bounded recipient-home replay
cache now remembers the first direct-message decision for 120 seconds and at
most 4,096 IDs, so an exact repeated frame receives the same result without
delivering twice; reuse of that ID with different content is rejected. The
updated wire exchange has not been tested between independent VMs in this
sandbox.
The user snapshot and direct result accept up to 1,600 UTF-8 bytes of AWAY
text, matching the configured ceiling of 400 Unicode characters.
`ACCEPT` now stores a typed remote home and UID in a local Mnesia table. The
nickname index also supports UID lookup for list display across nick changes.
The recipient home checks that exact identity for `+g`, and QUIT, snapshot
replacement and route loss revoke permissions for departed UIDs. The source
now routes `+R` and `+T` cases to the recipient home instead of rejecting them
from potentially stale replicated modes. A rejected remote direct message no
longer emits a source echo. Ordinary channel messages recheck selected
network modes and effective mute masks in the Hub before local echo. A
multiline batch can still be locally delivered before the Hub's final check.
Remote direct `PRIVMSG` and `NOTICE` inside a client multiline batch now
reject the whole batch before any line is queued to S2S. An atomic multiline
wire envelope and remote channel multiline delivery still need implementation.
Authenticated late `TOPIC` and `MODE` results also leave the link intact after
their pending entries have been cleared; mismatches against active entries
still reject the peer frame.
`LUSERS` now reads a typed, coordinator-owned count snapshot that includes
committed remote UIDs, transitively routed servers, direct peers and selected
network channels. It preserves local client and unknown-connection counts and
reports unavailable statistics if a configured network has no coordinator
view. The global historical maximum remains a lower bound based on the local
peak and current global count; a network-wide peak counter is still open.
The server-link supervisor now starts before client listeners, so its indexes
are ready before a client can receive registration numerics.

The disabled default in `config/elixircd.exs` preserves existing standalone
behavior while the federation data plane is being built. Direct links now
exchange user and channel records. Direct user messages worked across two
independent processes in the earlier TLS test; command coverage remains
partial as detailed in the table.
`LIST` now includes remote-only channels and counts committed remote members
alongside local members. It uses selected network topic and creation metadata
for filters and hides a channel when either its selected or local state is
private or secret to an outsider.
Local bursts are admission checked, and a stalled Hub subscriber is forced to
resynchronize when its projector mailbox reaches the configured message limit.
An overloaded projector inbox restarts the supervised projector and Hub, so
new links receive a fresh epoch and snapshot. Aggregate memory pressure is
still not bounded by bytes. Local nickname
assignment can race an incoming remote snapshot before both homes converge. Do not enable server links
for production until these and the remaining federation contracts are closed.
`JOIN` adopts a remote-only channel with the selected network identity and
enforces the effective network lists, global +l count and recent remote member
contributions to +j. Later selected
remote mode and topic changes update an aligned local adoption after replica
commit and notify local members. An older selected remote creation replaces a
conflicting local one and clears its losing privileges and lists. Network
admission remains incomplete: local and remote commits can race the ETS
authority read; remote invitations, ChanServ authority and atomic network-wide
+j throttling need coordinated policy and state updates.
When linking is configured but its coordinator index is unavailable, JOIN
fails closed rather than treating every remote channel as locally new. With an
active index, it also rejects an existing local channel missing from that
index, while allowing a genuinely new channel to be created. `NAMES` and
`LIST` suppress unindexed local channel details while links are enabled;
`LIST` uses a typed detailed-channel record for its filter pipeline.
Named-channel `WHO` also hides local members when the selected channel index
is missing or marks the channel secret, while retaining a newer local `+s`.
NICK likewise rejects a new nickname claim while its remote nickname index is
unavailable, instead of treating the remote network as empty.
The directory is an ETS view beside local Mnesia, so a channel created
concurrently with a remote burst can still race the check. Admission fencing
and convergence under concurrent mutation remain necessary before enabling
links for clients.
The same cross-process race remains for a simultaneous local and remote nick
claim; the unavailable-index guard only covers coordinator absence. A committed
collision now retains both UIDs and renames the losing local user, but the
three-server concurrent-claim path still needs proof over real links.

The last full gate before the new channel-view and `NAMES` changes passed
compilation, formatting, Credo, Sobelow, dependency audit, Doctor and Dialyzer;
all 2,703 tests passed, but the 100% coverage threshold failed at 98.9%.
Under the current network-restricted workspace, the latest
`MIX_OS_CONCURRENCY_LOCK=0 mix quality` passed every static gate through
Dialyzer after selected channel-message source permissions and effective mute masks, protocol v14 channel-message identity binding, v13 invite-notify extension, routed `TOPIC`, metadata/list `MODE`, and UID-routed `KICK` mutations, typed channel-view and route changes, projector pressure guards, missing-index guards, remote `+g` ACCEPT, typed direct replay, Unicode AWAY alignment, committed `LUSERS` counts and
accepted-only direct echo/NOTICE result correlation, UID-scoped direct history and shared message metadata, then could not start the
app's IRC listeners (`:eperm`), so no current full test or
coverage result exists. The dependency audit reported no vulnerabilities but
also logged that its `.git/FETCH_HEAD` write was denied by the read-only Git
metadata mount. A local no-listener harness passed 36 `NAMES` tests, 34 `WHOIS`
tests and one pure channel-view test before the event work. The current event
suites passed 13 tests covering delta and snapshot JOIN/PART, status changes,
auditorium visibility, remote NICK/QUIT and route-loss QUIT. The independent
two-VM test passed before the restriction change; its new JOIN/PART assertions
are unverified. The local-mode and channel-message slices passed 22 focused
no-listener tests; the versioned frame suite passed another 8 tests, and the
existing PRIVMSG and NOTICE suites passed 119 tests under the same no-listener
harness.
After the protocol v12 INVITE changes, 203 server-link, KICK and INVITE command tests
passed across 26 files under the no-listener harness. They cover post-commit
queueing, local and remote KICK projection, target-home authorization, replay,
result correlation, timeout, route loss, closed frame validation, marker cleanup,
and a KICK followed by a rejoin before projection. INVITE tests cover a remote
recipient, registered-channel rejection at both homes, AWAY and 341 after
acceptance, invite-only authority, replay, relay TTL, route loss, remote-only
invitation listing and consumption by JOIN.
The protocol v13 invite-notify extension passed 14 focused no-listener tests
and the 26-file server-link/KICK/INVITE slice passed 205 tests,
including an accepted remote target, a committed local-to-local invitation,
third-home relay, replay suppression, wrong-route and epoch rejection,
recipient-home deduplication, account-tag filtering, TTL exhaustion, and stale
channel identity filtering.
After protocol v14, a 28-file no-listener slice covering server links plus
KICK, INVITE, PRIVMSG and NOTICE passed 333 tests. The channel-message tests
cover a stale frame from another channel incarnation, local Mnesia identity
mismatch, outbound suppression against a stale selected identity, ordinary
delivery, delivery to a locally adopted channel retaining its remote creator,
selected +m source policy, missing-view failure, and combined local/remote mute
exceptions. Real-socket and independent-VM behavior remains unverified here.
The no-listener suite of server-link tests, the connection and QUIT suites,
the channel-mode parser, Dispatcher, history, BATCH, and ACCEPT/PRIVMSG/NOTICE/ISON/USERHOST/JOIN/LIST/LUSERS/MODE/NAMES/MONITOR/PART/TOPIC/WHO/WHOIS/CHATHISTORY/KICK commands passed 861 tests across 45 files after
the routed `TOPIC` and metadata/list `MODE` mutations, network MODE list reads,
the missing-index `TOPIC`, `JOIN`, `NAMES`, `LIST` and named-channel `WHO` guards,
the projector inbox and subscriber overflow, route path guarded snapshot forwarding,
auditorium `PART`, direct-message result routing, remote `+g` ACCEPT by UID, recipient-home `+R`/`+T` policy, rejection of partial remote multiline sends, typed direct-message replay, committed `LUSERS` network counts, and authenticated direct echo/result correlation for both `PRIVMSG` and `NOTICE`, plus UID-scoped direct history at both homes with a shared message ID and send time. Synthetic Hub tests cover
route authentication, MODE and direct-result transit TTL, pending-result correlation and route-loss cleanup. The socket-dependent Hub test compiles but its 16
tests, along with the independent-process assertions, have not run in this environment.
An exploratory all-file run under the no-listener harness completed 2,744 of
2,811 tests. Its 67 failures include socket `:eperm` cases and tests that need
normal boot initialization for cloaking, telemetry or configuration reload;
this harness result does not establish a full-suite pass or classify every
failure as an S2S defect.
This is not a release gate pass.

## Outstanding work and resumption order

The table above records partial behavior, not release completion. On a
resumption request, I would work in this order, updating the table and tests
as each contract is finished:

1. **Finish channel multiline semantics.** Introduce a bounded,
   versioned, identity-bound batch frame carrying the validated lines and
   concatenation markers. Authenticate its origin UID and route, replay it
   once, check selected channel policy for the whole batch, and deliver one
   IRCv3 batch to capable local clients with a coherent fallback for others.
   Hold source-side local delivery and echo until Hub acceptance. Add
   malformed-frame, invalid-later-line, status-target, split and three-server
   relay tests. Preserve message tags and history IDs across both homes.
2. **Fence network admissions and concurrent channel state.** Make local
   nickname and JOIN claims atomic with a chosen network authority or
   equivalent serial decision, including incoming remote bursts. Settle
   simultaneous nick claims deterministically without permanent link
   isolation. Prove oldest-channel timestamp/creator convergence, membership
   and mode outcomes, +l/+j admission, invitations, and rejoin after split
   under concurrent mutations on independent servers.
3. **Complete distributed channel commands and policy.** Finish remote
   membership/status MODE changes and remaining channel operations; audit
   JOIN, PART, KICK, TOPIC, INVITE, list writes/reads and channel messages
   against one selected authority. Preserve +o/+v, +u/+U, bans, exceptions,
   privacy, registered-channel restrictions, status targets and service
   permissions. Ensure every accepted mutation has a correlated result,
   idempotent replay behavior and post-commit client effects.
4. **Define shared account and services authority.** Current NickServ,
   ChanServ, SASL/account state, registered nick/channel policies, and
   TOPICLOCK are local. Decide their network owner and durable replication or
   request protocol; then implement account identity, registration,
   credentials, access lists, service modes and recovery across servers.
   Reject or defer commands whose global authorization cannot be proven.
5. **Close user-facing IRC semantics.** Audit all server-visible commands and
   numerics, including WHO/WHOX/WHOIS, NAMES, LIST, MONITOR, LUSERS, LINKS,
   AWAY, ACCEPT/SILENCE, nick changes, QUIT reasons, operator visibility,
   history, read markers, tags and CAP-dependent delivery. Keep remote UIDs
   separate from local PIDs and avoid copying remote socket, idle or CAP
   state into local user records. Add privacy and collision cases.
6. **Make recovery and pressure bounds complete.** Add stream
   acknowledgement, bounded per-link byte queues, multi-origin replay and
   resnapshot rules. Bound projector and relay memory by bytes as well as
   record counts; cover lag, slow peers, partial snapshots, epoch changes,
   route churn, cycles, duplicate messages, malformed inputs and TLS
   reauthentication. Define certificate rotation, config reload, migration
   and rollback behavior plus metrics and operator diagnostics.
7. **Prove the deployment contract.** Run normal boot with at least three
   independent Erlang VMs and Mnesia directories over mutual TLS. Exercise
   user/channel synchronization, bidirectional commands, services,
   concurrent claims, reconnects, netsplits, bursts and hostile peers.
   Resolve the current environment's listener `:eperm` restriction or use
   an authorized socket-capable environment. Then run the unmodified full
   `mix quality` gate, including every test and 100% coverage threshold,
   until green. Document configuration and operating procedures only after
   their real flows are verified; the disabled default stays until then.

If work resumes immediately, begin with item 1 and inspect the current
`Frame`, `Hub`, `ChannelMessage`, `Multiline` and independent-process
tests. The current per-line implementation is a useful local test baseline,
not an atomic network multiline contract. After item 1, prioritize items 2
and 4 because a coherent shared IRC network cannot be certified while
admission and services authority remain local.
