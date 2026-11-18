import std/[monotimes, net, os, strutils, unittest, times]
import ../src/[gifts, handoff, locators, onion, promises, references, session, syrup, transport]

type
  OnionNode = ref object
    name: string
    peer: PeerLocator
    listener: OnionListener
    handoffs: HandoffManager
    gifts: GiftTable
    accepted: seq[Session]
    receipts: seq[HandoffReceipt]

proc serviceEnv(index: char): string =
  getEnv("NIM_OCAPN_ONION_" & $index)

proc portEnv(index: char; fallback: int): Port =
  let value = getEnv("NIM_OCAPN_ONION_" & $index & "_PORT")
  if value.len == 0: return Port(fallback)
  Port(parseInt(value))

proc traceEnabled(): bool = getEnv("NIM_OCAPN_ONION_TRACE") == "1"

proc traceEvent(event: TraceEvent) =
  if not traceEnabled(): return
  let direction = if event.direction == tdIn: "IN" else: "OUT"
  echo "[TRACE] capTP node=", event.nodeId, " session=", event.sessionId,
    " ", direction, " op=", event.operation, " target=", event.target,
    " answer=", event.answer, " bytes=", event.bytes, " state=", event.promiseState,
    " ownership=", event.ownership

proc attachTrace(node: OnionNode; session: Session) =
  session.setTraceSink(node.name, traceEvent)

proc newOnionNode(name, service: string; localPort: Port): OnionNode =
  let layer = newOnionNetlayer()
  let peer = newPeerLocator("onion", service)
  result = OnionNode(name: name, peer: peer, listener: layer.listen(localPort = localPort,
    advertised = peer), handoffs: newHandoffManager(), gifts: newGiftTable(),
    accepted: @[], receipts: @[])
  result.handoffs.setTraceSink(name, traceEvent)

proc publishOrigin(session: Session) =
  discard session.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue =
    if args.len == 1 and args[0].kind == skString:
      text("Hello, " & args[0].data)
    else:
      raise newException(SessionError, "origin expects one string argument"))

proc acceptSession(node: OnionNode; seed: char; origin = false): Session =
  let started = getMonoTime()
  if traceEnabled():
    echo "[TRACE] ", node.name, " accept wait fd=", int(node.listener.socketHandle()),
      " port=", $node.listener.localPort()
  let transport = node.listener.accept()
  if traceEnabled():
    echo "[TRACE] ", node.name, " accept done fd=", int(transport.socketHandle()),
      " elapsedMs=", (getMonoTime() - started).inMilliseconds
  result = newSession(transport, repeat(seed, 32), node.peer.peerUri())
  result.gifts = node.gifts
  result.ownsGifts = false
  node.attachTrace(result)
  if origin: result.publishOrigin()
  node.accepted.add(result)

proc acceptPending(node: OnionNode) =
  let transport = node.listener.acceptIfReady()
  if transport.isNil: return
  if traceEnabled():
    echo "[TRACE] ", node.name, " accept-ready fd=", int(transport.socketHandle())
  let seed = char(ord('a') + node.accepted.len mod 26)
  let session = newSession(transport, repeat(seed, 32), node.peer.peerUri())
  session.gifts = node.gifts
  session.ownsGifts = false
  node.attachTrace(session)
  session.publishOrigin()
  node.accepted.add(session)

proc connectTo(node: OnionNode; seed: char; origin = false): tuple[client, server: Session] =
  let layer = newOnionNetlayer()
  let started = getMonoTime()
  if traceEnabled():
    echo "[TRACE] dial -> ", node.name, " listenerFd=", int(node.listener.socketHandle()),
      " port=", $node.listener.localPort()
  let clientTransport = layer.dial(node.peer)
  if traceEnabled():
    echo "[TRACE] dial <- ", node.name, " clientFd=", int(clientTransport.socketHandle()),
      " elapsedMs=", (getMonoTime() - started).inMilliseconds
  let client = newSession(clientTransport, repeat(seed, 32), node.peer.peerUri())
  node.attachTrace(client)
  client.remotePeer = node.peer
  let server = node.acceptSession(char(ord(seed) + 10), origin)
  (client, server)

