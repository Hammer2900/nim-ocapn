# v1 Readiness Audit

Audit date: 2026-11-19  
Code audit commit: `31012070f3d8291b7177640b186e10060972b245`  
Package version: `1.0.0` (`v1.0.0` scoped stable)

The code tree was clean at the start of this audit. The audit made only
documentation corrections; those corrections are intentionally uncommitted.
No wire format, public protocol behavior, or runtime dependency was changed.

## Executive summary

`nim-ocapn` is a credible beta protocol library for the documented Nim,
Glowcap, Goblins-bootstrap, testing TCP/Onion, and project-specific mutual-TLS
profiles. Local CapTP, handoff, distributed-GC, cancellation, robustness,
resource, concurrency, packaging, and deployment tests pass.

It is **NOT READY for a full v1.0 claim**. The main blockers are not basic
Nim↔Nim correctness: the pinned independent peers do not expose all required
cross-peer operations, no official OCapN authenticated netlayer profile is
implemented, Onion Service IDs are not cryptographically bound to CapTP
identities, and arbitrary distributed-GC/forwarding behavior is not formally
proven.

The project-specific mutual-TLS profile is suitable for a narrowly documented
authenticated Nim↔Nim deployment when its CA, certificate fingerprint, and
CapTP-key trust mapping are configured. It must not be presented as an
official OCapN netlayer.

## Public API stability assessment

### Recommended application surface

The stable-facing path is the `nimocapn` facade and these concepts from
`src/api.nim`:

- `NodeConfig`, `newNode`, `Node.close`, `Node.poll`, and `Node.stats`;
- `NodeIdentity`, `loadNodeIdentity`, and `publicIdentity`;
- explicit `PeerVerificationPolicy` selection;
- `connectUsing`, `connectVerified`, `bootstrap`, `RemoteCapability.call`;
- `waitFor`, `waitForCallTimeout`, `cancelCall`;
- `DiagnosticSink`, `SessionLimits`, and `HandoffLimits`.

Ownership is explicit at this level: `Node.close()` owns node shutdown,
`Session` remains event-loop state, and local cancellation does not claim that
remote execution stopped.

### Unstable or low-level surface

The following should not be treated as frozen v1 API without a separate API
review:

- direct `Session`, `CapabilityRef`, `ReferenceTables`, `HandoffManager`, and
  transport construction;
- exported mutable fields such as `Node.manager`, `Node.handoffs`,
  `Session.references`, and transport state;
- `Behavior`/`ActorBehavior` callbacks that expose protocol Sessions directly;
- direct `src/syrup`, `src/messages`, and `src/references` imports.

These are useful for protocol tests and unusual integrations, but expose
implementation ownership and lifecycle details. Hiding them would be a
breaking API change and is deferred rather than performed during this audit.

`SyrupValue` remains a separate public module dependency for application
callbacks; the facade does not duplicate or re-export the Syrup codec.

## Protocol compliance matrix

Baseline revisions are pinned in
[`SPECIFICATION_BASELINE.md`](SPECIFICATION_BASELINE.md):

| Area | Local Nim tests | Independent peer evidence | Status |
|---|---|---|---|
| Syrup encoding, canonical ordering, malformed input | PASS | Glowcap/Goblins paths exercised | COMPLETE for tested profile |
| Framing and partial I/O | PASS | Glowcap bootstrap paths | COMPLETE for tested transports |
| Session establishment and CapTP identity | PASS | Glowcap two-way; Goblins bootstrap | COMPLETE for tested profiles |
| Remote invocation/bootstrap/fetch | PASS | Glowcap two-way; Goblins Nim→Goblins | VERIFIED independent peer |
| Promise settlement and pipelining | PASS locally | Advanced independent pipeline driver unavailable | PARTIAL |
| `op:listen` modes 1/2/3 | PASS local normative matrix | External mode selection unavailable | PARTIAL/UNVERIFIED |
| Handoff | PASS 3/4-node, concurrent, failure matrix | Independent handoff drivers unavailable | PARTIAL |
| Distributed GC | PASS tested lifecycle paths | Arbitrary hostile graphs/external observation unavailable | PARTIAL |
| Cancellation/timeouts | PASS local semantics | Remote execution cancellation not claimed | COMPLETE for local semantics |
| Durable identity/expected peer policy | PASS | External peer durable identity varies | COMPLETE for exact-key profile |
| Locator/CapTP identity binding | PASS expected-key checks | Onion Service ownership binding absent | PARTIAL |
| TCP/Onion netlayers | PASS routing/framing | Unauthenticated by design | TESTING ONLY |
| Mutual TLS | PASS two-process Nim↔Nim | Not official OCapN interop | PROJECT-SPECIFIC PARTIAL |

