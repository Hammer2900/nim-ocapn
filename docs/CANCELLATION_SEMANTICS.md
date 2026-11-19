# Public Call and Handoff Cancellation

This document describes P1-10 for the current CapTP profile. It does not add
a wire-level cancellation operation.

## Calls

`Session.cancel(promise, reason)` (or the public `cancelCall` wrapper) is local cancellation. It is idempotent: the
first call breaks a pending promise with the supplied reason and later calls
return `false`. If the request has already been sent, the remote operation is
not cancelled or rolled back. The session remains usable.

For a bounded wait, use `Session.waitForTimeout(promise, timeoutMs)` or the
public `waitForCallTimeout` wrapper. On the
deadline it cancels the local pending answer, performs the existing
`op:gc-answer` cleanup, and raises `PromiseTimeoutError`. The older
`waitFor(..., maxPumps)` path also cleans up when its pump budget is exhausted.

Remote rejection and disconnect remain distinct from local timeout. A late
fulfillment after cancellation is ignored; it cannot revive the promise or
close the session.

```nim
let pending = capability.call("greet", [text("world")])
try:
  let value = session.waitForTimeout(pending, 1000)
except PromiseTimeoutError:
  discard

discard session.cancel(pending, "user stopped waiting")
```

## Handoff

`Node.cancel(receipt, reason)` removes the pending gift waiter, cancels the
withdrawal if it was sent, breaks the receipt promise, and closes only the
auxiliary handoff session. It does not close unrelated application sessions.

`Node.waitForHandoffTimeout(receipt, timeoutMs)` performs the same cleanup and
raises `HandoffTimeoutError`. Existing `waitForHandoff(..., maxPumps)` also
cancels on budget exhaustion.

After cancellation, a later deposit or replay cannot resolve the old receipt.
A fresh withdrawal is a separate operation and follows the existing GiftTable
redemption rules.

## Ownership and limitations

- `op:gc-answer` releases the remote answer slot after local cancellation.
- Resolver exports follow the existing answer lifecycle; late callbacks are
  harmless while their wire reference remains visible.
- Existing Session and GiftTable owners clean imports, exports, and waiters.
- CapTP has no general remote-execution cancellation in this profile. Timeout
  and cancellation control local observation and references only.
- No new wire format, protocol message, scheduler, or cancellation framework
  was introduced.
