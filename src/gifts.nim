import std/[sequtils, tables]
import ./[promises, syrup]

type
  GiftTableError* = object of CatchableError
  GiftEntry = object
    receiverKey: string
    value: SyrupValue
  GiftWaiter = object
    receiverKey: string
    promise: Promise
  GiftTable* = ref object
    gifts: Table[string, GiftEntry]
    waiters: Table[string, seq[GiftWaiter]]

proc newGiftTable*(): GiftTable =
  GiftTable(gifts: initTable[string, GiftEntry](),
    waiters: initTable[string, seq[GiftWaiter]]())

proc deposit*(table: GiftTable; giftId, receiverKey: string; value: SyrupValue) =
  if giftId.len == 0:
    raise newException(GiftTableError, "gift id is required")
  if table.gifts.hasKey(giftId):
    raise newException(GiftTableError, "gift already deposited")
  if table.waiters.hasKey(giftId):
    let waiters = table.waiters[giftId]
    let boundKey = if receiverKey.len > 0: receiverKey else: waiters[0].receiverKey
    var fulfilled = false
    for waiter in waiters:
      if not fulfilled and waiter.receiverKey == boundKey:
        if not settled(waiter.promise): waiter.promise.fulfill(value)
        fulfilled = true
      elif not settled(waiter.promise):
        waiter.promise.breakPromise("gift already withdrawn or receiver key mismatch")
    table.waiters.del(giftId)
  else:
    table.gifts[giftId] = GiftEntry(receiverKey: receiverKey, value: value)

proc withdraw*(table: GiftTable; giftId, receiverKey: string): Promise =
  if giftId.len == 0 or receiverKey.len == 0:
    raise newException(GiftTableError, "gift id and receiver key are required")
  result = newPromise()
  if table.gifts.hasKey(giftId):
    let entry = table.gifts[giftId]
    if entry.receiverKey.len > 0 and entry.receiverKey != receiverKey:
      result.breakPromise("gift receiver key mismatch")
    else:
      if entry.receiverKey.len == 0:
        table.gifts[giftId].receiverKey = receiverKey
      result.fulfill(entry.value)
      table.gifts.del(giftId)
    return
  table.waiters.mgetOrPut(giftId, @[]).add(GiftWaiter(receiverKey: receiverKey, promise: result))

proc cancel*(table: GiftTable; promise: Promise): bool =
  for giftId in toSeq(table.waiters.keys):
    var retained: seq[GiftWaiter]
    var found = false
    for waiter in table.waiters[giftId]:
      if waiter.promise == promise:
        found = true
      else:
        retained.add(waiter)
    if found:
      if not settled(promise): promise.breakPromise("gift withdrawal cancelled")
      if retained.len == 0: table.waiters.del(giftId)
      else: table.waiters[giftId] = retained
      return true
  false

proc pendingCount*(table: GiftTable; giftId: string): int =
  table.waiters.getOrDefault(giftId).len

proc clear*(table: GiftTable) =
  for _, pending in table.waiters.mpairs:
    for waiter in pending:
      if not settled(waiter.promise): waiter.promise.breakPromise("gift table cleared")
  table.waiters.clear()
  table.gifts.clear()
