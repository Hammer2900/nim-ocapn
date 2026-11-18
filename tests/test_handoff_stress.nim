import std/[net, strutils, unittest]
import ../src/[gifts, messages, promises, references, session, syrup, transport]

proc pumpPair(left, right: Session; rounds = 8) =
  for _ in 0 ..< rounds:
    discard left.pump()
    discard right.pump()

proc runHandoff(iteration: int) =
  let gifts = newGiftTable()
  let depositPair = inMemoryPair()
  let owner = newSession(depositPair.remote, repeat("o", 32))
  let gifter = newSession(depositPair.local, repeat("g", 32))
  owner.gifts = gifts
  owner.ownsGifts = false
  discard owner.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue =
    if args.len == 1 and args[0].kind == skString:
      text("Hello from owner, " & args[0].data)
    else:
      raise newException(SessionError, "origin expects one string"))

  let withdrawalPair = inMemoryPair()
  let withdrawalServer = newSession(withdrawalPair.remote, repeat("w", 32))
  let receiver = newSession(withdrawalPair.local, repeat("r", 32))
  withdrawalServer.gifts = gifts
  withdrawalServer.ownsGifts = false
  defer:
    owner.close("stress cleanup")
    gifter.close("stress cleanup")
    withdrawalServer.close("stress cleanup")
    receiver.close("stress cleanup")

  pumpPair(owner, gifter)
  pumpPair(withdrawalServer, receiver)

  let giftId = "stress-gift-" & $iteration
  let give = handoffGive(glowcapPublicKey(withdrawalServer.localPublicKey),
    glowcapLocation("stress-exporter"), gifter.sessionId(),
    gifter.localSideId(), giftId)
  let signedGive = signatureEnvelope(give, gifter.signLocal(give.encoded()))
  gifter.send(deliverV1Callback(exportRef(0).targetDescriptor(),
    [symbol("deposit-gift"), bytes(giftId), descriptor(descExport, 0)]))
  discard owner.pump()
  doAssert gifts.stats().deposited == 1

  let receive = handoffReceive(withdrawalServer.sessionId(),
    withdrawalServer.remoteSideId(), 0, signedGive)
  let answer = receiver.call(exportRef(0), "withdraw-gift",
    [signatureEnvelope(receive, withdrawalServer.signLocal(receive.encoded()))])
  pumpPair(withdrawalServer, receiver)
  doAssert answer.state == psFulfilled
  doAssert gifts.stats().deposited == 0
  doAssert gifts.stats().pendingWithdraws == 0

  let call = receiver.call(answer.value.descriptor(), "greet", [text("stress")])
  pumpPair(owner, gifter)
  pumpPair(withdrawalServer, receiver)
  doAssert call.state == psFulfilled
  doAssert call.value.data == "Hello from owner, stress"

suite "handoff stress":
  test "1000 sequential independent withdrawal sessions":
    for iteration in 0 ..< 1000:
      runHandoff(iteration)
      if iteration mod 100 == 99:
        stderr.writeLine("handoff stress progress=", iteration + 1)

