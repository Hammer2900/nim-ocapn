# Operations

`Node.poll(timeoutMs, maxWork)` is the application event-loop boundary. Keep
`maxWork` bounded and inspect `node.stats()` when diagnosing pressure. Set
`NodeConfig.sessionLimits`, `handoffLimits`, `maxActiveSessions`, and
`handshakeTimeoutMs` before starting the node.

Applications should close the node in a `finally` block:

```nim
try:
  while not stopping:
    discard node.poll(1000, 64)
finally:
  node.close()
```

`close()` is idempotent. Pending operations are broken and session-local
references are released according to the selected CapTP profile. The public
examples handle Ctrl-C and POSIX SIGTERM, release listeners, and can be
restarted on the same port.

Configure `NodeConfig.diagnosticSink` for structured events. Events contain
safe identifiers and categories, not private keys or capability payloads.

```sh
nimble deploymentTest
```

This bounded check covers clean builds, invocation, identity persistence,
signals, occupied ports, invalid identity paths, and process cleanup.
