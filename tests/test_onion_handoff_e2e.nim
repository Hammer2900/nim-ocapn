import std/[monotimes, net, os, strutils, unittest, times]
import ../src/[crypto, gifts, handoff, identity, locators, onion, promises, references, session, syrup, transport]
import ../src/api as api
import ../src/session as sessionApi

type
  OnionNode = ref object
    name: string
    peer: PeerLocator
    listener: OnionListener
    handoffs: HandoffManager
    gifts: GiftTable
    accepted: seq[Session]
    receipts: seq[HandoffReceipt]
    identity: NodeIdentity
    protected: bool
    trustedClientKeys: seq[string]

proc serviceEnv(index: char): string =
  getEnv("NIM_OCAPN_ONION_" & $index)

proc portEnv(index: char; fallback: int): Port =
  let value = getEnv("NIM_OCAPN_ONION_" & $index & "_PORT")
  if value.len == 0: return Port(fallback)
  Port(parseInt(value))

proc traceEnabled(): bool = getEnv("NIM_OCAPN_ONION_TRACE") == "1"

proc protectedOnly(): bool = getEnv("NIM_OCAPN_ONION_PROTECTED_ONLY") == "1"

proc torConfig(authenticateServer = false): OnionNetlayerConfig =
  result = defaultOnionNetlayerConfig()
  result.authenticateServer = authenticateServer
  if getEnv("NIM_OCAPN_TOR_SOCKS").len > 0:
    result.socksHost = getEnv("NIM_OCAPN_TOR_SOCKS")
  if getEnv("NIM_OCAPN_TOR_SOCKS_PORT").len > 0:
    result.socksPort = Port(parseInt(getEnv("NIM_OCAPN_TOR_SOCKS_PORT")))
  if getEnv("NIM_OCAPN_ONION_SERVICE_PORT").len > 0:
    result.servicePort = Port(parseInt(getEnv("NIM_OCAPN_ONION_SERVICE_PORT")))

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
  let layer = newOnionNetlayer(torConfig())
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

proc publishProtected(session: Session) =
  discard session.publishProtectedObject("protected", proc(args: seq[SyrupValue]): SyrupValue =
    if args.len == 1 and args[0].kind == skString:
      text("Protected hello, " & args[0].data)
    elif args.len == 2 and args[0].kind == skSymbol and args[0].data == "greet" and
        args[1].kind == skString:
      text("Protected hello, " & args[1].data)
    else:
      raise newException(SessionError, "protected expects one string argument"))

proc newProtectedOnionNode(name, service: string; localPort: Port;
                           identity: NodeIdentity; trustedClientKeys: seq[string] = @[]): OnionNode =
  let layer = newOnionNetlayer(torConfig())
  let peer = newPeerLocator("onion", service)
  result = OnionNode(name: name, peer: peer, listener: layer.listen(localPort = localPort,
    advertised = peer), handoffs: newHandoffManager(), gifts: newGiftTable(),
    accepted: @[], receipts: @[], identity: identity, protected: true,
    trustedClientKeys: trustedClientKeys)
  result.handoffs.setTraceSink(name, traceEvent)

proc protectedAuthSession(node: OnionNode; session: Session) =
  if not node.protected or node.trustedClientKeys.len == 0: return
  discard session.enableClientAuthentication(node.trustedClientKeys,
    node.peer.designator, onAuthenticated = proc(authorized: Session) =
      authorized.publishProtected())

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
  node.protectedAuthSession(result)
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
  node.protectedAuthSession(session)
  node.accepted.add(session)

proc connectTo(node: OnionNode; seed: char; origin = false;
              authenticated = false): tuple[client, server: Session] =
  let layer = newOnionNetlayer(torConfig(authenticated))
  let started = getMonoTime()
  if traceEnabled():
    echo "[TRACE] dial -> ", node.name, " listenerFd=", int(node.listener.socketHandle()),
      " port=", $node.listener.localPort()
  let clientTransport = layer.dial(node.peer)
  if traceEnabled():
    echo "[TRACE] dial <- ", node.name, " clientFd=", int(clientTransport.socketHandle()),
      " elapsedMs=", (getMonoTime() - started).inMilliseconds
  let clientPolicy = if authenticated: authenticatedOnionPolicy(node.peer)
                     else: testingOnlyPeerPolicy
  let client = newSession(clientTransport, repeat(seed, 32), node.peer.peerUri(),
    verificationPolicy = clientPolicy)
  client.setExpectedPeer(node.peer, authenticated)
  node.attachTrace(client)
  client.remotePeer = node.peer
  let server = node.acceptSession(char(ord(seed) + 10), origin)
  (client, server)

