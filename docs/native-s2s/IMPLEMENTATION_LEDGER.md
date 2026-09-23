# ENP/1 implementation ledger

This ledger is deliberately evidence-oriented. CODED means a production code path exists, FOCUSED means a related unit/module test ran, PARTIAL means the boundary exists but the complete contract or evidence is missing, NOT-RUN means the acceptance case was not executed, DEFERRED means the specification intentionally gates the case on a later released-schema lifecycle, and OPEN means a release gate cannot be claimed.

The requirement and test IDs are taken verbatim from
ELIXIRCD_NATIVE_S2S_SPEC_EN.md.

## Evidence index

| Key | Location or command |
| --- | --- |
| C1 | lib/elixircd/server/s2s/{identity,json,schema,protocol}.ex |
| C2 | lib/elixircd/server/s2s/{runtime,state,tree,sync,projection,policy}.ex |
| C3 | lib/elixircd/server/s2s/{manager,session,tls,listener,connector}.ex |
| C4 | lib/elixircd/server/s2s/{requests,sasl,delivery}.ex |
| C5 | lib/elixircd/server/s2s/{output,publication}.ex |
| C6 | lib/elixircd/{tables,repositories,config,commands}/ and current-schema bootstrap in lib/elixircd/utils/mnesia.ex |
| F1 | The previously completed focused S2S set passed 271 tests, including 230 non-process cases and 41 independent OS-process cases. It includes dedicated schema checks for Bytes wrappers, hello closure, TAGMSG text, policy-cache placement, membership revision zero, SASL phase data and structured replies, sensitive output draining, actor-origin fencing, runtime case mapping, wire-fuzz safety, shared repair capacity/incarnation guards, routed-message synchronization and coalesced hello/post-hello budget handling, generated-fallback namespace fencing, channel-incarnation invite invalidation and remote invite notification, terminal origin-quota release, uncertain versus cancelled route loss, same-revision policy-image fencing, destination-scoped output fencing and independent per-destination drains, global-service authority/readiness rejection, derived GUARD membership/query projection, channel-scoped ChanServ request validation, local ampersand isolation and private Memo delivery without a public policy revision, and terminal RESOURCE replies when request admission is full. The independent process set also covers topology/reconnect, service and owner actions, SASL cleanup, certificate rejection/rotation, malformed frames, queue refusal, privacy, and restart churn. A new 12-peer mailbox-pressure case was added after that passing run; it and its related log-capture test edits remain unverified, as recorded in F13. |
| F2 | mix format --check-formatted --no-compile, git diff --check and MIX_ENV=test mix compile --warnings-as-errors pass after the per-session hello fix. mix doctor --raise also passes 265 modules with complete documentation/spec coverage. |
| F3 | The recorded full-suite run completed with 2,807/2,812 tests passing; failures included two log-capture expectations, two NickServ log expectations, and the new mailbox-pressure fixture. The NickServ expectations were updated afterward. No full-suite run completed after those edits. The Manager module separately passed all 33 tests after adding startup fencing for an interrupted output generation. |
| F4 | `mix quality` reaches compile/format and stops at Credo strict with 208 refactoring, 54 readability, and 52 design findings. The remaining quality stages were run separately: Dialyzer reports 62 warning blocks and exits with status 2. |
| F5 | The previously passing independent OS-process set had 41 cases covering publication/split/reconnect, multihop and branching topologies, certificate pinning/rotation/rejection, duplicate-SID fencing, malformed-frame closure, queue refusal, remote delivery and service flows, SASL cleanup, privacy, and restart churn. The added 12-peer mailbox-demand case has not been confirmed; see F13. Broader resource abuse, stale-result permutations, performance budgets and production-canary evidence remain open. |
| F6 | mix deps.audit — no vulnerabilities found. |
| F7 | mix sobelow --config — scan passed with only the expected router-discovery warning for this non-Phoenix application. |
| F8 | mix doctor --raise — 265 modules passed with 100.0% documentation, moduledoc, and spec coverage after documenting the public explicit case-mapping helper. |
| F9 | `mix dialyzer` — 62 warning blocks remain and Dialyzer exits with status 2, including opaque `MapSet`, broad Manager contracts and pattern-coverage findings. No current warning points to the new GUARD/service-presence paths. |
| F10 | The latest `MIX_ENV=test mix coveralls` run passed 2,807 tests in 354.1 seconds with 78.2% total coverage, below the configured 100% threshold. |
| F11 | mix run --no-start bench/native_s2s_hot_paths.exs — pure ENP/1 baseline recorded on 2026-09-22 for JSON, schema, protocol, snapshot and membership paths. It excludes TLS, sockets, Mnesia, queue pressure and churn, so it is not a production capacity claim. |
| F12 | `MIX_ENV=test mix run --no-start bench/native_s2s_network.exs 2000` — two independent OS daemons with separate Mnesia directories, mutual TLS sockets, two clients and 2,000 routed private messages completed on 2026-09-22. The run measured 526 us send p50, 844 us p95, 8,570 us max, 1,259 ms final delivery wait, 83,908,520 B root memory and 86,239,392 B leaf memory. It is a short sustained burst baseline, not a production capacity or churn budget. |
| F13 | Closeout validation on 2026-09-22: a focused run of `test/elixircd/server/connection_test.exs` and `test/elixircd/server/s2s/process_integration_test.exs` exposed two log-capture test failures (the capture process needs a debug process level; the sent-message assertion must run in the outer test process) and a mailbox-test fixture that received a close frame while reusing one peer certificate pin. The test fixtures were adjusted to address these causes using a process-local debug level, an outer-process message assertion, and unique peer certificates/pins, but the run was stopped and those edits were not rerun. Do not treat the latest full suite or the 42-case process suite as passing evidence. Re-run focused tests, then the full suite, format check, and warnings-as-errors compile when work resumes. |

## Current remaining boundary

The current implementation is a broad native S2S vertical slice, but it is not
yet an ENP/1 release claim. The remaining work falls into these concrete
boundaries:

