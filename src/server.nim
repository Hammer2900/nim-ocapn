import std/[net, selectors, sequtils, tables, times, monotimes]
import ./[gifts, identity, session, transport]

type
  TcpManagerStats* = object
    activeSessions*: int
    pendingPromises*: int
    imports*: int
    exports*: int
    listenerLifecycles*: int
    queuedBytes*: int
    forwardedPromises*: int
    forwardedProxies*: int
    depositedGifts*: int
    pendingGiftWithdraws*: int
  SessionHandler* = proc(session: Session) {.closure.}
  SessionSlot = ref object
    session: Session
    transport: TcpTransport
    openNotified: bool
    acceptedAt: float
    registered: bool
  TcpSessionManager* = ref object
    listener*: TcpListener
    selector: Selector[SessionSlot]
    slots: Table[int, SessionSlot]
    seedPrefix: string
    hostPort: string
    onOpen: SessionHandler
    handshakeTimeoutMs: int
    gifts*: GiftTable
    forwardedRegistry*: ForwardedPromiseRegistry
    traceSink*: TraceSink
    traceNodeId*: string
    limits: SessionLimits
    verificationPolicy*: PeerVerificationPolicy
    identity*: NodeIdentity
    sessionIdentityMode*: SessionIdentityMode
    maxActiveSessions*: int
    diagnosticSink*: DiagnosticSink
    diagnosticNodeId*: string
    closed: bool

proc newTcpSessionManager*(host: string; port: Port; seedPrefix, hostPort: string;
                           onOpen: SessionHandler = nil;
                           handshakeTimeoutMs = 30000;
                           limits = defaultSessionLimits();
                           verificationPolicy = testingOnlyPeerPolicy;
                           identity: NodeIdentity = nil;
                           maxActiveSessions = 256;
                           diagnosticSink: DiagnosticSink = nil;
                           sessionIdentityMode = simPerSession): TcpSessionManager =
  validateSessionLimits(limits)
  validatePolicy(verificationPolicy)
  if verificationPolicy.mode != pvmTestingOnly and identity.isNil:
    raise newException(IdentityError, "strict peer policy requires durable node identity")
  if sessionIdentityMode == simLegacyDurable and identity.isNil:
    raise newException(IdentityError, "legacy durable session identity requires node identity")
  if maxActiveSessions <= 0:
    raise newException(SessionError, "max active sessions must be positive")
  result = TcpSessionManager(listener: listenTcp(host, port),
    selector: newSelector[SessionSlot](), slots: initTable[int, SessionSlot](),
    seedPrefix: seedPrefix, hostPort: hostPort, onOpen: onOpen,
    handshakeTimeoutMs: handshakeTimeoutMs, gifts: newGiftTable(),
    forwardedRegistry: ForwardedPromiseRegistry(
      origins: initTable[ForwardedPromiseKey, ForwardedPromiseOrigin](),
      retired: initTable[ForwardedPromiseKey, string]()),
    limits: limits, verificationPolicy: verificationPolicy, identity: identity,
    sessionIdentityMode: sessionIdentityMode,
    maxActiveSessions: maxActiveSessions, diagnosticSink: diagnosticSink)
  if port == Port(0):
    result.hostPort = host & ":" & $result.listener.localPort()
  result.listener.setNonBlocking()
  result.selector.registerHandle(result.listener.socketHandle(), {Read}, nil)

proc setTraceSink*(manager: TcpSessionManager; nodeId: string; sink: TraceSink) =
  manager.traceNodeId = nodeId
  manager.traceSink = sink
  for slot in manager.slots.values:
    slot.session.setTraceSink(nodeId, sink)

proc setDiagnosticSink*(manager: TcpSessionManager; nodeId: string; sink: DiagnosticSink) =
  manager.diagnosticNodeId = nodeId
  manager.diagnosticSink = sink
  for slot in manager.slots.values:
    slot.session.setDiagnosticSink(nodeId, sink)

proc reportLimit(manager: TcpSessionManager) =
  if not manager.diagnosticSink.isNil:
    manager.diagnosticSink(DiagnosticEvent(
      timestamp: getMonoTime().ticks.float / 1_000_000_000.0,
      nodeId: manager.diagnosticNodeId, sessionId: "-",
      kind: dekResourceLimit, errorCategory: decResource,
      detail: "active session limit exceeded"))

