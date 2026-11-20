# Handoff Failure and Replay Matrix

Profile: current CapTP handoff implementation, with one-time gift redemption.
Tests run through `nimble handoffFailureTest`; existing TCP and TLS E2E remain
separate regressions.

The independent-process happy path is covered by
`nimble threeNodeHandoffTest`. It runs A, B, and C as separate Nim processes:
B transfers a signed gift for A's capability to C, then closes both of its
sessions; C withdraws through its auxiliary Session to A and invokes the
capability. This verifies that the downstream reference does not depend on B's
continued Session lifetime.

The same command runs bounded checkpoint injection. Checkpoints are held by
control files, so the runner can use either a graceful stop or SIGTERM without
sleep-based races. It records pre/post cleanup `active`, `pending`, import,
export, gift, and handoff counters for surviving processes.

| Scenario | Expected behavior | Protection | Test |
|---|---|---|---|
| Before gift creation | No pending gift state | No table entry is created | `disconnect before gift creation` |
| After deposit, before receive | Gift is recoverable or cleared with its owner | `GiftTable.clear()` releases it | `disconnect after deposit clears...` |
| Receive timeout | Promise breaks and waiter is removed | `GiftTable.cancel()` | `withdraw timeout cancellation...` |
| Unknown token | Bounded pending wait, then explicit cancellation | waiter cleanup | `unknown token...` |
| Repeated receive | Immediate broken promise; no second capability | redeemed tombstone | `redeemed token...` |
| Repeated give/deposit | Reject duplicate token | duplicate/redeemed checks | `duplicate wire delivery...` |
| Two receivers | At most one fulfillment | atomic waiter resolution | `two concurrent receivers...` |
| Wrong receiver identity | Reject without consuming gift | receiver-key comparison | `wrong receiver...` |
| Session disconnect | Pending calls break; tables are cleared | `Session.close()` | `disconnect closes...` |
| Delayed/late delivery | No busy wait; release is bounded | controlled transport queue | `delayed handoff response...` |
| Reconnect | New session does not revive cancelled gift | session-local state | `reconnect starts...` |
| A/B/C disconnect at each handoff phase | Dependent promise breaks; unrelated sessions survive | node/session cleanup | `tests/test_handoff_disconnect.nim` (12/12) |
| Disconnect during give/receive/redeem | No pending handoff or gift waiter remains | bounded `HandoffManager.cleanup()` | disconnect matrix (12/12) |
| Wrong handoff identity | Reject before capability use | receiver-key and session checks | `receiver rejects a give...` |
| Corrupt/unknown certificate | Break answer; close only affected session | descriptor/signature validation | `test_handoff.nim`, `test_session.nim` |
| Repeated handoff count | Reject duplicate count | session-local count table | `test_session.nim` |
| Three-process post-handoff disconnect | C remains able to invoke A after B closes | auxiliary Session remains owned by C's HandoffManager; no pending receive | `nimble threeNodeHandoffTest` |
| Three-process before deposit | No gift is deposited; A/B/C cleanup is bounded | B stopped at `B_FETCHED0` | `threeNodeHandoffTest` |
| Three-process after deposit | Gift exists until A cleanup; no withdrawal occurs | B stopped at `B_DEPOSITED0` | `threeNodeHandoffTest` |
| Three-process during withdrawal | Gift/auxiliary Session is cleaned after C stop | C stopped at `C_WITHDRAWAL_STARTED` | `threeNodeHandoffTest` |
| Three-process after withdrawal | Capability is not invoked if C terminates | C stopped at `C_WITHDRAWAL_DONE` | `threeNodeHandoffTest` |
| Three-process during invocation | A or C termination breaks only the dependent operation | `C_INVOCATION_STARTED` | `threeNodeHandoffTest` |
| Three-process after invocation before release | Late cleanup does not revive the capability | C stopped at `C_INVOCATION_DONE` | `threeNodeHandoffTest` |
| Graceful vs process termination | Both paths finish without orphaned peers | alternating control-file stop and SIGTERM | `threeNodeHandoffTest` |

The fault transport is test-only. It controls delay, duplication and close
without sleeps or kernel-buffer assumptions. Remote call delivery is not made
exactly-once: only gift redemption is one-time; ordinary CapTP calls retain
their protocol semantics.

### Independent Goblins handoff boundary

The pinned Goblins source contains handoff coordinators and upstream handoff
tests, but its public Guile API does not provide the external three-process
driver required to run Nim A → Goblins B → Nim C (or the reverse) with
observable signed-gift and withdrawal state. Those upstream tests are therefore
`UNSUPPORTED` as Nim↔Goblins evidence. The protected three-process results in
this matrix are Nim-only and must not be promoted to cross-peer PASS.

The real Tor protected three-node fixture remains `ENVIRONMENT FAILURE`: after
the three Nim listeners are created, a separate bounded SOCKS5 probe retries
each Onion Service without sending CapTP bytes, but the current run still
ended before CapTP establishment. This does not invalidate the separate
successful single-service Tor E2E results.

Known boundary: replay tombstones live for the lifetime of the `GiftTable` and
are cleared when its owner is closed. Durable anti-replay across process
restarts is not implemented.

Protected three-node handoff is covered by the TLS-backed fixture in
`nimble threeNodeHandoffTest`: B and C use separate durable Ed25519 identities,
C authenticates its fresh auxiliary Session before withdrawal, B disconnects,
and C completes invocation. Unknown and unauthenticated C paths are rejected
without consuming the gift. This is a project-specific mutual-TLS profile;
the fixture does not claim a universal authenticated OCapN netlayer.

The real Tor v3 runner exercises the same protected A/B/C order over three
Onion Services, but the current multi-service run is not a protocol PASS. The
service and client daemons boot, all three local Nim listeners accept bounded
readiness connections, and the topology is printed with the virtual port and
local target. The separate SOCKS5 probes nevertheless return `0x04` for all
three services; Tor logs repeated resolve/connect failures, so CapTP is never
reached. The runner exits as `ENVIRONMENT FAILURE` with a bounded deadline
and cleans up both Tor and Nim processes. The single-service Tor profile still
passes independently.