- Complete the per-destination output owner and recovery evidence around the
  transient Mnesia group: committed groups now persist their destination
  scopes, wait only for an earlier overlapping scope, successful drains
  acknowledge them, and uncertain drains fence the affected scope and close
  its routed link generations. Focused Manager tests now cover a committed
  target-scoped drain failure and fencing at Manager startup after an
  interrupted generation. Independent-daemon crash/reconnect evidence,
  including every affected destination class, remains open.
- Finish the service and owner-action matrix across every global command,
  local/delegated authority path, multipart response, cancellation, timeout,
  and cross-daemon receipt ordering. Native Manager paths now defer Argon2 and
  credential verification for ChanServ/NickServ registration, IDENTIFY,
  recovery and SASL authority lookups. The derived GUARD ChanServ endpoint now
  appears in the supported query surfaces only while the authority is ready,
  rejects `&` export, emits MONITOR transitions, and one global `!op` request
  is proven to execute once at the authority. Independent daemons now also
  prove that global NickServ REGISTER, SET and MEMO mutate only the authority
  database and that MEMO does not advance the public policy revision; the
  complete service family matrix and load proof remain open.
- Add the remaining independent-daemon negative and abuse coverage: certificate
  revocation/rollout rehearsal, aggregate mailbox pressure, SASL load,
  stale-result permutations and restart/backoff timing. Explicit remote abort,
  authority loss, CAP withdrawal, disconnect cleanup, delayed-worker
  cancellation, timeout-under-pressure, malformed/oversized traffic, aggregate
  sync-queue refusal, duplicate-SID fencing and ten restart/disconnect churn
  cycles now have focused/independent evidence.
- The listener now exposes an explicit `max_connections_per_acceptor` budget,
  independent of client admission limits, and the Manager now enforces and
  reports aggregate pending synchronization frames/bytes in addition to the
  per-link queue. The independent suite covers listener refusal and aggregate
  syncing-state refusal; aggregate mailbox, authentication, snapshot, repair,
  queued-query and flood workloads still need independent pressure runs.
- Extend the new realistic network benchmark into sustained queue pressure,
  reconnect/churn and repair workloads, then set acceptance budgets from those
  runs. The current network result is a one-route smoke baseline, while the
  pure-code baseline remains useful for regression comparison.
- Resolve the current Credo and Dialyzer findings and raise meaningful native
  coverage. The last recorded full test run had five failures, and the latest
  fixture/log-test changes have not been rerun; the configured coverage gate
  is 100% while the historical observed total is 78.2%.
- Complete operational rehearsal and release audit: backup/restore of the
  current schema, certificate rotation/revocation, split/reconnect runbook,
  compatibility review, and production canary evidence.

## N-REQ requirements

