# Roadmap to v1

## Batch B status

- B1 durable identity: implemented as versioned, checksummed local storage
  with explicit replacement and safe file permissions. The durable key is a
  Node trust anchor/public identity; default Sessions do not reuse it as their
  CapTP wire key.
- B2 expected peer policy: implemented for exact CapTP session public keys;
  testing-only mode remains explicit in the model and authenticated-netlayer
  mode fails closed without proof.
- B3 locator/session binding: partial. Strict Sessions compare the signed
  advertised locator with the expected locator and independently verify the
  expected CapTP key. TCP and Onion still do not provide production ownership
  binding between the transport designator and that key.

### P9/P10 status

The pinned CapTP draft says each side MUST create a per-session cryptography
key pair and requires that session public key/signature in `op:start-session`.
The default `simPerSession` profile now creates a fresh key for every outbound,
accepted, reconnect, and auxiliary handoff Session. `simLegacyDurable` retains
the old stable wire key only as an explicit project-specific compatibility
mode; it is never selected after a handshake or verification failure.

Exact peer verification consequently pins the current CapTP session key, not
the durable Node key. Reconnect creates a new key and must be provisioned with
a new exact pin. This is fail-closed, but it does not claim a normative binding
between a durable Node identity and an ephemeral session key.

The documented `nimocapn` facade is the intended stable API. Low-level mutable
`Node`/`Session`/reference-table fields remain experimental until a deliberate
pre-v1 breaking freeze can replace them with minimal read-only accessors.
The deterministic A→B→A forwarding-cycle regression passes; no lifecycle
defect was found.

The remaining security work is to define any authenticated netlayer trust
binding that is actually supported by an upstream profile; Onion Service IDs
remain unbound to CapTP keys.

This roadmap is based on the pinned draft OCapN documents and the audit of
commit `31012070f3d8291b7177640b186e10060972b245`. It does not change the
wire format, tags, or release metadata.

## P0 — correctness, security, interoperability

1. **Pin a specification/profile revision.** Record exact CapTP, Locator,
   Netlayer, and Syrup revisions and regenerate the compliance matrix.
2. **Define node identity policy.** Add explicit durable identity configuration,
   expected-peer checks, key rotation rules, and negative tests. Touch
   `crypto.nim`, `session.nim`, `api.nim`; depends on item 1.
3. **Define locator/session binding.** Specify how a netlayer-authenticated peer
   binds to the CapTP hello key, especially for Onion Service IDs. Touch
   `onion.nim`, `session.nim`, and transport tests.
4. **Introduce one authenticated netlayer adapter seam.** The evidence
   contract, fail-closed checks, and a real project-specific mutual-TLS
   provider are present. Official OCapN netlayer interoperability remains
   unverified.
5. **Complete handoff failure/replay matrix.** Core one-time gift redemption,
   duplicate rejection, concurrent receiver arbitration, cancellation, and
   deterministic fault tests are implemented. Full durable anti-replay across
   process restarts remains open.
6. **Finish distributed-GC proof and tests.** Session-local ownership,
   recursive nested release, forwarding cleanup, disconnect and reconnect
   regressions are covered in `docs/DISTRIBUTED_GC_MATRIX.md`. A formal proof
   for arbitrary hostile forwarding graphs and durable cross-process state is
   still open.
7. **Run unmodified peer interoperability.** Keep the abort compatibility note,
   but separately run the upstream fixture without normalization and report the
   fixture mismatch as such. The pinned Glowcap CLI now passes two-way
   bootstrap/fetch/invocation in `nimble interopTest`; advanced scenarios remain
   unsupported or unverified because the peer CLI does not expose them.

### P0-7 status

The pinned Glowcap `0.1.7` CLI passed two-way bootstrap, fetch, invocation,
and promise settlement as an unmodified external process. This closes the
supported portion of P0-7. Handoff, external pipelining, malformed-message,
and production transport scenarios remain explicitly unsupported or
unverified; see `docs/INTEROPERABILITY_MATRIX.md`.

The next concrete item after the completed local P1-8 work is **P1-9**:
strict Locator/Syrup vectors. Its remaining profile-selector limitation is
recorded below.

## P1 — normative completeness

8. Complete cross-peer `op:listen` modes 1/2/3 matrix, including external peers.
   Local normative coverage is complete for direct, break, same-peer chains,
   repeated shortening, duplicate listeners, invalid modes, and disconnect;
   the item remains PARTIAL until an independent peer exposes selectable mode
   1/2/3 scenarios.
9. **Expand strict locator/Syrup vectors.** P1-9 vectors now cover URI
   percent-encoding, Unicode/UTF-8, empty hint values, duplicate hints,
   canonical byte ordering, nested values, and fragmented/truncated input.
   Strict parsing rejects malformed percent encodings, fragments, invalid
   UTF-8, duplicate keys, and empty sturdyref swiss numbers. The item remains
   PARTIAL as long as the public decoder has no explicit strict/legacy profile
   selector and continues accepting Glowcap's binary swiss-number form.
