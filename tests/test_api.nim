import std/[net, strutils, unittest]
import ../src/[api, promises, references, server, session, syrup]
import ../src/session as sessionApi

suite "public node lifecycle":
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
