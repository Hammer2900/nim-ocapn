import std/[monotimes, net, sequtils, strutils, tables]
import ./[handoff, identity, locators, messages, onion, promises, references, server, session, syrup, transport]
import ./session as sessionApi
when defined(ssl):
  import ./tls_transport

type
  NetlayerKind* = enum
    nlkTcpTestingOnly
    nlkOnionTestingOnly
    nlkMutualTls
  NodeConfig* = object
    host*: string
    port*: Port
    seedPrefix*: string
    identity*: NodeIdentity
    identityPath*: string
    verificationPolicy*: PeerVerificationPolicy
    netlayer*: NetlayerKind
    sessionLimits*: SessionLimits
    handoffLimits*: HandoffLimits
    onionConfig*: OnionNetlayerConfig
    maxActiveSessions*: int
    handshakeTimeoutMs*: int
    diagnosticSink*: DiagnosticSink
  NodeStats* = object
    activeSessions*: int
    pendingPromises*: int
    imports*: int
    exports*: int
    listenerLifecycles*: int
    queuedBytes*: int
    pendingHandoffs*: int
    forwardedPromises*: int
    forwardedProxies*: int
    depositedGifts*: int
    pendingGiftWithdraws*: int
  RemoteCapability* = object
    session*: Session
    reference*: CapabilityRef
    sturdy*: SturdyRef
    hasSturdy*: bool
  RemotePromise* = object
    session*: Session
    reference*: CapabilityRef
    promise*: Promise
  CallArgumentKind* = enum cakValue, cakCapability, cakPromise, cakList, cakRecord, cakDict, cakSet
  CallArgument* = object
    case kind*: CallArgumentKind
    of cakValue:
      value*: SyrupValue
    of cakCapability:
      capability*: RemoteCapability
    of cakPromise:
      remotePromise*: RemotePromise
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
    rakValue, rakCapability, rakPromise, rakList, rakRecord, rakDict, rakSet
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
    of rakPromise:
      promise*: RemotePromise
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
    identity*: NodeIdentity
    verificationPolicy*: PeerVerificationPolicy
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
    onionConfig: OnionNetlayerConfig
    diagnosticSink: DiagnosticSink

export identity, locators
export DiagnosticEvent, DiagnosticSink, DiagnosticEventKind, DiagnosticErrorCategory
export SessionLimits, SessionStats, SessionError, PromiseTimeoutError
export HandoffLimits

proc defaultNodeConfig*(port: Port = Port(0)): NodeConfig =
  NodeConfig(host: "127.0.0.1", port: port, seedPrefix: "nim-node",
    verificationPolicy: testingOnlyPeerPolicy, netlayer: nlkTcpTestingOnly,
    sessionLimits: defaultSessionLimits(), handoffLimits: HandoffLimits(maxPending: 256),
    onionConfig: defaultOnionNetlayerConfig(), maxActiveSessions: 256,
    handshakeTimeoutMs: 30000)

proc loadNodeIdentity*(path: string): NodeIdentity =
  loadOrCreateIdentity(path)

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
              handoffLimits = HandoffLimits(maxPending: 256);
              identity: NodeIdentity = nil;
              verificationPolicy = testingOnlyPeerPolicy;
              maxActiveSessions = 256;
              handshakeTimeoutMs = 30000;
              diagnosticSink: DiagnosticSink = nil): Node =
  new(result)
  result.host = host
  result.port = port
  result.seedPrefix = seedPrefix
  result.onionConfig = defaultOnionNetlayerConfig()
  result.diagnosticSink = diagnosticSink
  result.identity = identity
  result.verificationPolicy = verificationPolicy
  if verificationPolicy.mode != pvmTestingOnly and identity.isNil:
    raise newException(IdentityError, "strict peer policy requires durable node identity")
  result.publications = initTable[string, Behavior]()
  result.typedPublications = initTable[string, TypedBehavior]()
  result.handoffEnliveners = @[]
  result.outbound = @[]
  result.outboundCursor = 0
  result.sessionLimits = limits
  result.sturdyCache = initTable[string, RemoteCapability]()
  result.handoffs = newHandoffManager(handoffLimits, limits, verificationPolicy, identity)
  result.handoffs.setDiagnosticSink(seedPrefix, diagnosticSink)
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
    limits = limits, verificationPolicy = verificationPolicy, identity = identity,
    handshakeTimeoutMs = handshakeTimeoutMs,
    maxActiveSessions = maxActiveSessions)
  result.manager.setDiagnosticSink(seedPrefix, diagnosticSink)

