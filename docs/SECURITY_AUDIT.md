# Security Audit

## Findings

| ID | Finding | Severity | Evidence / consequence | Required action |
|---|---|---|---|---|
| S1 | TCP testing transport is plaintext and unauthenticated as a channel | High for production | `src/transport.nim`, `src/server.nim`; an attacker can observe, inject, or terminate traffic | Keep it testing-only; define and test an authenticated production netlayer |
| S2 | TCP/Onion channel is not authenticated despite durable CapTP identity | High for authorization | `src/identity.nim`, `src/server.nim`, `src/api.nim`, and `src/handoff.nim` use the durable seed for every Node Session; raw TCP/Onion channel security remains absent | Keep TCP/Onion testing-only; use the explicit mutual-TLS profile where its trust anchors are configured |
| S3 | Onion Service ID is not cryptographically bound to CapTP public key | High for peer authorization | Strict Sessions now compare the signed advertised locator and an external expected CapTP key, but `src/onion.nim` cannot prove that the Tor Service ID owns that key | Keep Onion `authenticated=false`; add a normative/authenticated binding mechanism |
| S8 | No official OCapN authenticated netlayer is implemented | High for production interoperability | `src/tls_transport.nim` supplies real mutual-TLS evidence, but it is a project-specific profile and not an official OCapN netlayer | Keep the TLS profile explicitly project-specific; obtain an official profile before claiming OCapN production-netlayer interoperability |
| S9 | Project TLS profile is not an official OCapN netlayer | Medium | `src/tls_transport.nim` requires CA, certificate fingerprint, and CapTP-key mapping; independent peers do not automatically interoperate | Keep the profile explicit and separately documented |
| S4 | Replay protection is scoped to session/gift state, not a durable global anti-replay store | Medium | Redeemed gift tombstones reject repeated receive/deposit while the GiftTable lives; they are cleared on owner shutdown | Define durable reconnect/replay semantics if cross-process replay protection is required |
| S5 | Handoff accepts a legacy inbound gift form for Glowcap compatibility | Medium | `gifts.nim` and protected withdraw paths distinguish provenance; legacy deposits are not a production authorization profile | Keep legacy mode explicit and disabled for protected production profiles |
| S6 | Resource limits are per session/manager, not a system-wide admission policy | Medium | `SessionLimits`, `HandoffLimits`, and bounded TCP output exist | Add deployment-level quotas and observability before hostile exposure |
| S7 | Error text crosses the CapTP boundary | Low/Medium | `breakPromise` and protocol errors carry reason strings | Define an error disclosure policy; avoid secrets/backtraces in remote reasons |

## Batch B controls

- `src/identity.nim` provides versioned, checksummed, `0600` durable storage,
  explicit replacement, and lock-based creation.
- A Node-provided identity is now the signing key for accepted, outbound, and
  handoff Sessions; restart and reconnect preserve the wire public key.
- Strict Sessions independently verify the expected peer key and the signed
  acceptable-location before setting `peerVerified`; failures close the
  session before capabilities are exposed.
- The TLS profile uses OpenSSL mutual certificate verification and pinned
  certificate fingerprints; CapTP identity is accepted only through the
  configured fingerprint-to-key mapping.
- Authenticated policy rejects missing, unknown, downgraded, or mismatched
  transport evidence; it does not trust `peerAuthenticated()` alone.
- `PeerVerificationPolicy` supports exact expected keys and fail-closed
  authenticated-netlayer policy. `Node.connectVerified` exposes the exact-key
  path without changing CapTP wire records.
- Verification is session-local and occurs before the session is marked open;
  rejected sessions clear pending state and do not publish capabilities.

## Controls already present

- Ed25519 signatures are verified over canonical encoded hello/handoff values in
  `src/session.nim` and `src/messages.nim`.
- Handoff receive certificates check receiver key, session/side identity,
  signature, count, gift ID shape, and provenance where available.
- Descriptors and positions are validated before table access; stale and
  duplicate GC is rejected rather than silently freeing a second reference.
- Frame size, pending promises, import/export counts, handoff work, and outbound
  queue sizes have configurable limits.
- Protocol/framing failures close only the affected session; pending promises
  are broken and session-local tables are cleared.
- Onion SOCKS5 success is deliberately not reported as CapTP authentication.
- Redeemed gift IDs are retained as session/table-local tombstones; repeated
  receive or deposit cannot issue the capability twice.
- Deterministic fault-injection tests cover cancellation, delayed delivery,
  duplicate delivery, concurrent receivers, disconnect cleanup, and reconnect
  isolation without changing CapTP wire semantics.
- Nested capability descriptors are recursively accounted when a delivery is
  released; forwarding keeps the source import until downstream wire ownership
  is gone, then closes release state with the owning Session.

## Not yet proven

No audit currently proves resistance to an active attacker who can substitute a
locator, obtain a valid independent session key, replay traffic across a
reconnect, or inject data through a compromised/incorrect netlayer. The
implementation has deterministic unit tests and real Onion routing tests, but
production channel security and peer authorization remain outside the current
profile.

## Priority security batch

1. Define the exact binding between a netlayer-authenticated peer and the
   `op:start-session` key.
2. Add durable cross-restart replay tests if the deployment requires replay
   protection beyond one GiftTable lifetime.
3. Add system-wide quotas and bounded cleanup tests under hostile input.
4. Prove release ordering for arbitrary hostile forwarding graphs and durable
   cross-process recovery if those guarantees become a deployment requirement.

Do not call `OnionTransport.authenticated` true until these rules are specified
and verified.
