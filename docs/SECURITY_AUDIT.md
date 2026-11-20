# Security Audit

## Findings

| ID | Finding | Severity | Evidence / consequence | Required action |
|---|---|---|---|---|
| S1 | TCP testing transport is plaintext and unauthenticated as a channel | High for production | `src/transport.nim`, `src/server.nim`; an attacker can observe, inject, or terminate traffic | Keep it testing-only; define and test an authenticated production netlayer |
| S2 | Default TCP/Onion channels are not authenticated despite durable Node identity | High for authorization | `src/server.nim`, `src/api.nim`, and `src/handoff.nim` use fresh per-session keys by default; default raw TCP/Onion channel security and durable Node-to-session binding remain absent | Keep TCP and default/inbound Onion testing-only; use mutual TLS or the explicit outbound Onion endpoint profile within its documented trust model |
| S3 | Onion Service ID is not cryptographically bound to CapTP public key | High for durable peer authorization | Strict Sessions now compare the signed advertised locator and an external expected CapTP key, but `src/onion.nim` cannot prove that the Tor Service ID owns that key | Keep default/inbound Onion unauthenticated; use the explicit endpoint-auth profile only within its documented trust model |
| S10 | Onion server profile authenticates the endpoint, not durable CapTP ownership | High if mis-scoped | The explicit profile trusts Tor's exact Service-ID routing and binds only the fresh CapTP key on that stream | Use only with a trusted Tor daemon and `authenticatedOnionPolicy`; do not claim durable identity binding or client authentication |
| S11 | Tor client authorization is not CapTP client authentication | High if confused | X25519 credentials control descriptor/service access, but Tor does not pass the credential or a signed CapTP-key binding to `Session` | Configure credentials in the external Tor daemon; use a separate CapTP trust anchor for client authorization |
| S12 | Onion client durable identity is application-level, not a CapTP/netlayer identity | High if mis-scoped | The opt-in authentication capability signs a session-bound challenge, but only after the standard Session exists | Require the authenticated Onion profile, trusted client keys, and protected publications; do not advertise this as universal OCapN mutual authentication |
| S8 | No official OCapN authenticated netlayer is implemented | High for production interoperability | `src/tls_transport.nim` supplies real mutual-TLS evidence, but it is a project-specific profile and not an official OCapN netlayer | Keep the TLS profile explicitly project-specific; obtain an official profile before claiming OCapN production-netlayer interoperability |
| S9 | Project TLS profile is not an official OCapN netlayer | Medium | `src/tls_transport.nim` requires CA, certificate fingerprint, and CapTP-key mapping; independent peers do not automatically interoperate | Keep the profile explicit and separately documented |
| S4 | Replay protection is scoped to session/gift state, not a durable global anti-replay store | Medium | Redeemed gift tombstones reject repeated receive/deposit while the GiftTable lives; they are cleared on owner shutdown | Define durable reconnect/replay semantics if cross-process replay protection is required |
| S5 | Handoff accepts a legacy inbound gift form for Glowcap compatibility | Medium | `gifts.nim` and protected withdraw paths distinguish provenance; legacy deposits are not a production authorization profile | Keep legacy mode explicit and disabled for protected production profiles |
| S6 | Resource limits are per session/manager, not a system-wide admission policy | Medium | `SessionLimits`, `HandoffLimits`, and bounded TCP output exist | Add deployment-level quotas and observability before hostile exposure |
| S7 | Error text crosses the CapTP boundary | Low/Medium | `breakPromise` and protocol errors carry reason strings | Define an error disclosure policy; avoid secrets/backtraces in remote reasons |

## Batch B controls

- `src/identity.nim` provides versioned, checksummed, `0600` durable storage,
  explicit replacement, and lock-based creation.
- A Node-provided identity persists as the durable Node trust anchor/public
  identity; default accepted, outbound, reconnect, and handoff Sessions use
  fresh per-session signing keys.
- Strict Sessions independently verify the expected peer key and the signed
  acceptable-location before setting `peerVerified`; failures close the
  session before capabilities are exposed.
- The TLS profile uses OpenSSL mutual certificate verification and pinned
  certificate fingerprints; CapTP identity is accepted only through the
  configured fingerprint-to-key mapping.
- Authenticated policy rejects missing, unknown, downgraded, or mismatched
  transport evidence; it does not trust `peerAuthenticated()` alone.
- `PeerVerificationPolicy` supports exact expected session keys and fail-closed
  authenticated-netlayer policy. `Node.connectVerified` exposes the exact-key
  path without changing CapTP wire records; reconnect requires a new pin.
- `Node.connectMutualTls` rejects a testing-only policy before opening a TLS
  socket; certificate authentication is not silently treated as CapTP peer
  authorization without the authenticated-netlayer policy.
- The inbound TLS facade uses the same Session registry and fail-closed
  verification path. Exact peer-key pinning is available; explicit unpinned
  mode binds the authenticated TLS channel to the actual signed ephemeral
  session key but does not prove durable Node ownership.
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
  The isolated real-Tor runner (`nimble onionE2eTest`) proves v3 routing,
  handshake, pipelining, reconnect, concurrent clients, failure handling, and
  cleanup, but does not change this security boundary.
- Redeemed gift IDs are retained as session/table-local tombstones; repeated
  receive or deposit cannot issue the capability twice.
- The explicit outbound Onion server profile is separate from the default:
  `authenticateServer=true` plus `authenticatedOnionPolicy(peer)` accepts only
  the `tor-onion-service-v3` evidence and binds the current CapTP key. Inbound
  Onion transports never produce this evidence.
- Tor v3 client authorization is supported only as an external-daemon test and
  deployment control. Allowed/revoked credentials are tested, but the
  credential is never treated as a CapTP identity or durable Node identity.
- The opt-in client authentication capability exposes no protected publication
  before verification. Its Ed25519 proof is bound to a fresh challenge, both
  per-session keys, Session ID, Onion Service ID, and role labels; failed proof
  closes the affected Session and clears its exports.
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

Only the explicit outbound `authenticateServer` profile may set
`OnionTransport.authenticated`; the default and every inbound Onion transport
remain unauthenticated. This profile is endpoint authentication, not durable
Onion-to-CapTP key ownership.

## Tor-5 client-authentication hardening

The project-specific Onion client-authentication profile now has an explicit
boundary for protected capability transfer:

- challenges expire on a monotonic deadline (30 seconds by default);
- a challenge is consumed on success or rejected on expiry/failure;
- protected publications are marked at export creation;
- protected gifts are withdrawn only by a Session in `casAuthenticated`;
- auxiliary handoff Sessions are not implicitly authenticated.

The canonical proof still uses server-held Session state: the actual nonce,
both ephemeral CapTP keys, Session ID, configured Onion Service ID and
role-separated domain data. The real Tor runner covers unknown durable keys,
replay, wrong Onion policy, revoked credentials, repeated/concurrent Sessions
and cleanup. This remains an application profile over ordinary CapTP, not a
universal OCapN authenticated netlayer.