proc newNode*(config: NodeConfig): Node =
  if config.netlayer != nlkTcpTestingOnly:
    raise newException(SessionError,
      "Node listeners use TCP; select Onion or mutual TLS when connecting with connectUsing")
  var identity = config.identity
  if identity.isNil and config.identityPath.len > 0:
    identity = loadNodeIdentity(config.identityPath)
  result = newNode(config.host, config.port, config.seedPrefix, config.sessionLimits,
    config.handoffLimits, identity, config.verificationPolicy,
    config.maxActiveSessions, config.handshakeTimeoutMs, config.diagnosticSink)
  result.onionConfig = config.onionConfig

proc setTraceSink*(node: Node; nodeId: string; sink: TraceSink) =
  node.manager.setTraceSink(nodeId, sink)

proc setDiagnosticSink*(node: Node; nodeId: string; sink: DiagnosticSink) =
  node.diagnosticSink = sink
  node.manager.setDiagnosticSink(nodeId, sink)

proc publicIdentity*(node: Node): string =
  if node.isNil or node.identity.isNil:
    raise newException(IdentityError, "node has no durable identity")
  node.identity.publicKey

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

proc listenToIncomingPromise(session: Session; reference: CapabilityRef): Promise =
  if reference.kind != rkImportPromise:
    raise newException(SessionError, "incoming promise requires desc:import-promise")
  result = newPromise()
  let local = result
  var resolver: CapabilityRef
  var subscribe: proc(reference: CapabilityRef) {.closure.}
  subscribe = proc(next: CapabilityRef) =
    session.accountOutboundExport(resolver)
    session.send(messages.listen(exportRef(next.position).descriptor(),
      importObject(resolver.position).descriptor(), 3))
  resolver = session.exportListenerActor(proc(actor: Session; args: seq[SyrupValue]): SyrupValue =
    if args.len != 2 or args[0].kind != skSymbol:
      raise newException(SessionError, "invalid incoming promise resolution")
    if args[0].data == "fulfill":
      if args[1].kind == skRecord and args[1].label.kind == skSymbol and
          args[1].label.data == "desc:import-promise":
        subscribe(args[1].descriptor())
      elif local.state == psPending:
        local.fulfill(args[1])
        session.unregisterPendingPromise(resolver.position)
        session.completeListenerResolver(resolver)
    elif args[0].data == "break":
      if args[1].kind != skString: raise newException(SessionError, "invalid incoming promise break")
      if local.state == psPending:
        local.breakPromise(args[1].data)
        session.unregisterPendingPromise(resolver.position)
        session.completeListenerResolver(resolver)
    else:
      raise newException(SessionError, "unknown incoming promise resolution")
    list())
  # op:listen names the promise in the sender's import table with desc:export.
  session.registerPendingPromise(resolver.position, local)
  subscribe(reference)

proc propagateForwardedPromise(source: Promise; sourceSession, targetSession: Session;
                               target: CapabilityRef) =
  if targetSession.state == ssClosed: return
  if source.state == psBroken:
    targetSession.breakPromise(target, source.reason)
    return
  if source.value.kind == skRecord and source.value.label.kind == skSymbol and
      source.value.label.data == "desc:import-promise":
    let next = targetSession.newPromisePair()
    let observed = listenToIncomingPromise(sourceSession, source.value.descriptor())
    targetSession.settlePromise(target,
      targetSession.promisePayloadDescriptor(next.vow))
    observed.onSettle(proc(settled: Promise) =
      propagateForwardedPromise(settled, sourceSession, targetSession, next.vow))
  elif source.value.kind == skRecord and source.value.label.kind == skSymbol and
      source.value.label.data == "desc:import-object":
    let sourceReference = source.value.descriptor()
    let proxy = targetSession.exportCapabilityProxy(sourceSession, sourceReference)
    targetSession.settlePromise(target, targetSession.promisePayloadDescriptor(proxy))
  else:
    targetSession.settlePromise(target, source.value)

proc exportForwardedPromise(targetSession, sourceSession: Session;
                            source: Promise): CapabilityRef =
  let pair = targetSession.newPromisePair()
  targetSession.registerForwardedPromise(pair.vow, sourceSession, source)
  source.onSettle(proc(settled: Promise) =
    targetSession.settleForwardedPromise(pair.vow, settled)
    propagateForwardedPromise(settled, sourceSession, targetSession, pair.vow))
  pair.vow