Detailed operation-level statuses remain in
[`PROTOCOL_COMPLIANCE.md`](PROTOCOL_COMPLIANCE.md) and
[`INTEROPERABILITY_MATRIX.md`](INTEROPERABILITY_MATRIX.md).

## Transport security assessment

| Profile | Authentication | Recommendation |
|---|---|---|
| Raw TCP | None; CapTP signatures do not provide channel confidentiality | Testing only |
| Tor Onion | Onion routing, but no proven Onion-Service-ID ↔ CapTP-key binding | Testing/interop only |
| Mutual TLS | CA validation, certificate fingerprint pinning, explicit CapTP-key mapping, channel integrity/confidentiality | Narrow project-specific Nim↔Nim deployment |

`testingOnlyPeerPolicy` is the default compatibility profile and is not a
production authorization policy. `exactPeerPolicy` provides explicit CapTP
key authorization independently of transport security. Authenticated-netlayer
policy fails closed if the transport does not provide verified evidence.

The general inbound `Node` listener remains TCP-oriented. There is no unified
production Onion/TLS listener in the public Node API.

## Resource and concurrency contracts

Sessions, Nodes, HandoffManagers, and reference tables are single-owner
event-loop state. They are not implicitly thread-safe. Applications must
serialize calls through `Node.poll`/`Session.pump`.

Default bounded resources:

| Resource | Default |
|---|---:|
| Syrup decode depth | 255 nested containers |
| Frame size | 1 MiB |
| Pending promises, inbound answers, pipeline requests | 4096 per Session |
| Imports/exports | 4096 per Session |
| Outgoing queue | 1 MiB per Session |
| Active TCP sessions | 256 per Node |
| Pending handoffs | 256 |
| Handshake timeout | 30 seconds |

Cancellation is local observation/lifecycle cancellation. It does not promise
remote execution cancellation. Disconnect breaks dependent local operations.
Backpressure rejects work before queues exceed their configured bounds.

Redeemed gift tombstones are lifecycle-bounded, not size-bounded: they remain
until the owning GiftTable/manager is cleared. Evicting them would weaken the
current replay-protection profile and needs a separately specified expiry
policy.

## Packaging verification

- `nimble check`: PASS.
- No declarative or VM runtime Nimble dependencies.
- Isolated consumer import of `nimocapn`: PASS.
- SSL and non-SSL compilation: PASS.
- Package excludes tests, examples, docs, identities, logs, CSVs, and binaries.
- Apache-2.0 metadata and license are present.
- Version is `1.0.0`, accepted by the installed Nimble packaging rule.

## Test results

| Command | Result |
|---|---|
| `nimble test` | PASS |
| `nimble complianceTest` | PASS |
| `nimble identityTest` | PASS |
| `nimble stressTest` | PASS |
| `nimble robustnessTest` | PASS |
| `nimble fuzzTest` | PASS |
| `nimble resourceTest` | PASS |
| `nimble enduranceTest` | PASS |
| `nimble concurrencyTest` | PASS |
| `nimble distributedGcTest` | PASS |
| `nimble handoffFailureTest` | PASS |
| `nimble cancellationTest` | PASS |
| `nimble transportConformanceTest` | PASS; Onion SKIP without environment |
| `nimble tlsTest` | PASS |
| `nimble packagingTest` | PASS |
| `nimble publicApiTest` | PASS |
| `nimble deploymentTest` | PASS |
| `nimble interopTest` | PASS; advanced cases UNSUPPORTED/UNVERIFIED |
| `nimble independentInteropTest` | PASS; Goblins limits documented |
| `nimble advancedInteropTest` | PASS; advanced cases UNSUPPORTED/UNVERIFIED |
| `git diff --check` | PASS |

