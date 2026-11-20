# Distributed GC and Reference Lifecycle Matrix

Profile: current CapTP implementation. `imports` and `exports` below are
session-local tables; a capability remains usable while any downstream wire
reference or local owner still holds it.

| Scenario | Expected final state | Test |
|---|---|---|
| One import, one release | import count 0; repeated release rejected | `one import and repeated release are bounded` |
| Multiple imports of one capability | count decrements one at a time; final count 0 | `multiple imports release independently` |
| Nested capability argument | sender wire ref decremented after dispatch; local export remains until explicit release | `nested delivery imports are released after dispatch` |
| Forwarded capability with downstream reference | source import retained while downstream exists | `forwarding keeps the source import while downstream is alive` |
| Intermediary close | source reference released; forwarding registry/proxy state cleared | same forwarding test and existing session regressions |
| Handoff then release | gift is redeemed once; no pending waiter or deposited gift remains | `handoff gift release does not retain a capability` |
| Pending promise on close | promise broken; answers, imports, exports and listeners cleared | `pending promise and delayed transport clean up on close` |
| Concurrent close | close is idempotent; no table resurrection | `concurrent close is idempotent...` |
| Reconnect after cleanup | new Session starts with independent empty tables | `reconnect after cleanup...` |
| Release after disconnect | stale release rejected; no table mutation | `release after disconnect...` |
| Duplicate/stale wire GC | underflow or stale position closes only the affected Session | existing `test_session.nim` and `test_server.nim` regressions |
| A→B→C and A→B→C→D forwarding | active downstream references remain callable; cleanup occurs after final release | existing multi-peer handoff/API tests; `nimble threeNodeHandoffTest` uses independent A/B/C processes |
| Three-process import release | B releases its imported capability after handoff; C remains callable | B session import count returns during repeated runs; C uses its auxiliary import | `threeNodeHandoffTest` x1/x10/x50 |
| Three-process final cleanup | Sessions, gifts, pending handoffs and queued state return to post-close baseline | pre/post `STATE` counters from A/B/C | `threeNodeHandoffTest` failure checkpoints |
| Reconnect/session replacement | New process cluster uses fresh Session state and does not reuse old gifts | second independent A/B/C run after full cleanup | `threeNodeHandoffTest` reconnect |
| Protected three-process handoff | C's authenticated auxiliary Session owns the transferred behavior after B closes; release returns the auxiliary state to baseline | `threeNodeHandoffTest` protected TLS fixture |

The implementation does not add a global distributed collector. `Session`
owns its tables, `HandoffManager` owns temporary handoff Sessions, and the
existing wire `op:gc-exports`/`op:gc-answers` messages perform protocol-level
release. Ordinary remote calls are not given exactly-once semantics.

Known limitation: release state and replay tombstones are process-local. A
restarted process does not recover old references or provide durable GC/replay
accounting.

The real Tor protected handoff also observed the expected sequence of
`op:gc-exports` and `op:gc-answers` after withdrawal, B disconnect, C
invocation, and release. This is wire/lifecycle evidence for the three-process
fixture; it does not claim durable GC across process restarts.