proc exportForwardedPromise(targetSession: Session; remote: RemotePromise): CapabilityRef =
  let pair = targetSession.newPromisePair()
  targetSession.registerForwardedPromiseReference(pair.vow, remote.session,
    remote.reference, remote.promise)
  remote.promise.onSettle(proc(settled: Promise) =
    targetSession.settleForwardedPromise(pair.vow, settled)
    propagateForwardedPromise(settled, remote.session, targetSession, pair.vow))
  pair.vow

proc convertArgument(node: Node; session: Session; value: SyrupValue;
                     receipts: var seq[HandoffReceipt]): ReceivedArgument =
  if isHandoffGive(value):
    let receipt = node.receiveHandoff(value, session)
    receipts.add(receipt)
    return ReceivedArgument(kind: rakCapability,
      capability: RemoteCapability(session: receipt.session),
      pendingHandoff: receipt)
  if value.kind == skRecord and value.label.kind == skSymbol and
      value.label.data == "desc:import-promise":
    let reference = value.descriptor()
    return ReceivedArgument(kind: rakPromise,
      promise: RemotePromise(session: session, reference: reference,
        promise: listenToIncomingPromise(session, reference)))
  if value.kind == skRecord and value.label.kind == skSymbol and
      value.label.data in ["desc:export", "desc:import-object"]:
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

proc promiseArg*(promise: RemotePromise): CallArgument =
  CallArgument(kind: cakPromise, remotePromise: promise)

proc callPipelined*(promise: RemotePromise; verb: string;
                    args: openArray[SyrupValue]): Promise =
  if promise.reference.kind == rkImportPromise:
    var callArgs = @[symbol(verb)]
    for arg in args: callArgs.add(arg)
    return promise.session.deliverCall(promise.reference, callArgs)
  if promise.promise.isNil or promise.promise.answerPosition < 0:
    raise newException(SessionError,
      "promise pipelining requires an unresolved local answer promise")
  promise.session.callPipelined(promise.promise, verb, args)

proc promiseRef*(session: Session; promise: Promise): RemotePromise =
  if promise.isNil:
    raise newException(SessionError, "cannot reference a nil promise")
  if promise.state == psFulfilled and promise.value.kind == skRecord and
      promise.value.label.kind == skSymbol and
      promise.value.label.data == "desc:import-promise":
    let reference = promise.value.descriptor()
    return RemotePromise(session: session, reference: reference,
      promise: listenToIncomingPromise(session, reference))
  RemotePromise(session: session, promise: promise)

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
      target.session.accountOutboundExport(arg.capability.reference)
      arg.capability.reference.payloadDescriptor()
    else:
      node.handoffs.handoffArgument(arg.capability.session,
        arg.capability.reference, target.session)
  of cakPromise:
    let remote = arg.remotePromise
    if remote.session == target.session and remote.reference.kind != rkAnswer:
      target.session.accountOutboundExport(remote.reference)
      remote.reference.payloadDescriptor()
    else:
      let reference = if remote.reference.kind == rkImportPromise:
          exportForwardedPromise(target.session, remote)
        else:
          exportForwardedPromise(target.session, remote.session, remote.promise)
      target.session.promisePayloadDescriptor(reference)
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
      except CatchableError:
        discard
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
      result.listenerLifecycles += current.listenerLifecycleCount
      result.queuedBytes += current.queuedBytes
      result.forwardedPromises += current.forwardedPromiseCount
      result.forwardedProxies += current.forwardedProxyCount
      result.depositedGifts += current.depositedGifts
      result.pendingGiftWithdraws += current.pendingGiftWithdraws
  result.pendingPromises += managerStats.pendingPromises
  result.imports += managerStats.imports
  result.exports += managerStats.exports
  result.listenerLifecycles += managerStats.listenerLifecycles
  result.queuedBytes += managerStats.queuedBytes
  result.forwardedPromises += managerStats.forwardedPromises
  result.forwardedProxies += managerStats.forwardedProxies
  result.depositedGifts += managerStats.depositedGifts
  result.pendingGiftWithdraws += managerStats.pendingGiftWithdraws
  result.pendingHandoffs = handoffStats.pendingEnliven + handoffStats.pendingReceives

