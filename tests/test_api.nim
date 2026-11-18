import std/[net, strutils, unittest]
import ../src/[api, promises, references, server, session, syrup, transport]
import ../src/session as sessionApi

suite "public node lifecycle":
  test "disconnect breaks an incoming remote promise":
    let pair = inMemoryPair()
    let session = newSession(pair.local)
    let peer = newSession(pair.remote)
    discard session.pump()
    discard peer.pump()
    let source = newPromise()
    source.fulfill(importPromise(7).descriptor())
    let remote = promiseRef(session, source)
    check remote.promise.state == psPending
    session.close("incoming promise disconnect")
    check remote.promise.state == psBroken
    check session.stats().pendingPromises == 0
    peer.close()

  test "forwards a remote promise across two independent hops":
    var sourcePair: tuple[vow, resolver: CapabilityRef]
    var sourceReady = false
    let source = newTcpSessionManager("127.0.0.1", Port(0), "hops-a",
      "127.0.0.1:0", proc(session: Session) =
        sourceReady = true
        sourcePair = session.newPromisePair()
        discard session.publishActor("makePromise", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.promisePayloadDescriptor(sourcePair.vow))
        discard session.publishActor("resolvePromise", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.settlePromise(sourcePair.vow, text("multi-hop result"))
          list()))
    let nodeB = newNode(port = Port(0), seedPrefix = "hops-b")
    let nodeC = newNode(port = Port(0), seedPrefix = "hops-c")
    let nodeD = newNode(port = Port(0), seedPrefix = "hops-d")
    var receivedAtD: ReceivedArgument
    var relayResult: Promise
    var dTarget: RemoteCapability
    nodeD.publishTyped("acceptPromise", proc(session: Session;
        args: seq[ReceivedArgument]): SyrupValue =
      if args.len != 1 or args[0].kind != rakPromise:
        raise newException(SessionError, "D expected a RemotePromise")
      receivedAtD = args[0]
      text("accepted by D"))
    nodeC.publishTyped("relayPromise", proc(session: Session;
        args: seq[ReceivedArgument]): SyrupValue =
      if args.len != 1 or args[0].kind != rakPromise:
        raise newException(SessionError, "C expected a RemotePromise")
      relayResult = nodeC.call(dTarget, "acceptPromise",
        [promiseArg(args[0].promise)])
      text("relayed by C"))
    let bToA = nodeB.dial("127.0.0.1", source.listenPort(), repeat("h", 32))
    let bToC = nodeB.dial("127.0.0.1", nodeC.manager.listenPort(), repeat("i", 32))
    let cToD = nodeC.dial("127.0.0.1", nodeD.manager.listenPort(), repeat("j", 32))
    proc pumpAll() =
      discard source.poll(1)
      discard nodeB.poll(1)
      discard nodeC.poll(1)
      discard nodeD.poll(1)
    var spins = 0
    while bToA.state != ssOpen or bToC.state != ssOpen or
        cToD.state != ssOpen or not sourceReady:
      inc spins
      if spins > 8000: raise newException(CatchableError, "multi-hop handshake timeout")
      pumpAll()
    let makeRef = sessionApi.fetch(bToA, "makePromise")
    let resolveRef = sessionApi.fetch(bToA, "resolvePromise")
    let relayRef = sessionApi.fetch(bToC, "relayPromise")
    let acceptRef = sessionApi.fetch(cToD, "acceptPromise")
    while not settled(makeRef) or not settled(resolveRef) or
        not settled(relayRef) or not settled(acceptRef):
      inc spins
      if spins > 16000: raise newException(CatchableError, "multi-hop fetch timeout")
      pumpAll()
    dTarget = RemoteCapability(session: cToD, reference: acceptRef.value.descriptor())
    let remotePromise = RemoteCapability(session: bToA,
      reference: makeRef.value.descriptor()).call("makePromise", [])
    while not settled(remotePromise):
      inc spins
      if spins > 20000: raise newException(CatchableError, "multi-hop promise creation timeout")
      pumpAll()
    let relayTarget = RemoteCapability(session: bToC, reference: relayRef.value.descriptor())
    let relayed = nodeB.call(relayTarget, "relayPromise",
      [promiseArg(promiseRef(bToA, remotePromise))])
    while not settled(relayed) or relayResult.isNil or receivedAtD.isNil:
      inc spins
      if spins > 26000: raise newException(CatchableError, "multi-hop forwarding timeout")
      pumpAll()
    check relayed.value.data == "relayed by C"
    check receivedAtD.kind == rakPromise
    check receivedAtD.promise.promise.state == psPending
    discard RemoteCapability(session: bToA,
      reference: resolveRef.value.descriptor()).call("resolvePromise", [])
    while receivedAtD.promise.promise.state == psPending or
        relayResult.state == psPending:
      inc spins
      if spins > 32000: raise newException(CatchableError, "multi-hop settlement timeout")
      pumpAll()
    check receivedAtD.promise.promise.value.data == "multi-hop result"
    check relayResult.value.data == "accepted by D"

    nodeB.close()
    nodeC.close()
    nodeD.close()
    source.close()

  test "three peers preserve a forwarded promise and shortening/break":
    var firstPair: tuple[vow, resolver: CapabilityRef]
    var secondPair: tuple[vow, resolver: CapabilityRef]
    var breakPair: tuple[vow, resolver: CapabilityRef]
    var aReady = false
    let aManager = newTcpSessionManager("127.0.0.1", Port(0), "promise-a",
      "127.0.0.1:0", proc(session: Session) =
        aReady = true
        firstPair = session.newPromisePair()
        secondPair = session.newPromisePair()
        breakPair = session.newPromisePair()
        discard session.publishActor("makePromise", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.promisePayloadDescriptor(firstPair.vow))
        discard session.publishActor("makeChain", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.promisePayloadDescriptor(secondPair.vow))
        discard session.publishActor("resolveFirst", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.settlePromise(firstPair.vow, session.promisePayloadDescriptor(secondPair.vow))
          list())
        discard session.publishActor("resolveSecond", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.settlePromise(secondPair.vow, text("chained result"))
          list())
        discard session.publishActor("makeBreak", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.promisePayloadDescriptor(breakPair.vow))
        discard session.publishActor("breakPromise", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.breakPromise(breakPair.vow, "broken by A")
          list()))
    let nodeB = newNode(port = Port(0), seedPrefix = "promise-b")
    var received: ReceivedArgument
    let nodeC = newNode(port = Port(0), seedPrefix = "promise-c")
    nodeC.publishTyped("acceptPromise", proc(session: Session;
        args: seq[ReceivedArgument]): SyrupValue =
      if args.len != 1 or args[0].kind != rakPromise:
        raise newException(SessionError, "expected a RemotePromise")
      received = args[0]
      text("accepted"))
    let bToA = nodeB.dial("127.0.0.1", aManager.listenPort(), repeat("b", 32))
    let bToC = nodeB.dial("127.0.0.1", nodeC.manager.listenPort(), repeat("d", 32))
    proc pumpAll() =
      discard aManager.poll(1)
      discard nodeB.poll(1)
      discard nodeC.poll(1)
    var spins = 0
    while bToA.state != ssOpen or bToC.state != ssOpen or not aReady:
      inc spins
      if spins > 4000: raise newException(CatchableError, "promise handshake timeout")
      pumpAll()
    let makeRef = sessionApi.fetch(bToA, "makePromise")
    let chainRef = sessionApi.fetch(bToA, "makeChain")
    let resolveRef = sessionApi.fetch(bToA, "resolveFirst")
    let resolveSecondRef = sessionApi.fetch(bToA, "resolveSecond")
    let makeBreakRef = sessionApi.fetch(bToA, "makeBreak")
    let breakRef = sessionApi.fetch(bToA, "breakPromise")
    let registerRef = sessionApi.fetch(bToC, "acceptPromise")
    while not settled(makeRef) or not settled(chainRef) or not settled(resolveRef) or
        not settled(resolveSecondRef) or
        not settled(makeBreakRef) or not settled(breakRef) or not settled(registerRef):
      inc spins
      if spins > 10000: raise newException(CatchableError, "promise reference fetch timeout")
      pumpAll()
    let remote = RemoteCapability(session: bToA, reference: makeRef.value.descriptor())
    let pending = remote.call("make", [])
    while not settled(pending):
      inc spins
      if spins > 12000: raise newException(CatchableError, "promise creation timeout")
      pumpAll()
    let register = RemoteCapability(session: bToC, reference: registerRef.value.descriptor())
    let accepted = nodeB.call(register, "acceptPromise",
      [promiseArg(promiseRef(bToA, pending))])
    while not settled(accepted):
      inc spins
      if spins > 16000: raise newException(CatchableError, "promise forwarding timeout")
      pumpAll()
    check accepted.value.data == "accepted"
    check not received.isNil
    check received.kind == rakPromise
    check received.promise.promise.state == psPending
    check bToC.stats().forwardedPromiseCount == 1

    let resolver = RemoteCapability(session: bToA, reference: resolveRef.value.descriptor())
    discard resolver.call("resolveFirst", [])
    let resolveSecond = RemoteCapability(session: bToA, reference: resolveSecondRef.value.descriptor())
    discard resolveSecond.call("resolveSecond", [])
    while received.promise.promise.state == psPending:
      inc spins
      if spins > 20000: raise newException(CatchableError, "promise shortening timeout")
      pumpAll()
    check received.promise.promise.state == psFulfilled
    check received.promise.promise.value.data == "chained result"

    let breakPromise = RemoteCapability(session: bToA, reference: breakRef.value.descriptor())
    let breakSource = RemoteCapability(session: bToA, reference: makeBreakRef.value.descriptor())
    let breakResult = breakSource.call("makeBreak", [])
    while not settled(breakResult):
      inc spins
      if spins > 22000: raise newException(CatchableError, "break promise creation timeout")
      pumpAll()
    let acceptedBreak = nodeB.call(register, "acceptPromise",
      [promiseArg(promiseRef(bToA, breakResult))])
    while not settled(acceptedBreak):
      inc spins
      if spins > 23000: raise newException(CatchableError, "break forwarding timeout")
      pumpAll()
    let pendingBreak = breakPromise.call("breakPromise", [])
    while not settled(pendingBreak):
      inc spins
      if spins > 24000: raise newException(CatchableError, "promise break timeout")
      pumpAll()
    while received.promise.promise.state == psPending:
      inc spins
      if spins > 26000: raise newException(CatchableError, "promise break notification timeout")
      pumpAll()
    check received.promise.promise.state == psBroken
    nodeB.close()
    nodeC.close()
    aManager.close()
    check nodeB.stats().forwardedPromises == 0
    check nodeC.stats().forwardedPromises == 0
    check nodeB.stats().activeSessions == 0
    check nodeB.stats().pendingPromises == 0
    check nodeC.stats().activeSessions == 0
    check nodeC.stats().pendingPromises == 0

  test "three peers preserve two independent remote promise identities":
    var firstPair: tuple[vow, resolver: CapabilityRef]
    var secondPair: tuple[vow, resolver: CapabilityRef]
    var aReady = false
    let aManager = newTcpSessionManager("127.0.0.1", Port(0), "identity-a",
      "127.0.0.1:0", proc(session: Session) =
        aReady = true
        firstPair = session.newPromisePair()
        secondPair = session.newPromisePair()
        discard session.publishActor("makeFirst", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.promisePayloadDescriptor(firstPair.vow))
        discard session.publishActor("makeSecond", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.promisePayloadDescriptor(secondPair.vow))
        discard session.publishActor("resolveFirst", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.settlePromise(firstPair.vow, text("first result")); list())
        discard session.publishActor("resolveSecond", proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          session.settlePromise(secondPair.vow, text("second result")); list()))
    let nodeB = newNode(port = Port(0), seedPrefix = "identity-b")
    let nodeC = newNode(port = Port(0), seedPrefix = "identity-c")
    var received: seq[ReceivedArgument]
    nodeC.publishTyped("acceptTwo", proc(session: Session;
        args: seq[ReceivedArgument]): SyrupValue =
      received = args
      text("accepted"))
    let bToA = nodeB.dial("127.0.0.1", aManager.listenPort(), repeat("e", 32))
    let bToC = nodeB.dial("127.0.0.1", nodeC.manager.listenPort(), repeat("f", 32))
    proc pumpAll() =
      discard aManager.poll(1)
      discard nodeB.poll(1)
      discard nodeC.poll(1)
    var spins = 0
    while bToA.state != ssOpen or bToC.state != ssOpen or not aReady:
      inc spins
      if spins > 4000: raise newException(CatchableError, "identity handshake timeout")
      pumpAll()
    let firstRef = sessionApi.fetch(bToA, "makeFirst")
    let secondRef = sessionApi.fetch(bToA, "makeSecond")
    let resolveFirst = sessionApi.fetch(bToA, "resolveFirst")
    let resolveSecond = sessionApi.fetch(bToA, "resolveSecond")
    let accept = sessionApi.fetch(bToC, "acceptTwo")
    while not settled(firstRef) or not settled(secondRef) or not settled(resolveFirst) or
        not settled(resolveSecond) or not settled(accept):
      inc spins
      if spins > 10000: raise newException(CatchableError, "identity fetch timeout")
      pumpAll()
    let first = RemoteCapability(session: bToA, reference: firstRef.value.descriptor()).call("makeFirst", [])
    let second = RemoteCapability(session: bToA, reference: secondRef.value.descriptor()).call("makeSecond", [])
    while not settled(first) or not settled(second):
      inc spins
      if spins > 14000: raise newException(CatchableError, "identity promise timeout")
      pumpAll()
    let target = RemoteCapability(session: bToC, reference: accept.value.descriptor())
    let accepted = nodeB.call(target, "acceptTwo", [
      promiseArg(promiseRef(bToA, first)), promiseArg(promiseRef(bToA, second))])
    while not settled(accepted):
      inc spins
      if spins > 18000: raise newException(CatchableError, "identity forwarding timeout")
      pumpAll()
    check received.len == 2
    check received[0].kind == rakPromise
    check received[1].kind == rakPromise
    discard RemoteCapability(session: bToA, reference: resolveFirst.value.descriptor()).call("resolveFirst", [])
    discard RemoteCapability(session: bToA, reference: resolveSecond.value.descriptor()).call("resolveSecond", [])
    while received[0].promise.promise.state == psPending or
        received[1].promise.promise.state == psPending:
      inc spins
      if spins > 22000: raise newException(CatchableError, "identity settle timeout")
      pumpAll()
    check received[0].promise.promise.value.data == "first result"
    check received[1].promise.promise.value.data == "second result"
    nodeB.close()
    nodeC.close()
    aManager.close()
    check nodeB.stats().forwardedPromises == 0
    check nodeC.stats().forwardedPromises == 0

  test "prunes disconnected outbound sessions":
    let server = newNode(port = Port(0), seedPrefix = "prune-server")
    let client = newNode(port = Port(0), seedPrefix = "prune-client")
    let connection = client.dial("127.0.0.1", server.manager.listenPort())
    var spins = 0
    while connection.state != ssOpen:
      inc spins
      if spins > 2000: raise newException(CatchableError, "handshake timeout")
      discard server.poll(1)
      discard client.poll(1)
    connection.close("disconnect test")
    discard client.poll(1)
    check client.stats().activeSessions == 0
    client.close()
    server.close()

  test "reconnects without retaining closed sessions":
    let server = newNode(port = Port(0), seedPrefix = "reconnect-server")
    let client = newNode(port = Port(0), seedPrefix = "reconnect-client")
    for index in 0 ..< 8:
      let connection = client.dial("127.0.0.1", server.manager.listenPort(),
        repeat(char(ord('a') + index), 32))
      var spins = 0
      while connection.state != ssOpen:
        inc spins
        if spins > 2000: raise newException(CatchableError, "reconnect handshake timeout")
        discard server.poll(1)
        discard client.poll(1)
      connection.close("reconnect cycle complete")
      while server.manager.sessionCount > 0:
        discard server.poll(1)
      discard client.poll(1)
      check client.stats().activeSessions == 0
    client.close()
    server.close()

  test "polls and closes handoff orchestration with the node":
    let node = newNode(port = Port(0))
    node.publishHandoffEnlivener()
    discard node.poll(0)
    check node.stats().activeSessions == 0
    node.close()
    node.close()
    check node.stats().pendingPromises == 0

  test "transparently passes a live capability through a typed API":
    var received: ReceivedArgument
    var receivedMany: seq[ReceivedArgument]
    let nodeA = newNode(port = Port(0), seedPrefix = "node-a")
    nodeA.publish("origin", proc(args: seq[SyrupValue]): SyrupValue =
      if args.len == 1: text("Hello from A, " & args[0].data)
      else: text("invalid args"))
    let nodeC = newNode(port = Port(0), seedPrefix = "node-c")
    nodeC.publishTyped("register", proc(session: Session;
        args: seq[ReceivedArgument]): SyrupValue =
      if args.len != 1 or args[0].kind != rakCapability:
        raise newException(SessionError, "register expects one capability")
      received = args[0]
      text("registered"))
    nodeC.publishTyped("registerMany", proc(session: Session;
        args: seq[ReceivedArgument]): SyrupValue =
      receivedMany = args
      text("registered-many"))
    let nodeB = newNode(port = Port(0), seedPrefix = "node-b")
    let bToA = nodeB.dial("127.0.0.1", nodeA.manager.listenPort(), repeat("b", 32))
    let bToC = nodeB.dial("127.0.0.1", nodeC.manager.listenPort(), repeat("d", 32))

    proc pumpAll() =
      discard nodeA.poll(1)
      discard nodeB.poll(1)
      discard nodeC.poll(1)

    var spins = 0
    while bToA.state != ssOpen or bToC.state != ssOpen:
      inc spins
      if spins > 2000: raise newException(CatchableError, "node handshake timeout")
      pumpAll()

    let fetchedOrigin = sessionApi.call(bToA, exportRef(0), "fetch", [bytes("origin")])
    while not settled(fetchedOrigin):
      inc spins
      if spins > 4000: raise newException(CatchableError, "origin fetch timeout")
      pumpAll()
    check fetchedOrigin.state == psFulfilled
    let origin = RemoteCapability(session: bToA,
      reference: fetchedOrigin.value.descriptor())

    let fetchedRegister = sessionApi.call(bToC, exportRef(0), "fetch", [bytes("register")])
    while not settled(fetchedRegister):
      inc spins
      if spins > 6000: raise newException(CatchableError, "register fetch timeout")
      pumpAll()
    let register = RemoteCapability(session: bToC,
      reference: fetchedRegister.value.descriptor())
    let registered = nodeB.call(register, "register", [capabilityArg(origin)])
    while not settled(registered):
      inc spins
      if spins > 8000: raise newException(CatchableError, "handoff call timeout")
      pumpAll()
    check registered.state == psFulfilled
    check registered.value.data == "registered"
    check not received.isNil
    check received.kind == rakCapability

    let greeting = received.capability.call("greet", [text("world")])
    while not settled(greeting):
      inc spins
      if spins > 10000: raise newException(CatchableError, "forwarded call timeout")
      pumpAll()
    check greeting.state == psFulfilled
    check greeting.value.data == "Hello from A, world"

    let fetchedMany = sessionApi.call(bToC, exportRef(0), "fetch", [bytes("registerMany")])
    while not settled(fetchedMany):
      inc spins
      if spins > 12000: raise newException(CatchableError, "many fetch timeout")
      pumpAll()
    let registerMany = RemoteCapability(session: bToC,
      reference: fetchedMany.value.descriptor())
    let many = nodeB.call(registerMany, "register", [
      capabilityArg(origin),
      listArg([capabilityArg(origin), recordArg(symbol("nested"),
        [capabilityArg(origin)])]),
      dictArg([dictPair(valueArg(text("cap")), capabilityArg(origin))]),
      setArg([capabilityArg(origin)])])
    while not settled(many):
      inc spins
      if spins > 16000: raise newException(CatchableError, "nested handoff timeout")
      pumpAll()
    check many.state == psFulfilled
    check many.value.data == "registered-many"
    check receivedMany.len == 4
    check receivedMany[0].kind == rakCapability
    check receivedMany[1].kind == rakList
    check receivedMany[1].items[1].kind == rakRecord
    check receivedMany[2].kind == rakDict
    check receivedMany[3].kind == rakSet

    let repeated = nodeB.call(register, "register", [capabilityArg(origin)])
    while not settled(repeated):
      inc spins
      if spins > 20000: raise newException(CatchableError, "repeat handoff timeout")
      pumpAll()
    check repeated.state == psFulfilled
    nodeB.close()
    nodeC.close()
    nodeA.close()

  test "four independent TCP nodes preserve a capability through handoff":
    var receivedAtC: RemoteCapability
    var receivedAtD: seq[RemoteCapability]
    var relayToD: Promise
    let nodeA = newNode(port = Port(0), seedPrefix = "four-a")
    nodeA.publish("origin", proc(args: seq[SyrupValue]): SyrupValue =
      if args.len == 1: text("Hello from A, " & args[0].data)
      else: text("invalid args"))
    let nodeD = newNode(port = Port(0), seedPrefix = "four-d")
    nodeD.publishTyped("accept", proc(session: Session;
        args: seq[ReceivedArgument]): SyrupValue =
      if args.len != 1 or args[0].kind != rakCapability:
        raise newException(SessionError, "D expected one capability")
      receivedAtD.add(args[0].capability)
      text("accepted by D"))
    let nodeC = newNode(port = Port(0), seedPrefix = "four-c")
    var dTarget: RemoteCapability
    nodeC.publishTyped("relay", proc(session: Session;
        args: seq[ReceivedArgument]): SyrupValue =
      if args.len != 1 or args[0].kind != rakCapability:
        raise newException(SessionError, "C expected one capability")
      receivedAtC = args[0].capability
      relayToD = nodeC.call(dTarget, "accept", [capabilityArg(receivedAtC)])
      text("relayed by C"))
    let nodeB = newNode(port = Port(0), seedPrefix = "four-b")
    let bToA = nodeB.dial("127.0.0.1", nodeA.manager.listenPort(), repeat("a", 32))
    let bToC = nodeB.dial("127.0.0.1", nodeC.manager.listenPort(), repeat("b", 32))
    let bToD = nodeB.dial("127.0.0.1", nodeD.manager.listenPort(), repeat("c", 32))
    let cToD = nodeC.dial("127.0.0.1", nodeD.manager.listenPort(), repeat("d", 32))

    proc pumpAll() =
      discard nodeA.poll(1)
      discard nodeB.poll(1)
      discard nodeC.poll(1)
      discard nodeD.poll(1)

    var spins = 0
    while bToA.state != ssOpen or bToC.state != ssOpen or
        bToD.state != ssOpen or cToD.state != ssOpen:
      inc spins
      if spins > 12000: raise newException(CatchableError, "four-node handshake timeout")
      pumpAll()

    let originP = sessionApi.fetch(bToA, "origin")
    let relayP = sessionApi.fetch(bToC, "relay")
    let acceptP = sessionApi.fetch(cToD, "accept")
    let directAcceptP = sessionApi.fetch(bToD, "accept")
    while not settled(originP) or not settled(relayP) or
        not settled(acceptP) or not settled(directAcceptP):
      inc spins
      if spins > 24000: raise newException(CatchableError, "four-node fetch timeout")
      pumpAll()
    check originP.state == psFulfilled
    check relayP.state == psFulfilled
    check acceptP.state == psFulfilled
    check directAcceptP.state == psFulfilled

    dTarget = RemoteCapability(session: cToD, reference: acceptP.value.descriptor())
    let origin = RemoteCapability(session: bToA, reference: originP.value.descriptor())
    let relay = RemoteCapability(session: bToC, reference: relayP.value.descriptor())
    let directAccept = RemoteCapability(session: bToD,
      reference: directAcceptP.value.descriptor())
    let cResult = nodeB.call(relay, "relay", [capabilityArg(origin)])
    let dResult = nodeB.call(directAccept, "accept", [capabilityArg(origin)])
    while not settled(cResult) or not settled(dResult) or
        relayToD.isNil or not settled(relayToD):
      inc spins
      if spins > 36000: raise newException(CatchableError, "four-node handoff timeout")
      pumpAll()
    check cResult.state == psFulfilled
    check relayToD.state == psFulfilled
    check dResult.state == psFulfilled
    check not receivedAtC.session.isNil
    check receivedAtD.len == 2
    check receivedAtC.session != receivedAtD[0].session
    check receivedAtC.session != receivedAtD[1].session

    let viaC = receivedAtC.call("greet", [text("world")])
    let viaD = receivedAtD[0].call("greet", [text("world")])
    while not settled(viaC) or not settled(viaD):
      inc spins
      if spins > 48000: raise newException(CatchableError, "four-node call timeout")
      pumpAll()
    check viaC.state == psFulfilled
    check viaD.state == psFulfilled
    check viaC.value.data == "Hello from A, world"
    check viaD.value.data == "Hello from A, world"
    check nodeB.stats().pendingHandoffs == 0
    check nodeC.stats().pendingHandoffs == 0
    check nodeD.stats().pendingHandoffs == 0
    nodeD.close()
    nodeC.close()
    nodeB.close()
    nodeA.close()