10. **Define cancellation and timeout semantics for public calls and handoffs.**
    Implemented for local observation, answer/gift cleanup, bounded waits,
    late callbacks, and independent calls. Remote execution cancellation is
    not claimed because the selected CapTP profile has no such operation.
11. **Add transport-neutral conformance tests run unchanged over TCP and Onion.**
    The shared local scenarios pass over in-memory and raw TCP; the same
    supported scenarios pass over the project TLS profile. Onion remains
    conditional and is reported SKIP without a configured service.
12. **Verify bootstrap/sturdyref against a second independent implementation.**
   Guile Goblins is pinned as the candidate peer (`2771da67e80b5c2a9e4ed684f24f4f95428cb419`,
   `v0.18.0-40-g2771da6`) and `nimble independentInteropTest` runs its
   unmodified upstream OCapN suite. The isolated Nim bootstrap/sturdyref/
   invocation path and upstream start-session/deliver modules pass with the
   pinned runtime. Reconnect/cleanup remain UNVERIFIED, while the complete
   repeated-session suite is UNSUPPORTED by the pinned fixture lifecycle.

## P2 — API and operations

13. Add public identity/configuration and unified netlayer selection API.
14. Add structured diagnostics/metrics and bounded fault-injection harnesses.
15. **Document deployment and operational hardening.** The deployment,
    operations, and troubleshooting guides cover clean installation, identity
    files, transport profiles, limits, diagnostics, and graceful shutdown.
    `nimble deploymentTest` covers the public examples, restart, signals,
    occupied ports, invalid identity paths, and cleanup.
16. **Prepare beta packaging and reproducible release.** The public
    `nimocapn` entrypoint, package exclusions, isolated consumer smoke test,
    local release checklist, and `RELEASING.md` are present.
    Stable version: `v1.0.0` (`1.0.0` in Nimble); no tag or
    publication is created.

## Recommended independent batches

- **Batch A:** profile pinning + compliance matrix + strict Syrup/locator vectors.
- **Batch B:** identity policy and locator binding design/tests.
- **Batch C:** netlayer adapter seam, with existing TCP/Onion regression tests.
- **Batch D:** handoff/GC failure matrix and long-run cleanup.
- **Batch E:** public API improvements and documentation.

Batches A and D can begin in parallel. Batch B should precede production
netlayer work; Batch C depends on B's identity metadata decision. Public API
changes should wait until the identity/netlayer contract is stable.

### P1-9 status

The pinned Syrup and Locator vectors pass through `nimble complianceTest`.
The implementation changes only strict validation and canonical URI emission;
the legacy binary swiss-number acceptance remains unchanged for Glowcap. The
remaining gap is profile selection, not an untested malformed-input path.

### P1-10 status

`nimble cancellationTest` covers timeout, cancellation before/after send,
late fulfillment, competing settlement, independent calls, handoff waiter
cleanup, and gift replay after cancellation. The next item is P1-11:
transport-neutral conformance tests over TCP and Onion.

### P1-11 status

`nimble transportConformanceTest` runs the common scenario harness over
in-memory and raw TCP, the extended two-process TLS profile, and the existing
Tor test when configured. P1-12 is pinned to Guile Goblins. The isolated
Nim↔Goblins bootstrap/sturdyref/invocation path now passes with
the pinned external runtime. Broader reconnect/cleanup coverage remains
UNVERIFIED, and the full repeated-session suite is UNSUPPORTED by the pinned
fixture lifecycle.

## First implementation batch

Batch A is complete as a documentation and vector baseline. P1-11 is complete
for the supported local/TLS profiles. P1-12 has a reproducible external runner
and a real Nim↔Goblins bootstrap/sturdyref/invocation PASS. Do not advance to
P2-13 yet: close the remaining Goblins reconnect/cleanup and broader suite
coverage, or document them as unsupported by a newer pinned Goblins harness.

### P2-13 status

The public facade now supports durable identity paths, explicit peer policy,
peer locator publication, bootstrap, explicit TCP/Onion selection, bounded
polling, and idempotent shutdown. Mutual TLS has explicit client and inbound
listener paths under `-d:ssl`; the listener reuses the Node Session registry,
while Onion inbound serving remains outside the public facade and no security
downgrade is allowed.

P2-14 covers structured diagnostics and application-facing operational limits.

### P2-14 status

`DiagnosticEvent`/`DiagnosticSink`, Node snapshots, active-session admission,
and existing Session/Transport/Handoff limits are exposed through
`NodeConfig`. Limits reject excess work without a global Node shutdown, and
the deterministic suite is `nimble diagnosticsTest`. The next item is P2-15:
deployment documentation and operational hardening.

### P2-15 status