proc installReceiver(node: OnionNode; server: Session): CapabilityRef =
  result = server.publishActor("register", proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    if args.len != 2 or args[0].kind != skSymbol or args[0].data != "register" or
        args[1].kind != skRecord:
      raise newException(SessionError, "register expects one handoff descriptor")
    let answer = actor.deferAnswer()
    let receipt = node.handoffs.startHandoffReceiver(args[1], actor)
    node.receipts.add(receipt)
    receipt.promise.onSettle(proc(done: Promise) =
      if done.state == psFulfilled:
        try:
          let remapped = actor.rehomeCapability(receipt.session, done.value)
          actor.fulfillAnswer(answer, remapped)
        except CatchableError as error:
          actor.breakAnswer(answer, error.msg)
      else:
        actor.breakAnswer(answer, done.reason))
    list())

proc addUnique(sessions: var seq[Session]; session: Session) =
  for current in sessions:
    if current == session: return
  sessions.add(session)

proc traceStage(stage, source, destination, detail: string) =
  if traceEnabled():
    echo "[TRACE] handoff stage=", stage, " source=", source,
      " destination=", destination, " ", detail

proc giveId(value: SyrupValue): string =
  if value.kind == skRecord and value.fields.len == 2 and
      value.fields[0].kind == skRecord and value.fields[0].fields.len == 5 and
      value.fields[0].fields[4].kind == skBytes:
    let raw = value.fields[0].fields[4].data
    const digits = "0123456789abcdef"
    for ch in raw:
      result.add(digits[(ord(ch) shr 4) and 0x0f])
      result.add(digits[ord(ch) and 0x0f])
  else:
    result = "-"

proc pumpAll(nodes: openArray[OnionNode]; sessions: openArray[Session];
             managers: openArray[HandoffManager];
             timeoutMs: int; done: proc(): bool {.closure.}): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var receivedFrames = 0
  var lastSummary = getMonoTime()
  var active: seq[Session]
  while getMonoTime() < deadline:
    for node in nodes:
      node.acceptPending()
    active.setLen(0)
    for session in sessions: active.addUnique(session)
    for node in nodes:
      for session in node.accepted: active.addUnique(session)
    for session in active:
      if session.state != ssClosed:
        if session.pump(): inc receivedFrames
    for manager in managers:
      if not manager.isNil:
        discard manager.pumpWork(64)
    if done(): return true
    if traceEnabled() and (getMonoTime() - lastSummary).inMilliseconds >= 1000:
      var pending = 0
      var imports = 0
      var exports = 0
      var gifts = 0
      var completedHandoffs = 0
      var acceptedCount = 0
      for session in active:
        let stats = session.stats()
        pending += stats.pendingPromises
        imports += stats.importCount
        exports += stats.exportCount
        gifts += stats.depositedGifts + stats.pendingGiftWithdraws
      for manager in managers:
        if manager.isNil: continue
        for session in manager.trackedSessions():
          let stats = session.stats()
          pending += stats.pendingPromises
          imports += stats.importCount
          exports += stats.exportCount
          gifts += stats.depositedGifts + stats.pendingGiftWithdraws
      for node in nodes:
        acceptedCount += node.accepted.len
        for receipt in node.receipts:
          if receipt.promise.state != psPending: inc completedHandoffs
      echo "[TRACE] summary accepted=", acceptedCount,
        " active=", active.len, "receivedFrames=", receivedFrames,
        "completedHandoffs=", completedHandoffs, "pendingPromises=", pending,
        "imports=", imports, "exports=", exports, "gifts=", gifts
      lastSummary = getMonoTime()
    let remaining = (deadline - getMonoTime()).inMilliseconds.int
    if remaining <= 0: break
    var waited = false
    for session in active:
      if session.state != ssClosed and session.transport.waitReadable(min(remaining, 25)):
        waited = true
    for manager in managers:
      if not manager.isNil and manager.waitReadable(min(remaining, 25)):
        waited = true
    discard waited
  echo "[TIMEOUT] Onion pump deadline reached; accepted connections and session state:"
  for node in nodes:
    echo "[TIMEOUT] node=", node.name, " listenerFd=", int(node.listener.socketHandle()),
      " port=", $node.listener.localPort(), " accepted=", node.accepted.len,
      " receipts=", node.receipts.len, " pendingReceives=", node.handoffs.stats().pendingReceives,
      " receiverSessions=", node.handoffs.stats().receiverSessions
  for session in active:
    let stats = session.stats()
    echo "[TIMEOUT] session=", $session.state, " pending=", stats.pendingPromises,
      " imports=", stats.importCount, " exports=", stats.exportCount,
      " queued=", stats.queuedBytes, " transportClosed=", session.transport.isClosed()
  for manager in managers:
    if manager.isNil: continue
    for session in manager.trackedSessions():
      let stats = session.stats()
      echo "[TIMEOUT] manager-session=", $session.state,
        " pending=", stats.pendingPromises, " imports=", stats.importCount,
        " exports=", stats.exportCount, " answers=", stats.answerCount,
        " queued=", stats.queuedBytes, " transportClosed=", session.transport.isClosed()
  done()

