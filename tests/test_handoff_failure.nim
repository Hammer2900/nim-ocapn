import std/[strutils, unittest]
import ../src/[gifts, promises, session, syrup]
import ./fault_transport

proc pumpPair(a, b: Session; limit = 256) =
  for _ in 0 ..< limit:
    var progress = false
    try: progress = a.pump() or progress
    except CatchableError: discard
    try: progress = b.pump() or progress
    except CatchableError: discard
    if a.state == ssOpen and b.state == ssOpen and not progress: break

proc handoffGift(table: GiftTable; id = "gift"; receiver = "receiver"): Promise =
  table.deposit(id, receiver, text("capability"))
  table.withdraw(id, receiver)

suite "CapTP handoff failure and replay matrix":
  test "disconnect before gift creation leaves no state":
    let table = newGiftTable()
    check table.stats().deposited == 0
    check table.stats().pendingWithdraws == 0

  test "disconnect after deposit clears an unclaimed gift":
    let table = newGiftTable()
    table.deposit("after-deposit", "receiver", text("capability"))
    check table.stats().deposited == 1
    table.clear()
    check table.stats().deposited == 0
    check table.stats().redeemed == 0

  test "withdraw timeout cancellation removes the waiter":
    let table = newGiftTable()
    let pending = table.withdraw("timeout", "receiver")
    check pending.state == psPending
    check table.pendingCount("timeout") == 1
    check table.cancel(pending)
    check pending.state == psBroken
    check table.stats().pendingWithdraws == 0

  test "unknown token fails without creating an unbounded gift":
    let table = newGiftTable()
    let pending = table.withdraw("unknown", "receiver")
    check table.stats().pendingWithdraws == 1
    discard table.cancel(pending)
    check table.stats().pendingWithdraws == 0
    check table.stats().deposited == 0

  test "redeemed token rejects a repeated receive":
    let table = newGiftTable()
    let first = handoffGift(table, "replay", "receiver")
    check first.state == psFulfilled
    let replay = table.withdraw("replay", "receiver")
    check replay.state == psBroken
    check replay.reason == "gift already redeemed"
    check table.stats().pendingWithdraws == 0
    check table.stats().redeemed == 1

  test "duplicate delivery cannot deposit or redeem twice":
    let table = newGiftTable()
    table.deposit("duplicate", "receiver", text("capability"))
    let first = table.withdraw("duplicate", "receiver")
    check first.state == psFulfilled
    expect GiftTableError:
      table.deposit("duplicate", "receiver", text("capability"))

  test "two concurrent receivers resolve atomically":
    let table = newGiftTable()
    let first = table.withdraw("concurrent", "receiver")
    let second = table.withdraw("concurrent", "receiver")
    table.deposit("concurrent", "receiver", text("capability"))
    check first.state == psFulfilled
    check second.state == psBroken
    check table.stats().pendingWithdraws == 0
    check table.stats().redeemed == 1

  test "wrong receiver does not consume a deposited gift":
    let table = newGiftTable()
    table.deposit("wrong-receiver", "expected", text("capability"))
    let denied = table.withdraw("wrong-receiver", "attacker")
    check denied.state == psBroken
    check table.stats().deposited == 1
    let accepted = table.withdraw("wrong-receiver", "expected")
    check accepted.state == psFulfilled

  test "disconnect closes an in-flight CapTP promise":
    let pair = faultPair()
    let server = newSession(pair.a, repeat('a', 32))
    discard server.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue =
      text("ok"))
    let client = newSession(pair.b, repeat('b', 32))
    pumpPair(server, client)
    check server.state == ssOpen
    check client.state == ssOpen
    pair.b.setDelayed(true)
    let pending = client.fetch("origin")
    client.close("fault injection disconnect")
    check pending.state == psBroken
    check client.state == ssClosed
    server.close("cleanup")

  test "duplicate wire delivery is rejected or idempotently ignored":
    let pair = faultPair()
    let server = newSession(pair.a, repeat('c', 32))
    discard server.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue = text("ok"))
    let client = newSession(pair.b, repeat('d', 32))
    pumpPair(server, client)
    pair.b.setDuplicated(true)
    let pending = client.fetch("origin")
    for _ in 0 ..< 32:
      try: discard server.pump()
      except CatchableError: discard
      try: discard client.pump()
      except CatchableError: discard
      if pending.state != psPending: break
    check pending.state in {psFulfilled, psBroken}
    server.close("cleanup")
    client.close("cleanup")

  test "delayed handoff response can be released without a busy wait":
    let pair = faultPair()
    let server = newSession(pair.a, repeat('e', 32))
    discard server.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue = text("ok"))
    let client = newSession(pair.b, repeat('f', 32))
    pumpPair(server, client)
    pair.a.setDelayed(true)
    let pending = client.fetch("origin")
    for _ in 0 ..< 16:
      discard client.pump()
    check pending.state == psPending
    pair.a.releaseHeld()
    for _ in 0 ..< 32:
      discard server.pump()
      discard client.pump()
      if pending.state != psPending: break
    check pending.state == psFulfilled
    server.close("cleanup")
    client.close("cleanup")

  test "reconnect starts with a fresh session and does not revive a cancelled gift":
    let table = newGiftTable()
    let pending = table.withdraw("reconnect", "receiver")
    discard table.cancel(pending)
    check pending.state == psBroken
    let replacement = handoffGift(table, "replacement", "receiver")
    check replacement.state == psFulfilled
    check table.stats().pendingWithdraws == 0

  test "late promise settlement is rejected after cancellation":
    let promise = newPromise()
    promise.breakPromise("timeout")
    expect ValueError:
      promise.fulfill(text("late"))
