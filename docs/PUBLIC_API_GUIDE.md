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
project-specific mutual-TLS client adapter is available as
`connectMutualTls` when compiled with `-d:ssl`; it requires its certificate,
CA, certificate-fingerprint, and expected CapTP-key configuration.

The current `Node` listener is TCP-based. Onion inbound listeners and the
mutual-TLS server accept path remain transport-level APIs; they are not falsely
represented as a unified production listener. This is an explicit limitation,
not a security downgrade.

## Lifecycle and errors

Use `RemoteCapability.call`, `api.waitFor`, `waitForCallTimeout`,
`cancelCall`, `waitForHandoffTimeout`, and `node.close`. A local timeout or
cancellation does not claim that a remote method stopped executing. A strict
identity mismatch closes the session before capabilities are exposed.

The low-level `Session`, `CapabilityRef`, Syrup descriptors, and handoff APIs
remain available for protocol tests and unusual integrations, but ordinary
applications should use `Node`, `RemoteCapability`, `Node.bootstrap`, and
`CallArgument` helpers.

For v1 compatibility, only the `nimocapn` facade and the documented `api.nim`
operations should be treated as stable. Direct mutable fields on `Node`,
`Session`, `RemoteCapability`, and `RemotePromise`, plus direct reference-table
or handoff-manager access, are experimental and may be hidden or changed
before v1. They can bypass ownership and lifecycle invariants.