| ID | status | scope | code/test evidence | result or limitation |
| --- | --- | --- | --- | --- |
| N-REQ-001 | OPEN | architecture/profile | C1,C2,C3; profile/manager tests | Escopo completo ainda depende das operações de serviço e dos testes distribuídos. |
| N-REQ-002 | CODED | architecture/profile | C1,C2,C3; profile/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-003 | PARTIAL | architecture/profile | C1,C2,C3; profile/manager tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-004 | CODED | architecture/profile | C1,C2,C3; profile/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-005 | CODED | architecture/profile | C1,C2,C3; profile/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-006 | CODED | architecture/profile | C1,C2,C3; profile/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-007 | CODED | architecture/profile | C1,C2,C3; profile/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-008 | CODED | architecture/profile | C1,C2,C3; profile/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-009 | CODED | architecture/profile | C1,C2,C3; profile/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-010 | PARTIAL | architecture/profile | C1,C2,C3; profile/manager tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-011 | CODED | local identity/effects | C2,C5,C6; existing regression suite | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-012 | PARTIAL | local identity/effects | C2,C5,C6; existing regression suite | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-013 | CODED | local identity/effects | C2,C5,C6; existing regression suite | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-014 | CODED | local identity/effects | C2,C5,C6; existing regression suite | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-015 | CODED | local identity/effects | C2,C5,C6; existing regression suite | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-016 | PARTIAL | local identity/effects | C2,C5,C6; output/manager/remote_sasl tests | Transaction intents are collected and drained only after commit; SASL credential-bearing intents are marked sensitive, stripped from persistent NativeOutputGroup rows and drained through the transient post-commit path. The full rollback/retry audit across every dispatcher, monitor, service and job side effect remains open. |
| N-REQ-017 | PARTIAL | local identity/effects | C2,C5,C6; service_endpoint/session/manager tests | Os caminhos nativos do Manager adiam Argon2, a verificação de credenciais e agora o REHASH remoto para fora da ordem de rede; ainda falta completar a matriz de serviços, os caminhos não nativos restantes e a prova sob carga. |
| N-REQ-018 | CODED | local identity/effects | C2,C5,C6; existing regression suite | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-019 | PARTIAL | local identity/effects | C2,C5,C6; manager/output/process tests | State, request, reply and message frames use bounded per-link queues while a peer is in hello/syncing. Durable output groups now carry destination scopes and serialize only overlapping destinations, while broadcast groups retain the network barrier. CAP/local-client barrier coverage and the complete destination matrix remain open. |
| N-REQ-020 | PARTIAL | local identity/effects | C2,C5,C6; dispatcher/output/listener/process tests | C2S message intents validate the current pid+UID record inside Mnesia before sending; post-delete disconnect and cleanup intents carry only UID, generation and scalar transient tokens, while the endpoint PID remains process-local for the committed drain. Stale PID reuse is discarded without a nickname lookup. Negotiated-capability/generation barriers and the complete local ordering matrix remain open. |
| N-REQ-021 | PARTIAL | local identity/effects | C2,C5,C6; output/manager tests | O grupo limitado é gravado atomicamente em Mnesia, carrega as gerações/destinos afetados, drena apenas depois dos grupos persistidos que compartilham o destino e é removido somente após retorno explícito `:ok`; grupos incertos são fenced seletivamente antes de fechar os links roteados, ou globalmente quando a autoridade de ordenação foi perdida. ManagerTest agora percorre falha de drain de grupo real com destino e valida o fence de grupo pendente na inicialização após interrupção. O teste de snapshot também descarta deltas de estado já incluídos e mensagens anteriores, preservando eventos posteriores. Evidência independente de crash/reconexão e a matriz completa de destinos continuam abertas. |
| N-REQ-022 | CODED | local identity/effects | C2,C5,C6; existing regression suite | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-023 | PARTIAL | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-024 | PARTIAL | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-025 | PARTIAL | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-026 | PARTIAL | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-027 | CODED | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-028 | CODED | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-029 | PARTIAL | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-030 | CODED | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-031 | CODED | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-032 | PARTIAL | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-033 | PARTIAL | TLS/codec/lifecycle | C1,C3; config/session/listener/process tests | Frame limits, per-link receive/output queues, stream limits and snapshot budgets are configured. Independent tests refuse excess connections, close an authenticated peer when aggregate sync state exceeds budget, and bound one Manager event per TLS peer; snapshot, authentication and broader pressure workloads remain open. |
| N-REQ-034 | PARTIAL | TLS/codec/lifecycle | C1,C3; config/session/listener/process tests | TLS reads use active-once and the session exposes queue/buffer counts; independent evidence covers listener capacity, aggregate sync refusal, and one pending Manager event per peer. Authentication flood and broad churn remain open. |
| N-REQ-035 | CODED | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-036 | CODED | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-037 | PARTIAL | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-038 | PARTIAL | TLS/codec/lifecycle | C1,C3; TLS/profile/protocol/session tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-039 | CODED | sync/repair/topology | C2,C3; runtime/sync/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-040 | PARTIAL | sync/repair/topology | C2,C3; runtime/sync/manager tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-041 | PARTIAL | sync/repair/topology | C2,C3; runtime/sync/manager tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-042 | PARTIAL | sync/repair/topology | C2,C3; runtime/sync/manager tests | Manager now holds a merge-scoped channel repair after merge.end when the owner node is known but its connecting edge is not ready, then releases it on edge activation; nested subtree/import and independent-process completion evidence remain open. |
| N-REQ-043 | CODED | sync/repair/topology | C2,C3; runtime/sync/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-044 | PARTIAL | sync/repair/topology | C2,C3; runtime/sync/manager tests | Repair replies are bound to the request/session generation, owner node reference and exact channel incarnation; shared channel/policy repair capacity is enforced. Nested repair races, stale-result permutations and independent-process evidence remain open. |
| N-REQ-045 | CODED | sync/repair/topology | C2,C3; runtime/sync/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-046 | PARTIAL | sync/repair/topology | C2,C3; runtime/sync/manager tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-047 | PARTIAL | sync/repair/topology | C2,C3; runtime/sync/manager tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-048 | PARTIAL | sync/repair/topology | C2,C3; runtime/sync/manager tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-049 | CODED | sync/repair/topology | C2,C3; runtime/sync/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-050 | CODED | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-051 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-052 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-053 | CODED | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-054 | CODED | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-055 | PARTIAL | UID/nickname/membership/state | C2,C4,C5,C6; domain/manager tests | Owner-local KICK/PART executes guards, commits membership removal and publishes one owner update; independent remote-owner and delayed-cross-daemon evidence remain open. |
| N-REQ-056 | CODED | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-057 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-058 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-059 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-060 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-061 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-062 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-063 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-064 | CODED | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-065 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-066 | CODED | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-067 | PARTIAL | UID/nickname/membership/state | C2,C6; identity/state/runtime tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-068 | PARTIAL | delivery/invitations/services | C2,C4,C5; delivery/state/policy tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-069 | PARTIAL | delivery/invitations/services | C2,C4,C5; delivery/state/policy tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-070 | PARTIAL | delivery/invitations/services | C2,C4,C5; delivery/state/policy tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-071 | CODED | delivery/invitations/services | C2,C4,C5; delivery/state/policy tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-072 | CODED | delivery/invitations/services | C2,C4,C5; delivery/state/policy tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-073 | CODED | delivery/invitations/services | C2,C4,C5; delivery/state/policy tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-074 | PARTIAL | delivery/invitations/services | C2,C4,C5; view/service-presence/manager tests | A projeção GUARD deriva a presença somente da autoridade alcançável e da policy pronta, rejeita exportação em `&` e não cria User/PID persistente; a auditoria completa de origem de toda ação/saída global ainda está aberta. |
| N-REQ-075 | PARTIAL | delivery/invitations/services | C2,C4,C5; delivery/state/policy/process tests | Global fantasy requests now carry an explicit channel scope, execute only at the ChanServ authority, and preserve the local `&` delegate; the complete origin audit for every service-triggered output remains open. |
| N-REQ-076 | CODED | requests/authorization | C4,C3; requests/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-077 | PARTIAL | requests/authorization | C2,C3,C4,C5; domain/manager tests | Owner-local user_action/invite/account/oper execution is integrated through Manager with revision guards, commit-before-reply effects and C2S receipts; cross-daemon receipt ordering and the remaining action families remain open. |
| N-REQ-078 | PARTIAL | requests/authorization | C4,C3; requests/manager tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-079 | CODED | requests/authorization | C4,C3; requests/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-080 | CODED | requests/authorization | C4,C3; requests/manager tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-081 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-082 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-083 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-084 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-085 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-086 | PARTIAL | policy/services/SASL | C4,C6; policy/runtime/process tests | Binding agora depende de policy epoch/auth_epoch, enquanto +r é derivado separadamente da posse do alias. Testes provam que UNGROUP preserva a sessão autenticada sem +r; a matriz completa de serviços e revogações segue aberta. |
| N-REQ-087 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-088 | PARTIAL | policy/services/SASL | C4,C6; service_endpoint/manager_domain/policy/process tests | Manager dispatches global service work through ServiceEndpoint; focused tests cover authority mutations and C2S replies, while an independent leaf exercises the read-only NickServ/ChanServ matrix at one authority. Complete cross-daemon write-family coverage, cancellation/timeout and multipart backpressure evidence remain open. |
| N-REQ-089 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL/privmsg/process tests | NOTICE/TAGMSG error-loop behavior remains covered by the existing paths; channel-scoped fantasy forwarding now returns one authority reply and local `&` channels delegate locally, while the full service error/multipart matrix remains open. |
| N-REQ-090 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-091 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-092 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-093 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL tests | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-094 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL/CAP/process tests | Mechanism eligibility now shares one CAP/AUTHENTICATE calculation, filters PLAIN by client transport, emits CAP DEL/NEW on authority reachability changes, and cancels active attempts on authority loss or disconnect; SASL load and broader abuse evidence remain open. |
| N-REQ-095 | CODED | policy/services/SASL | C4,C6; policy/SASL tests | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-096 | PARTIAL | policy/services/SASL | C2,C4,C5,C6; policy/SASL/domain/manager/process tests | Owner account binding validates account/auth/policy epochs, commits the binding and emits 900/903 once; independent processes cover remote IDENTIFY/LOGOUT, cached public binding and the authority-side read-only service matrix, while full global write-family completion and pre-registration projection remain open. |
| N-REQ-097 | PARTIAL | policy/services/SASL | C4,C6; policy/SASL/output tests | SASL intents are marked sensitive and never retained in persistent native output groups; authority context carries origin boot fencing and sensitive payloads are drained only after commit. TLS trusted-hop coverage, every service credential path, termination erasure and sustained-load proof remain open. |
| N-REQ-098 | PARTIAL | policy/services/SASL | C4,C6; sasl pool/manager/process tests | Fixed-size transient SASL workers return BUSY without a waiting queue, the independent two-client pressure case cleans attempts/jobs, timeout/late results recheck the attempt, and disconnect/abort paths cancel the request and worker state. Authority abort now preserves the admitted abort request while removing matching late SASL requests; sustained multi-client load and broader resource-pressure evidence remain open. |
| N-REQ-099 | PARTIAL | queries/admin/teardown | C3,C4; manager/commands | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-100 | PARTIAL | queries/admin/teardown | C3,C4; manager/commands | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-101 | PARTIAL | queries/admin/teardown | C3,C4; manager/commands | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-102 | PARTIAL | queries/admin/teardown | C3,C4; manager/commands/tests | Os cinco actions allowlisted existem, shutdown/restart reconhecem antes do fechamento e REHASH roda em worker monitorado; falta a matriz distribuída completa e a prova operacional. |
| N-REQ-103 | PARTIAL | queries/admin/teardown | C3,C4; manager/commands | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-104 | PARTIAL | queries/admin/teardown | C3,C4; manager/commands | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-105 | PARTIAL | queries/admin/teardown | C3,C4; manager/commands | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-106 | PARTIAL | queries/admin/teardown | C3,C4; manager/commands | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-107 | PARTIAL | queries/admin/teardown | C3,C4; manager/commands | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-108 | PARTIAL | queries/admin/teardown | C3,C4; manager/commands | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-109 | PARTIAL | atomicity/limits/security | C1,C2,C4; schema/runtime/policy/service/output tests | Private store, epoch/revision, policy rows, service output groups e efeitos locais têm fronteiras transacionais; falta completar a matriz de serviços e provar a recuperação de uma publicação incerta sem perda de revisão. |
| N-REQ-110 | PARTIAL | atomicity/limits/security | C1,C2,C4; schema/runtime/policy | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-111 | CODED | atomicity/limits/security | C1,C2,C4; schema/runtime/policy | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-112 | CODED | atomicity/limits/security | C1,C2,C4; schema/runtime/policy | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-113 | PARTIAL | atomicity/limits/security | C1,C2,C4; schema/runtime/policy/manager/process tests | Aggregate pending synchronization frames/bytes have configured refusal and status accounting; full request admission returns a correlated terminal RESOURCE reply. Per-session parser buffers are bounded by receive limits and listener capacity. A 12-peer Manager-mailbox test is present but its latest fixture failed before assertions and needs rerun. Aggregate output, policy staging, repairs, authentication and broader pressure evidence remain open. |
| N-REQ-114 | PARTIAL | atomicity/limits/security | C1,C3,C4; session/connector/listener/manager/process tests | Session parsing uses one-event demand with an asynchronous generation-fenced Manager acknowledgement; TLS reads use active-once and auxiliary listener/connector event queues have fixed bounds and timeouts. The 12-peer burst test is intended to verify one queued Manager event per peer while reads are paused; it needs rerun with the unique-certificate fixture. Authentication-flood and downstream-mailbox workloads remain open. |
| N-REQ-115 | CODED | atomicity/limits/security | C1,C2,C4; schema/runtime/policy | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-116 | PARTIAL | atomicity/limits/security | C1,C2,C4; schema/runtime/policy and connection logging tests | IRC input/output and SASL/IDENTIFY debug logs now omit payloads, account names and credentials; capture-log tests cover private inbound and outbound content. A broader audit of remaining service, transport and error paths is still open. |
| N-REQ-117 | PARTIAL | atomicity/limits/security | C1,C2,C4; schema/runtime/policy | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-118 | PARTIAL | atomicity/limits/security | C1,C2,C4; schema/runtime/policy | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-119 | PARTIAL | atomicity/limits/security | C1,C2,C4; schema/runtime/policy | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-120 | CODED | process/performance/reuse | C1,C2,C3,C5; module boundaries | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-121 | CODED | process/performance/reuse | C1,C2,C3,C5; module boundaries | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-122 | PARTIAL | process/performance/reuse | C1,C2,C3,C5; bench/native_s2s_hot_paths.exs; bench/native_s2s_network.exs; process tests | Há perfil puro, uma rajada de rede de 2.000 mensagens com TLS, sockets, Mnesia, CPU/memória e entrega, e recusas independentes de conexão/fila agregada; ainda faltam filas sustentadas, lock contention, reparos e carga com churn. |
| N-REQ-123 | PARTIAL | process/performance/reuse | C1,C2,C3,C5; docs/native-s2s/PERFORMANCE.md | Há baselines puros e de rede reproduzíveis, incluindo burst curto de 2.000 mensagens; ainda falta transformar workloads de pressão/reconexão em orçamento de aceitação. |
| N-REQ-124 | PARTIAL | process/performance/reuse | C1,C2,C3,C5; module boundaries | Parte da fronteira existe; falta a execução/integração completa descrita na especificação. |
| N-REQ-125 | CODED | process/performance/reuse | C1,C2,C3,C5; module boundaries | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-126 | PARTIAL | schema/evidence/docs | C6; schema/docs/ledger | A fronteira de primeiro release está definida; falta a execução/integração completa descrita na especificação. |
| N-REQ-127 | CODED | schema/evidence/docs | C6; MIGRATION.md; ledger | ENP/1 exige schema atual em instalação nova e rejeita diretório incompatível; migração de schema nativo pré-lançamento foi explicitamente adiada. |
| N-REQ-128 | CODED | schema/evidence/docs | C6; schema/docs/ledger | Implementação presente; confirmar contra a aceitação específica. |
| N-REQ-129 | CODED | schema/evidence/docs | C6; schema/docs/ledger | Implementação presente; confirmar contra a aceitação específica. |

