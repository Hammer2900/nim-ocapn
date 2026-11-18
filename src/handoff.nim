import std/[net, strutils, sysrand, tables]
import ./[locators, messages, promises, references, session, syrup, transport]

type
  HandoffLimits* = object
    maxPending*: int
  HandoffStats* = object
    pendingEnliven*: int
    pendingReceives*: int
    outboundSessions*: int
    receiverSessions*: int
  HandoffReceipt* = ref object
    promise*: Promise
    session*: Session
  PendingEnliven = ref object
    source: Session
    answer: AnswerContext
    sturdy: SturdyRef
    outbound: Session
    fetchStarted: bool
    completed: bool
  PendingReceive = ref object
    session: Session
    signer: Session
    signedGive: SyrupValue
    sent: bool
    withdrawal: Promise
    result: Promise
  HandoffManager* = ref object
    outboundSessions*: seq[Session]
    pendingEnliven: seq[PendingEnliven]
    receiverSessions: seq[Session]
    pendingReceives: seq[PendingReceive]
    nextHandoffCounts: Table[string, int64]
    closed: bool
    limits: HandoffLimits
    sessionLimits: SessionLimits
    outboundCursor: int
    receiverCursor: int

proc newHandoffManager*(limits = HandoffLimits(maxPending: 256);
                        sessionLimits = defaultSessionLimits()): HandoffManager =
  if limits.maxPending < 0:
    raise newException(SessionError, "handoff limits must not be negative")
  HandoffManager(outboundSessions: @[], pendingEnliven: @[],
    receiverSessions: @[], pendingReceives: @[], limits: limits,
    sessionLimits: sessionLimits,
    nextHandoffCounts: initTable[string, int64]())

proc ensureOpen(manager: HandoffManager) =
  if manager.closed:
    raise newException(SessionError, "handoff manager is closed")

proc newGiftId(): string =
  let random = urandom(32)
  result = newString(random.len)
  for index, value in random:
    result[index] = char(value)

proc finishEnliven(manager: HandoffManager; item: PendingEnliven; promise: Promise) =
  item.completed = true
  if promise.state == psBroken:
    item.source.breakAnswer(item.answer, promise.reason)
    return
  try:
    let capability = promise.value.descriptor()
    let imported = importObject(capability.position).descriptor()
    let giftId = newGiftId()
    let give = handoffGive(glowcapPublicKey(item.source.remotePublicKey),
      item.sturdy.peer.peerSyrup(), item.outbound.sessionId(),
      item.outbound.localSideId(), giftId)
    let signedGive = signatureEnvelope(give, item.outbound.signLocal(give.encoded()))
    item.outbound.send(deliverV1Callback(exportRef(0).targetDescriptor(),
      [symbol("deposit-gift"), bytes(giftId), imported]))
    item.source.fulfillAnswer(item.answer, signedGive)
  except CatchableError as error:
    item.source.breakAnswer(item.answer, error.msg)

proc startHandoffReceiver*(manager: HandoffManager; signedGive: SyrupValue;
                           signer: Session): HandoffReceipt =
  manager.ensureOpen()
  if signedGive.kind != skRecord or signedGive.label.kind != skSymbol or
      signedGive.label.data != "desc:sig-envelope" or signedGive.fields.len != 2 or
      not validHandoffGive(signedGive.fields[0]):
    raise newException(SessionError, "invalid handoff give")
  if signer.isNil or extractGlowcapPublicKey(signedGive.fields[0].fields[0]) !=
      signer.localPublicKey:
    raise newException(SessionError, "handoff receiver identity mismatch")
  let peer = signedGive.fields[0].fields[1].peerLocator()
  if peer.transport notin ["tcp-testing-only", "tcp"] or
      not peer.hints.hasKey("host") or not peer.hints.hasKey("port"):
    raise newException(SessionError, "unsupported handoff exporter transport")
  let host = peer.hints["host"]
  let port = Port(parseInt(peer.hints["port"]))
  let tcp = connectTcp(host, port)
  tcp.setNonBlocking()
  let session = newGlowcapSession(tcp, newGiftId(), host & ":" & $port,
    manager.sessionLimits)
  session.remoteLocation = peer.peerSyrup().encoded()
  session.remotePeer = peer
  if manager.pendingReceives.len >= manager.limits.maxPending:
    session.close("pending handoff limit exceeded")
    raise newException(SessionError, "pending handoff limit exceeded")
  manager.receiverSessions.add(session)
  let completion = newPromise()
  result = HandoffReceipt(promise: completion, session: session)
  manager.pendingReceives.add(PendingReceive(session: session, signer: signer,
    signedGive: signedGive, result: completion))

