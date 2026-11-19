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
| Pending promises/answers per Session | 4096 | `maxPendingPromises` |
| Imports per Session | 4096 | `maxImports` |
| Exports per Session | 4096 | `maxExports` |
| Queued outbound bytes per Session | 1 MiB | `maxOutboundBytes` |
| Active TCP sessions per Node | 256 | `NodeConfig.maxActiveSessions` |
| Handshake wait | 30 seconds | `NodeConfig.handshakeTimeoutMs` |
| Pending handoffs | 256 | `NodeConfig.handoffLimits.maxPending` |

Frame, promise, inbound-answer, queued-pipeline, import/export, and outbound
queue limits are enforced by the existing Session/Transport code. Duplicate
inbound answer positions are rejected instead of replacing state. Active-session
admission is checked by the TCP manager before registering a session. Pending
handoff admission is checked before retaining the operation. Rejected
operations emit `dekResourceLimit`, return a typed error, and do not close
unrelated sessions.

## State snapshots

`node.stats()` returns the current bounded snapshot: active sessions, pending
promises, imports, exports, queued bytes, listener/forwarding counters, and
pending gifts/handoffs. `session.stats()` remains available for per-session
inspection.

The application remains responsible for calling `node.poll(timeoutMs,
maxWork)`. No scheduler or background logging thread is introduced.

## Concurrency model

Session, Node, HandoffManager, and the reference tables are single-owner
state. They are not implicitly thread-safe; concurrent work must be
serialized by the application through the existing polling/event-loop calls.
`nimble concurrencyTest` exercises interleaved operations across four
independent in-memory Session pairs, including reverse-order settlement,
rejection, and disconnect. It does not claim multi-threaded safety.

## Endurance evidence

`nimble resourceTest` runs a bounded quick workload. `nimble enduranceTest`
runs 2,000 sequential calls, 100 repeated in-memory sessions, and a valid
unresolved-call limit test. The harness reports peak pending operations and
RSS when available, while correctness is determined by protocol counters and
post-cleanup state rather than RSS alone.

The tests confirm bounded pending answers, pending promises, exports, imports,
and queued bytes for the exercised paths. They do not prove bounded memory for
every valid application workload or hostile long-lived connection.

The testing-only in-memory transport also enforces a private 1 MiB peer inbox
bound and reports it through `queuedBytes()`. TCP/TLS/Onion retain their
existing transport-specific queue behavior.

## Remaining unbounded state

`GiftTable.redeemed` retains one tombstone per redeemed gift until the owning
manager/session is closed or the table is explicitly cleared. This is required
by the current replay-protection profile: silently evicting tombstones would
allow a late duplicate gift to be accepted. No expiry policy is introduced in
this batch, so a long-lived node processing an unbounded number of successful
handoffs can accumulate tombstones. Applications should use the existing
manager lifecycle and cleanup rather than treating this as an unlimited queue.
