# Changelog

## 0.3.0-beta.1

Release candidate prepared for local beta verification.

- Public `nimocapn` package entrypoint with durable identity, Node configuration,
  bootstrap, invocation, typed capability arguments, diagnostics, limits and
  graceful shutdown.
- TCP testing, Tor Onion testing, and project-specific mutual-TLS profiles are
  explicitly separated; no transport silently downgrades security.
- Reproducible local `file://` Nimble installation and external consumer smoke
  test.
- Local Syrup/Locator, lifecycle, handoff, cancellation, diagnostics, stress,
  TLS, deployment and transport regression suites pass.
- Glowcap conformance passes 24/24 in three consecutive runs.

Known limitations: the OCapN/Syrup revisions are pinned draft specifications;
cross-peer `op:listen` modes 1/2/3 remain partial, Goblins reconnect/cleanup
coverage is incomplete, and Tor E2E requires externally configured services.

## 0.2.0-alpha

Added the first OCapN Onion transport profile on top of an externally managed
Tor daemon.

- SOCKS5 OnionTransport and external Onion Service listener using the local
  `onion` locator profile.
- Explicit `torTest` integration command; without
  `NIM_OCAPN_ONION_SERVICE` it reports `SKIP`, while configured connection
  failures are test failures.
- Confirmed real Nim↔Nim Onion CapTP handshake, pipelined greet call, and
  orderly session cleanup on the Fedora mini test host.
- Added explicit three-node, four-node, and concurrent Onion handoff harnesses;
  these require separate externally configured Onion Service IDs and remain
  unverified until run with those services.
- Onion handoff listeners now use nonblocking readiness-gated accept; pending
  accepts are serviced fairly from the bounded multi-peer pump loop.
- Onion handoff, Tor/CapTP identity binding, production channel security, and
  full OCapN compliance remain unconfirmed.

## 0.1.0-alpha

Initial alpha of the independent Nim 2.x OCapN/CapTP prototype.

- Syrup codec, framing, Ed25519 session handshake, references, promises, and
  testing-only TCP transport.
- Multi-session TCP manager with bounded polling work and output backpressure.
- Import/export lifecycle, disconnect handling, handoff, typed arguments, and
  automatic capability transfer.
- Promise-valued arguments across three peers with preserved identity,
  shortening, chained settlement, break propagation, and independent promises.
- `op:listen` mode 1/2/3 matrix coverage, descriptor-aware listener lifecycle,
  duplicate/stale GC protection, disconnect/reconnect fault tests, and exposed
  listener lifecycle diagnostics.
- Nim↔Nim and Nim↔Glowcap interoperability tests.
- Local Nimble commands cover the full test task and compilation of public
  examples.

The tested profile does not provide production channel security or a complete
distributed-GC collector for arbitrary independent runtimes. Persistence,
actor runtime, scheduler, and VM integration are also outside this alpha.
