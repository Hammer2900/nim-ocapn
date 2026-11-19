# Public API Guide

`nimocapn` is the application-facing package entrypoint. It re-exports the
facade from `src/api.nim`, which delegates session,
reference, handoff, and transport lifecycle to the existing implementation.

## Durable identity and node configuration

```nim
import ../src/[api, syrup]

var config = defaultNodeConfig(Port(42030))
config.identityPath = "server.identity"
config.netlayer = nlkTcpTestingOnly
config.verificationPolicy = testingOnlyPeerPolicy
let node = newNode(config)
echo node.publicIdentity()
```

`identityPath` uses the existing versioned `loadOrCreateIdentity` storage.
Loading is stable across restarts; a failed or corrupt load is not replaced
silently. For authenticated peers use `exactPeerPolicy(publicKey)` or
`authenticatedNetlayerPolicy(verifier)` explicitly.

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