External statuses are not promoted: Goblins module cases may be SKIP when
optional Python modules are absent; Tor is SKIP without
`NIM_OCAPN_ONION_SERVICE`; cross-peer listen/pipeline/handoff/GC cases remain
UNVERIFIED or UNSUPPORTED where the peer driver lacks the operation.

## Release blockers

### BLOCKER for full v1.0 scope

1. No official OCapN authenticated netlayer profile is implemented or verified.
2. Onion Service ID ownership is not cryptographically bound to the CapTP peer
   identity.

### HIGH

1. Cross-peer `op:listen` modes 1/2/3 are not independently verified.
2. Cross-peer promise pipelining, handoff, and observable distributed GC are
   unavailable in the pinned independent peer drivers.
3. Arbitrary hostile forwarding-graph GC correctness is tested but not proven.
4. The public API still exposes mutable low-level state that should be frozen
   or hidden before a long-term v1 compatibility promise.

### MEDIUM

1. Redeemed gift tombstones can grow for a long-lived manager.
2. Quotas are Node/Session scoped rather than system-wide.
3. Inbound production listener selection is not unified across transports.
4. Remote error strings have no finalized disclosure/redaction policy.

### LOW

1. Additional API examples could avoid importing low-level modules directly.
2. Broader independent malformed-message drivers would improve evidence.

## Recommendation

**NOT READY for v1.0.**

The library is suitable for a documented beta and for controlled Nim↔Nim use
with testing TCP or the project-specific mutual-TLS profile. A v1.0 claim
should wait for the two BLOCKER items and a deliberate decision about whether
the remaining independent-peer gaps are part of the supported v1 scope.

## Minimal path to v1.0

1. Freeze the facade API and hide or explicitly mark mutable low-level fields.
2. Define and verify an official-compatible authenticated netlayer and locator
   identity binding, or narrow the v1 claim to a project-specific profile.
3. Obtain independent drivers for `op:listen`, pipelining, handoff, and GC;
   otherwise mark those operations outside the v1 interoperability guarantee.
4. Specify hostile forwarding-graph GC evidence and a safe replay-tombstone
   lifecycle policy.
5. Repeat packaging and full regression checks on the final release candidate.

## Proposed commit plan

No commit was created by this audit. If accepted, use separate commits:

1. `docs: correct v1 readiness and security profile documentation`
2. `docs: add v1 readiness audit`

Do not mix a future API freeze or authenticated-netlayer implementation into
the documentation commits.

## P9/P10 follow-up

The follow-up audit added a deterministic A→B→A capability-forwarding cycle
to `tests/test_api.nim`; `nim c -r --hints:off tests/test_api.nim` passes and
the cycle returns the expected result with clean session shutdown. Existing
distributed-GC, handoff-failure, robustness, and stale-resolver suites also
pass.

The pinned draft says each side MUST create a per-session Ed25519 key. The
implementation now follows that requirement: default Node, server-accept, reconnect, and
handoff paths now generate a fresh session key, while the durable Node seed is
kept as the persistent Node trust anchor/public identity. The explicit
`simLegacyDurable` mode remains a project-specific compatibility profile and is
not strict CapTP semantics.

Exact expected-peer verification now applies to the current session key. A
reconnect intentionally has a new key, so a stale exact-key pin is rejected;
there is no automatic fallback to the durable key or legacy mode. The
project-specific mutual-TLS profile still needs an out-of-band mapping to the
session key and does not itself prove durable Node identity.
