# v1 Security and API Decision

Decision date: 2026-11-19  
Audit commit: `e915486`  
Package: `1.0.0` (`v1.0.0` scoped stable)

This document records the smallest defensible v1 scope after the P7 readiness
audit. P10 adds one explicit identity-profile setting without changing the
wire format or transports.

## 1. Normative boundary

The selected baseline is:

- OCapN: `ebf68742a40a89fff4730886a8788c5fe1bc9b96`;
- Syrup: `931fa528b8ddda976febba577fb09ee0726845d4`.

The pinned documents are drafts, not a stable OCapN 1.0 release.

### Netlayers

`../ocapn/draft-specifications/Netlayers.md` requires a netlayer to provide:

- bidirectional message transmission;
- ordered delivery while the session is active;
- session security such that only session participants can insert messages.

Encryption and protection from observation are described as desirable, not as
universal technical requirements. The document explicitly allows multiple
netlayers, including TCP and Tor Onion, and requires each netlayer to define
its locator information. A designator is conventionally self-authenticating,
but the specification does not require that property for every netlayer.

The Tor section defines the Onion Service ID as the `onion` locator designator.
It does not define a certificate, signature, or key-derivation rule binding
that Service ID to a CapTP Ed25519 key.

### CapTP identity

The pinned CapTP specification says that each side **MUST create a
per-session cryptography key pair** when initializing a connection. It carries
that session public key and a signature over the acceptable location in
`op:start-session`; the public identifier and session ID are derived from the
per-session key. This authenticates the session transcript when the key is
trusted; it does not make an unauthenticated key an authorized peer.

The implementation follows this boundary in `src/session.nim`:

- `verifyPeerPolicy()` applies `pvmTestingOnly`, `pvmExactIdentity`, or
  `pvmAuthenticatedNetlayer`;
- `setExpectedPeer()` checks the advertised locator separately;
- `pumpImpl()` verifies the `op:start-session` signature before opening the
  session;
- capabilities are processed only after the session reaches `ssOpen`.

The strict/default Node path now follows the per-session requirement. Empty
session seeds cause `newSession`/`newGlowcapSession` to generate a fresh
cryptographic seed; the server accept path, outbound Node connections, and
auxiliary handoff sessions use that default. The durable Node key remains a
local trust anchor and public identity, but is not used as the CapTP session
key on the wire.

`SessionIdentityMode.simLegacyDurable` is an explicit project-specific
compatibility mode. It requires a loaded durable identity and deliberately
reuses it as the session key for legacy peers. No handshake failure or
verification error silently selects this mode. It is not strict CapTP identity
semantics and is not recommended for new deployments.

There is no normative rule in the pinned baseline that equates an Onion
Service ID with a CapTP public key. Comparing their strings or raw bytes would
therefore be an invented authentication scheme and is intentionally not done.

## 2. Security profile matrix

| Profile | Authentication | Confidentiality/integrity | Locator binding | Interoperability | Decision |
|---|---|---|---|---|---|
| Raw TCP | None by default; optional exact CapTP key policy | No channel confidentiality; CapTP framing/signatures alone are not a secure channel | Expected locator and expected CapTP key can be checked independently | Broad testing interoperability | Testing-only |
| Tor Onion | Default routing is unauthenticated; explicit outbound profile authenticates the expected endpoint through a trusted Tor daemon | Tor supplies routing encryption; no durable Onion-to-CapTP ownership proof | Explicit profile binds the fresh CapTP key to the expected stream, not to the Onion private key | Real isolated Tor v3 E2E; external authenticated interop unavailable | Testing by default; narrow project-specific endpoint-auth profile |
| Project mutual TLS | Certificate/CA and fingerprint checks plus explicit CapTP-key mapping | TLS channel confidentiality and integrity | Trust configuration binds the TLS peer to the expected CapTP key | Verified in the project-specific Nim↔Nim profile | Narrow authenticated profile |
| Official OCapN authenticated netlayer | Not defined by the pinned baseline as one universal profile | Netlayer-specific | Netlayer-specific | Not verified | Unavailable |