## N-TEST acceptance cases

| ID | status | scope | evidence |
| --- | --- | --- | --- |
| N-TEST-001 | FOCUSED | TLS/topology | test/elixircd/server/s2s/process_integration_test.exs — two independent OS daemons authenticate over mTLS and publish state without creating a C2S user row. |
| N-TEST-002 | FOCUSED | TLS/topology | process_integration_test.exs rejects a CA-valid but unpinned peer, an independent peer signed by an untrusted CA, expired and missing-client certificates, and a hostname-mismatched server certificate before hello. |
| N-TEST-003 | FOCUSED | TLS/topology | process_integration_test.exs sends a normal IRC PASS line to the native TLS listener and confirms the socket closes without creating a user or reachable peer. |
| N-TEST-004 | NOT-RUN | TLS/topology | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-005 | NOT-RUN | TLS/topology | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-006 | NOT-RUN | TLS/topology | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-007 | FOCUSED | TLS/topology | process_integration_test.exs plus test/elixircd/commands/connect_test.exs — child initiation and parent CONNECT admission/wait behavior are exercised. |
| N-TEST-008 | FOCUSED | TLS/topology | process_integration_test.exs holds the established root/leaf generation while a second independent daemon with the same SID attempts the configured edge. |
| N-TEST-009 | FOCUSED | TLS/topology | process_integration_test.exs uses a second live daemon with the same SID/valid pin and verifies that the existing generation and root reachability remain unchanged. |
| N-TEST-010 | PARTIAL | TLS/topology | manager/profile generation guards and the duplicate-SID process case pass; a dedicated stale old-edge removal race remains open. |
| N-TEST-011 | FOCUSED | TLS/topology | process_integration_test.exs covers independent chain, star and balanced branching topologies with separate certificates. |
| N-TEST-012 | FOCUSED | TLS/topology | process_integration_test.exs verifies that hub loss partitions root and leaf reachability without implicit reparenting. |
| N-TEST-013 | NOT-RUN | TLS/topology | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-014 | NOT-RUN | TLS/topology | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-015 | FOCUSED | TLS/topology | test/elixircd/server/s2s/{profile,manager,tls}_test.exs |
| N-TEST-016 | NOT-RUN | TLS/topology | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-017 | PARTIAL | TLS/topology | process_integration_test.exs proves old/new certificate pin overlap, reconnect with the new certificate, and rejection after the old pin is restored alone; CRL/OCSP-style revocation and rollout rehearsal remain open. |
| N-TEST-018 | PARTIAL | TLS/topology | process_integration_test.exs verifies fresh reconnect and state rebuild after leaf/hub restart, ten repeated leaf restart/disconnect cycles beyond the former 30-second hello validity window, and a permanent wrong-pin retry block. Manager now creates a fresh nonce/timestamp for each TLS session and retains that exact hello for edge identity. Exact bounded backoff timing and explicit corrective-action rehearsal remain open. |
| N-TEST-019 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{json,protocol,schema,session}_test.exs |
| N-TEST-020 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{json,protocol,schema,session}_test.exs |
| N-TEST-021 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{protocol,session}_test.exs plus process_integration_test.exs — declared body limits fail before the advertised payload is received, while an independent oversized ENP length closes before the advertised payload is received. |
| N-TEST-022 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{json,protocol,schema,session}_test.exs |
| N-TEST-023 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{json,protocol,schema,session}_test.exs |
| N-TEST-024 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{json,protocol,schema,session}_test.exs |
| N-TEST-025 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{json,protocol,schema,session}_test.exs |
| N-TEST-026 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{json,protocol,schema,session}_test.exs |
| N-TEST-027 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{json,protocol,schema,session}_test.exs |
| N-TEST-028 | FOCUSED | codec/JSON | test/elixircd/server/s2s/schema_test.exs — valid UTF-8 and canonical binary wrappers are accepted while content remains bounded. |
| N-TEST-029 | FOCUSED | codec/JSON | test/elixircd/server/s2s/schema_test.exs — noncanonical Base64, decoded-size overflow and forbidden bytes are rejected. |
| N-TEST-030 | FOCUSED | codec/JSON | sasl_test.exs rejects decoded NUL and extra SASL fields before they can enter raw IRC text. Full mechanism/fragment boundary coverage remains open. |
| N-TEST-031 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{json,protocol,schema,session}_test.exs |
| N-TEST-032 | FOCUSED | codec/JSON | schema_test.exs warms the schema module, fuzzes unknown wire values and verifies no atom/module growth attributable to the input. Long-running fuzz and process-level resource evidence remain open. |
| N-TEST-033 | FOCUSED | codec/JSON | test/elixircd/server/s2s/{json,protocol,schema,session}_test.exs |
| N-TEST-034 | FOCUSED | codec/JSON | schema_test.exs rejects Erlang ETF, compressed payload and foreign IRC wire forms explicitly. Independent malformed/oversized daemon traffic coverage remains open. |
| N-TEST-035 | FOCUSED | transaction/sync | output_test.exs forces a Mnesia deadlock retry and confirms that intents collected by the aborted attempt are discarded; only the committed attempt reaches the post-commit drain. |
| N-TEST-036 | FOCUSED | transaction/sync | manager_test.exs commits a real target-scoped output group, fails its drain, verifies the Manager closes that link and fences the group, and verifies startup fences a group left by an interrupted Manager generation. Independent-daemon crash/reconnect and complete destination-class coverage remain open. |
| N-TEST-037 | FOCUSED | transaction/sync | manager_test.exs proves a routed message is queued while its peer synchronizes and is emitted only after the link becomes active; dispatcher_test.exs and the independent process suite cover UID-bound local disconnect delivery. The local-client/CAP/disconnect ordering matrix remains open. |
| N-TEST-038 | PARTIAL | transaction/sync | manager_test.exs queues channel creation, user introduction/nickname change, membership JOIN/PART, topic update and QUIT after sync begins; it proves the snapshot excludes those post-cut rows and all deltas arrive afterward in order. Mutations racing inside snapshot capture and the full independent-daemon interleaving matrix remain open. |
| N-TEST-039 | FOCUSED | transaction/sync | manager_test.exs starts a new link after a queued state delta and chat event, then proves the snapshot contains the state once and neither pre-cut frame is replayed afterward. |
| N-TEST-040 | FOCUSED | transaction/sync | test/elixircd/server/s2s/{output,sync,runtime,session}_test.exs |
| N-TEST-041 | FOCUSED | transaction/sync | test/elixircd/server/s2s/{output,sync,runtime,session}_test.exs |
| N-TEST-042 | FOCUSED | transaction/sync | test/elixircd/server/s2s/{output,sync,runtime,session}_test.exs |
| N-TEST-043 | FOCUSED | transaction/sync | test/elixircd/server/s2s/{output,sync,runtime,session}_test.exs |
| N-TEST-044 | FOCUSED | transaction/sync | test/elixircd/server/s2s/{output,sync,runtime,session}_test.exs |
| N-TEST-045 | PARTIAL | transaction/sync | manager_test.exs and process_integration_test.exs exhaust bounded pending state queues and close the authenticated syncing peer with an explicit RESOURCE boundary; staging deadline, parser/mailbox and repair-storm pressure remain open. |
| N-TEST-046 | NOT-RUN | transaction/sync | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-047 | FOCUSED | transaction/sync | test/elixircd/server/s2s/manager_test.exs covers a merge-scoped missing-channel repair held until the owner edge becomes active; nested independent-daemon timing remains open. |
| N-TEST-048 | NOT-RUN | transaction/sync | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-049 | NOT-RUN | transaction/sync | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-050 | FOCUSED | transaction/sync | manager_test.exs rejects a channel-repair response with a different cid/born incarnation and closes the responsible link without importing it. Full foreign-owner/metadata injection matrix remains open. |
| N-TEST-051 | FOCUSED | transaction/sync | manager_test.exs proves policy and channel repairs share max_repairs and aggregate byte capacity; independent repair-storm evidence remains open. |
| N-TEST-052 | NOT-RUN | transaction/sync | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-053 | FOCUSED | UID/membership | test/elixircd/server/s2s/{identity,state,runtime,delivery}_test.exs |
| N-TEST-054 | FOCUSED | UID/membership | dispatcher_test.exs proves distinct nil-PID recipients are not collapsed or mistaken for the sender; metadata_test.exs proves a different nil-PID UID cannot write another user's metadata; WHO membership reads now use stable UIDs. |
| N-TEST-055 | FOCUSED | UID/membership | runtime_test.exs sends a live user.put for an already-owned UID from another home and proves it fails with uid_home_conflict without replacing the existing projection. |
| N-TEST-056 | FOCUSED | UID/membership | test/elixircd/server/s2s/{identity,state,runtime,delivery}_test.exs |
| N-TEST-057 | NOT-RUN | UID/membership | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-058 | FOCUSED | UID/membership | runtime_test.exs applies three colliding nick claims in all six arrival orders and asserts identical winners and injective fallbacks. |
| N-TEST-059 | FOCUSED | UID/membership | runtime_test.exs proves the next claimant regains a vacated nick only while its requested nick remains unchanged. |
| N-TEST-060 | FOCUSED | UID/membership | state_test.exs checks bracket equivalence in ASCII/strict-RFC1459/RFC1459 and caret/tilde equivalence only in RFC1459. |
| N-TEST-061 | NOT-RUN | UID/membership | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-062 | NOT-RUN | UID/membership | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-063 | NOT-RUN | UID/membership | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-064 | FOCUSED | UID/membership | test/elixircd/server/s2s/{identity,state,runtime,delivery}_test.exs |
| N-TEST-065 | NOT-RUN | UID/membership | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-066 | FOCUSED | UID/membership | test/elixircd/server/s2s/{identity,state,runtime,delivery}_test.exs |
| N-TEST-067 | NOT-RUN | UID/membership | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-068 | FOCUSED | UID/membership | process_integration_test.exs executes a remote ChanServ KICK at the target's home daemon and verifies the membership change and delivery. |
| N-TEST-069 | FOCUSED | UID/membership | domain_test.exs changes the target's nickname/revision before a delayed recovery kill and verifies STALE, preserving the replacement session without effects. |
| N-TEST-070 | NOT-RUN | UID/membership | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-071 | FOCUSED | state/delivery | test/elixircd/server/s2s/{state,delivery,runtime}_test.exs |
| N-TEST-072 | FOCUSED | state/delivery | test/elixircd/server/s2s/{state,delivery,runtime}_test.exs |
| N-TEST-073 | FOCUSED | state/delivery | test/elixircd/server/s2s/{state,delivery,runtime}_test.exs |
| N-TEST-074 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-075 | FOCUSED | state/delivery | test/elixircd/server/s2s/{state,delivery,runtime}_test.exs |
| N-TEST-076 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-077 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-078 | FOCUSED | state/delivery | test/elixircd/server/s2s/{state,delivery,runtime}_test.exs |
| N-TEST-079 | FOCUSED | state/delivery | test/elixircd/server/s2s/{state,delivery,runtime}_test.exs |
| N-TEST-080 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-081 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-082 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-083 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-084 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-085 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-086 | FOCUSED | state/delivery | test/elixircd/server/s2s/process_integration_test.exs proves a local `&` channel and membership remain on the home daemon while the remote daemon receives the user projection without the channel or membership. The complete local invitation/topic/ACL/service matrix remains open. |
| N-TEST-087 | FOCUSED | state/delivery | test/elixircd/server/s2s/{state,delivery,runtime}_test.exs |
| N-TEST-088 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-089 | FOCUSED | state/delivery | test/elixircd/server/s2s/process_integration_test.exs routes NOTICE and TAGMSG across independent daemons, verifies that no automatic private-message error is emitted, and the real leaf C2S service test returns an unsupported-service NOTICE without a loop. |
| N-TEST-090 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-091 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-092 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-093 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-094 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-095 | NOT-RUN | state/delivery | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-096 | FOCUSED | policy/services | process_integration_test.exs executes leaf-originated NickServ REGISTER, SET and MEMO at the configured authority, asserts the public policy revision changes only for REGISTER/SET, asserts the memo is stored only in the root Mnesia directory, and confirms the leaf has no canonical registered-nick or memo rows. The remaining service families are covered only by focused/unit evidence. |
| N-TEST-097 | FOCUSED | policy/services | test/elixircd/server/s2s/{policy,sasl}_test.exs |
| N-TEST-098 | FOCUSED | policy/services | process_integration_test.exs proves that GROUP preserves the primary account ID on two independent daemons, UNGROUP moves the alias into a distinct account while retaining that session's authentication, and the primary display name does not identify the detached alias account. |
| N-TEST-099 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-100 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-101 | FOCUSED | policy/services | test/elixircd/server/s2s/{policy,sasl}_test.exs |
| N-TEST-102 | FOCUSED | policy/services | test/elixircd/server/s2s/{policy,sasl}_test.exs |
| N-TEST-103 | FOCUSED | policy/services | test/elixircd/server/s2s/{policy,sasl}_test.exs |
| N-TEST-104 | FOCUSED | policy/services | test/elixircd/server/s2s/{policy,sasl}_test.exs |
| N-TEST-105 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-106 | PARTIAL | policy/services | process_integration_test.exs proves that a leaf retains a ready cached policy while the services authority is partitioned and rejects a new global SET without local canonical writes or pending-request leakage; pending in-flight write cancellation and the complete revocation matrix remain open. |
| N-TEST-107 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-108 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-109 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-110 | PARTIAL | policy/services | manager_domain_test.exs covers authority policy binding, owner commit and one 900/903 result; process_integration_test.exs also covers remote IDENTIFY completion and owner projection, while full service completion remains open. |
| N-TEST-111 | PARTIAL | policy/services | manager_domain_test.exs covers owner logout and process_integration_test.exs covers remote LOGOUT plus DROP revocation across two authenticated sessions at two daemons; the complete revocation matrix remains open. |
| N-TEST-112 | FOCUSED | policy/services | Three independent daemons place the target at a non-authority owner and the requester at another leaf. The test verifies owner-side removal and authority reservation before RECOVER success, then checks RELEASE. |
| N-TEST-113 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-114 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-115 | FOCUSED | policy/services | test/elixircd/server/s2s/process_integration_test.exs proves a leaf-originated global `!op` reaches the ChanServ authority once, produces one service reply and one shared message identity for the resulting mode output; the complete fantasy command matrix remains open. |
| N-TEST-116 | FOCUSED | policy/services | test/elixircd/server/s2s/view_test.exs and test/elixircd/commands/service_presence_test.exs verify ready-authority visibility, retained-channel offline behavior, query projection and MONITOR online/offline transitions; independent multi-daemon service evidence remains open. |
| N-TEST-117 | FOCUSED | policy/services | test/elixircd/server/s2s/view_test.exs and test/elixircd/commands/privmsg_test.exs verify that `&` channels never receive exported logical ChanServ membership and delegate fantasy status locally; the complete local registration/ACL/job matrix remains open. |
| N-TEST-118 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-119 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-120 | NOT-RUN | policy/services | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-121 | FOCUSED | requests/SASL | test/elixircd/server/s2s/{requests,sasl,manager}_test.exs |
| N-TEST-122 | NOT-RUN | requests/SASL | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-123 | FOCUSED | requests/SASL | test/elixircd/server/s2s/{requests,sasl,manager}_test.exs |
| N-TEST-124 | NOT-RUN | requests/SASL | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-125 | FOCUSED | requests/SASL | test/elixircd/server/s2s/{requests,sasl,manager}_test.exs |
| N-TEST-126 | FOCUSED | requests/SASL | test/elixircd/server/s2s/{requests,sasl,manager}_test.exs |
| N-TEST-127 | PARTIAL | requests/SASL | The real leaf C2S NickServ HELP test receives the multipart stream through the authority and preserves ordered NOTICE items; bounded stream/resource and backpressure stress remain open. |
| N-TEST-128 | FOCUSED | requests/SASL | test/elixircd/server/s2s/{requests,sasl,manager}_test.exs |
| N-TEST-129 | FOCUSED | requests/SASL | test/elixircd/server/s2s/{requests,sasl,manager}_test.exs |
| N-TEST-130 | NOT-RUN | requests/SASL | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-131 | PARTIAL | requests/SASL | process_integration_test.exs covers explicit remote abort, authority loss, CAP withdrawal, disconnect cleanup, two-client worker pressure and an independent timeout-under-pressure case with late-result fencing; manager_domain_test.exs covers authority timeout and late-worker release. The disconnect case passed four repeated runs after the admitted-state cancellation fix. Broader timeout/load permutations and the full stale-result matrix remain open. |
| N-TEST-132 | FOCUSED | requests/SASL | test/elixircd/server/s2s/{requests,sasl,manager}_test.exs |
| N-TEST-133 | NOT-RUN | requests/SASL | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-134 | FOCUSED | requests/SASL | cap_test.exs covers transport filtering and CAP DEL/NEW with runtime reachability; process_integration_test.exs observes CAP DEL during an independent-daemon authority loss and fail-closed reauthentication. |
| N-TEST-135 | FOCUSED | operations/integration/performance | test/elixircd/server/s2s/manager_test.exs covers acceptance-before-close for configured remote shutdown and bounded graceful teardown. Independent daemon restart/shutdown rehearsal remains open. |
| N-TEST-136 | PARTIAL | operations/integration/performance | manager_test.exs covers asynchronous remote REHASH acceptance and single-flight execution; invalid-candidate atomicity and structural transition evidence remain in the existing C2S/config suite, not yet mapped to an ENP acceptance run. |
| N-TEST-137 | DEFERRED | operations/integration/performance | The specification gates persistence testing on a released ENP/1 schema. First use starts from the current clean Mnesia schema; importing an older pre-release native schema is out of scope. |
| N-TEST-138 | PARTIAL | operations/integration/performance | test/elixircd/server/s2s/process_integration_test.exs has 42 cases defined with separate OS processes, Mnesia directories and TLS sockets. The previously verified set had 41 passing process cases. The added 12-peer Manager-mailbox case failed in its certificate/hello fixture and is pending rerun; see F13. |
| N-TEST-139 | NOT-RUN | operations/integration/performance | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |
| N-TEST-140 | PARTIAL | operations/integration/performance | process_integration_test.exs has passing evidence for untrusted-CA, expired/missing-client/hostname rejection, malformed/oversized/permanently partial frame closure, listener connection limits, aggregate sync refusal, bounded SASL BUSY and late-result fencing. The 12-peer Manager mailbox assertion is present but unverified after its fixture failure; huge policy, repair storm, queued-query, authentication-flood and broader aggregate-byte workloads remain open. |
| N-TEST-141 | PARTIAL | operations/integration/performance | The recorded full suite completed at 2,807/2,812 passing before the latest fixture/log-test edits. A later focused run exposed three remaining failures after the NickServ expectation updates; the run was stopped and no full suite was completed afterward. The historical instrumented run measured 78.2%, below the configured 100% threshold. |
| N-TEST-142 | PARTIAL | operations/integration/performance | bench/native_s2s_hot_paths.exs and bench/native_s2s_network.exs record pure and TLS/socket/Mnesia baselines, including a 2,000-message short sustained burst; repair pressure, reconnect churn under load and accepted production budgets remain open. |
| N-TEST-143 | PARTIAL | operations/integration/performance | process_integration_test.exs repeats leaf restart/disconnect cleanup through ten cycles and asserts no ghost users or pending requests; combined nick/mode/service churn, longer duration and stale-queue growth budgets remain open. |
| N-TEST-144 | NOT-RUN | operations/integration/performance | NOT RUN: requires independent daemons, domain integration, churn, or performance evidence. |

