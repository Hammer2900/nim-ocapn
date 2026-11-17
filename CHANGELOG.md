# Changelog

## 0.1.0-alpha

Initial alpha of the independent Nim 2.x OCapN/CapTP prototype.

- Syrup codec, framing, Ed25519 session handshake, references, promises, and
  testing-only TCP transport.
- Multi-session TCP manager with bounded polling work and output backpressure.
- Import/export lifecycle, disconnect handling, handoff, typed arguments, and
  automatic capability transfer.
- Nim↔Nim and Nim↔Glowcap interoperability tests.

This release does not provide production channel security, distributed GC,
persistence, actor runtime, scheduler, or VM integration.
