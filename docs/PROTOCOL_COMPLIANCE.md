# Protocol Compliance Audit

Audit scope: `nim-ocapn` at `31012070f3d8291b7177640b186e10060972b245`, local drafts in `../ocapn`, and the
official repository revision currently published on `main`. The OCapN documents
explicitly warn that they are drafts; this is a profile assessment, not a
claim of final standard compliance.

Baseline: [`SPECIFICATION_BASELINE.md`](SPECIFICATION_BASELINE.md). The IDs
below are the stable references used by this audit; the longer module inventory
and limitation notes follow the table.

| ID | Normative section | Implementation | Test | Status |
|---|---|---|---|---|
| SY-01 | Syrup draft: scalars/containers | `src/syrup.nim:encoded`, `decoded` | `test_syrup` golden/negative, nested generated vectors | COMPLETE for tested values |
| SY-02 | Syrup draft: canonical sorting | `src/syrup.nim:canonicalMembers`, dict encoder | `test_syrup` byte-order and round-trip vectors | COMPLETE |
| FR-01 | CapTP reliable ordered channel framing | `src/framing.nim`, `src/transport.nim` | `test_session`, `test_transport` | COMPLETE for TCP/in-memory |
| CP-01 | CapTP: establishing connection | `src/session.nim:pumpImpl` | session + Glowcap runner | COMPLETE for tested profiles |
| CP-02 | CapTP: operations and descriptors | `src/messages.nim`, `src/session.nim:processMessage` | messages/session/TCP suites | COMPLETE for tested profiles |
| CP-03 | CapTP: promises and pipelining | `src/promises.nim`, `src/session.nim:executePipelineRequest` | pipeline/forwarding tests | COMPLETE for tested paths |
| CP-04 | CapTP: `op:listen` modes 1/2/3 | `src/session.nim:notifyListener` | `tests/test_session.nim` listen matrix and invalid-mode vector | PARTIAL: local normative paths complete; external mode matrix unverified |
| CP-05 | CapTP: abort/error lifecycle | `src/session.nim:close`, `src/server.nim` | disconnect/malformed tests | COMPLETE for tested paths |
| GC-01 | CapTP: `op:gc-exports`/answers | `src/references.nim`, `src/session.nim` | GC/forwarding tests | PARTIAL for arbitrary distributed graphs |
| HO-01 | CapTP: third-party handoff | `src/handoff.nim`, `src/gifts.nim` | 3/4-node and stress tests | PARTIAL |
| LO-01 | Locators: peer/sturdyref Syrup | `src/locators.nim` | locator golden/negative and duplicate-hint vectors | PARTIAL: legacy bytes form remains accepted |
| LO-02 | Locators: URI and equality | `src/locators.nim:peerUri`, `parse*Uri` | URI escaping, UTF-8, duplicate, empty-value, and fragment vectors | COMPLETE for tested grammar |
| NL-01 | Netlayers: ordered bidirectional channel | `src/transport.nim`, `src/onion.nim` | TCP/Onion pipeline tests | PARTIAL: security boundary |
| NL-02 | Netlayers: authenticated participant insertion | no production implementation | no authenticated-netlayer test | MISSING |
| ID-01 | CapTP Ed25519/session identity | `src/crypto.nim`, `src/session.nim`, `src/api.nim`, `src/server.nim` | `tests/test_identity.nim`, session-id tests | COMPLETE for the default per-session profile; explicit legacy durable mode remains project-specific |
| ID-02 | Locator identity binding | `src/session.nim:verifyPeerPolicy` | `tests/test_identity.nim` locator substitution tests | PARTIAL: expected locator is checked; Tor designator ownership is not |
| IX-01 | Independent peer interoperability | `tests/test_interop.py`, Glowcap profile | `nimble interopTest` | PARTIAL: two-way bootstrap/invocation PASS; advanced cases unsupported by peer CLI |
| IX-02 | Bootstrap/sturdyref against a second independent peer | Goblins OCapN test-suite at pinned checkout | `nimble independentInteropTest` | PARTIAL: Nim bootstrap/sturdyref/invocation and isolated upstream start-session/deliver pass; full repeated-session suite and reconnect/cleanup remain unsupported or unverified |
| API-01 | Public call timeout/cancellation lifecycle | `src/session.nim:cancel`, `waitForTimeout`; `src/handoff.nim:cancel` | `tests/test_cancellation.nim` | COMPLETE for local observation; no remote execution cancellation |
| NL-05 | Transport-neutral CapTP behavior | `tests/test_transport_conformance.nim`, `tests/tls_peer.nim` | `nimble transportConformanceTest` | COMPLETE for in-memory/TCP/TLS tested cases; Onion conditional |
| ID-03 | Explicit expected-peer policy and session wire key | `src/identity.nim`, `src/session.nim`, `src/api.nim`, `src/server.nim` | `tests/test_identity.nim` | COMPLETE for exact current-session-key policy; reconnect requires a new pin |
| ID-04 | Locator/session identity binding | `src/session.nim:setExpectedPeer`, `src/api.nim`, `src/handoff.nim` | `tests/test_identity.nim` | PARTIAL: strict signed-locator/key binding; Onion ownership unproven |
| NL-03 | Authenticated netlayer evidence | `src/transport.nim:authenticationEvidence`, `src/session.nim`, `src/tls_transport.nim` | `tests/test_identity.nim`, `nimble tlsTest` | PARTIAL: project-specific mutual-TLS provider; no official OCapN profile |
| NL-04 | Authenticated channel provider | `src/tls_transport.nim` | `nimble tlsTest` | PARTIAL: real two-process project TLS profile; not official OCapN interop |