## N-GATE release gates

| ID | status | evidence and remaining condition |
| --- | --- | --- |
| N-GATE-01 | PARTIAL | C2S/service inventory and native routing exist; complete operation mapping is open. |
| N-GATE-02 | PARTIAL | Closed schemas and allowlists exist; full negative coverage and every action path are open. |
| N-GATE-03 | PARTIAL | Atomic transient output groups, abort/retry isolation, post-commit acknowledgement and uncertain-drain fencing pass in focused tests; full retry/effect integration and independent crash-boundary evidence remain open. |
| N-GATE-04 | PARTIAL | Stable account IDs and current-schema validation exist. First use starts with the current clean Mnesia schema, so migration from an older pre-release native schema is out of scope; backup/restore evidence for a released schema remains open. |
| N-GATE-05 | PARTIAL | Independent OS-process mTLS chain, star and balanced-tree tests pass, including split/reconnect, sibling-topology snapshot reconvergence, wrong pinning, untrusted CA, expired/missing-client/hostname rejection, explicit pin overlap/removal, duplicate live-SID fencing, oversized/partial-frame closure and ten restart/disconnect cycles; revocation rehearsal, bounded backoff timing and full conformance remain open. |
| N-GATE-06 | PARTIAL | Policy/SASL primitives, remote PLAIN/ECDSA, explicit cancellation, authority-loss fail-closed behavior, disconnect cleanup, bounded worker pressure, timeout cleanup, remote NickServ IDENTIFY/LOGOUT and a real read-only NickServ/ChanServ authority matrix have independent-process evidence; full global write-family integration, stale-result matrix and multipart backpressure remain open. |
| N-GATE-07 | PARTIAL | Independent processes prove private/channel delivery across learned routes, query/service streams, a real leaf C2S multipart service reply/error, exactly one fantasy execution and remote NickServ/ChanServ owner actions; labeled-response ordering and complete cross-process service behavior remain open. |
| N-GATE-08 | PARTIAL | Bounded parser/schema checks, malformed/oversized-frame refusal and aggregate sync refusal pass. The 12-peer Manager-mailbox case is pending fixture revalidation; fuzzing, policy/repair pressure, queued-query and authentication-abuse evidence remain open. |
| N-GATE-09 | PARTIAL | Pure and two-daemon TLS/socket/Mnesia smoke baselines are recorded; sustained pressure/churn measurements and accepted production budgets remain open. |
| N-GATE-10 | CODED | The implementation uses explicit finite modules and no remote-user processes or Erlang cluster. |
| N-GATE-11 | PARTIAL | Operator, certificate, topology, first-release schema, and recovery docs are present; rehearsal is open. |
| N-GATE-12 | PARTIAL | This ledger maps all IDs; compatibility/release audit remains open until the missing evidence is run. |

