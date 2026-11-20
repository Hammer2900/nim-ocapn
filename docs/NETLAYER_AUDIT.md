# Netlayer Audit

## Batch B identity contract

`Transport` now exposes `peerIdentity()` and `peerAuthenticated()` metadata.
These hooks are deliberately advisory until a netlayer can prove the binding
required by the selected OCapN profile. TCP returns no authenticated identity;
the default and inbound Onion adapters also remain unauthenticated after
successful SOCKS5 CONNECT. The explicit outbound Onion profile is opt-in;
`pvmAuthenticatedNetlayer` fails closed unless that profile is selected with
its matching policy.

`Session` applies the explicit `PeerVerificationPolicy` after validating the
CapTP hello key and before exposing an open, trusted session. Locator metadata
is not treated as an identity assertion.

`Transport.authenticationEvidence()` is now the minimal adapter seam. It is
empty for TCP, Onion, and in-memory transports. The authenticated Session
policy requires a recognized proof type, a 32-byte transport identity, channel
integrity, equality with the CapTP key, and an explicit verifier callback.
`src/tls_transport.nim` supplies a real project-specific mutual-TLS provider
with certificate pinning and an explicit CapTP-key mapping; it is not official
OCapN interoperability.

## Current architecture

`Session` depends on the small `Transport` seam in `src/transport.nim`:
`send`, `receive`, `flushOutput`, `wantsWrite`, `queuedBytes`, `waitReadable`,
`isClosed`, and `close`. Framing and CapTP state stay in `src/session.nim`.
This is the correct protocol/transport boundary and is exercised by the
in-memory tests.

The TCP path is split between `TcpTransport` and `TcpSessionManager`:

- `connectTcp` creates an unbuffered socket and applies nonblocking I/O.
- `TcpSessionManager` owns the listener, selector, accept loop, fair bounded
  polling, handshake expiry, session registration, and shared manager gift table.
- `newGlowcapSession` creates the CapTP session used by accepted and outbound
  testing TCP connections.

The Onion path in `src/onion.nim` performs SOCKS5 CONNECT to
`<service-id>.onion:9045`, returns an `OnionTransport` wrapping the same
`TcpTransport`, and provides a nonblocking `OnionListener`. It does not own a
CapTP session and does not claim identity authentication. Public `Node.connect`
has an Onion branch, while the general inbound `Node` manager is still TCP
specific; Onion listeners are currently driven explicitly by integration
harnesses.

`nimble onionE2eTest` now provisions an isolated Tor 0.4.x daemon, a v3
`HiddenServiceDir`, and a temporary SOCKS listener. The real test exercises
two sequential sessions, two concurrent clients, CapTP handshake, bootstrap
fetch, pipelined invocation, disconnect/cleanup, and a failed connection to a
different valid-looking Service ID. The test owns the daemon and temporary
keys; it does not use or reconfigure the system Tor process. This proves
routing and protocol operation only, not Onion Service ID ownership of a CapTP
key.

## Requirements comparison

| Requirement | Current state | Status |
|---|---|---|
| Bidirectional, ordered delivery | TCP socket and SOCKS-wrapped TCP | COMPLETE for tested transports |
| Partial reads/writes and EAGAIN | `TcpTransport` output queue and frame decoder | COMPLETE for tested paths |
| Bounded outbound memory | `maxOutputBytes` and `SessionLimits` | COMPLETE for current limits |
| Fair multi-session polling | selector + bounded manager/session work | COMPLETE for tested TCP manager |
| Connect/listen/accept/close | TCP manager and explicit Onion listener | PARTIAL unified API; real Tor path tested |
| Authenticated peer identity | Project TLS profile and explicit outbound Onion endpoint profile | PARTIAL; no universal provider |
| Locator provenance | stored on sessions/transports | PARTIAL; no cryptographic binding |
| Production secure channel | none | MISSING |
| New netlayer without Session rewrite | possible through `Transport` | PARTIAL; Node/manager selection is TCP-oriented |

The local Netlayers draft requires bidirectional ordered delivery and that only
participants can insert messages. It names Tor Onion as a netlayer with
designator = Service ID, transport = `onion`, no hints, and service port 9045.
The current Onion adapter satisfies routing, framing, reconnect, concurrency,
and failure tests, but a SOCKS5 connection alone does not establish the
required application identity policy.

The explicit `OnionNetlayerConfig.authenticateServer` profile supplies
`tor-onion-service-v3` evidence only for outbound dials. It requires
`authenticatedOnionPolicy(expectedPeer)` and the Session still verifies the
signed CapTP hello and expected locator before opening. The evidence means
"this fresh CapTP session is on the stream routed to the expected Onion
Service ID by the trusted Tor daemon"; it is not a signature binding the
ephemeral CapTP key to the Onion private key. Accepted inbound Onion sockets
remain unverified.

Tor v3 client authorization is configured outside this library through the
service's `authorized_clients/*.auth` files and the client's
`ClientOnionAuthDir/*.auth_private` files. The isolated runner exercises two
authorized clients, an invalid credential, and revocation after service
restart. Tor admission is access control for the Onion service; it does not
expose the client's X25519 credential as CapTP identity evidence.

## Tor-4 application identity binding

The project-specific Onion profile now has an opt-in application-level client
authentication capability. It uses ordinary CapTP bootstrap/fetch/deliver
operations and therefore does not add a CapTP opcode or change Syrup. The
server publishes only the authentication capability initially. A successful
proof signs a canonical, domain-separated Syrup record containing a fresh
nonce, the durable client key, both ephemeral session keys, the current Session
ID, the configured Onion Service ID, and explicit client/server roles. Protected
publications are installed only after verification.

This proves possession of a trusted durable client key for that exact Session;
it does not make Tor client authorization itself a CapTP identity proof. The
server must configure the trusted public-key list and Onion Service ID, and the
client must use the server-authenticated Onion policy. Reconnects receive a
new challenge and new session keys. Challenge reuse, session swapping, wrong
signatures, and unknown durable keys fail closed.

## Tor-5 boundary hardening

Client-authentication challenges are single-use and expire on a monotonic
deadline. The signed binding uses the server Session's actual nonce, ephemeral
keys, Session ID and configured Onion Service ID; client metadata is not the
server's source of truth. Protected exports are marked when published and
protected gifts are rejected by Sessions that have not reached
`casAuthenticated`. A standard handoff auxiliary Session is fresh but not
implicitly authenticated, so protected handoff fails closed unless that
Session independently authenticates. No CapTP/Syrup record or opcode changed.

## Minimal next interface

Do not add another abstraction until it has two implementations. The next
minimal step is an adapter-owned `NetlayerConnection` carrying:

1. `PeerLocator` provenance;
2. optional authenticated peer identity and authentication status;
3. ordered send/receive/readiness/flush;
4. bounded connect/listen/accept/close errors.

`Session` should consume that connection as a `Transport` plus identity metadata;
`Node` should select adapters. Keep TCP explicitly testing-only and preserve the
current Onion harness while the interface is introduced.

## Acceptance tests

Add transport-neutral session tests, then run the same suite over TCP and Onion:
handshake identity mismatch, partial I/O, timeout, close during handshake,
malformed frame, bounded queue, greet, pipelining, handoff, and cleanup. Add a
negative test proving that failed Onion routing never falls back to direct TCP.
