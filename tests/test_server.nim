import std/[net, os, sequtils, strutils, unittest]
import ../src/[gifts, promises, references, session, server, syrup, transport]

suite "TCP session manager":
  test "poll honors a per-call work budget":
    let manager = newTcpSessionManager("127.0.0.1", Port(0), "budget-manager",
      "127.0.0.1:0")
    var transports: seq[TcpTransport]
    for _ in 0 ..< 4:
      let transport = connectTcp("127.0.0.1", manager.listenPort())
      transport.setNonBlocking()
      transports.add(transport)
    check manager.poll(20, 1) <= 1
    for transport in transports: transport.close()
    manager.close()

  test "handles many calls across several clients":
    let manager = newTcpSessionManager("127.0.0.1", Port(0), "load-manager",
      "127.0.0.1:0", proc(session: Session) =
        discard session.publishObject("echo", proc(args: seq[SyrupValue]): SyrupValue =
          if args.len == 1: args[0] else: text("bad args")))
    var clients: seq[Session]
    for index in 0 ..< 16:
      let transport = connectTcp("127.0.0.1", manager.listenPort())
      transport.setNonBlocking()
      clients.add(newGlowcapSession(transport, repeat(char(ord('a') + index), 32),
        "127.0.0.1:" & $manager.listenPort()))
    while clients.anyIt(it.state != ssOpen):
      discard manager.poll(5, 32)
      for client in clients: discard client.pump()
    var pending: seq[Promise]
    for client in clients:
      let fetched = client.fetch("echo")
      while not settled(fetched):
        discard manager.poll(5, 32)
        for peer in clients: discard peer.pump()
      for callIndex in 0 ..< 128:
        pending.add(client.call(fetched.value.descriptor(), "echo", [text($callIndex)]))
    while pending.anyIt(not settled(it)):
      discard manager.poll(5, 32)
      for client in clients: discard client.pump()
    for promise in pending:
      check promise.state == psFulfilled
    for client in clients:
      let current = client.stats()
      check current.pendingPromises == 0
    for client in clients: client.close("load test complete")
    while manager.sessionCount > 0:
      discard manager.poll(5, 32)
    check manager.sessionCount == 0
    let finalStats = manager.stats()
    check finalStats.pendingPromises == 0
    check finalStats.imports == 0
    check finalStats.exports == 0
    manager.close()

  test "isolates a bad client from a healthy client":
    var opened = 0
    let manager = newTcpSessionManager("127.0.0.1", Port(0), "test-manager",
      "127.0.0.1:0", proc(capSession: Session) =
        inc opened
        discard capSession.publishObject("nim-greeter", proc(args: seq[SyrupValue]): SyrupValue =
          if args.len != 1 or args[0].kind notin {skString, skBytes}:
            raise newException(SessionError, "greet expects one string")
          text("Hello from Nim, " & args[0].data)))
    let port = manager.listenPort()
    let badTransport = connectTcp("127.0.0.1", port)
    badTransport.setNonBlocking()
    let bad = newGlowcapSession(badTransport, repeat("b", 32),
      "127.0.0.1:" & $port)
    let goodTransport = connectTcp("127.0.0.1", port)
    goodTransport.setNonBlocking()
    let good = newGlowcapSession(goodTransport, repeat("c", 32),
      "127.0.0.1:" & $port)
    while manager.sessionCount < 2:
      discard manager.poll(20)
    discard bad.pump()
    discard good.pump()
    while opened < 2:
      discard manager.poll(20)
    check bad.state == ssOpen
    check good.state == ssOpen

    bad.send(record(symbol("op:unknown")))
    discard manager.poll(20)
    check manager.sessionCount == 1

    let fetched = good.fetch("nim-greeter")
    while not settled(fetched):
      discard manager.poll(20)
      discard manager.poll(20)
      discard good.pump()
    check fetched.state == psFulfilled
    let answer = good.call(fetched.value.descriptor(), "greet", [text("survivor")])
    while not settled(answer):
      discard manager.poll(20)
      discard manager.poll(20)
      discard good.pump()
    check answer.state == psFulfilled
    check answer.value.data == "Hello from Nim, survivor"
    manager.close()

  test "closes a client with a malformed TCP frame only":
    var opened = 0
    let manager = newTcpSessionManager("127.0.0.1", Port(0), "frame-manager",
      "127.0.0.1:0", proc(session: Session) = inc opened)
    let port = manager.listenPort()
    let badTransport = connectTcp("127.0.0.1", port)
    badTransport.setNonBlocking()
    let bad = newGlowcapSession(badTransport, repeat("j", 32),
      "127.0.0.1:" & $port)
    let goodTransport = connectTcp("127.0.0.1", port)
    goodTransport.setNonBlocking()
    let good = newGlowcapSession(goodTransport, repeat("k", 32),
      "127.0.0.1:" & $port)
    while opened < 2:
      discard manager.poll(20)
      discard bad.pump()
      discard good.pump()
    check bad.state == ssOpen
    check good.state == ssOpen
    badTransport.send("x")
    discard manager.poll(20)
    check manager.sessionCount == 1
    check good.state == ssOpen
    good.close("frame fault test complete")
    manager.close()

  test "disconnect breaks a pending promise without affecting another client":
    var opened = 0
    let manager = newTcpSessionManager("127.0.0.1", Port(0), "pending-manager",
      "127.0.0.1:0", proc(capSession: Session) =
        inc opened
        discard capSession.publishObject("never", proc(args: seq[SyrupValue]): SyrupValue =
          text("should not be reached")))
    let port = manager.listenPort()
    let pendingTransport = connectTcp("127.0.0.1", port)
    pendingTransport.setNonBlocking()
    let pendingClient = newGlowcapSession(pendingTransport, repeat("d", 32),
      "127.0.0.1:" & $port)
    let healthyTransport = connectTcp("127.0.0.1", port)
    healthyTransport.setNonBlocking()
    let healthyClient = newGlowcapSession(healthyTransport, repeat("e", 32),
      "127.0.0.1:" & $port)
    while manager.sessionCount < 2:
      discard manager.poll(20)
    discard pendingClient.pump()
    discard healthyClient.pump()
    while opened < 2:
      discard manager.poll(20)
    check pendingClient.state == ssOpen
    let pending = pendingClient.call(exportRef(1), "wait", [])
    check pending.state == psPending

    pendingClient.close("client disconnected")
    while manager.sessionCount > 1:
      discard manager.poll(20)
    check pending.state == psBroken

    let fetched = healthyClient.fetch("never")
    while not settled(fetched):
      discard manager.poll(20)
      discard healthyClient.pump()
    check fetched.state == psFulfilled
    manager.close()

  test "expires a client that never completes the handshake":
    let manager = newTcpSessionManager("127.0.0.1", Port(0), "timeout-manager",
      "127.0.0.1:0", handshakeTimeoutMs = 1)
    let transport = connectTcp("127.0.0.1", manager.listenPort())
    transport.setNonBlocking()
    while manager.sessionCount == 0:
      discard manager.poll(20)
    sleep(5)
    discard manager.poll(20)
    check manager.sessionCount == 0
    transport.close()
    manager.close()

  test "reuses selector slots after sequential client disconnects":
    var opened = 0
    let manager = newTcpSessionManager("127.0.0.1", Port(0), "reuse-manager",
      "127.0.0.1:0", proc(capSession: Session) = inc opened)
    for index in 0 ..< 4:
      let transport = connectTcp("127.0.0.1", manager.listenPort())
      transport.setNonBlocking()
      let client = newGlowcapSession(transport, repeat(char(ord('f') + index), 32),
        "127.0.0.1:" & $manager.listenPort())
      while manager.sessionCount == 0:
        discard manager.poll(20)
      discard client.pump()
      while client.state != ssOpen:
        discard client.pump()
      while opened < index + 1:
        discard manager.poll(20)
      client.close("sequential disconnect")
      while manager.sessionCount > 0:
        discard manager.poll(20)
    check opened == 4
    manager.close()

  test "shares one gift table across TCP sessions":
    var opened: seq[Session]
    let manager = newTcpSessionManager("127.0.0.1", Port(0), "gift-manager",
      "127.0.0.1:0", proc(session: Session) = opened.add(session))
    let firstTransport = connectTcp("127.0.0.1", manager.listenPort())
    firstTransport.setNonBlocking()
    let first = newGlowcapSession(firstTransport, repeat("g", 32),
      "127.0.0.1:" & $manager.listenPort())
    let secondTransport = connectTcp("127.0.0.1", manager.listenPort())
    secondTransport.setNonBlocking()
    let second = newGlowcapSession(secondTransport, repeat("h", 32),
      "127.0.0.1:" & $manager.listenPort())
    while opened.len < 2:
      discard manager.poll(20)
      discard first.pump()
      discard second.pump()
    check opened[0].gifts == opened[1].gifts
    manager.gifts.deposit("survivor", "receiver", text("still-live"))
    first.close("test complete")
    check manager.gifts.withdraw("survivor", "receiver").state == psFulfilled
    second.close("test complete")
    manager.close()