## Current validation record

The latest closeout attempt (2026-09-22) was a focused run of the connection and independent-process suites. It exposed two log-capture test failures and one mailbox-pressure fixture failure; the corresponding test adjustments are in the worktree but were not rerun after the user asked to pause. The last recorded full suite completed at 2,807/2,812 passing before those latest edits. Formatting, warnings-as-errors compilation and the full suite must be rerun on resume. Earlier quality results remain: Credo strict reports 208 refactoring, 54 readability and 52 design findings; Dialyzer reports 62 warning blocks and exits with status 2; instrumented coverage is 78.2% against a 100% threshold. The recorded service-presence focused set passed 157 tests, the earlier focused S2S set passed 271 tests (230 non-process and 41 independent-process cases), and the Manager module passed all 33 tests. These are historical results, not validation of the current worktree.

On resumption, first rerun the two edited log-capture tests and the 12-peer mailbox-pressure case; then run the focused S2S suite, full project tests, formatting and warnings-as-errors compilation. Reconcile the requirement/test ledger with those results before continuing the still-open service-action matrix, output recovery/crash boundaries, stale-result and race cases, certificate revocation/rollout, aggregate resource pressure and fuzzing, sustained network/churn budgets, and operator rehearsal. `mix quality` also remains red on the recorded Credo and Dialyzer findings. First use starts with the current clean Mnesia schema; migration from a pre-release native schema is intentionally out of scope. This WIP does not claim merge, deployment, or production approval.
