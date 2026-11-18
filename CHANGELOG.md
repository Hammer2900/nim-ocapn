# Changelog

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
- CI covers Nim 2.0/2.2/2.4, the full test task, and compilation of all public
  examples.

The tested profile does not provide production channel security or a complete
distributed-GC collector for arbitrary independent runtimes. Persistence,
actor runtime, scheduler, and VM integration are also outside this alpha.
