# Changelog

## 1.1.0-rc.2

Release candidate focused on lifecycle correctness, independent promise
pipeline coverage, and honest Tor readiness reporting.

- Fixes routing when an external peer pipelines through an answer that
  delivers an unresolved `desc:import-promise`.
- Adds Goblins → Nim success, rejection, repeated-delivery, duplicate
  settlement, and disconnect regression coverage.
- Adds three-process handoff/failure lifecycle coverage and bounded resource
  cleanup checks.
- Adds multi-Onion topology, local-listener, SOCKS5, and Tor-log diagnostics.
- Preserves the standard Syrup/CapTP wire format and fresh per-session keys.

Known limitation: protected multi-Onion A/B/C currently remains an
`ENVIRONMENT FAILURE` when Tor returns SOCKS5 `0x04` before CapTP. This is not
claimed as protocol interoperability. Advanced `op:listen`, cross-peer
handoff, and observable cross-peer distributed GC remain unverified or
unsupported.

## 1.1.0-rc.1

Scoped release candidate for the project-specific authenticated Onion
deployment profile.

- Adds real isolated Tor v3 E2E coverage for routing, client authorization,
  reconnect, concurrency, revocation and cleanup.
- Adds application-level durable client identity authentication over an
  authenticated Onion CapTP Session.
- Adds single-use challenge expiry and fail-closed protected capability
  publication and handoff behavior.
- Preserves the standard Syrup/CapTP wire format and fresh per-session Ed25519
  identities.

Security scope: the Onion mutual endpoint profile is project-specific
application authentication, not a universal authenticated OCapN netlayer. It
does not prove durable server Node identity. Raw TCP and default Onion remain
testing-only; advanced independent-peer interoperability remains partial.

## 1.0.0

Scoped stable protocol-library release prepared from `v1.0.0-rc.1` without
wire-format or protocol-scope changes.

- Confirms the documented public `nimocapn` facade, strict per-session identity,
  promises/pipelining, handoff, distributed GC, cancellation, diagnostics,
  resource limits, and project-specific mutual TLS profile.
- Raw TCP and Tor Onion remain testing-only profiles; mutual TLS remains a
  project-specific authenticated profile rather than a universal OCapN netlayer.
- Advanced cross-peer `op:listen`, handoff, pipelining, and distributed-GC
  interoperability remain partially unverified or unsupported.

## 1.0.0-rc.1

Scoped protocol-library release candidate prepared for local verification.

- Public `nimocapn` package entrypoint with durable identity, Node configuration,
  bootstrap, invocation, typed capability arguments, diagnostics, limits and
  graceful shutdown.
- TCP testing, Tor Onion testing, and project-specific mutual-TLS profiles are
  explicitly separated; no transport silently downgrades security.
- Reproducible local `file://` Nimble installation and external consumer smoke
  test.
- Local Syrup/Locator, lifecycle, handoff, cancellation, diagnostics, stress,
  TLS, deployment and transport regression suites pass.
- Basic Nim↔Glowcap interoperability is verified. The separate Glowcap
  24/24 × 3 conformance runner was not available in this checkout and remains
  UNVERIFIED for this candidate.

Known limitations: the OCapN/Syrup revisions are pinned draft specifications;
cross-peer `op:listen` modes 1/2/3 remain partial, Goblins reconnect/cleanup
coverage is incomplete, and Tor E2E requires externally configured services.
The project-specific mutual-TLS profile is not an official OCapN netlayer, and
raw TCP/Onion remain testing-only profiles.

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
