import std/[net, strutils, unittest]
import ../src/[crypto, handoff, locators, messages, promises, references, server, session, syrup, transport]

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