Implementation evidence is in `src/transport.nim`, `src/onion.nim`,
`src/tls_transport.nim`, and `src/session.nim`. `TransportAuthEvidence` is
accepted only through `pvmAuthenticatedNetlayer`; empty evidence from TCP,
Onion, or in-memory transports fails closed.

The minimum supportable v1 security scope is therefore either exact expected
CapTP-key authorization over a chosen channel, or the project-specific mutual
TLS profile with explicit trust anchors. Neither makes raw TCP or Onion safe
for arbitrary hostile Internet deployments.

## 3. Onion identity binding assessment

The current flow is:

1. `src/locators.nim` parses an `ocapn-peer` locator whose `onion` designator
   is the Tor Service ID.
2. `src/onion.nim:socks5Connect()` sends that designator to the external Tor
   SOCKS5 proxy and records routing/endpoint state.
3. Tor accepts the connection at the configured local service port.
4. `src/session.nim:pumpImpl()` validates the CapTP `op:start-session`
   signature and the advertised acceptable location.
5. `verifyPeerPolicy()` may compare the session key with an explicitly pinned
   key, but Onion transport supplies no authenticated key evidence.

This proves three different facts only when stated separately:

- SOCKS routing reached the requested Onion designator;
- the remote endpoint completed a valid CapTP handshake;
- the remote CapTP key is authorized only if an explicit expected-key policy
  or authenticated netlayer trust anchor says so.

The pinned Netlayers document does not specify a netlayer-level binding between
the first and third facts. The project now provides a separate opt-in
application capability: after the standard Session is open, a trusted durable
client key signs a fresh challenge bound to both session keys, the Session ID,
the configured Onion Service ID, and explicit roles. Protected publications
are withheld until that proof succeeds. Status: **PARTIAL**: this authenticates
the client application key for one authenticated Onion Session, not a standard
OCapN netlayer identity or a durable server Node identity.

## 4. Public API stability decision

The intended application surface is the `nimocapn` facade (`src/nimocapn.nim`)
and the Node operations in `src/api.nim`: `NodeConfig`, `newNode`, identity
loading, `connectUsing`, `connectVerified`, `connectMutualTls`, `bootstrap`,
capability calls, bounded waits, diagnostics, `stats`, and `close`. The exact
authentication contract is recorded in `docs/API_STABILITY.md`.

The following exported state is not suitable for a long-term compatibility
promise:

- `Node.manager`, `Node.handoffs`, and other low-level mutable fields;
- `RemoteCapability.session` and `.reference`;
- `RemotePromise.session`, `.reference`, and `.promise`;
- direct `Session` fields including `references`, `pending`, `answers`, and
  lifecycle tables;
- direct construction/use of `ReferenceTables`, `HandoffManager`, and raw
  transports.

These fields can bypass ownership, reference accounting, policy checks, and
resource limits. `Node.identity`, `Node.verificationPolicy`, and
`Node.sessionIdentityMode` are now private; manager/handoff and Session fields
remain available for existing protocol tests and unusual integrations because
hiding them would be a larger breaking change.

### Minimal pre-v1 proposal

1. Treat only `nimocapn` and documented `src/api.nim` operations as stable.
2. Mark direct low-level module imports and exported mutable fields as
   experimental in the API guide.
3. Before v1, make internal fields private in one deliberate breaking change
   and retain read-only accessors for identity, state, and statistics.
4. Do not add wrappers for every internal table; expose only invariants users
   actually need (`isOpen`, peer identity status, stats, and close).

No API changes are required to ship the scoped beta. A v1 freeze without step
3 would make the current mutable internals part of the compatibility contract.

## 5. Hostile forwarding and lifecycle evidence

