import std/[net, strutils, unittest]
import ../src/[gifts, messages, promises, references, session, syrup, transport]

proc pumpPair(left, right: Session; rounds = 8) =
  for _ in 0 ..< rounds:
    discard left.pump()
    discard right.pump()

proc pumpMany(owner, gifter: Session; servers, clients: seq[Session]; rounds = 12) =
  for _ in 0 ..< rounds:
    discard owner.pump()
    discard gifter.pump()
    for index in 0 ..< servers.len:
      discard servers[index].pump()
      discard clients[index].pump()

proc seed32(prefix: string; index: int): string =
  let raw = prefix & $index
  let repeated = raw.repeat(32 div raw.len + 1)
  repeated[0 ..< 32]

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

  test "100 concurrent handoffs keep receiver identities isolated":
    const count = 100
    let gifts = newGiftTable()
    let depositPair = inMemoryPair()
    let owner = newSession(depositPair.remote, seed32("owner", 0))
    let gifter = newSession(depositPair.local, seed32("gifter", 0))
    owner.gifts = gifts
    owner.ownsGifts = false
    discard owner.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue =
      if args.len == 1 and args[0].kind == skString:
        text("Hello concurrent, " & args[0].data)
      else:
        raise newException(SessionError, "origin expects one string"))

    var servers: seq[Session]
    var clients: seq[Session]
    var answers: seq[Promise]
    defer:
      owner.close("concurrent stress cleanup")
      gifter.close("concurrent stress cleanup")
      for session in servers: session.close("concurrent stress cleanup")
      for session in clients: session.close("concurrent stress cleanup")

    for index in 0 ..< count:
      let pair = inMemoryPair()
      let server = newSession(pair.remote, seed32("server", index))
      let client = newSession(pair.local, seed32("client", index))
      server.gifts = gifts
      server.ownsGifts = false
      servers.add(server)
      clients.add(client)

    pumpMany(owner, gifter, servers, clients)
    for index in 0 ..< count:
      let giftId = "concurrent-gift-" & $index
      let give = handoffGive(glowcapPublicKey(servers[index].localPublicKey),
        glowcapLocation("concurrent-exporter"), gifter.sessionId(),
        gifter.localSideId(), giftId)
      let signedGive = signatureEnvelope(give, gifter.signLocal(give.encoded()))
      gifter.send(deliverV1Callback(exportRef(0).targetDescriptor(),
        [symbol("deposit-gift"), bytes(giftId), descriptor(descExport, 0)]))
      let receive = handoffReceive(servers[index].sessionId(),
        servers[index].remoteSideId(), 0, signedGive)
      answers.add(clients[index].call(exportRef(0), "withdraw-gift",
        [signatureEnvelope(receive, servers[index].signLocal(receive.encoded()))]))

    pumpMany(owner, gifter, servers, clients)
    check answers.len == count
    for answer in answers:
      check answer.state == psFulfilled
    check gifts.stats().deposited == 0
    check gifts.stats().pendingWithdraws == 0

    var calls: seq[Promise]
    for index, answer in answers:
      calls.add(clients[index].call(answer.value.descriptor(), "greet", [text($index)]))
    pumpMany(owner, gifter, servers, clients)
    for index, call in calls:
      check call.state == psFulfilled
      check call.value.data == "Hello concurrent, " & $index

  test "disconnect during pending withdrawal is bounded and idempotent":
    let gifts = newGiftTable()
    let pair = inMemoryPair()
    let server = newSession(pair.remote, seed32("pending-server", 0))
    let client = newSession(pair.local, seed32("pending-client", 0))
    server.gifts = gifts
    server.ownsGifts = false
    pumpPair(server, client)
    let missing = repeat("m", 32)
    let give = handoffGive(glowcapPublicKey(server.localPublicKey),
      glowcapLocation("pending-exporter"), client.sessionId(),
      client.localSideId(), missing)
    let receive = handoffReceive(server.sessionId(), server.remoteSideId(), 0,
      signatureEnvelope(give, client.signLocal(give.encoded())))
    let pending = client.call(exportRef(0), "withdraw-gift",
      [signatureEnvelope(receive, server.signLocal(receive.encoded()))])
    pumpPair(server, client)
    check pending.state == psPending
    client.close("fault injection")
    server.close("fault injection")
    server.close("repeat close")
    client.close("repeat close")
    check pending.state == psBroken
    check gifts.stats().pendingWithdraws == 0

  test "disconnect during deposit does not leave a gift behind":
    let gifts = newGiftTable()
    let pair = inMemoryPair()
    let owner = newSession(pair.remote, seed32("deposit-owner", 0))
    let gifter = newSession(pair.local, seed32("deposit-gifter", 0))
    owner.gifts = gifts
    owner.ownsGifts = true
    pumpPair(owner, gifter)
    let giftId = repeat("d", 32)
    gifter.send(deliverV1Callback(exportRef(0).targetDescriptor(),
      [symbol("deposit-gift"), bytes(giftId), descriptor(descExport, 0)]))
    gifter.close("deposit disconnect")
    discard owner.pump()
    owner.close("deposit disconnect")
    owner.close("repeat close")
    check gifts.stats().deposited == 0
    check gifts.stats().pendingWithdraws == 0