proc startSturdyRefSession*(manager: HandoffManager; sturdy: SturdyRef;
                            source: Session; answer: AnswerContext;
                            existing: openArray[Session] = []): SyrupValue =
  manager.ensureOpen()
  if sturdy.peer.transport notin ["tcp-testing-only", "tcp"] or
      not sturdy.peer.hints.hasKey("host") or not sturdy.peer.hints.hasKey("port"):
    raise newException(SessionError, "unsupported sturdyref transport")
  let host = sturdy.peer.hints["host"]
  let port = Port(parseInt(sturdy.peer.hints["port"]))
  let expectedLocation = sturdy.peer.peerSyrup().encoded()
  var session: Session
  for candidate in existing:
    if candidate != source and candidate.state == ssOpen and
        candidate.remoteLocation == expectedLocation:
      session = candidate
      break
  if session.isNil:
    let tcp = connectTcp(host, port)
    tcp.setNonBlocking()
    session = newGlowcapSession(tcp, newGiftId(), host & ":" & $port,
      manager.sessionLimits)
    session.remoteLocation = expectedLocation
    session.remotePeer = sturdy.peer
    manager.outboundSessions.add(session)
  if not answer.resolver.isNil:
    if manager.pendingEnliven.len >= manager.limits.maxPending:
      raise newException(SessionError, "pending handoff limit exceeded")
    manager.pendingEnliven.add(PendingEnliven(source: source, answer: answer,
      sturdy: sturdy, outbound: session))
  list()

proc handoffArgument*(manager: HandoffManager; source: Session;
                      capability: CapabilityRef; receiver: Session): SyrupValue =
  manager.ensureOpen()
  if source.state != ssOpen or receiver.state != ssOpen or
      capability.kind notin {rkImportObject, rkImportPromise} or source.remoteLocation.len == 0 or
      receiver.remotePublicKey.len != 32:
    raise newException(SessionError, "capability cannot be handed off")
  let exporter = if source.remotePeer.transport.len > 0:
      source.remotePeer
    else:
      decoded(source.remoteLocation).peerLocator()
  let giftId = newGiftId()
  let give = handoffGive(glowcapPublicKey(receiver.remotePublicKey),
    exporter.peerSyrup(), source.sessionId(), source.localSideId(), giftId)
  source.send(deliverV1Callback(exportRef(0).targetDescriptor(),
    [symbol("deposit-gift"), bytes(giftId), capability.descriptor()]))
  signatureEnvelope(give, source.signLocal(give.encoded()))

proc cleanup(manager: HandoffManager) =
  var pendingEnliven: seq[PendingEnliven]
  for item in manager.pendingEnliven:
    if not item.completed and item.outbound.state == ssClosed:
      item.completed = true
      if item.source.state != ssClosed:
        item.source.breakAnswer(item.answer, "handoff session disconnected")
    if not item.completed and item.source.state != ssClosed and
        item.outbound.state != ssClosed:
      pendingEnliven.add(item)
  manager.pendingEnliven = pendingEnliven

  var pendingReceives: seq[PendingReceive]
  for item in manager.pendingReceives:
    if item.session.state == ssClosed or item.signer.isNil or item.signer.state == ssClosed:
      if not item.result.isNil and item.result.state == psPending:
        item.result.breakPromise("handoff session disconnected")
    elif not item.sent or item.withdrawal.isNil or
        item.withdrawal.state == psPending:
      pendingReceives.add(item)
  manager.pendingReceives = pendingReceives

  var outboundSessions: seq[Session]
  for session in manager.outboundSessions:
    if session.state != ssClosed:
      outboundSessions.add(session)
  manager.outboundSessions = outboundSessions

  var receiverSessions: seq[Session]
  for session in manager.receiverSessions:
    if session.state != ssClosed:
      receiverSessions.add(session)
  manager.receiverSessions = receiverSessions