proc connectNodes(source, target: OnionNode; seed: char; origin = false;
                  authenticated = false): tuple[client, server: Session] =
  let layer = newOnionNetlayer(torConfig(authenticated))
  let started = getMonoTime()
  if traceEnabled():
    echo "[TRACE] dial ", source.name, " -> ", target.name,
      " listenerFd=", int(target.listener.socketHandle()),
      " port=", $target.listener.localPort()
  let clientTransport = layer.dial(target.peer)
  if traceEnabled():
    echo "[TRACE] dial ", source.name, " <- ", target.name,
      " clientFd=", int(clientTransport.socketHandle()),
      " elapsedMs=", (getMonoTime() - started).inMilliseconds
  let clientPolicy = if authenticated: authenticatedOnionPolicy(target.peer)
                     else: testingOnlyPeerPolicy
  let client = newSession(clientTransport, repeat(seed, 32), target.peer.peerUri(),
    verificationPolicy = clientPolicy)
  client.setExpectedPeer(target.peer, authenticated)
  source.attachTrace(client)
  client.remotePeer = target.peer
  let server = target.acceptSession(char(ord(seed) + 10), origin)
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

  let fetched = sessionApi.fetch(bToA, "origin")
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
    let register = sessionApi.call(downstream, registerTarget, "register", [give])
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

  let answer = sessionApi.call(sourceSession, capability, "greet", [text("world")])
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
  let fetched = sessionApi.fetch(bToA, "origin")
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
  let registerC = sessionApi.call(cLink.client, cRegister, "register", [giveC])
  let registerD = sessionApi.call(dLink.client, dRegister, "register", [giveD])
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
  let cAnswer = sessionApi.call(cReceipt.session, cReceipt.promise.value.descriptor(), "greet", [text("world")])
  let dAnswer = sessionApi.call(dReceipt.session, dReceipt.promise.value.descriptor(), "greet", [text("world")])
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

proc installProtectedReceiver(node: OnionNode; server: Session;
                             withdrawn: ref bool): CapabilityRef =
  result = server.publishActor("register-protected", proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    if args.len != 2 or args[0].kind != skSymbol or args[0].data != "register":
      raise newException(SessionError, "protected register expects one gift")
    let answer = actor.deferAnswer()
    let receipt = node.handoffs.startHandoffReceiver(args[1], actor)
    node.receipts.add(receipt)
    receipt.promise.onSettle(proc(done: Promise) =
      if done.state == psBroken:
        actor.breakAnswer(answer, done.reason)
      else:
        withdrawn[] = true
        actor.fulfillAnswer(answer, text("protected withdrawal complete")))
    list())

proc configureProtectedAuxiliary(node, owner: OnionNode) =
  node.handoffs = newHandoffManager(identity = node.identity,
    verificationPolicy = authenticatedOnionPolicy(owner.peer))
  node.handoffs.setTraceSink(node.name, traceEvent)
  node.handoffs.setHandoffSessionOpener(proc(peer: PeerLocator): Session =
    let layer = newOnionNetlayer(torConfig(true))
    let transport = layer.dial(peer)
    let session = newSession(transport, "", peer.peerUri(),
      verificationPolicy = authenticatedOnionPolicy(peer))
    session.remotePeer = peer
    session.setExpectedPeer(peer, true)
    session)
  node.handoffs.setHandoffSessionPreparer(proc(session: Session): bool =
    for peerSession in owner.accepted:
      if peerSession.state == ssOpen and
          peerSession.remotePublicKey == session.localPublicKey:
        try:
          let authenticated = api.authenticateClient(session, node.identity,
            pumpPeer = peerSession, maxPumps = 10_000)
          if traceEnabled(): echo "[TRACE] protected auxiliary authenticated=", authenticated
          return authenticated
        except CatchableError as error:
          if traceEnabled(): echo "[TRACE] protected auxiliary auth error: ", error.msg
          return false
    if traceEnabled(): echo "[TRACE] protected auxiliary peer session not ready"
    false)