proc closeNode(node: OnionNode) =
  node.handoffs.close("Onion E2E cleanup")
  for session in node.accepted:
    session.close("Onion E2E cleanup")
  node.gifts.clear()
  node.listener.close()

proc requireServices(count: int): seq[string] =
  for index in 0 ..< count:
    let service = serviceEnv(char(ord('A') + index))
    if service.len == 0:
      echo "  [SKIP] set NIM_OCAPN_ONION_", char(ord('A') + index),
        " for the ", count, "-node Onion handoff test"
      return @[]
    result.add(service)

proc runChain(services: seq[string]) =
  var nodes: seq[OnionNode]
  for index, service in services:
    nodes.add(newOnionNode($char(ord('A') + index), service,
      portEnv(char(ord('A') + index), 9045 + index)))
  defer:
    for node in nodes: node.closeNode()

  let first = nodes[1].connectTo('b', true)
  let aServer = first.server
  let bToA = first.client
  let sessions = @[aServer, bToA]
  discard pumpAll(nodes, sessions, @[], 10000,
    proc(): bool = aServer.state == ssOpen and bToA.state == ssOpen)
  if aServer.state != ssOpen or bToA.state != ssOpen:
    raise newException(SessionError, "Onion A-B handshake timeout")

  let fetched = bToA.fetch("origin")
  if not pumpAll(nodes, sessions, @[], 10000, proc(): bool = fetched.settled()):
    raise newException(SessionError, "Onion origin fetch timeout")
  if fetched.state != psFulfilled:
    raise newException(SessionError, "Onion origin fetch failed: " & fetched.reason)
  var sourceSession = bToA
  var capability = fetched.value.descriptor()
  var allSessions = sessions
  var managers: seq[HandoffManager]

  for index in 1 ..< nodes.high:
    let link = nodes[index + 1].connectTo(char(ord('b') + index), false)
    let downstream = link.client
    let downstreamServer = link.server
    allSessions.add(downstream)
    allSessions.add(downstreamServer)
    discard pumpAll(nodes, allSessions, managers, 10000,
      proc(): bool = downstream.state == ssOpen and downstreamServer.state == ssOpen)
    if downstream.state != ssOpen or downstreamServer.state != ssOpen:
      raise newException(SessionError, "Onion handoff link handshake timeout")
    let sourceName = $char(ord('A') + index)
    let destinationName = $char(ord('A') + index + 1)
    let registerTarget = installReceiver(nodes[index + 1], downstreamServer)
    traceStage("give", sourceName, destinationName, "creating signed handoff-give")
    let give = nodes[index].handoffs.handoffArgument(sourceSession, capability, downstream)
    traceStage("deposit", sourceName, destinationName, "gift=" & giveId(give))
    let register = downstream.call(registerTarget, "register", [give])
    traceStage("withdraw", sourceName, destinationName, "waiting for handoff-receive")
    managers.add(nodes[index + 1].handoffs)
    let current = nodes[index + 1]
    if not pumpAll(nodes, allSessions, managers, 20000,
        proc(): bool = register.settled() and current.receipts.len > 0 and
          current.receipts[^1].promise.settled()):
      raise newException(SessionError, "Onion handoff timeout at node " & $index)
    let receipt = current.receipts[^1]
    if receipt.promise.state != psFulfilled:
      raise newException(SessionError, "Onion handoff failed: " & receipt.promise.reason)
    sourceSession = receipt.session
    capability = receipt.promise.value.descriptor()
    traceStage("complete", sourceName, destinationName,
      "gift=" & giveId(give) & " pendingPromises=" & $receipt.session.stats().pendingPromises)
    allSessions.add(sourceSession)

  let answer = sourceSession.call(capability, "greet", [text("world")])
  if not pumpAll(nodes, allSessions, managers, 20000, proc(): bool = answer.settled()):
    raise newException(SessionError, "Onion final call timeout")
  if answer.state != psFulfilled or answer.value.isNil or answer.value.data != "Hello, world":
    raise newException(SessionError, "unexpected Onion handoff result")
  check nodes[0].accepted.len >= services.len - 1
  check nodes[^1].handoffs.stats().pendingReceives == 0