proc close*(manager: HandoffManager; reason = "handoff manager closed") =
  if manager.isNil or manager.closed:
    return
  manager.closed = true
  for item in manager.pendingEnliven:
    if not item.completed:
      item.source.breakAnswer(item.answer, reason)
  for session in manager.outboundSessions:
    session.close(reason)
  for session in manager.receiverSessions:
    session.close(reason)
  for item in manager.pendingReceives:
    if not item.result.isNil and item.result.state == psPending:
      item.result.breakPromise(reason)
  manager.pendingEnliven.setLen(0)
  manager.pendingReceives.setLen(0)
  manager.outboundSessions.setLen(0)
  manager.receiverSessions.setLen(0)
  manager.nextHandoffCounts.clear()

proc stats*(manager: HandoffManager): HandoffStats =
  result.pendingEnliven = manager.pendingEnliven.len
  result.pendingReceives = manager.pendingReceives.len
  result.outboundSessions = manager.outboundSessions.len
  result.receiverSessions = manager.receiverSessions.len

proc pumpWork*(manager: HandoffManager; maxWork = 64): int =
  manager.ensureOpen()
  if maxWork <= 0: return 0
  var work = 0
  var inspected = 0
  while inspected < manager.outboundSessions.len and work < maxWork:
    let index = (manager.outboundCursor + inspected) mod manager.outboundSessions.len
    let session = manager.outboundSessions[index]
    if session.state != ssClosed:
      try: discard session.pump()
      except CatchableError: discard
      inc work
    inc inspected
  if manager.outboundSessions.len > 0:
    manager.outboundCursor = (manager.outboundCursor + inspected) mod manager.outboundSessions.len
  for index in 0 ..< manager.pendingEnliven.len:
    if work >= maxWork: break
    let item = manager.pendingEnliven[index]
    if item.completed or item.fetchStarted or item.outbound.state != ssOpen:
      continue
    item.fetchStarted = true
    let promise = item.outbound.fetch(item.sturdy.swissNum)
    promise.onSettle(proc(settled: Promise) = manager.finishEnliven(item, settled))
    inc work
  inspected = 0
  while inspected < manager.receiverSessions.len and work < maxWork:
    let index = (manager.receiverCursor + inspected) mod manager.receiverSessions.len
    let session = manager.receiverSessions[index]
    if session.state != ssClosed:
      try: discard session.pump()
      except CatchableError: discard
      inc work
    inc inspected
  if manager.receiverSessions.len > 0:
    manager.receiverCursor = (manager.receiverCursor + inspected) mod manager.receiverSessions.len
  for index in 0 ..< manager.pendingReceives.len:
    if work >= maxWork: break
    let item = manager.pendingReceives[index]
    if item.sent:
      continue
    if item.session.state != ssOpen or item.signer.state == ssClosed:
      continue
    let sessionKey = item.session.sessionId()
    let handoffCount = manager.nextHandoffCounts.getOrDefault(sessionKey, 0)
    manager.nextHandoffCounts[sessionKey] = handoffCount + 1
    let receive = handoffReceive(item.session.sessionId(), item.session.localSideId(),
      handoffCount, item.signedGive)
    let signedReceive = signatureEnvelope(receive,
      item.signer.signLocal(receive.encoded()))
    item.withdrawal = item.session.call(exportRef(0), "withdraw-gift", [signedReceive])
    let completion = item.result
    item.withdrawal.onSettle(proc(settled: Promise) =
      if settled.state == psBroken:
        completion.breakPromise(settled.reason)
      else:
        completion.fulfill(settled.value))
    item.sent = true
    inc work
  manager.cleanup()
  result = work

proc pump*(manager: HandoffManager; maxWork = 64) =
  discard manager.pumpWork(maxWork)