proc dial*(node: Node; host: string; port: Port;
           seed = "cccccccccccccccccccccccccccccccc"): Session

proc registerOutbound(node: Node; session: Session; peer: PeerLocator;
                      policy: PeerVerificationPolicy): Session =
  result = session
  session.forwardedRegistry = node.manager.forwardedRegistry
  session.setTraceSink(node.manager.traceNodeId, node.manager.traceSink)
  session.setDiagnosticSink(node.manager.diagnosticNodeId, node.manager.diagnosticSink)
  session.remotePeer = peer
  session.verificationPolicy = policy
  session.setExpectedPeer(peer, policy.mode != pvmTestingOnly)
  node.outbound.add(session)

proc waitForHandshake(session: Session; maxPumps: int): Session =
  var remaining = maxPumps
  while session.state == ssNegotiating:
    if remaining <= 0:
      session.close("handshake timeout")
      raise newException(SessionError, "handshake timeout")
    discard session.pump()
    dec remaining
  session

proc sessionSeed(node: Node; fallback: string): string =
  if node.identity.isNil: fallback else: node.identity.sessionSeed()

proc connect*(node: Node; host: string; port: Port; seed = "cccccccccccccccccccccccccccccccc";
              maxPumps = 10000): Session =
  result = waitForHandshake(node.dial(host, port, seed), maxPumps)

proc dial*(node: Node; host: string; port: Port;
           seed = "cccccccccccccccccccccccccccccccc"): Session =
  let tcp = connectTcp(host, port)
  tcp.setNonBlocking()
  let actualSeed = node.sessionSeed(seed)
  let peer = newPeerLocator("tcp", host & ":" & $port,
    [("host", host), ("port", $port)])
  result = newGlowcapSession(tcp, actualSeed, host & ":" & $port, node.sessionLimits,
    node.verificationPolicy)
  result = node.registerOutbound(result, peer, node.verificationPolicy)

proc connect*(node: Node; peer: PeerLocator;
              seed = "cccccccccccccccccccccccccccccccc";
              maxPumps = 10000): Session =
  if peer.transport == "onion":
    let onionTransport = newOnionNetlayer().dial(peer)
    let actualSeed = node.sessionSeed(seed)
    result = newSession(onionTransport, actualSeed, peer.peerUri(), node.sessionLimits,
      node.verificationPolicy)
    return waitForHandshake(node.registerOutbound(result, peer, node.verificationPolicy), maxPumps)
  if not peer.hints.hasKey("host") or not peer.hints.hasKey("port"):
    raise newException(SessionError, "TCP peer locator requires host and port hints")
  let host = peer.hints["host"]
  let port = Port(parseInt(peer.hints["port"]))
  node.connect(host, port, seed, maxPumps)

proc connectUsing*(node: Node; peer: PeerLocator; netlayer: NetlayerKind;
                   seed = "cccccccccccccccccccccccccccccccc";
                   maxPumps = 10000): Session =
  case netlayer
  of nlkTcpTestingOnly:
    if peer.transport != "tcp":
      raise newException(SessionError, "TCP selection requires a tcp peer locator")
    node.connect(peer, seed, maxPumps)
  of nlkOnionTestingOnly:
    if peer.transport != "onion":
      raise newException(SessionError, "Onion selection requires an onion peer locator")
    let onionTransport = newOnionNetlayer(node.onionConfig).dial(peer)
    let actualSeed = node.sessionSeed(seed)
    let session = newSession(onionTransport, actualSeed, peer.peerUri(),
      node.sessionLimits, node.verificationPolicy)
    waitForHandshake(node.registerOutbound(session, peer, node.verificationPolicy), maxPumps)
  of nlkMutualTls:
    raise newException(SessionError,
      "mutual TLS requires connectMutualTls with its certificate configuration")

when defined(ssl):
  proc connectMutualTls*(node: Node; host: string; port: Port;
                         config: TlsTransportConfig;
                         maxPumps = 10000): Session =
    let transport = newTlsClient(host, port, config)
    let peer = newPeerLocator("tls-testing-only", host & ":" & $port,
      [("host", host), ("port", $port)])
    let session = newSession(transport, node.sessionSeed(node.seedPrefix), peer.peerUri(),
      node.sessionLimits, node.verificationPolicy)
    result = waitForHandshake(node.registerOutbound(session, peer,
      node.verificationPolicy), maxPumps)

proc listenPort*(node: Node): Port =
  node.manager.listenPort()

