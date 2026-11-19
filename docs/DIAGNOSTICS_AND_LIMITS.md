# Diagnostics and Operational Limits

P2-14 adds a small callback-based diagnostic surface. It is not a logging or
metrics framework and has no external dependencies.

## Diagnostic events

Configure `NodeConfig.diagnosticSink` or call `node.setDiagnosticSink`:

```nim
var events: seq[DiagnosticEvent]
var config = defaultNodeConfig()
config.diagnosticSink = proc(event: DiagnosticEvent) = events.add(event)
let node = newNode(config)
```

`DiagnosticEvent` contains `timestamp`, `nodeId`, `sessionId`, typed `kind`,
typed `errorCategory`, and safe `detail`. Event kinds cover session open/close,
handshake success/failure, peer verification failure, transport disconnect or
error, promise timeout/cancellation, handoff success/failure, and resource
limit rejection.

Details are fixed operational descriptions. Private keys, capability payloads,
Syrup payloads, and secret material are not included.

## Default limits

| Limit | Default | Configuration |
|---|---:|---|
| Incoming frame | 1 MiB | `NodeConfig.sessionLimits.maxFrameBytes` |
| Pending promises per Session | 4096 | `maxPendingPromises` |
| Imports per Session | 4096 | `maxImports` |
| Exports per Session | 4096 | `maxExports` |
| Queued outbound bytes per Session | 1 MiB | `maxOutboundBytes` |
| Active TCP sessions per Node | 256 | `NodeConfig.maxActiveSessions` |
| Handshake wait | 30 seconds | `NodeConfig.handshakeTimeoutMs` |
| Pending handoffs | 256 | `NodeConfig.handoffLimits.maxPending` |

Frame, promise, import/export, and outbound queue limits are enforced by the
existing Session/Transport code. Active-session admission is checked by the
TCP manager before registering a session. Pending handoff admission is checked
before retaining the operation. Rejected operations emit `dekResourceLimit`,
return a typed error, and do not close unrelated sessions.

## State snapshots

`node.stats()` returns the current bounded snapshot: active sessions, pending
promises, imports, exports, queued bytes, listener/forwarding counters, and
pending gifts/handoffs. `session.stats()` remains available for per-session
inspection.

The application remains responsible for calling `node.poll(timeoutMs,
maxWork)`. No scheduler or background logging thread is introduced.
