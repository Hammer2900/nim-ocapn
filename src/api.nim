import std/[net, sequtils, strutils, tables]
import ./[handoff, locators, promises, references, server, session, syrup, transport]
import ./session as sessionApi

type
  NodeStats* = object
    activeSessions*: int
    pendingPromises*: int
    imports*: int
    exports*: int
    queuedBytes*: int
    pendingHandoffs*: int
  RemoteCapability* = object
    session*: Session
    reference*: CapabilityRef
    sturdy*: SturdyRef
    hasSturdy*: bool
  CallArgumentKind* = enum cakValue, cakCapability, cakList, cakRecord, cakDict, cakSet
  CallArgument* = object
    case kind*: CallArgumentKind
    of cakValue:
      value*: SyrupValue
    of cakCapability:
      capability*: RemoteCapability
    of cakList, cakSet:
      items*: seq[CallArgument]
    of cakRecord:
      label*: SyrupValue
      fields*: seq[CallArgument]
    of cakDict:
      pairs*: seq[CallPair]
  CallPair* = object
    key*: CallArgument
    value*: CallArgument
  ReceivedArgumentKind* = enum
    rakValue, rakCapability, rakList, rakRecord, rakDict, rakSet
  ReceivedPair* = object
    key*: ReceivedArgument
    value*: ReceivedArgument
  ReceivedArgument* = ref object
    case kind*: ReceivedArgumentKind
    of rakValue:
      value*: SyrupValue
    of rakCapability:
      capability*: RemoteCapability
      pendingHandoff: HandoffReceipt
    of rakList, rakSet:
      items*: seq[ReceivedArgument]
    of rakRecord:
      label*: ReceivedArgument
      fields*: seq[ReceivedArgument]
    of rakDict:
      pairs*: seq[ReceivedPair]
  TypedBehavior* = proc(session: Session; args: seq[ReceivedArgument]): SyrupValue {.closure.}
  PendingTypedCall = ref object
    node: Node
    session: Session
    handler: TypedBehavior
    args: seq[ReceivedArgument]
    receipts: seq[HandoffReceipt]
    answer: AnswerContext
    done: bool
  Node* = ref object
    manager*: TcpSessionManager
    handoffs*: HandoffManager
    publications: Table[string, Behavior]
    typedPublications: Table[string, TypedBehavior]
    handoffEnliveners: seq[string]
    outbound: seq[Session]
    outboundCursor: int
    sessionLimits: SessionLimits
    sturdyCache: Table[string, RemoteCapability]
    host: string
    port: Port
    seedPrefix: string

proc invokeTyped(node: Node; session: Session; handler: TypedBehavior;
                 raw: seq[SyrupValue]): SyrupValue
proc receiveHandoff*(node: Node; signedGive: SyrupValue;
                     signer: Session): HandoffReceipt

proc installTyped(node: Node; session: Session; name: string;
                  behavior: TypedBehavior) =
  let handler = behavior
  discard session.publishActor(name, proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    invokeTyped(node, actor, handler, args))

proc newNode*(host = "127.0.0.1"; port: Port; seedPrefix = "nim-node";
              limits = defaultSessionLimits();
              handoffLimits = HandoffLimits(maxPending: 256)): Node =
  new(result)
  result.host = host
  result.port = port
  result.seedPrefix = seedPrefix
  result.publications = initTable[string, Behavior]()
  result.typedPublications = initTable[string, TypedBehavior]()
  result.handoffEnliveners = @[]
  result.outbound = @[]
  result.outboundCursor = 0
  result.sessionLimits = limits
  result.sturdyCache = initTable[string, RemoteCapability]()
  result.handoffs = newHandoffManager(handoffLimits, limits)
  let node = result
  result.manager = newTcpSessionManager(host, port, seedPrefix, host & ":" & $port,
    proc(session: Session) =
      for name, behavior in node.publications:
        discard session.publishObject(name, behavior)
      for name, behavior in node.typedPublications:
        installTyped(node, session, name, behavior)
      for name in node.handoffEnliveners:
        discard session.publishActor(name, proc(actor: Session;
            args: seq[SyrupValue]): SyrupValue =
          if args.len != 1 or args[0].kind != skRecord:
            raise newException(SessionError, "sturdyref enlivener expects one sturdyref")
          let answer = actor.deferAnswer()
          discard node.handoffs.startSturdyRefSession(args[0].sturdyRef(), actor, answer)
          list()),
    limits = limits)

proc publish*(node: Node; name: string; behavior: Behavior) =
  node.publications[name] = behavior