| Requirement | Specification / implementation | Status | Tests / problem |
|---|---|---|---|
| Canonical Syrup scalars, containers, records | `src/syrup.nim:encoded`, `decoded` | COMPLETE | `tests/test_syrup.nim`; vectors for duplicate dict/set members |
| Canonical frame encoding and limits | `src/framing.nim` | COMPLETE | `tests/test_session.nim`, `test_transport.nim` |
| Peer/sturdyref Syrup and URI forms | `src/locators.nim` | PARTIAL | `tests/test_locators.nim`; binary swiss numbers remain legacy-compatible |
| Per-session Ed25519 hello and Session ID | `src/session.nim`, `src/crypto.nim` | COMPLETE for default profile | `tests/test_session.nim`, `tests/test_identity.nim`; explicit legacy durable mode is project-specific |
| Secure channel before CapTP | Netlayer responsibility; absent for TCP | MISSING | TCP is explicitly testing-only |
| `op:start-session`, crossed hello arbitration | `src/messages.nim`, `src/session.nim` | COMPLETE for tested profile | Local/session tests PASS; Glowcap `24/24 × 3` runner UNVERIFIED in this checkout; one abort fixture needs compatibility normalization |
| `op:deliver`, `deliver-only`, answer/resolver | `src/messages.nim`, `src/session.nim` | COMPLETE for tested profile | session, TCP, and public API suites |
| `op:listen` modes 1/2/3 | `session.nim` listener lifecycle | PARTIAL | direct/chained/break/duplicate/disconnect local matrix; Glowcap per-mode external tests unavailable |
| Promise resolution, break, pipelining | `promises.nim`, `session.nim`, `api.nim` | COMPLETE for tested profile | chained and forwarded promise regressions |
| Session-local import/export descriptors | `references.nim`, `session.nim` | COMPLETE for tested paths | isolation, remap, proxy and GC tests |
| Third-party handoff | `handoff.nim`, `gifts.nim` | PARTIAL | 3/4-node, concurrent and 100-stress tests; formal all-peer/replay matrix remains |
| `op:gc-exports` / `op:gc-answers` | `session.nim`, `references.nim` | PARTIAL | duplicate/stale/forwarding tests; arbitrary distributed-GC proof absent |
| `op:abort` and disconnect cleanup | `session.nim`, `server.nim` | COMPLETE for tested profile | TCP matrix and malformed-message tests |
| Bootstrap and sturdyref enlivening | `api.nim`, `handoff.nim` | PARTIAL | TCP/Glowcap paths work; no authenticated production locator binding |
| OCapN peer locator semantics | `locators.nim` | PARTIAL | strict edge vectors pass; no runtime selector separates strict from legacy binary swiss parsing |
| TCP netlayer | `transport.nim`, `server.nim` | TESTING ONLY | reliable ordered transport; no channel security |
| Tor Onion adapter | `onion.nim` | PARTIAL | real Nim↔Nim pipeline/handoff on Fedora; `authenticated=false` by design |
| Cross-implementation interoperability | Glowcap testing profile | PARTIAL | `nimble interopTest`: two-way bootstrap/invocation PASS; advanced operations are unsupported or unverified |

