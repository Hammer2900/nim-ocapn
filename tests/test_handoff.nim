import std/[net, strutils, unittest]
import ../src/[handoff, locators, messages, promises, references, server, session, syrup, transport]

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
    let give = handoffGive(glowcapPublicKey(repeat("k", 32)), peer.peerSyrup(),
      repeat("s", 32), repeat("d", 32), "gift")
    let signedGive = signatureEnvelope(give, repeat("x", 64))
    let manager = newHandoffManager()
    let receipt = manager.startHandoffReceiver(signedGive, nil)
    receipt.session.close("peer disconnected")
    manager.pump()
    check receipt.promise.state == psBroken
    manager.close("cleanup complete")
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
    cHandoffs.close()
    bHandoffs.close()
    c.close("test complete")
    a.close()
    b.close()
