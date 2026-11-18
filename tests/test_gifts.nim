import std/[strutils, unittest]
import ../src/[gifts, promises, syrup]

suite "handoff gift table":
  test "fulfills a pending withdrawal after deposit":
    let table = newGiftTable()
    let pending = table.withdraw(repeat("g", 32), repeat("r", 32))
    check pending.state == psPending
    check table.pendingCount(repeat("g", 32)) == 1
    table.deposit(repeat("g", 32), repeat("r", 32), text("gift"))
    check pending.state == psFulfilled
    check pending.value.data == "gift"

  test "supports multiple waiters and checks receiver key":
    let table = newGiftTable()
    let first = table.withdraw("gift", "receiver")
    let second = table.withdraw("gift", "receiver")
    table.deposit("gift", "receiver", text("value"))
    check first.state == psFulfilled
    check second.state == psBroken
    table.deposit("gift", "receiver", text("replacement"))
    let denied = table.withdraw("gift", "other")
    check denied.state == psBroken

  test "binds the first pending receiver and rejects another":
    let table = newGiftTable()
    let owner = table.withdraw("pending", "owner")
    let intruder = table.withdraw("pending", "intruder")
    table.deposit("pending", "", text("value"))
    check owner.state == psFulfilled
    check intruder.state == psBroken
    check table.withdraw("pending", "owner").state == psPending

  test "rejects duplicate deposits and clears waiters":
    let table = newGiftTable()
    let pending = table.withdraw("gift", "receiver")
    table.clear()
    check pending.state == psBroken
    table.deposit("gift", "receiver", text("one"))
    expect GiftTableError:
      table.deposit("gift", "receiver", text("two"))

  test "redeemed gift can be awaited again but does not replay":
    let table = newGiftTable()
    let giftId = repeat("r", 32)
    table.deposit(giftId, "receiver", text("one"))
    let first = table.withdraw(giftId, "receiver")
    check first.state == psFulfilled
    let second = table.withdraw(giftId, "receiver")
    check second.state == psPending
    check table.stats().deposited == 0
    check table.stats().pendingWithdraws == 1
    discard table.cancel(second)
    check table.stats().pendingWithdraws == 0

  test "tracks independent gifts and removes them after withdrawal":
    let table = newGiftTable()
    table.deposit(repeat("a", 32), "a", text("a"))
    table.deposit(repeat("b", 32), "b", text("b"))
    check table.stats().deposited == 2
    discard table.withdraw(repeat("a", 32), "a")
    check table.stats().deposited == 1
    discard table.withdraw(repeat("b", 32), "b")
    check table.stats().deposited == 0
