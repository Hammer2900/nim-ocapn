# OCapN Compliance Matrix

This matrix describes the checked working tree of `../ocapn` at the time of
writing. The local Locator, Netlayer, and CapTP documents are explicitly draft
specifications and do not provide a pinned release or revision identifier.
Statuses therefore describe this prototype, not a claim of final OCapN
compliance.

## Locators

| Requirement | Nim implementation | Status | Priority / test |
|---|---|---|---|
| Peer locator fields: designator, transport, hints | `src/locators.nim`: `PeerLocator` | Implemented | P0; `tests/test_locators.nim` |
| Peer Syrup record `<ocapn-peer transport designator hints>` | `peerSyrup()` / `peerLocator()` | Implemented; transport symbols reject `.` | P0; locator round-trip and malformed tests |
| Hints are a map or `false` | `peerSyrup()` and parser | Implemented | P0; locator tests |
| Peer equality ignores hints | `samePeer()` | Implemented | P1; add broader URI identity coverage later |
| Peer URI `ocapn://designator.transport[?hints]` | `peerUri()` / `parsePeerUri()` | Implemented for current URI grammar | P0; URI round-trip test |
| Sturdyref Syrup `<ocapn-sturdyref peer swiss-num>` | `sturdySyrup()` / `sturdyRef()` | Implemented | P0; sturdyref round-trip test |
| Sturdyref URI `/s/<swiss-num>` | `sturdyUri()` / `parseSturdyUri()` | Implemented | P0; URI round-trip test |
| RFC3986 escaping | `std/uri` encoding and decoding | Implemented for tested values | P1; expand reserved-character vectors |
| Swiss number is a string | Parser accepts string | Partial: binary bytes remain in legacy Glowcap profile | P0; retain interoperability test, add strict-profile test |

## Syrup and CapTP identity

| Requirement | Nim implementation | Status | Priority / test |
| Canonical dict and set ordering | `src/syrup.nim:encoded()` | Implemented; duplicate keys/members rejected | P0; Syrup and conformance suites |
| Canonical integer and length spelling | `src/syrup.nim` encoder/decoder | Implemented | P0; Syrup vectors |
| CapTP frames over reliable, ordered channel | `src/framing.nim`, `src/transport.nim` | Implemented only by testing TCP/in-memory transports | P0; TCP probe, conformance |
| Per-session Ed25519 key and signed location | `src/crypto.nim`, `src/session.nim` | Implemented | P0; session and conformance suites |
| `op:start-session` CapTP 1.0 and identity checks | `src/messages.nim`, `src/session.nim` | Implemented with Glowcap compatibility branch | P0; Glowcap 24/24 × 3 |
| Secure channel before CapTP session | None in Nim TCP path | Missing | P0 before production deployment |
| Netlayer-authenticated peer identity bound to locator | `Session.remotePeer` is locator metadata only | Missing; no Tor Service ID ↔ CapTP key binding is defined locally | P0; identity audit and negative tests |

## Netlayer requirements

The local Netlayers draft requires bidirectional, ordered, reliable delivery
while a session is active and protection against message insertion by
nonparticipants. Encryption is desirable but not itself the only requirement.
The only concrete netlayer specified in this checkout is the **Tor Onion
Netlayer**, using transport symbol `onion`, a Tor Service ID as designator,
false/empty hints, port `9045`, and ED25519-V3 service keys. Its implementation
is explicitly out of scope in the draft.

| Requirement | Current code | Status | Priority / test |
|---|---|---|---|
| Transport-independent CapTP session core | `Session.transport: Transport` | Implemented seam | P0; in-memory session tests |
| `dial`, `listen/accept`, lifecycle | `api.nim` onion branch, `src/onion.nim`, `server.nim` | Outbound `Node.connect(PeerLocator)` supports onion; inbound uses explicit `OnionListener`; TCP manager remains separate | P0; bounded Tor E2E pending daemon |
| Authenticated peer identity | No netlayer interface; session Ed25519 only | Missing | P0 |
| Testing-only TCP profile | `TcpTransport`, `TcpSessionManager`, locator hints | Implemented and tested | Keep for conformance only |
| Tor Onion SOCKS5 transport adapter | `src/onion.nim:OnionNetlayer`, `OnionTransport` | Implemented; real Nim↔Nim handshake and pipeline confirmed on Fedora mini | P0; `nimble torTest` with configured service |
| Tor Onion service listener | `OnionListener` binds a local endpoint for external Tor port forwarding | Implemented; real endpoint accept confirmed on Fedora mini | P0; `nimble torTest` with configured service |
| Spec-defined production netlayer | No complete authenticated production profile | Partial | P0 for production interoperability |
| Glowcap production-netlayer interoperability | Tested only on `tcp-testing-only` | Not demonstrated | P1 after a shared netlayer exists |