Deployment profiles, optional dependencies, persistent identity operation,
bounded process lifecycle checks, signal shutdown, port failure handling, and
troubleshooting are documented. `nimble deploymentTest` builds both public
examples in isolated Nim caches and verifies invocation, restart, SIGINT/SIGTERM,
occupied ports, invalid identity paths, and cleanup. The next item is P2-16:
beta packaging and release reproducibility.

### P2-16 status

Packaging metadata, the public entrypoint, isolated consumer build, local
release checks, release checklist, and reproducible release instructions are prepared. Registry
publication, the proposed beta tag, Tor E2E, Goblins reconnect/cleanup, and
broader external `op:listen` interoperability remain explicitly unverified.

### P3-Next status

`nimble advancedInteropTest` adds a bounded independent Glowcap driver for two
sequential Nim→Glowcap sessions using persistent peer state. The same harness
reports `UNVERIFIED` for selectable `op:listen` modes and `UNSUPPORTED` for
pipeline, handoff, and wire-level GC cases when the external peer exposes no
corresponding driver. Goblins remains `SKIP` without Guile 3.x and its pinned
`pre-inst-env`.

### P3-Goblins status

The independent Goblins runner now discovers the prepared local Guile/Goblins
environment when available and drives the unmodified pinned
`tests/ocapn-test-suite.scm` as a separate process. With Guile 3.0.9 and the
isolated Python `cryptography`/`stem` environment, Nim bootstrap, sturdyref
fetch, invocation, and a restarted-process invocation pass; upstream
start-session, deliver/promise, GC, listen, and handoff cases are also run.
The local SIGPIPE-safe wrapper now supports repeated Nim sessions. Durable
identity across process restart remains `UNVERIFIED` because pinned
`spawn-mycapn` has no persistent identity input. Strict `op:listen` modes,
Nim-originated promise pipelining, handoff, and observable distributed GC
remain `UNVERIFIED`; Goblins' legacy listener form and upstream-directed
scenarios use a different direction/profile. No Goblins source is modified.

### P4 robustness status

The bounded robustness suite covers malformed Syrup, frame-boundary errors,
fragmented/coalesced and zero-length frames, excessive nesting, deterministic
mutation inputs, malformed application operations, and duplicate answer-GC
positions. Syrup recursion is capped before descent and public frame decoder
limits must be positive. The suite is available as `nimble robustnessTest`
and `nimble fuzzTest`.

This hardening does not establish complete protocol fuzz coverage, durable
anti-exhaustion guarantees for every valid operation, or production security
for raw TCP and Onion transports.

### P5 resource lifecycle status

The resource harness covers 2,000 sequential invocations, 100 repeated
Session create/close cycles, unresolved-call admission, and post-cleanup
counter checks. Existing session limits now also bound inbound unresolved
answer slots, while duplicate inbound answer positions fail closed instead of
overwriting lifecycle state; queued pipeline requests use the same bound.
`nimble resourceTest` is the quick workload and `nimble enduranceTest` is the
extended workload.

The evidence is bounded for the exercised paths, not a proof of bounded memory
for every valid application workload. Valid long-lived sessions, arbitrary
forwarding graphs, and transport-specific kernel/resource limits remain
operational concerns. Redeemed gift replay tombstones also remain retained
until manager/table cleanup; eviction would require a separately specified
expiry policy and is intentionally not added here.

### P6 concurrency and replay status

`nimble concurrencyTest` exercises 1,000 simultaneous calls across four
independent Session pairs with reverse-order fulfillment, rejection, loaded
disconnect, and isolation checks. The existing event-loop ownership model is
explicit: Sessions and reference tables are not thread-safe. The testing-only
in-memory inbox now has a private 1 MiB bound and exposes queued bytes through
the existing transport statistics.

Gift replay protection remains lifecycle-bounded rather than size-bounded:
redeemed tombstones are retained until the owning GiftTable is cleared. No
automatic eviction or TTL was added because the current protocol profile does
not provide a safe expiry proof.

### P11 status

The supported facade and authentication contract are documented in
`docs/API_STABILITY.md`. `Node` no longer exposes direct mutation of its
identity, verification policy, or session identity mode; configuration remains
through `NodeConfig`. Low-level Session, manager, handoff, and reference-table
fields remain experimental for beta compatibility. Connection methods now
explicitly distinguish durable Node identity, ephemeral session keys, exact
current-session pins, and project-specific TLS evidence. No automatic downgrade
is permitted.

### P12 status

The public mutual-TLS connection path now rejects testing-only peer policy
before opening a socket. TLS certificate/fingerprint authentication and the
configured CapTP session-key mapping are verified independently by the
transport and Session handshake. The scoped release checklist is
`docs/RELEASE_CANDIDATE_CHECKLIST.md`; official universal authenticated
netlayers, Onion identity binding, and full advanced independent
interoperability remain outside the scoped v1 profile.

The P13 inbound TLS listener uses `NodeConfig.tlsServerConfig` and the same
Session registry as the TCP listener. Exact expected session-key pinning and
explicit certificate-backed unpinned ephemeral-key mode are supported; no
durable identity binding is inferred.