proc locator*(node: Node): PeerLocator =
  newPeerLocator("tcp", node.host & ":" & $node.listenPort(),
    [("host", node.host), ("port", $node.listenPort())])

proc bootstrap*(node: Node; session: Session; name: string;
                maxPumps = 10000): RemoteCapability =
  discard node
  result.session = session
  result.reference = sessionApi.waitFor(session, sessionApi.fetch(session, name), maxPumps).descriptor()

proc connectVerified*(node: Node; host: string; port: Port; expectedPublicKey: string;
                      seed = "cccccccccccccccccccccccccccccccc";
                      maxPumps = 10000): Session =
  let policy = exactPeerPolicy(expectedPublicKey)
  let tcp = connectTcp(host, port)
  tcp.setNonBlocking()
  let actualSeed = node.sessionSeed(seed)
  let peer = newPeerLocator("tcp", host & ":" & $port,
    [("host", host), ("port", $port)])
  result = newGlowcapSession(tcp, actualSeed, host & ":" & $port, node.sessionLimits, policy)
  result = node.registerOutbound(result, peer, policy)
  result = waitForHandshake(result, maxPumps)

proc connectVerified*(node: Node; peer: PeerLocator; expectedPublicKey: string;
                      seed = "cccccccccccccccccccccccccccccccc";
                      maxPumps = 10000): Session =
  let policy = exactPeerPolicy(expectedPublicKey)
  if peer.transport != "onion":
    if not peer.hints.hasKey("host") or not peer.hints.hasKey("port"):
      raise newException(SessionError, "TCP peer locator requires host and port hints")
    return node.connectVerified(peer.hints["host"], Port(parseInt(peer.hints["port"])),
      expectedPublicKey, seed, maxPumps)
  let onionTransport = newOnionNetlayer().dial(peer)
  let actualSeed = node.sessionSeed(seed)
  result = newSession(onionTransport, actualSeed, peer.peerUri(), node.sessionLimits, policy)
  result = node.registerOutbound(result, peer, policy)
  result = waitForHandshake(result, maxPumps)

proc fetch*(session: Session; name: string): Promise = sessionApi.fetch(session, name)
proc call*(session: Session; target: CapabilityRef; verb: string;
           args: openArray[SyrupValue]): Promise = sessionApi.call(session, target, verb, args)
proc waitFor*(session: Session; promise: Promise; maxPumps = 10000): SyrupValue =
  sessionApi.waitFor(session, promise, maxPumps)

proc cancelCall*(session: Session; promise: Promise; reason = "call cancelled"): bool =
  sessionApi.cancel(session, promise, reason)

proc waitForCallTimeout*(session: Session; promise: Promise; timeoutMs: int): SyrupValue =
  sessionApi.waitForTimeout(session, promise, timeoutMs)

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
      discard node.handoffs.cancel(receipt, "handoff timeout")
      raise newException(HandoffTimeoutError, "handoff timeout")
    discard node.poll(1)
    dec remaining
  if receipt.promise.state == psBroken:
    node.handoffs.diagnostic(dekHandoffFailure, decHandoff, "handoff failed")
    raise newException(SessionError, receipt.promise.reason)
  node.handoffs.diagnostic(dekHandoffSuccess, decNone, "handoff completed")
  result.session = receipt.session
  result.reference = receipt.promise.value.descriptor()

proc cancel*(node: Node; receipt: HandoffReceipt; reason = "handoff cancelled"): bool =
  node.handoffs.cancel(receipt, reason)

proc waitForHandoffTimeout*(node: Node; receipt: HandoffReceipt;
                           timeoutMs: int): RemoteCapability =
  if receipt.isNil or receipt.promise.isNil:
    raise newException(SessionError, "cannot wait for a nil handoff")
  if timeoutMs < 0:
    raise newException(SessionError, "timeout must not be negative")
  let deadline = getMonoTime().ticks + int64(timeoutMs) * 1_000_000
  while receipt.promise.state == psPending:
    let remaining = deadline - getMonoTime().ticks
    if remaining <= 0:
      discard node.cancel(receipt, "handoff timeout")
      raise newException(HandoffTimeoutError, "handoff timeout")
    let work = node.poll(min(1, int(remaining div 1_000_000)), 64)
    if work == 0:
      discard node.handoffs.waitReadable(min(1, int(remaining div 1_000_000)))
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
      discard peer.cancel(give, "handoff timeout")
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