The existing deterministic suites were run against the current commit:

| Surface | Command | Result |
|---|---|---|
| Malformed frames, invalid GC, bounded answers/pipelines | `nimble robustnessTest` | PASS |
| Nested forwarding, stale callbacks, duplicate GC, disconnect cleanup | `nimble distributedGcTest` | PASS |
| Gift replay, duplicate delivery, concurrent receivers, late settlement | `nimble handoffFailureTest` | PASS |

Covered scenarios include repeated forwarding, stale answer/resolver use,
disconnect during forwarding, GC during active forwarding, duplicate wire
delivery, and session isolation. The implementation keeps forwarded origins
and retired positions in the shared registry in `src/session.nim`; close paths
release source references and break pending local promises.

There is no dedicated test named for an arbitrary cyclic forwarding graph.
The current tests exercise bounded forwarding chains and nested references, but
do not constitute a proof for every possible cyclic graph. Status:
**PARTIAL/UNVERIFIED**, not a confirmed defect.

No reproducible lifecycle or forwarding defect was found in this audit, so no
production code was changed.

## 6. Release scope options

### A. Full secure OCapN v1.0

Required work:

- an authenticated netlayer profile accepted by the target OCapN baseline or a
  formally selected successor;
- a specified, cryptographically verified locator-to-peer binding for Onion or
  an explicit exclusion of Onion from the secure profile;
- independent-peer evidence for `op:listen`, pipelining, handoff, and GC;
- a deliberate public API freeze with mutable internals removed or hidden;
- stronger evidence for hostile forwarding graphs and replay state lifecycle.

This is a substantial interoperability and security program. It is not a
small follow-up to P7 and should not be implied by the current TLS profile.

### B. Scoped protocol-library v1.0

Scope the stable claim to:

- the pinned draft OCapN/Syrup profile;
- Nim↔Nim CapTP, promises, pipelining, handoff, GC, cancellation, and
  bounded resource behavior;
- exact expected CapTP-key authorization;
- the explicitly documented project mutual-TLS profile;
- testing-only raw TCP and Onion routing.

Out of scope for the stable security claim: arbitrary untrusted TCP/Onion
deployment, official authenticated-netlayer interoperability, and any
cross-peer operation not independently verified. This option is honest and
achievable, but it is not a claim of secure OCapN operation over the public
Internet.

## 7. Recommendation and minimal implementation plan

Recommend **Option B**, with the name and documentation making the scoped
profile explicit. Keep the current package in beta until these items are
completed:

1. Freeze the facade/API guide and add deprecation wording for low-level
   mutable fields.
2. Decide whether v1 excludes Onion from authenticated deployment; do not
   implement a guessed Service-ID binding.
3. Keep exact-key and project mutual-TLS tests as the only authenticated paths.
4. Add one deterministic cyclic-forwarding stress case if the protocol profile
   requires that topology; otherwise document it as outside the guarantee.
5. Re-run the existing full regression and independent-peer matrix at the final
   release candidate.

P10 resolves the durable-key versus per-session-key decision in favor of the
strict default. Exact peer verification therefore pins the current *session*
public key; a reconnect has a new key and an old exact-key pin is expected to
reject it. This preserves fail-closed verification but does not infer durable
Node authorization from a transient session key. Applications needing stable
legacy wire keys must opt into `simLegacyDurable` explicitly.

The project-specific mutual-TLS profile still needs an out-of-band mapping for
the expected CapTP session key. TLS does not automatically authenticate the
durable Node identity, and no such binding is invented here.

The public `connectMutualTls` path now requires
`pvmAuthenticatedNetlayer` before opening the TLS socket. Its optional explicit
session seed supports the existing out-of-band mapping; it does not turn a
testing-only policy into authenticated peer verification.

Option A should be reopened only after an upstream or explicitly selected
netlayer binding specification exists. The smallest correct change now is a
scope/API decision, not another transport abstraction.

