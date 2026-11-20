# Public API Guide

`nimocapn` is the application-facing package entrypoint. It re-exports the
facade from `src/api.nim`, which delegates session,
reference, handoff, and transport lifecycle to the existing implementation.

## Durable identity and node configuration

```nim
import nimocapn
import syrup

var config = defaultNodeConfig(Port(42030))
config.identityPath = "server.identity"
config.netlayer = nlkTcpTestingOnly
config.verificationPolicy = testingOnlyPeerPolicy
# The default is simPerSession; every Session gets a fresh CapTP key.
let node = newNode(config)
echo node.publicIdentity()
```

`identityPath` uses the existing versioned `loadOrCreateIdentity` storage.
Loading is stable across restarts; a failed or corrupt load is not replaced
silently. For authenticated peers use `exactPeerPolicy(publicKey)` or
`authenticatedNetlayerPolicy(verifier)` explicitly.

`Node.publicIdentity()` is the durable Node identity. It is not the CapTP key
advertised by a default Session. `Session.localPublicKey` is per-session, so a
reconnect intentionally has a different wire identity. Exact peer policy pins
the current session key and therefore must be provisioned again for a new
session. `SessionIdentityMode.simLegacyDurable` is available only as an
explicit project-specific compatibility mode for peers that require the old
durable wire key; it is never selected automatically and is not the strict
profile.

## Server

```nim
node.publish("greeter", proc(args: seq[SyrupValue]): SyrupValue =
  text("Hello, " & args[0].data))
echo node.locator().peerUri()
while true:
  discard node.poll(1000)
```

`node.poll(timeoutMs, maxWork)` is the application event-loop boundary.
`node.close()` is idempotent.

For bounded operation and diagnostics, set `NodeConfig.maxActiveSessions`,
`handshakeTimeoutMs`, `sessionLimits`, `handoffLimits`, and `diagnosticSink`.
See [DIAGNOSTICS_AND_LIMITS.md](DIAGNOSTICS_AND_LIMITS.md) for defaults and
event kinds. `node.stats()` provides a current resource snapshot.

## Client

```nim
let peer = parsePeerUri(locatorText)
let session = node.connectUsing(peer, nlkTcpTestingOnly)
let greeter = node.bootstrap(session, "greeter")
let answer = api.waitFor(session, greeter.call("greet", [text("world")]))
```

`nlkTcpTestingOnly` is unverified and unencrypted. Onion selection is explicit:
`connectUsing(peer, nlkOnionTestingOnly)`, and never falls back to TCP. The
optional project-specific server-authenticated Onion profile requires both an
exact expected Onion locator and explicit configuration:

```nim
config.onionConfig.authenticateServer = true
config.verificationPolicy = authenticatedOnionPolicy(peer)
let session = node.connectUsing(peer, nlkOnionTestingOnly)
```

This authenticates the remote endpoint represented by the expected Onion
Service ID through the configured Tor daemon and binds the current CapTP
session key to that stream. It does not authenticate the Onion client, prove
durable Node ownership, or establish an official OCapN authenticated netlayer.
Inbound Onion connections remain unauthenticated.

Tor v3 client authorization is not managed by `nim-ocapn`. Configure the
external Tor daemon with `authorized_clients/*.auth` on the service and
`ClientOnionAuthDir/*.auth_private` on each client. Those credentials restrict
which Tor clients can discover/use the service; they are not CapTP client
identity evidence and are never loaded, logged, or serialized by this library.

For a project-specific authenticated Onion deployment, configure a trusted
durable client-key list and publish protected capabilities explicitly:

```nim
config.clientAuth = ClientAuthConfig(
  trustedClientKeys: @[trustedClientPublicKey],
  onionServiceId: expectedServiceId,
  capabilityName: "authenticate",
  challengeTimeoutMs: 30_000)
let node = newNode(config)
node.publishProtected("greeter", greeterBehavior)
```

The client must first use the server-authenticated Onion session:

```nim
discard authenticateClient(session, clientIdentity)
let greeter = node.bootstrap(session, "greeter")
```

`authenticateClient` signs a fresh challenge using the durable client identity.

The challenge is single-use and expires after `challengeTimeoutMs` (30 seconds
by default). Protected capabilities are not published before authentication
and cannot be redeemed through an unauthenticated handoff auxiliary Session;
that Session needs its own authenticated state. This is a project-specific
application profile, not a universal OCapN authenticated netlayer.
The proof is bound to the current CapTP session keys, Session ID, configured
Onion Service ID, and explicit roles. `publishProtected` capabilities are not
available before verification. `pumpPeer` is an optional argument only for an
embedded two-Session test topology; normal Node applications leave it unset.
This is not a standard OCapN authentication mechanism and does not prove a
durable server Node identity.

The project-specific mutual-TLS client adapter is available as
`connectMutualTls` when compiled with `-d:ssl`; it requires its certificate,
CA, certificate-fingerprint, expected CapTP-key configuration, and an
`authenticatedNetlayerPolicy`. It fails before opening a socket when the Node
still uses the testing-only policy. Its optional `seed` is an explicit
out-of-band session-key mapping, not a durable identity binding.

The current `Node` listener is TCP-based. Onion inbound listeners and the
mutual-TLS server accept path can be selected with `-d:ssl` by setting
`NodeConfig.netlayer = nlkMutualTls`, `tlsServerConfig`, and an
`authenticatedNetlayerPolicy`. The TLS listener reuses the Node Session
registry and supports multiple accepted Sessions. A non-empty
`expectedPeerCapTpKey` pins one expected session key; the explicit
`allowUnpinnedPeerCapTpKey` mode is needed for rotating ephemeral peer keys
and requires a verifier that checks the certificate evidence. It does not
authenticate a durable Node identity automatically.

## Lifecycle and errors

Use `RemoteCapability.call`, `waitFor`, `waitForCallTimeout`,
`cancelCall`, `waitForHandoffTimeout`, and `node.close`. A local timeout or
cancellation does not claim that a remote method stopped executing. A strict
identity mismatch closes the session before capabilities are exposed.

Use `closeSession(session)` when one connection must be closed while the Node
continues serving other Sessions.

The low-level `Session`, `CapabilityRef`, Syrup descriptors, and handoff APIs
remain available for protocol tests and unusual integrations, but ordinary
applications should use `Node`, `RemoteCapability`, `Node.bootstrap`, and
`CallArgument` helpers.

For v1 compatibility, only the `nimocapn` facade and the documented `api.nim`
operations should be treated as stable. Direct mutable fields on `Node`,
`Session`, `RemoteCapability`, and `RemotePromise`, plus direct reference-table
or handoff-manager access, are experimental and may be hidden or changed
before v1. They can bypass ownership and lifecycle invariants.

See [API_STABILITY.md](API_STABILITY.md) for the frozen surface and the exact
authentication contract of each connection method.