proc isHandoffGive(value: SyrupValue): bool =
  value.kind == skRecord and value.label.kind == skSymbol and
    value.label.data == "desc:sig-envelope" and value.fields.len == 2 and
    value.fields[0].kind == skRecord and value.fields[0].label.kind == skSymbol and
    value.fields[0].label.data == "desc:handoff-give"

proc containsHandoff(value: SyrupValue): bool =
  if isHandoffGive(value): return true
  case value.kind
  of skList: value.items.anyIt(containsHandoff(it))
  of skRecord:
    if containsHandoff(value.label): return true
    value.fields.anyIt(containsHandoff(it))
  of skDict:
    for item in value.pairs:
      if containsHandoff(item.key) or containsHandoff(item.value): return true
    false
  of skSet:
    value.elements.anyIt(containsHandoff(it))
  else: false

proc convertArgument(node: Node; session: Session; value: SyrupValue;
                     receipts: var seq[HandoffReceipt]): ReceivedArgument =
  if isHandoffGive(value):
    let receipt = node.receiveHandoff(value, session)
    receipts.add(receipt)
    return ReceivedArgument(kind: rakCapability,
      capability: RemoteCapability(session: receipt.session),
      pendingHandoff: receipt)
  if value.kind == skRecord and value.label.kind == skSymbol and
      value.label.data in ["desc:export", "desc:import-object", "desc:import-promise"]:
    let reference = value.descriptor()
    return ReceivedArgument(kind: rakCapability,
      capability: RemoteCapability(session: session, reference: reference))
  case value.kind
  of skList:
    result = ReceivedArgument(kind: rakList, items: @[])
    for item in value.items:
      result.items.add(convertArgument(node, session, item, receipts))
  of skRecord:
    result = ReceivedArgument(kind: rakRecord,
      label: convertArgument(node, session, value.label, receipts), fields: @[])
    for field in value.fields:
      result.fields.add(convertArgument(node, session, field, receipts))
  of skDict:
    result = ReceivedArgument(kind: rakDict, pairs: @[])
    for item in value.pairs:
      result.pairs.add(ReceivedPair(key: convertArgument(node, session, item.key, receipts),
        value: convertArgument(node, session, item.value, receipts)))
  of skSet:
    result = ReceivedArgument(kind: rakSet, items: @[])
    for item in value.elements:
      result.items.add(convertArgument(node, session, item, receipts))
  else:
    result = ReceivedArgument(kind: rakValue, value: value)

proc materializeArgument(value: ReceivedArgument) =
  case value.kind
  of rakCapability:
    if not value.pendingHandoff.isNil:
      if value.pendingHandoff.promise.state == psBroken:
        raise newException(SessionError, value.pendingHandoff.promise.reason)
      value.capability.session = value.pendingHandoff.session
      value.capability.reference = value.pendingHandoff.promise.value.descriptor()
      value.pendingHandoff = nil
  of rakList, rakSet:
    for item in value.items: materializeArgument(item)
  of rakRecord:
    materializeArgument(value.label)
    for item in value.fields: materializeArgument(item)
  of rakDict:
    for item in value.pairs:
      materializeArgument(item.key)
      materializeArgument(item.value)
  else: discard

proc finishTypedCall(call: PendingTypedCall; settled: Promise) =
  if call.done: return
  for receipt in call.receipts:
    if receipt.promise.state == psPending: return
  call.done = true
  try:
    for arg in call.args: materializeArgument(arg)
    let reply = call.handler(call.session, call.args)
    if call.session.state != ssClosed:
      call.session.fulfillAnswer(call.answer, reply)
  except CatchableError as error:
    if call.session.state != ssClosed:
      call.session.breakAnswer(call.answer, error.msg)

proc invokeTyped(node: Node; session: Session; handler: TypedBehavior;
                 raw: seq[SyrupValue]): SyrupValue =
  var hasHandoff = false
  for value in raw:
    if containsHandoff(value):
      hasHandoff = true
      break
  if hasHandoff and not session.hasActiveAnswer():
    raise newException(SessionError, "handoff argument requires an answer")
  let application = if session.usesGlowcapV1() and raw.len > 0: raw[1 ..^ 1] else: raw
  var receipts: seq[HandoffReceipt]
  var args: seq[ReceivedArgument]
  try:
    for value in application:
      args.add(convertArgument(node, session, value, receipts))
  except CatchableError as error:
    raise newException(SessionError, error.msg)
  if receipts.len == 0:
    return handler(session, args)
  let call = PendingTypedCall(node: node, session: session, handler: handler,
    args: args, receipts: receipts, answer: session.deferAnswer())
  for receipt in receipts:
    receipt.promise.onSettle(proc(promise: Promise) = call.finishTypedCall(promise))
  call.finishTypedCall(nil)
  list()