proc runProtectedChain(services: seq[string]) =
  if services.len < 3: return
  let aIdentity = newEphemeralIdentity(repeat('a', 32))
  let bIdentity = newEphemeralIdentity(repeat('b', 32))
  let cIdentity = newEphemeralIdentity(repeat('c', 32))
  let trusted = @[bIdentity.publicKey, cIdentity.publicKey]
  var nodes: seq[OnionNode]
  nodes.add(newProtectedOnionNode("A", services[0], portEnv('A', 9145), aIdentity, trusted))
  nodes.add(newProtectedOnionNode("B", services[1], portEnv('B', 9146), bIdentity))
  nodes.add(newProtectedOnionNode("C", services[2], portEnv('C', 9147), cIdentity))
  configureProtectedAuxiliary(nodes[2], nodes[0])
  defer:
    for node in nodes: node.closeNode()

  let readinessFile = getEnv("NIM_OCAPN_ONION_READINESS_FILE")
  let readinessDone = getEnv("NIM_OCAPN_ONION_READINESS_DONE")
  if readinessFile.len > 0:
    writeFile(readinessFile, "listeners-ready\n")
    let deadline = getMonoTime() + initDuration(seconds = 60)
    while readinessDone.len > 0 and not fileExists(readinessDone) and
        getMonoTime() < deadline:
      sleep(50)
    if readinessDone.len > 0 and not fileExists(readinessDone):
      raise newException(SessionError, "Onion readiness probe deadline exceeded")

  let first = connectNodes(nodes[1], nodes[0], 'b', false, true)
  var sessions = @[first.client, first.server]
  if not pumpAll(nodes, sessions, @[], 30_000,
      proc(): bool = first.client.state == ssOpen and first.server.state == ssOpen):
    raise newException(SessionError, "protected Onion A-B handshake timeout")
  if not api.authenticateClient(first.client, bIdentity, pumpPeer = first.server):
    raise newException(SessionError, "protected Onion B authentication failed")
  let fetched = api.fetch(first.client, "protected")
  if not pumpAll(nodes, sessions, @[], 20_000, proc(): bool = fetched.settled()):
    raise newException(SessionError, "protected Onion fetch timeout")
  if fetched.state != psFulfilled:
    raise newException(SessionError, "protected Onion fetch rejected: " & fetched.reason)

  let link = connectNodes(nodes[1], nodes[2], 'c', false)
  sessions.add(link.client)
  sessions.add(link.server)
  if not pumpAll(nodes, sessions, @[], 30_000,
      proc(): bool = link.client.state == ssOpen and link.server.state == ssOpen):
    raise newException(SessionError, "protected Onion B-C handshake timeout")
  var withdrawn = new(bool)
  let register = installProtectedReceiver(nodes[2], link.server, withdrawn)
  let bHandoffs = newHandoffManager()
  let give = bHandoffs.handoffArgument(first.client, fetched.value.descriptor(), link.client)
  let registerCall = sessionApi.call(link.client, register, "register", [give])
  var managers = @[nodes[2].handoffs]
  if not pumpAll(nodes, sessions, managers, 30_000,
      proc(): bool = registerCall.settled() and withdrawn[]):
    raise newException(SessionError, "protected Onion withdrawal timeout")
  if registerCall.state != psFulfilled:
    raise newException(SessionError, "protected Onion register rejected: " & registerCall.reason)
  first.client.close("protected B disconnected")
  link.client.close("protected B disconnected")
  let protectedCall = sessionApi.call(nodes[2].receipts[^1].session,
    nodes[2].receipts[^1].promise.value.descriptor(), "greet", [text("world")])
  if not pumpAll(nodes, sessions, managers, 30_000,
      proc(): bool = protectedCall.settled()):
    raise newException(SessionError, "protected Onion invocation timeout after B disconnect")
  if protectedCall.state != psFulfilled or protectedCall.value.kind != skString or
      protectedCall.value.data != "Protected hello, world":
    raise newException(SessionError, "protected Onion invocation rejected: " &
      (if protectedCall.state == psBroken: protectedCall.reason else: "unexpected result"))
  nodes[2].receipts[^1].session.release(
    nodes[2].receipts[^1].promise.value.descriptor())
  check nodes[0].accepted.len >= 2
  check nodes[2].handoffs.stats().pendingReceives == 0
  echo "[PASS] protected Onion A/B/C handoff with independent client authentication"

suite "OCapN Onion handoff integration":
  test "three-node Onion handoff A to B to C":
    if not protectedOnly():
      let services = requireServices(3)
      if services.len == 0:
        skip()
      else:
        runChain(services)

  test "four-node Onion handoff A to B to C to D":
    if not protectedOnly():
      let services = requireServices(4)
      if services.len == 0:
        skip()
      else:
        runChain(services)

  test "concurrent Onion handoff keeps receiver identities independent":
    if not protectedOnly():
      let services = requireServices(4)
      if services.len == 0:
        skip()
      else:
        runConcurrent(services)

  test "protected Onion handoff authenticates C before withdrawal":
    let services = requireServices(3)
    if services.len == 0:
      skip()
    else:
      runProtectedChain(services)
