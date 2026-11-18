import std/[net, strutils, unittest]
import ../src/[api, handoff, locators, messages, promises, references, server, session, syrup]
import ../src/session as sessionApi

type
  DisconnectRole = enum drA, drB, drC
  HandoffPhase = enum hpBeforeDeposit, hpAfterDeposit, hpDuringWithdraw, hpAfterRedeem
  Fixture = ref object
    a, b, c: Node
    bToA, cToB: Session
    give: SyrupValue
    receipt: HandoffReceipt

proc pump(fixture: Fixture) =
  discard fixture.a.poll(1)
  discard fixture.b.poll(1)
  discard fixture.c.poll(1)

proc pumpUntil(fixture: Fixture; condition: proc(): bool {.closure.}; limit = 4000) =
  var spins = 0
  while not condition():
    inc spins
    if spins > limit:
      raise newException(CatchableError, "handoff disconnect harness timeout")
    fixture.pump()

proc setupFixture(): Fixture =
  new(result)
  result.a = newNode(port = Port(0), seedPrefix = "matrix-a")
  result.a.publish("origin", proc(args: seq[SyrupValue]): SyrupValue =
    if args.len == 1: text("Hello from A, " & args[0].data)
    else: text("invalid args"))
  result.b = newNode(port = Port(0), seedPrefix = "matrix-b")
  result.c = newNode(port = Port(0), seedPrefix = "matrix-c")
  result.bToA = result.b.dial("127.0.0.1", result.a.manager.listenPort(), repeat("m", 32))
  result.cToB = result.c.dial("127.0.0.1", result.b.manager.listenPort(), repeat("n", 32))
  let fixture = result
  fixture.pumpUntil(proc(): bool = fixture.bToA.state == ssOpen and fixture.cToB.state == ssOpen)
  let originPromise = sessionApi.fetch(result.bToA, "origin")
  fixture.pumpUntil(proc(): bool = settled(originPromise))
  let origin = originPromise.value
  let giftId = repeat("g", 32)
  let give = handoffGive(glowcapPublicKey(result.cToB.localPublicKey),
    result.bToA.remotePeer.peerSyrup(), result.bToA.sessionId(),
    result.bToA.localSideId(), giftId)
  result.bToA.send(deliverV1Callback(exportRef(0).targetDescriptor(),
    [symbol("deposit-gift"), bytes(giftId), origin]))
  result.give = signatureEnvelope(give, result.bToA.signLocal(give.encoded()))

proc closeRole(fixture: Fixture; role: DisconnectRole) =
  case role
  of drA: fixture.a.close()
  of drB: fixture.b.close()
  of drC: fixture.c.close()

proc closeAll(fixture: Fixture) =
  fixture.c.close()
  fixture.b.close()
  fixture.a.close()

proc runScenario(phase: HandoffPhase; role: DisconnectRole) =
  let fixture = setupFixture()
  case phase
  of hpBeforeDeposit:
    discard
  of hpAfterDeposit:
    fixture.pumpUntil(proc(): bool = fixture.a.stats().depositedGifts == 1)
  of hpDuringWithdraw:
    fixture.pumpUntil(proc(): bool = fixture.a.stats().depositedGifts == 1)
    fixture.receipt = fixture.c.receiveHandoff(fixture.give, fixture.cToB)
    fixture.pumpUntil(proc(): bool = fixture.receipt.session.state == ssOpen)
    fixture.c.handoffs.pump()
    check fixture.receipt.promise.state == psPending
  of hpAfterRedeem:
    fixture.pumpUntil(proc(): bool = fixture.a.stats().depositedGifts == 1)
    fixture.receipt = fixture.c.receiveHandoff(fixture.give, fixture.cToB)
    fixture.pumpUntil(proc(): bool = settled(fixture.receipt.promise))
    check fixture.receipt.promise.state == psFulfilled
    check fixture.receipt.promise.value.kind == skRecord

  closeRole(fixture, role)
  closeAll(fixture)
  if phase == hpDuringWithdraw:
    check fixture.receipt.promise.state == psBroken
  check fixture.a.stats().activeSessions == 0
  check fixture.b.stats().activeSessions == 0
  check fixture.c.stats().activeSessions == 0
  check fixture.a.stats().pendingPromises == 0
  check fixture.b.stats().pendingPromises == 0
  check fixture.c.stats().pendingPromises == 0
  check fixture.a.stats().pendingHandoffs == 0
  check fixture.b.stats().pendingHandoffs == 0
  check fixture.c.stats().pendingHandoffs == 0
  check fixture.a.stats().depositedGifts == 0
  check fixture.b.stats().pendingGiftWithdraws == 0
  check fixture.c.stats().pendingGiftWithdraws == 0

suite "wire-level handoff disconnect matrix":
  for phase in HandoffPhase:
    for role in DisconnectRole:
      test($phase & " disconnect " & $role):
        runScenario(phase, role)
