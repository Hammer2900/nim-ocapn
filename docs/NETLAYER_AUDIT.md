# Netlayer Audit

## Batch B identity contract

`Transport` now exposes `peerIdentity()` and `peerAuthenticated()` metadata.
These hooks are deliberately advisory until a netlayer can prove the binding
required by the selected OCapN profile. TCP returns no authenticated identity;
the Onion adapter also remains unauthenticated even after successful SOCKS5
CONNECT. `pvmAuthenticatedNetlayer` therefore fails closed on both transports.

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
| Authenticated peer identity | Explicit evidence seam; no production provider | PARTIAL |
| Locator provenance | stored on sessions/transports | PARTIAL; no cryptographic binding |
| Production secure channel | none | MISSING |
| New netlayer without Session rewrite | possible through `Transport` | PARTIAL; Node/manager selection is TCP-oriented |

The local Netlayers draft requires bidirectional ordered delivery and that only
participants can insert messages. It names Tor Onion as a netlayer with
designator = Service ID, transport = `onion`, no hints, and service port 9045.
The current Onion adapter satisfies routing, framing, reconnect, concurrency,
and failure tests, but a SOCKS5 connection alone does not establish the
required application identity policy.

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