proc publishTyped*(node: Node; name: string; behavior: TypedBehavior) =
  node.typedPublications[name] = behavior

proc valueArg*(value: SyrupValue): CallArgument =
  CallArgument(kind: cakValue, value: value)

proc capabilityArg*(capability: RemoteCapability): CallArgument =
  CallArgument(kind: cakCapability, capability: capability)

proc listArg*(items: openArray[CallArgument]): CallArgument =
  CallArgument(kind: cakList, items: @items)

proc setArg*(items: openArray[CallArgument]): CallArgument =
  CallArgument(kind: cakSet, items: @items)

proc recordArg*(label: SyrupValue; fields: openArray[CallArgument]): CallArgument =
  CallArgument(kind: cakRecord, label: label, fields: @fields)

proc dictPair*(key, value: CallArgument): CallPair =
  CallPair(key: key, value: value)

proc dictArg*(pairs: openArray[CallPair]): CallArgument =
  CallArgument(kind: cakDict, pairs: @pairs)

proc encodeArgument(node: Node; target: RemoteCapability;
                    arg: CallArgument): SyrupValue =
  case arg.kind
  of cakValue:
    arg.value
  of cakCapability:
    if arg.capability.session == target.session:
      arg.capability.reference.payloadDescriptor()
    else:
      node.handoffs.handoffArgument(arg.capability.session,
        arg.capability.reference, target.session)
  of cakList:
    var values: seq[SyrupValue]
    for item in arg.items: values.add(node.encodeArgument(target, item))
    list(values)
  of cakSet:
    var values: seq[SyrupValue]
    for item in arg.items: values.add(node.encodeArgument(target, item))
    setValue(values)
  of cakRecord:
    var fields: seq[SyrupValue]
    for item in arg.fields: fields.add(node.encodeArgument(target, item))
    record(arg.label, fields)
  of cakDict:
    var pairs: seq[SyrupPair]
    for item in arg.pairs:
      pairs.add(pair(node.encodeArgument(target, item.key),
        node.encodeArgument(target, item.value)))
    dict(pairs)

proc publishHandoffEnlivener*(node: Node; name = "enlivener") =
  if name notin node.handoffEnliveners:
    node.handoffEnliveners.add(name)

proc pruneOutbound(node: Node) =
  var active: seq[Session]
  for session in node.outbound:
    if session.state != ssClosed:
      active.add(session)
  node.outbound = active
  if node.outbound.len == 0:
    node.outboundCursor = 0
  else:
    node.outboundCursor = node.outboundCursor mod node.outbound.len

proc poll*(node: Node; timeoutMs = 1000; maxWork = 64): int =
  if maxWork <= 0: return 0
  result = node.manager.poll(timeoutMs, maxWork)
  var work = result
  var inspected = 0
  while inspected < node.outbound.len and work < maxWork:
    let index = (node.outboundCursor + inspected) mod node.outbound.len
    let session = node.outbound[index]
    if session.state != ssClosed:
      try: discard session.pump()
      except CatchableError: discard
      inc work
    inc inspected
  if node.outbound.len > 0:
    node.outboundCursor = (node.outboundCursor + inspected) mod node.outbound.len
  node.pruneOutbound()
  if work < maxWork:
    work += node.handoffs.pumpWork(maxWork - work)
  result = work

proc stats*(node: Node): NodeStats =
  let managerStats = node.manager.stats()
  let handoffStats = node.handoffs.stats()
  result.activeSessions = managerStats.activeSessions
  for session in node.outbound:
    if session.state != ssClosed:
      inc result.activeSessions
      let current = session.stats()
      result.pendingPromises += current.pendingPromises
      result.imports += current.importCount
      result.exports += current.exportCount
      result.queuedBytes += current.queuedBytes
  result.pendingPromises += managerStats.pendingPromises
  result.imports += managerStats.imports
  result.exports += managerStats.exports
  result.queuedBytes += managerStats.queuedBytes
  result.pendingHandoffs = handoffStats.pendingEnliven + handoffStats.pendingReceives

proc dial*(node: Node; host: string; port: Port;
           seed = "cccccccccccccccccccccccccccccccc"): Session

proc connect*(node: Node; host: string; port: Port; seed = "cccccccccccccccccccccccccccccccc";
              maxPumps = 10000): Session =
  result = node.dial(host, port, seed)
  var remaining = maxPumps
  while result.state == ssNegotiating:
    if remaining <= 0:
      result.close("handshake timeout")
      raise newException(SessionError, "handshake timeout")
    discard result.pump()
    dec remaining

