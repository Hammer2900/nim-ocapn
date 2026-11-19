# Identity and Security Model

## Durable identity

`createIdentity`, `loadIdentity`, and `loadOrCreateIdentity` in
`src/identity.nim` manage a versioned binary Ed25519 seed file. The file has a
magic value, version byte, seed, and SHA-256 integrity checksum. Creation uses
a `0600` lock/temp file and refuses implicit replacement; replacement requires
`replaceExisting = true`. Private material is never included in logs,
Syrup values, or node diagnostics.

`Node.identity` is opt-in. `node.publicIdentity()` exposes only the public key.
When supplied, the identity seed is used by the Node's accepted, outbound, and
handoff Sessions, so the public key carried in every `op:start-session` is
stable across reconnects and process restarts. Nodes without an identity keep
the legacy/testing-only per-session seed behavior.

## Peer verification

`PeerVerificationPolicy` makes the trust decision explicit:

- `pvmExactIdentity` accepts only the configured 32-byte Ed25519 key.
- `pvmAuthenticatedNetlayer` requires a netlayer-provided authenticated key
  matching the CapTP key.
- `pvmTestingOnly` preserves existing TCP/Glowcap compatibility and does not
  claim peer authentication.

Use `node.connectVerified(...)` or pass an exact policy to `newNode`. A key
mismatch, invalid signature, or unavailable authenticated-netlayer proof closes
the session before capabilities are exposed. Verification state is per
session; reconnect and handoff do not inherit it.

## Transport authentication evidence

`Transport.authenticationEvidence()` is the adapter contract. It carries a
peer identity, proof type, and channel integrity/authentication flags. Default
TCP, Onion, and in-memory transports return empty evidence. The authenticated
Session policy accepts only the recognized
`external-authenticated-channel` evidence type, a 32-byte identity, channel
integrity, equality with the CapTP hello key, and an explicit
`TransportEvidenceVerifier` trust callback.

This is a fail-closed contract boundary, not a cryptographic protocol
implementation. A concrete netlayer must populate evidence only after its own
authenticated channel verifies it. `src/tls_transport.nim` provides the
project-specific `nim-ocapn/tls-mtls-v1` profile using OpenSSL mutual TLS,
certificate pinning, and an explicit fingerprint-to-CapTP-key mapping. This
is not an official OCapN Netlayer profile; peers must explicitly agree on it.

## Locator and Onion binding

For strict connections, the expected `PeerLocator` is stored on the Session.
After the signed `op:start-session` is verified, its acceptable-location is
decoded and compared by transport and designator with the expected locator.
The CapTP public key is checked independently by `PeerVerificationPolicy`.
Both checks must pass before `peerVerified` becomes true. A substituted
locator or key therefore fails closed and clears session state.

The Onion adapter proves SOCKS routing and endpoint reachability, not the
relationship between a Tor Service ID and a CapTP Ed25519 key. Its
`peerAuthenticated` value remains false. No byte comparison between these two
different identity systems is performed. A production locator/session binding
mechanism for an authenticated Tor identity remains Batch C work. The current
Onion profile can verify an externally supplied CapTP key and the advertised
Onion locator, but this is not proof that the Tor Service ID owns that key.

TCP is testing-only: it provides ordered I/O but no confidentiality or channel
authentication. Applications requiring production authorization must configure
an authenticated netlayer and an explicit trust anchor.
