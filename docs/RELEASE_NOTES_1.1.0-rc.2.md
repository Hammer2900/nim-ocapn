# nim-ocapn v1.1.0-rc.2

This is a scoped protocol-library release candidate. It does not claim a
universal authenticated OCapN netlayer or complete advanced interoperability
with every independent peer.

## Included

- Correct external `desc:answer` → `desc:import-promise` pipeline routing.
- Bidirectional Nim ↔ Goblins pipeline evidence for fulfillment, rejection,
  repeated delivery, duplicate settlement, and disconnect cleanup.
- Three-process handoff, failure-injection, reconnect, and distributed-GC
  lifecycle coverage.
- Bounded multi-Onion readiness probes with topology and Tor diagnostics.

The public facade remains source-compatible with RC1. The low-level
`HandoffManager` gained optional session opener/preparer hooks; these are
experimental and additive, and are not required by ordinary facade users.

## Security and transport scope

- Session-local authentication and protected capability authorization remain
  fail-closed.
- The mutual TLS and durable-client authentication profiles are
  project-specific.
- Raw TCP and default/inbound Onion remain testing-only.
- The multi-Onion protected A/B/C Tor fixture currently reports
  `ENVIRONMENT FAILURE` on SOCKS5 `0x04` before CapTP; this is not advertised
  as verified interoperability.

## Remaining limitations

`op:listen` modes 1/2/3, cross-peer handoff, and observable cross-peer
distributed GC remain `UNVERIFIED` or `UNSUPPORTED` where independent peer
drivers are unavailable. No CapTP/Syrup wire format or public facade change is
introduced by this candidate.