proc runConcurrent(services: seq[string]) =
  var nodes: seq[OnionNode]
  for index, service in services:
    nodes.add(newOnionNode($char(ord('A') + index), service,
      portEnv(char(ord('A') + index), 9045 + index)))
  defer:
    for node in nodes: node.closeNode()

  let first = nodes[1].connectTo('b', true)
  let aServer = first.server
  let bToA = first.client
  var sessions = @[aServer, bToA]
  discard pumpAll(nodes, sessions, @[], 10000,
    proc(): bool = aServer.state == ssOpen and bToA.state == ssOpen)
  let fetched = bToA.fetch("origin")
  if not pumpAll(nodes, sessions, @[], 10000, proc(): bool = fetched.settled()):
    raise newException(SessionError, "concurrent Onion fetch timeout")
  if fetched.state != psFulfilled:
    raise newException(SessionError, "concurrent Onion fetch failed")
  let capability = fetched.value.descriptor()

  let cLink = nodes[2].connectTo('c', false)
  let dLink = nodes[3].connectTo('d', false)
  sessions.add(cLink.client)
  sessions.add(cLink.server)
  sessions.add(dLink.client)
  sessions.add(dLink.server)
  discard pumpAll(nodes, sessions, @[], 10000,
    proc(): bool = cLink.client.state == ssOpen and cLink.server.state == ssOpen and
      dLink.client.state == ssOpen and dLink.server.state == ssOpen)
  let cRegister = installReceiver(nodes[2], cLink.server)
  let dRegister = installReceiver(nodes[3], dLink.server)
  traceStage("give", "B", "C", "creating concurrent signed handoff-give")
  let giveC = nodes[1].handoffs.handoffArgument(bToA, capability, cLink.client)
  traceStage("give", "B", "D", "creating concurrent signed handoff-give")
  let giveD = nodes[1].handoffs.handoffArgument(bToA, capability, dLink.client)
  let registerC = cLink.client.call(cRegister, "register", [giveC])
  let registerD = dLink.client.call(dRegister, "register", [giveD])
  traceStage("withdraw", "B", "C", "gift=" & giveId(giveC))
  traceStage("withdraw", "B", "D", "gift=" & giveId(giveD))
  let managers = @[nodes[2].handoffs, nodes[3].handoffs]
  if not pumpAll(nodes, sessions, managers, 30000,
      proc(): bool = registerC.settled() and registerD.settled() and
        nodes[2].receipts.len == 1 and nodes[3].receipts.len == 1 and
        nodes[2].receipts[0].promise.settled() and nodes[3].receipts[0].promise.settled()):
    raise newException(SessionError, "concurrent Onion handoff timeout")
  let cReceipt = nodes[2].receipts[0]
  let dReceipt = nodes[3].receipts[0]
  check cReceipt.promise.state == psFulfilled
  check dReceipt.promise.state == psFulfilled
  check cReceipt.session.localPublicKey != dReceipt.session.localPublicKey
  let cAnswer = cReceipt.session.call(cReceipt.promise.value.descriptor(), "greet", [text("world")])
  let dAnswer = dReceipt.session.call(dReceipt.promise.value.descriptor(), "greet", [text("world")])
  if not pumpAll(nodes, sessions, managers, 20000,
      proc(): bool = cAnswer.settled() and dAnswer.settled()):
    raise newException(SessionError, "concurrent Onion calls timeout")
  check cAnswer.state == psFulfilled
  check dAnswer.state == psFulfilled
  check cAnswer.value.data == "Hello, world"
  check dAnswer.value.data == "Hello, world"
  check aServer.stats().depositedGifts == 0
  check nodes[2].handoffs.stats().pendingReceives == 0
  check nodes[3].handoffs.stats().pendingReceives == 0

suite "OCapN Onion handoff integration":
  test "three-node Onion handoff A to B to C":
    let services = requireServices(3)
    if services.len == 0:
      skip()
    else:
      runChain(services)

  test "four-node Onion handoff A to B to C to D":
    let services = requireServices(4)
    if services.len == 0:
      skip()
    else:
      runChain(services)

  test "concurrent Onion handoff keeps receiver identities independent":
    let services = requireServices(4)
    if services.len == 0:
      skip()
    else:
      runConcurrent(services)
