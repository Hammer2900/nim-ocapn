import std/[net, selectors, sequtils, tables, times]
import ./[gifts, session, transport]

type
  TcpManagerStats* = object
    activeSessions*: int
    pendingPromises*: int
    imports*: int
    exports*: int
    queuedBytes*: int
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
    nextSeed: int
    handshakeTimeoutMs: int
    gifts*: GiftTable
    limits: SessionLimits
    closed: bool

proc newTcpSessionManager*(host: string; port: Port; seedPrefix, hostPort: string;
                           onOpen: SessionHandler = nil;
                           handshakeTimeoutMs = 30000;
                           limits = defaultSessionLimits()): TcpSessionManager =
  validateSessionLimits(limits)
  result = TcpSessionManager(listener: listenTcp(host, port),
    selector: newSelector[SessionSlot](), slots: initTable[int, SessionSlot](),
    seedPrefix: seedPrefix, hostPort: hostPort, onOpen: onOpen, nextSeed: 0,
    handshakeTimeoutMs: handshakeTimeoutMs, gifts: newGiftTable(), limits: limits)
  result.listener.setNonBlocking()
  result.selector.registerHandle(result.listener.socketHandle(), {Read}, nil)

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
    let transport = manager.listener.acceptTcp()
    transport.setNonBlocking()
    var seed = manager.seedPrefix
    while seed.len < 32: seed.add('x')
    seed.setLen(32)
    seed[0] = char(ord('a') + manager.nextSeed mod 26)
    inc manager.nextSeed
    let session = newGlowcapSession(transport, seed, manager.hostPort, manager.limits)
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
    result.queuedBytes += current.queuedBytes

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