proc removeSlot(manager: TcpSessionManager; fd: int) =
  let slot = manager.slots.getOrDefault(fd)
  if slot.isNil: return
  if slot.registered:
    manager.selector.unregister(fd)
    slot.registered = false
  slot.session.close("TCP session removed")
  slot.transport.close()
  manager.slots.del(fd)

proc acceptReady(manager: TcpSessionManager) =
  try:
    if manager.slots.len >= manager.maxActiveSessions:
      let rejected = manager.listener.acceptRawTcpSocket()
      rejected.close()
      manager.reportLimit()
      return
    let transport = manager.listener.acceptTcp()
    transport.setNonBlocking()
    var seed = ""
    if manager.sessionIdentityMode == simLegacyDurable:
      seed = manager.identity.sessionSeed()
    let session = newGlowcapSession(transport, seed, manager.hostPort, manager.limits,
      manager.verificationPolicy)
    session.forwardedRegistry = manager.forwardedRegistry
    session.setTraceSink(manager.traceNodeId, manager.traceSink)
    session.setDiagnosticSink(manager.diagnosticNodeId, manager.diagnosticSink)
    session.gifts = manager.gifts
    session.ownsGifts = false
    let slot = SessionSlot(session: session, transport: transport, openNotified: false,
      acceptedAt: epochTime(), registered: true)
    let fd = int(transport.socketHandle())
    manager.slots[fd] = slot
    manager.selector.registerHandle(transport.socketHandle(), {Read}, slot)
  except CatchableError:
    discard

proc poll*(manager: TcpSessionManager; timeoutMs = 1000; maxWork = 64): int =
  if manager.closed: return 0
  if maxWork <= 0: return 0
  var handled = 0
  for ready in manager.selector.select(timeoutMs):
    if handled >= maxWork: break
    if ready.fd == int(manager.listener.socketHandle()):
      manager.acceptReady()
      inc handled
      continue
    if not manager.slots.hasKey(ready.fd):
      continue
    let slot = manager.slots[ready.fd]
    if slot.registered:
      manager.selector.unregister(ready.fd)
      slot.registered = false
    try:
      if not slot.openNotified:
        slot.openNotified = true
        if not manager.onOpen.isNil: manager.onOpen(slot.session)
      discard slot.session.pump()
      if slot.session.state == ssClosed:
        manager.removeSlot(ready.fd)
      else:
        let events = if slot.transport.wantsWrite(): {Read, Write} else: {Read}
        manager.selector.registerHandle(slot.transport.socketHandle(), events, slot)
        slot.registered = true
      inc handled
    except CatchableError:
      manager.removeSlot(ready.fd)
  if manager.handshakeTimeoutMs >= 0:
    let now = epochTime()
    var expired: seq[int]
    for fd, slot in manager.slots:
      if slot.session.state == ssNegotiating and
          (now - slot.acceptedAt) * 1000.0 >= manager.handshakeTimeoutMs.float:
        expired.add(fd)
    for fd in expired:
      if handled >= maxWork: break
      manager.removeSlot(fd)
      inc handled
  handled

proc sessionCount*(manager: TcpSessionManager): int = manager.slots.len

proc stats*(manager: TcpSessionManager): TcpManagerStats =
  result.activeSessions = manager.slots.len
  for slot in manager.slots.values:
    let current = slot.session.stats()
    result.pendingPromises += current.pendingPromises
    result.imports += current.importCount
    result.exports += current.exportCount
    result.listenerLifecycles += current.listenerLifecycleCount
    result.queuedBytes += current.queuedBytes
    result.forwardedPromises += current.forwardedPromiseCount
    result.forwardedProxies += current.forwardedProxyCount
  let giftStats = manager.gifts.stats()
  result.depositedGifts = giftStats.deposited
  result.pendingGiftWithdraws = giftStats.pendingWithdraws

proc hasSession*(manager: TcpSessionManager; session: Session): bool =
  for slot in manager.slots.values:
    if slot.session == session:
      return true
  false

proc listenPort*(manager: TcpSessionManager): Port = manager.listener.localPort()

proc close*(manager: TcpSessionManager) =
  if manager.isNil or manager.closed: return
  manager.closed = true
  for fd in manager.slots.keys.toSeq:
    manager.removeSlot(fd)
  manager.selector.close()
  manager.listener.close()
  manager.gifts.clear()
  manager.forwardedRegistry.origins.clear()
  manager.forwardedRegistry.retired.clear()
