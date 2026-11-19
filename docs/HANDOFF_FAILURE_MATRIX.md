# Handoff Failure and Replay Matrix

Profile: current CapTP handoff implementation, with one-time gift redemption.
Tests run through `nimble handoffFailureTest`; existing TCP and TLS E2E remain
separate regressions.

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

The fault transport is test-only. It controls delay, duplication and close
without sleeps or kernel-buffer assumptions. Remote call delivery is not made
exactly-once: only gift redemption is one-time; ordinary CapTP calls retain
their protocol semantics.

Known boundary: replay tombstones live for the lifetime of the `GiftTable` and
are cleared when its owner is closed. Durable anti-replay across process
restarts is not implemented.