## Module inventory

- `syrup.nim`, `framing.nim`: value model, canonical encoding/decoding, and
  decimal length framing. Limits are enforced at frame level and session level.
- `messages.nim`: constructors and shape validators for CapTP operations,
  descriptors, signatures, and handoff certificates.
- `references.nim`, `promises.nim`: session-local reference tables, wire/local
  counts, promise state and callbacks.
- `session.nim`: handshake, dispatch, pipeline routing, listeners, answer and
  GC lifecycle, proxy/rehome logic, and protocol error closure.
- `gifts.nim`, `handoff.nim`: transport-independent gift registry plus
  asynchronous handoff orchestration and auxiliary sessions.
- `transport.nim`, `server.nim`: in-memory/TCP transports and selector-based
  multi-session manager. `onion.nim` wraps TCP I/O after SOCKS5 CONNECT.
- `tests/test_interop.py`: separate-process, two-way Glowcap CLI smoke matrix;
  it reports unsupported peer capabilities separately from failures.
- `api.nim`: `Node`, typed arguments, public capability/promise operations,
  polling, stats, handoff and shutdown.
- `crypto.nim`, `identity.nim`: OpenSSL-backed Ed25519/SHA-256 primitives and
  versioned durable node identity storage; transport identity remains a
  separate netlayer concern.

## Identity evidence and limits

Durable identity persistence, per-session wire keys, reconnect key rotation,
exact expected-session-key rejection, and signed acceptable-location matching
are covered by `tests/test_identity.nim`. This does not make the current TCP or
Onion transports authenticated, and no normative Tor Service ID-to-CapTP
identity binding has been implemented. `simLegacyDurable` is an explicit
compatibility profile and is not strict CapTP identity semantics.

## Evidence and limits

The strongest verified profiles are CapTP over testing-only TCP for broad
interoperability and the project-specific mutual-TLS profile for authenticated
two-process Nim↔Nim tests. A successful `.onion` call proves routing and CapTP
operation, not locator-to-identity authentication. The official draft
specifications are pinned inputs, but remain draft documents rather than a
stable OCapN release.

The public API contract is intentionally separate from protocol compliance:
`import nimocapn` exposes the supported Node operations, while mutable Session,
manager, handoff, and reference-table fields remain experimental. The default
Node profile uses a fresh CapTP key per Session; exact peer checks pin that
ephemeral session key, not the durable Node identity.

The project-specific TLS profile now has an inbound Node listener under
`-d:ssl`. It reuses the TCP manager's Session lifecycle and verifies TLS
certificate evidence before authenticated CapTP sessions are opened. This is
still project-specific and does not establish an official OCapN netlayer.

Sources: [`CapTP Specification.md`](../../ocapn/draft-specifications/CapTP%20Specification.md),
[`Locators.md`](../../ocapn/draft-specifications/Locators.md),
[`Netlayers.md`](../../ocapn/draft-specifications/Netlayers.md).