proc dial*(node: Node; host: string; port: Port;
           seed = "cccccccccccccccccccccccccccccccc"): Session =
  let tcp = connectTcp(host, port)
  tcp.setNonBlocking()
  result = newGlowcapSession(tcp, seed, host & ":" & $port, node.sessionLimits)
  result.remotePeer = newPeerLocator("tcp", host & ":" & $port,
    [("host", host), ("port", $port)])
  node.outbound.add(result)

proc connect*(node: Node; peer: PeerLocator;
              seed = "cccccccccccccccccccccccccccccccc";
              maxPumps = 10000): Session =
  if not peer.hints.hasKey("host") or not peer.hints.hasKey("port"):
    raise newException(SessionError, "TCP peer locator requires host and port hints")
  let host = peer.hints["host"]
  let port = Port(parseInt(peer.hints["port"]))
  node.connect(host, port, seed, maxPumps)

proc fetch*(session: Session; name: string): Promise = sessionApi.fetch(session, name)
proc call*(session: Session; target: CapabilityRef; verb: string;
           args: openArray[SyrupValue]): Promise = sessionApi.call(session, target, verb, args)
proc waitFor*(session: Session; promise: Promise; maxPumps = 10000): SyrupValue =
  sessionApi.waitFor(session, promise, maxPumps)

proc fetchCapability*(session: Session; name: string; maxPumps = 10000): RemoteCapability =
  result.session = session
  result.reference = sessionApi.waitFor(session, sessionApi.fetch(session, name), maxPumps).descriptor()

proc receiveHandoff*(node: Node; signedGive: SyrupValue;
                     signer: Session): HandoffReceipt =
  node.handoffs.startHandoffReceiver(signedGive, signer)

proc waitForHandoff*(node: Node; receipt: HandoffReceipt;
                     maxPumps = 10000): RemoteCapability =
  var remaining = maxPumps
  while receipt.promise.state == psPending:
    if remaining <= 0:
      raise newException(SessionError, "handoff timeout")
    discard node.poll(1)
    dec remaining
  if receipt.promise.state == psBroken:
    raise newException(SessionError, receipt.promise.reason)
  result.session = receipt.session
  result.reference = receipt.promise.value.descriptor()

proc enlivenVia*(node: Node; peer: Session; sturdy: SturdyRef;
                 enlivener = "enlivener"; maxPumps = 10000): RemoteCapability =
  let enlivenerRef = peer.fetchCapability(enlivener, maxPumps)
  let give = peer.deliverCall(enlivenerRef.reference, [sturdy.sturdySyrup()])
  var remaining = maxPumps
  while give.state == psPending:
    if remaining <= 0:
      raise newException(SessionError, "handoff enlivener timeout")
    discard node.poll(1)
    try: discard peer.pump()
    except CatchableError: discard
    dec remaining
  if give.state == psBroken:
    raise newException(SessionError, give.reason)
  let receipt = node.receiveHandoff(give.value, peer)
  result = node.waitForHandoff(receipt, maxPumps)
  result.sturdy = sturdy
  result.hasSturdy = true

proc enliven*(node: Node; sturdy: SturdyRef; maxPumps = 10000): RemoteCapability =
  let cacheKey = sturdy.peer.transport & "\0" & sturdy.peer.designator & "\0" & sturdy.swissNum
  if node.sturdyCache.hasKey(cacheKey):
    let cached = node.sturdyCache[cacheKey]
    if cached.session.state != ssClosed:
      return cached
    node.sturdyCache.del(cacheKey)
  let session = node.connect(sturdy.peer)
  result.session = session
  result.reference = sessionApi.waitFor(session, sessionApi.fetch(session, sturdy.swissNum), maxPumps).descriptor()
  result.sturdy = sturdy
  result.hasSturdy = true
  node.sturdyCache[cacheKey] = result

proc forget*(node: Node; sturdy: SturdyRef) =
  let cacheKey = sturdy.peer.transport & "\0" & sturdy.peer.designator & "\0" & sturdy.swissNum
  if node.sturdyCache.hasKey(cacheKey):
    let cached = node.sturdyCache[cacheKey]
    node.sturdyCache.del(cacheKey)
    cached.session.close("sturdyref forgotten")

proc call*(capability: RemoteCapability; verb: string;
           args: openArray[SyrupValue]): Promise =
  sessionApi.call(capability.session, capability.reference, verb, args)

proc call*(node: Node; target: RemoteCapability; verb: string;
           args: openArray[CallArgument]): Promise =
  var values: seq[SyrupValue]
  for arg in args: values.add(node.encodeArgument(target, arg))
  sessionApi.call(target.session, target.reference, verb, values)

proc close*(node: Node) =
  node.handoffs.close("node closed")
  for session in node.outbound:
    session.close("node closed")
  node.outbound.setLen(0)
  node.sturdyCache.clear()
  node.manager.close()
