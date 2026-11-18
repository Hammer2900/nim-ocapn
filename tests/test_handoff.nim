import std/[net, strutils, unittest]
import ../src/[crypto, gifts, handoff, locators, messages, promises, references, server, session, syrup, transport]

suite "handoff manager lifecycle":
  test "rejects invalid handoff limits":
    expect SessionError:
      discard newHandoffManager(HandoffLimits(maxPending: -1))

  test "close is idempotent and stops new work":
    let manager = newHandoffManager()
    manager.close()
    manager.close()
    expect SessionError:
      manager.pump()

  test "close rejects new receiver sessions":
    let manager = newHandoffManager()
    manager.close()
    expect SessionError:
      discard manager.startHandoffReceiver(list(), nil)

  test "disconnect during receive breaks the handoff promise":
    let listener = listenTcp("127.0.0.1", Port(0))
    let peer = newPeerLocator("tcp-testing-only", "exporter",
      [("host", "127.0.0.1"), ("port", $listener.localPort())])
    let give = handoffGive(glowcapPublicKey(crypto.publicKey(repeat("k", 32))), peer.peerSyrup(),
      repeat("s", 32), repeat("d", 32), repeat("g", 32))
    let signedGive = signatureEnvelope(give, repeat("x", 64))
    let manager = newHandoffManager()
    let signerPair = inMemoryPair()
    let signer = newSession(signerPair.local, repeat("k", 32))
    let receipt = manager.startHandoffReceiver(signedGive, signer)
    receipt.session.close("peer disconnected")
    manager.pump()
    check receipt.promise.state == psBroken
    manager.close("cleanup complete")
    signer.close("cleanup complete")
    listener.close()

  test "handoff gift ids are random 32-byte values":
    let pair = inMemoryPair()
    let source = newSession(pair.local, repeat("s", 32))
    let receiver = newSession(pair.remote, repeat("r", 32))
    discard source.pump()
    discard receiver.pump()
    source.remoteLocation = "tcp-testing-only"
    source.remotePeer = newPeerLocator("tcp-testing-only", "exporter",
      [("host", "127.0.0.1"), ("port", "1")])
    let manager = newHandoffManager()
    let first = manager.handoffArgument(source, importObject(7), receiver)
    let second = manager.handoffArgument(source, importObject(7), receiver)
    let firstId = first.fields[0].fields[4].data
    let secondId = second.fields[0].fields[4].data
    check firstId.len == 32
    check secondId.len == 32
    check firstId != secondId
    manager.close()
    source.close()
    receiver.close()

  test "concurrent receiver handoffs use independent identities and clean up":
    let listener = listenTcp("127.0.0.1", Port(0))
    let signerPair = inMemoryPair()
    let signer = newSession(signerPair.local, repeat("k", 32))
    let peer = newPeerLocator("tcp-testing-only", "exporter",
      [("host", "127.0.0.1"), ("port", $listener.localPort())])
    let give = handoffGive(glowcapPublicKey(signer.localPublicKey),
      peer.peerSyrup(), repeat("s", 32), repeat("d", 32), repeat("g", 32))
    let signedGive = signatureEnvelope(give, repeat("x", 64))
    let manager = newHandoffManager()
    let first = manager.startHandoffReceiver(signedGive, signer)
    let second = manager.startHandoffReceiver(signedGive, signer)
    check first.session.localPublicKey != second.session.localPublicKey
    check manager.stats().pendingReceives == 2
    manager.close("cancel concurrent handoffs")
    check first.promise.state == psBroken
    check second.promise.state == psBroken
    check manager.stats().pendingReceives == 0
    check manager.stats().receiverSessions == 0
    signer.close("cleanup signer")
    listener.close()

  test "receiver rejects a give addressed to another key before dialing":
    let listener = listenTcp("127.0.0.1", Port(0))
    let signerPair = inMemoryPair()
    let signer = newSession(signerPair.local, repeat("k", 32))
    let peer = newPeerLocator("tcp-testing-only", "exporter",
      [("host", "127.0.0.1"), ("port", $listener.localPort())])
    let give = handoffGive(glowcapPublicKey(crypto.publicKey(repeat("z", 32))),
      peer.peerSyrup(), repeat("s", 32), repeat("d", 32), repeat("g", 32))
    let manager = newHandoffManager()
    expect SessionError:
      discard manager.startHandoffReceiver(signatureEnvelope(give, repeat("x", 64)), signer)
    manager.close()
    signer.close("cleanup signer")
    listener.close()

  test "passes a capability through an intermediate peer":
    var bHandoffs = newHandoffManager()
    var cHandoffs = newHandoffManager()
    var aReady = false
    var bReady = false
    let a = newTcpSessionManager("127.0.0.1", Port(0), "handoff-a",
      "127.0.0.1:0", proc(session: Session) =
        aReady = true
        discard session.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue =
          if args.len == 1: text("Hello from A, " & args[0].data)
          else: text("invalid args")))
    let b = newTcpSessionManager("127.0.0.1", Port(0), "handoff-b",
      "127.0.0.1:0", proc(session: Session) =
        bReady = true
        discard session.publishActor("enlivener", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          let answer = actor.deferAnswer()
          discard bHandoffs.startSturdyRefSession(args[0].sturdyRef(), actor, answer)
          list()))
    let cTransport = connectTcp("127.0.0.1", b.listenPort())
    cTransport.setNonBlocking()
    let c = newGlowcapSession(cTransport, repeat("c", 32),
      "127.0.0.1:" & $b.listenPort())
    var spins = 0
    while c.state != ssOpen or not bReady:
      inc spins
      if spins > 2000: raise newException(CatchableError, "C handshake timeout")
      discard b.poll(10)
      discard c.pump()

    let enlivener = c.fetch("enlivener")
    spins = 0
    while not settled(enlivener):
      inc spins
      if spins > 2000: raise newException(CatchableError, "fetch timeout")
      discard b.poll(10)
      discard c.pump()
    check enlivener.state == psFulfilled

    let peer = newPeerLocator("tcp-testing-only", "handoff-a",
      [("host", "127.0.0.1"), ("port", $a.listenPort())])
    let sturdy = SturdyRef(peer: peer, swissNum: "origin")
    let give = c.deliverCall(enlivener.value.descriptor(), [sturdy.sturdySyrup()])
    spins = 0
    while not settled(give):
      inc spins
      if spins > 2000: raise newException(CatchableError, "give timeout")
      discard a.poll(10)
      discard b.poll(10)
      discard c.pump()
      bHandoffs.pump()
    check aReady
    check give.state == psFulfilled

    let received = cHandoffs.startHandoffReceiver(give.value, c)
    spins = 0
    while not settled(received.promise):
      inc spins
      if spins > 2000: raise newException(CatchableError, "receive timeout")
      discard a.poll(10)
      discard c.pump()
      cHandoffs.pump()
    check received.promise.state == psFulfilled

    let answer = received.session.call(received.promise.value.descriptor(), "greet", [text("world")])
    spins = 0
    while not settled(answer):
      inc spins
      if spins > 2000: raise newException(CatchableError, "call timeout")
      discard a.poll(10)
      discard c.pump()
      cHandoffs.pump()
    check answer.state == psFulfilled
    check answer.value.data == "Hello from A, world"

    let repeated = cHandoffs.startHandoffReceiver(give.value, c)
    spins = 0
    while repeated.session.state != ssOpen or cHandoffs.stats().pendingReceives == 0:
      inc spins
      if spins > 2000: raise newException(CatchableError, "repeat withdraw setup timeout")
      discard a.poll(10)
      discard c.pump()
      cHandoffs.pump()
    check repeated.promise.state == psPending
    check cHandoffs.stats().pendingReceives == 1
    repeated.session.close("redeemed gift must not replay")
    cHandoffs.pump()
    check repeated.promise.state == psBroken
    check cHandoffs.stats().pendingReceives == 0
    cHandoffs.close()
    bHandoffs.close()
    c.close("test complete")
    a.close()
    b.close()

  test "withdrawal on a separate session sees the deposited gift":
    let sharedGifts = newGiftTable()
    let depositPair = inMemoryPair()
    let depositServer = newSession(depositPair.remote, repeat("d", 32))
    let gifter = newSession(depositPair.local, repeat("g", 32))
    discard depositServer.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue =
      if args.len == 1 and args[0].kind == skString:
        text("Hello from owner, " & args[0].data)
      else:
        raise newException(SessionError, "origin expects one string"))
    depositServer.gifts = sharedGifts
    depositServer.ownsGifts = false

    let withdrawalPair = inMemoryPair()
    let withdrawalServer = newSession(withdrawalPair.remote, repeat("w", 32))
    let receiver = newSession(withdrawalPair.local, repeat("r", 32))
    withdrawalServer.gifts = sharedGifts
    withdrawalServer.ownsGifts = false

    discard depositServer.pump()
    discard gifter.pump()
    discard withdrawalServer.pump()
    discard receiver.pump()

    let giftId = repeat("z", 32)
    let give = handoffGive(glowcapPublicKey(withdrawalServer.localPublicKey),
      glowcapLocation("withdrawal-exporter"), gifter.sessionId(),
      gifter.localSideId(), giftId)
    let signedGive = signatureEnvelope(give, gifter.signLocal(give.encoded()))
    gifter.send(deliverV1Callback(exportRef(0).targetDescriptor(),
      [symbol("deposit-gift"), bytes(giftId), descriptor(descExport, 0)]))
    discard depositServer.pump()
    check sharedGifts.stats().deposited == 1

    let receive = handoffReceive(withdrawalServer.sessionId(),
      withdrawalServer.remoteSideId(), 0, signedGive)
    let signedReceive = signatureEnvelope(receive,
      withdrawalServer.signLocal(receive.encoded()))
    let answer = receiver.call(exportRef(0), "withdraw-gift", [signedReceive])
    discard withdrawalServer.pump()
    discard receiver.pump()
    check answer.state == psFulfilled
    check sharedGifts.stats().deposited == 0
    check sharedGifts.stats().pendingWithdraws == 0

    let appPair = inMemoryPair()
    let appServer = newSession(appPair.remote, repeat("a", 32))
    let appClient = newSession(appPair.local, repeat("b", 32))
    discard appServer.pump()
    discard appClient.pump()
    let remapped = appServer.rehomeCapability(receiver, answer.value)
    let appCall = appClient.call(remapped.descriptor(), "greet", [text("app")])
    for _ in 0 ..< 10:
      discard appServer.pump()
      discard appClient.pump()
      discard withdrawalServer.pump()
      discard receiver.pump()
    check appCall.state == psFulfilled
    check appCall.value.data == "Hello from owner, app"

    let forwarded = receiver.call(answer.value.descriptor(), "greet", [text("world")])
    for _ in 0 ..< 8:
      discard withdrawalServer.pump()
      discard receiver.pump()
      discard depositServer.pump()
      discard gifter.pump()
    check forwarded.state == psFulfilled
    check forwarded.value.data == "Hello from owner, world"

    depositServer.close("test cleanup")
    gifter.close("test cleanup")
    withdrawalServer.close("test cleanup")
    receiver.close("test cleanup")
    appServer.close("test cleanup")
    appClient.close("test cleanup")

  test "two independent withdrawal sessions receive callable proxies":
    let sharedGifts = newGiftTable()
    let depositPair = inMemoryPair()
    let depositServer = newSession(depositPair.remote, repeat("d", 32))
    let gifter = newSession(depositPair.local, repeat("g", 32))
    discard depositServer.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue =
      if args.len == 1 and args[0].kind == skString:
        text("Hello concurrent, " & args[0].data)
      else:
        raise newException(SessionError, "origin expects greet"))
    depositServer.gifts = sharedGifts
    depositServer.ownsGifts = false

    let pairC = inMemoryPair()
    let serverC = newSession(pairC.remote, repeat("c", 32))
    let clientC = newSession(pairC.local, repeat("x", 32))
    serverC.gifts = sharedGifts
    serverC.ownsGifts = false
    let pairD = inMemoryPair()
    let serverD = newSession(pairD.remote, repeat("e", 32))
    let clientD = newSession(pairD.local, repeat("y", 32))
    serverD.gifts = sharedGifts
    serverD.ownsGifts = false

    discard depositServer.pump()
    discard gifter.pump()
    discard serverC.pump()
    discard clientC.pump()
    discard serverD.pump()
    discard clientD.pump()

    let giveC = handoffGive(glowcapPublicKey(serverC.localPublicKey),
      glowcapLocation("concurrent-exporter"), gifter.sessionId(),
      gifter.localSideId(), repeat("1", 32))
    let giveD = handoffGive(glowcapPublicKey(serverD.localPublicKey),
      glowcapLocation("concurrent-exporter"), gifter.sessionId(),
      gifter.localSideId(), repeat("2", 32))
    let signedC = signatureEnvelope(giveC, gifter.signLocal(giveC.encoded()))
    let signedD = signatureEnvelope(giveD, gifter.signLocal(giveD.encoded()))
    gifter.send(deliverV1Callback(exportRef(0).targetDescriptor(),
      [symbol("deposit-gift"), bytes(repeat("1", 32)), descriptor(descExport, 0)]))
    gifter.send(deliverV1Callback(exportRef(0).targetDescriptor(),
      [symbol("deposit-gift"), bytes(repeat("2", 32)), descriptor(descExport, 0)]))
    discard depositServer.pump()
    check sharedGifts.stats().deposited == 2

    let receiveC = handoffReceive(serverC.sessionId(), serverC.remoteSideId(), 0, signedC)
    let receiveD = handoffReceive(serverD.sessionId(), serverD.remoteSideId(), 0, signedD)
    let answerC = clientC.call(exportRef(0), "withdraw-gift",
      [signatureEnvelope(receiveC, serverC.signLocal(receiveC.encoded()))])
    let answerD = clientD.call(exportRef(0), "withdraw-gift",
      [signatureEnvelope(receiveD, serverD.signLocal(receiveD.encoded()))])
    for _ in 0 ..< 8:
      discard serverC.pump()
      discard clientC.pump()
      discard serverD.pump()
      discard clientD.pump()
      discard depositServer.pump()
      discard gifter.pump()
    check answerC.state == psFulfilled
    check answerD.state == psFulfilled

    let callC = clientC.call(answerC.value.descriptor(), "greet", [text("C")])
    let callD = clientD.call(answerD.value.descriptor(), "greet", [text("D")])
    for _ in 0 ..< 10:
      discard serverC.pump()
      discard clientC.pump()
      discard serverD.pump()
      discard clientD.pump()
      discard depositServer.pump()
      discard gifter.pump()
    check callC.state == psFulfilled
    check callD.state == psFulfilled
    check callC.value.data == "Hello concurrent, C"
    check callD.value.data == "Hello concurrent, D"

    depositServer.close("test cleanup")
    gifter.close("test cleanup")
    serverC.close("test cleanup")
    clientC.close("test cleanup")
    serverD.close("test cleanup")
    clientD.close("test cleanup")