## TCP and temporary identity coupling

- `src/server.nim` owns `TcpSessionManager`, selector registration, TCP accept,
  and generated per-session seed material.
- `src/api.nim` constructs outbound sessions with `connectTcp()` and requires
  `host`/`port` locator hints.
- `src/handoff.nim` opens exporter sessions only for `tcp-testing-only` and
  `tcp`, then calls `connectTcp()` directly.
- `src/onion.nim` is deliberately separate: it performs only Tor SOCKS5
  routing and wraps the existing `Transport`; it does not claim that SOCKS5 or
  a successful `.onion` connection authenticates the remote CapTP identity.
- `src/session.nim` is the reusable boundary: it already consumes `Transport`,
  performs CapTP framing, and owns session-local references and promises. Its
  Ed25519 key is a CapTP session identity, not proof that the underlying
  channel is a production-secure netlayer.

## Minimal future interface

Do not add a second abstraction until there is an implementation to use. The
existing `Transport` is the correct low-level seam for now. The next safe
refactor should introduce one adapter-owned interface with:

1. `dial(PeerLocator) -> authenticated connection`;
2. `listen(PeerLocator/config) -> listener` and `accept() -> connection`;
3. connection `send/receive`, ordered framing, peer identity, and `close()`;
4. explicit lifecycle/error reporting to the existing `Session` and `Node`.

`Session` should continue to own CapTP state; `Node` should select a netlayer
and manage connections. The current `Node`/`TcpSessionManager` remains
TCP-specific, so OnionTransport can currently be used through the existing
Session seam but is not yet wired into the public Node dial/listen API. TCP
testing remains an adapter, not a production identity mechanism.

## Profile and remaining limits

The supported profile is CapTP 1.0 over the repository's testing-only TCP
transport, with Nim Ed25519 session signatures and the documented Glowcap
compatibility forms. An Onion SOCKS5 transport adapter now exists, but no Tor
E2E has run in this environment and it is not a production security profile.
No TLS Netlayer is defined by the checked local draft, so inventing one would
be non-interoperable. The first production target remains the spec-named Tor
Onion netlayer (`onion`), after external Tor configuration, identity binding,
and shared interop vectors are available.

Unverified items are Tor wire interoperability, authenticated channel binding,
cross-implementation URI edge cases, and a strict non-legacy sturdyref profile.

## Onion identity-binding audit

The local drafts distinguish these facts:

1. SOCKS5 CONNECT succeeded: the proxy established a circuit/request.
2. The request reached the Tor Onion Service identified by the Service ID:
   Tor provides this routing/authentication property, subject to the daemon and
   network being trusted as configured.
3. The remote CapTP session identity matches the expected peer locator:
   the current local specifications do not define a Tor Service ID to CapTP
   Ed25519 session-key binding procedure.

`PeerLocator.designator` identifies the netlayer location; it is not a
requirement to compare that value directly with the per-session CapTP public
key. `op:start-session` verifies the CapTP signature and acceptable location,
but does not, in the checked drafts, prove that a Tor Service ID and the
CapTP session key belong to the same administrator. The library therefore
tracks `remotePeer` as provenance and does not mark OnionTransport
authenticated. Onion E2E proves routing and CapTP operation, not production
identity binding.

## Onion handoff test profile

`tests/test_onion_handoff_e2e.nim` requires four externally configured Onion
Service IDs: `NIM_OCAPN_ONION_A`, `NIM_OCAPN_ONION_B`,
`NIM_OCAPN_ONION_C`, and `NIM_OCAPN_ONION_D`. It runs three-node,
four-node, and concurrent handoff scenarios with bounded deadlines. Each
service is mapped to a distinct local port; no direct TCP fallback is used.
These tests are skipped when the required variables are absent and fail on
connection or protocol errors when configured.

The handoff harness uses nonblocking Onion listeners and readiness-gated
accepts. It does not block a CapTP session inside `accept4`; pending accepts
are drained by the bounded fair pump loop.
