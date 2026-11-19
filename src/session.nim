import std/[strutils, tables, monotimes, sysrand]
import ./[crypto, framing, gifts, identity, locators, messages, promises, references, syrup, transport]

type
  SessionError* = object of CatchableError
  PromiseTimeoutError* = object of SessionError
  SessionLimits* = object
    maxFrameBytes*: int
    maxPendingPromises*: int
    maxExports*: int
    maxImports*: int
    maxOutboundBytes*: int
  DiagnosticEventKind* = enum
    dekSessionOpened
    dekSessionClosed
    dekHandshakeSuccess
    dekHandshakeFailure
    dekPeerVerificationFailure
    dekTransportDisconnect
    dekTransportError
    dekPromiseTimeout
    dekPromiseCancellation
    dekHandoffSuccess
    dekHandoffFailure
    dekResourceLimit
  DiagnosticErrorCategory* = enum
    decNone
    decHandshake
    decVerification
    decTransport
    decPromise
    decHandoff
    decResource
    decProtocol
  DiagnosticEvent* = object
    timestamp*: float
    nodeId*: string
    sessionId*: string
    kind*: DiagnosticEventKind
    errorCategory*: DiagnosticErrorCategory
    detail*: string
  DiagnosticSink* = proc(event: DiagnosticEvent) {.closure.}
  SessionStats* = object
    pendingPromises*: int
    importCount*: int
    exportCount*: int
    queuedBytes*: int
    answerCount*: int
    inboundAnswerCount*: int
    promiseSlotCount*: int
    promiseListenerCount*: int
    listenerLifecycleCount*: int
    forwardedPromiseCount*: int
    forwardedProxyCount*: int
    depositedGifts*: int
    pendingGiftWithdraws*: int
  TraceDirection* = enum tdIn, tdOut
  TraceEvent* = object
    number*: int64
    monotonicSeconds*: float
    nodeId*: string
    sessionId*: string
    direction*: TraceDirection
    operation*: string
    target*: string
    answer*: string
    bytes*: int
    promiseState*: string
    ownership*: string
  TraceSink* = proc(event: TraceEvent) {.closure.}
  SessionState* = enum ssNegotiating, ssOpen, ssClosed
  AnswerContext* = object
    answerPosition*: int64
    resolver*: SyrupValue
    listenMode*: int64
  Behavior* = BehaviorRef
  ActorBehavior* = proc(session: Session; args: seq[SyrupValue]): SyrupValue {.closure.}
  PromiseListener = object
    resolver: SyrupValue
    mode: int64
    lifecycle: ListenerLifecycle
  ListenerLifecycle = ref object
    resolverKey: ReferenceKey
    resolverPosition: int64
    shorteningActive: bool
    settlingActive: bool
    callbackComplete: bool
    gcSent: bool
  PromiseSlot = object
    pending: bool
    broken: bool
    value: SyrupValue
    reason: SyrupValue
    listeners: seq[PromiseListener]
  PipelineRequest = object
    args: seq[SyrupValue]
    answerPosition: int64
    resolver: SyrupValue
  ForwardedPromiseOrigin* = ref object
    sourceSession*: Session
    sourcePromise*: Promise
    sourceReference*: CapabilityRef
    hasSourceReference*: bool
    settled*: bool
    broken*: bool
    reason*: string
    targetWireRefs*: int64
    sourceWireRefs*: int64
    latePipelineActive*: int64
    latePipelineSeen*: bool
  ForwardedPromiseKey* = object
    sessionIdentity: string
    reference: ReferenceKey
  ForwardedPromiseRegistry* = ref object
    origins*: Table[ForwardedPromiseKey, ForwardedPromiseOrigin]
    retired*: Table[ForwardedPromiseKey, string]
  Session* = ref object
    transport*: Transport
    state*: SessionState
    identityVerified*: bool
    peerVerified*: bool
    transportAuthenticated*: bool
    verificationPolicy*: PeerVerificationPolicy
    expectedPeer*: PeerLocator
    enforceExpectedPeer: bool
    localPublicKey*: string
    localSecret: string
    remotePublicKey*: string
    remoteLocation*: string
    remotePeer*: PeerLocator
    references*: ReferenceTables
    outboundDescriptorUses: Table[int64, int64]
    nextAnswer: int64
    freeAnswers: seq[int64]
    decoder: FrameDecoder
    sawHello: bool
    sentHello: bool
    glowcapV1: bool
    publications: Table[string, CapabilityRef]
    actors: Table[int64, ActorBehavior]
    promiseSlots: Table[int64, PromiseSlot]
    answerSlots: Table[int64, PromiseSlot]
    listenerLifecycles: Table[ReferenceKey, ListenerLifecycle]
    listenerGcSent: Table[ReferenceKey, bool]
    listenerResolverExports: Table[int64, bool]
    listenerResolverDone: Table[int64, bool]
    retiredListenerResolvers: Table[int64, bool]
    pending: Table[int64, Promise]
    answers: Table[int64, int64]
    inboundAnswers: Table[int64, bool]
    resolvedAnswers: Table[int64, SyrupValue]
    brokenAnswers: Table[int64, string]
    pipelines: Table[int64, seq[PipelineRequest]]
    forwardedRegistry*: ForwardedPromiseRegistry
    seenHandoffCounts: Table[int64, bool]
    gifts*: GiftTable
    ownsGifts*: bool
    giftPromises: seq[Promise]
    activeAnswerPosition: int64
    activeListenMode: int64
    activeResolver: SyrupValue
    deferredAnswers: Table[int64, bool]
    limits*: SessionLimits
    traceSink*: TraceSink
    traceNodeId*: string
    traceSequence*: int64
    diagnosticSink*: DiagnosticSink
    diagnosticNodeId*: string

proc defaultSessionLimits*(): SessionLimits =
  SessionLimits(maxFrameBytes: 1024 * 1024, maxPendingPromises: 4096,
    maxExports: 4096, maxImports: 4096, maxOutboundBytes: 1024 * 1024)

proc sessionId*(session: Session): string

proc freshSessionSeed(): string =
  let randomBytes = urandom(32)
  result = newString(randomBytes.len)
  for index, value in randomBytes:
    result[index] = char(value)

proc setDiagnosticSink*(session: Session; nodeId: string; sink: DiagnosticSink) =
  session.diagnosticNodeId = nodeId
  session.diagnosticSink = sink

proc diagnosticSessionId(session: Session): string =
  if session.remotePublicKey.len != 32: return "-"
  session.sessionId()

proc diagnostic*(session: Session; kind: DiagnosticEventKind;
                category = decNone; detail = "") =
  if session.diagnosticSink.isNil: return
  session.diagnosticSink(DiagnosticEvent(timestamp: getMonoTime().ticks.float / 1_000_000_000.0,
    nodeId: session.diagnosticNodeId, sessionId: session.diagnosticSessionId(),
    kind: kind, errorCategory: category, detail: detail))

proc setTraceSink*(session: Session; nodeId: string; sink: TraceSink) =
  session.traceNodeId = nodeId
  session.traceSink = sink

proc traceId(value: string): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(value.len * 2)
  for ch in value:
    result.add(digits[(ord(ch) shr 4) and 0x0f])
    result.add(digits[ord(ch) and 0x0f])

proc traceSessionId(session: Session): string =
  if session.remotePublicKey.len != 32: return "-"
  traceId(session.sessionId())

proc traceDescriptor(value: SyrupValue): string =
  if value.kind != skRecord or value.label.kind != skSymbol or value.fields.len != 1:
    return "-"
  if value.fields[0].kind != skInteger:
    return value.label.data & ":?"
  value.label.data & ":" & (if value.fields[0].negative: "-" else: "") &
    value.fields[0].magnitude

proc traceMessage(session: Session; direction: TraceDirection; message: SyrupValue) =
  if session.traceSink.isNil: return
  inc session.traceSequence
  var target = "-"
  var answer = "-"
  if message.kind == skRecord:
    if message.fields.len > 0: target = traceDescriptor(message.fields[0])
    if message.label.kind == skSymbol and message.label.data == "op:gc-exports" and
        message.fields.len == 2 and message.fields[0].kind == skList and
        message.fields[1].kind == skList:
      target = "gc:"
      for index, item in message.fields[0].items:
        if index > 0: target.add(",")
        target.add(traceDescriptor(record(symbol("id"), item)))
        if index < message.fields[1].items.len:
          target.add("/" & traceDescriptor(record(symbol("delta"),
            message.fields[1].items[index])))
    if message.label.kind == skSymbol and message.label.data == "op:deliver":
      if message.fields.len > 2: answer = traceDescriptor(message.fields[2])
      if message.fields.len > 3: answer = traceDescriptor(message.fields[3]) & "/" & answer
    elif message.label.kind == skSymbol and message.label.data == "op:listen" and
        message.fields.len > 1:
      answer = traceDescriptor(message.fields[1])
  session.traceSink(TraceEvent(number: session.traceSequence,
    monotonicSeconds: getMonoTime().ticks.float / 1_000_000_000.0,
    nodeId: session.traceNodeId, sessionId: session.traceSessionId(),
    direction: direction,
    operation: if message.kind == skRecord and message.label.kind == skSymbol:
      message.label.data else: "invalid",
    target: target, answer: answer, bytes: message.encoded().len,
    promiseState: "-", ownership: "-"))

proc traceLifecycle*(session: Session; operation, target, state, ownership: string) =
  if session.traceSink.isNil: return
  inc session.traceSequence
  session.traceSink(TraceEvent(number: session.traceSequence,
    monotonicSeconds: getMonoTime().ticks.float / 1_000_000_000.0,
    nodeId: session.traceNodeId, sessionId: session.traceSessionId(),
    direction: tdOut, operation: operation, target: target, answer: "-", bytes: 0,
    promiseState: state, ownership: ownership))

proc traceProtocol(session: Session; operation, target, state, detail: string) =
  if session.traceSink.isNil: return
  inc session.traceSequence
  session.traceSink(TraceEvent(number: session.traceSequence,
    monotonicSeconds: getMonoTime().ticks.float / 1_000_000_000.0,
    nodeId: session.traceNodeId, sessionId: session.traceSessionId(),
    direction: tdIn, operation: operation, target: target, answer: "-", bytes: 0,
    promiseState: state, ownership: detail))

proc traceArgumentShape(value: SyrupValue): string =
  case value.kind
  of skSymbol: "symbol"
  of skString: "string(len=" & $value.data.len & ")"
  of skBytes: "bytes(len=" & $value.data.len & ")"
  of skList: "list(len=" & $value.items.len & ")"
  of skRecord: "record"
  of skDict: "dict(len=" & $value.pairs.len & ")"
  of skSet: "set(len=" & $value.elements.len & ")"
  else: $value.kind

proc traceArgumentShapes(session: Session; target: string; args: seq[SyrupValue]) =
  var shapes = ""
  for index, value in args:
    if index > 0: shapes.add(",")
    shapes.add(traceArgumentShape(value))
  session.traceProtocol("dispatch:args", target, "received",
    "count=" & $args.len & ",shapes=[" & shapes & "]")

proc validateSessionLimits*(limits: SessionLimits) =
  if limits.maxFrameBytes <= 0:
    raise newException(SessionError, "maxFrameBytes must be positive")
  if limits.maxPendingPromises < 0 or limits.maxExports < 0 or limits.maxImports < 0:
    raise newException(SessionError, "session limits must not be negative")
  if limits.maxOutboundBytes <= 0:
    raise newException(SessionError, "maxOutboundBytes must be positive")

proc send*(session: Session; message: SyrupValue)


proc forwardedSessionIdentity(session: Session): string =
  session.localPublicKey & "/" & session.remotePublicKey

proc forwardedPromiseKey(session: Session; reference: CapabilityRef): ForwardedPromiseKey =
  ForwardedPromiseKey(sessionIdentity: session.forwardedSessionIdentity(),
    reference: reference.referenceKey())

proc findForwardedOrigin*(registry: ForwardedPromiseRegistry;
                         remotePublicKey: string;
                         reference: CapabilityRef): ForwardedPromiseOrigin =
  let wanted = (if reference.kind == rkImportPromise:
      exportRef(reference.position) else: reference).referenceKey()
  let suffix = "/" & remotePublicKey
  for key, origin in registry.origins:
    if key.reference == wanted and key.sessionIdentity.endsWith(suffix):
      return origin

proc newBaseSession(transport: Transport; seed: string; limits: SessionLimits;
                    verificationPolicy: PeerVerificationPolicy;
                    firstExport: int64; glowcapV1: bool): Session =
  if seed.len != 32: raise newException(SessionError, "session seed must be 32 bytes")
  validateSessionLimits(limits)
  validatePolicy(verificationPolicy)
  let actualPublicKey = crypto.publicKey(seed)
  result = Session(transport: transport, state: ssNegotiating, identityVerified: false,
    peerVerified: false, verificationPolicy: verificationPolicy,
    localPublicKey: actualPublicKey,
    localSecret: seed,
    references: initReferenceTables(firstExport), outboundDescriptorUses: initTable[int64, int64](), nextAnswer: 0,
    freeAnswers: @[],
    glowcapV1: glowcapV1,
    publications: initTable[string, CapabilityRef](), pending: initTable[int64, Promise](),
    answers: initTable[int64, int64](),
    inboundAnswers: initTable[int64, bool](),
    resolvedAnswers: initTable[int64, SyrupValue](),
    brokenAnswers: initTable[int64, string](),
    pipelines: initTable[int64, seq[PipelineRequest]](),
    forwardedRegistry: ForwardedPromiseRegistry(
      origins: initTable[ForwardedPromiseKey, ForwardedPromiseOrigin](),
      retired: initTable[ForwardedPromiseKey, string]()),
    actors: initTable[int64, ActorBehavior](),
    promiseSlots: initTable[int64, PromiseSlot](),
    answerSlots: initTable[int64, PromiseSlot](),
    listenerLifecycles: initTable[ReferenceKey, ListenerLifecycle](),
    listenerGcSent: initTable[ReferenceKey, bool](),
    listenerResolverExports: initTable[int64, bool](),
    listenerResolverDone: initTable[int64, bool](),
    retiredListenerResolvers: initTable[int64, bool](),
    seenHandoffCounts: initTable[int64, bool](),
    gifts: newGiftTable(),
    ownsGifts: true,
    giftPromises: @[],
    activeAnswerPosition: -1,
    activeListenMode: 3,
    deferredAnswers: initTable[int64, bool](),
    decoder: newFrameDecoder(limits.maxFrameBytes), limits: limits)
  if transport of TcpTransport:
    TcpTransport(transport).maxOutputBytes = limits.maxOutboundBytes


proc newSession*(transport: Transport; seed = "";
                 location = "nim://in-memory";
                 limits = defaultSessionLimits();
                 verificationPolicy = testingOnlyPeerPolicy): Session =
  let actualSeed = if seed.len == 0: freshSessionSeed() else: seed
  result = newBaseSession(transport, actualSeed, limits, verificationPolicy, 0, false)
  let signature = crypto.sign(actualSeed, location)
  result.send(startSession(bytes(location), bytes(result.localPublicKey), bytes(signature)))
  result.sentHello = true

proc newGlowcapSession*(transport: Transport; seed = ""; hostPort = "";
                        limits = defaultSessionLimits();
                        verificationPolicy = testingOnlyPeerPolicy): Session =
  let actualSeed = if seed.len == 0: freshSessionSeed() else: seed
  result = newBaseSession(transport, actualSeed, limits, verificationPolicy, 1, true)
  let location = glowcapLocation(hostPort)
  let signedLocation = record(symbol("my-location"), location).encoded()
  let signature = crypto.sign(actualSeed, signedLocation)
  let hello = glowcapStartSession(location, glowcapPublicKey(result.localPublicKey), glowcapSignature(signature))
  result.send(hello)
  result.sentHello = true

proc exportObject*(session: Session; behavior: Behavior): CapabilityRef =
  if session.references.exportCount() >= session.limits.maxExports:
    raise newException(SessionError, "export table limit exceeded")
  session.references.allocateExport(behavior)

proc registerPendingPromise*(session: Session; position: int64; promise: Promise) =
  if session.pending.hasKey(position):
    raise newException(SessionError, "duplicate pending promise position")
  if session.pending.len >= session.limits.maxPendingPromises:
    session.diagnostic(dekResourceLimit, decResource, "pending promise limit exceeded")
    raise newException(SessionError, "pending promise limit exceeded")
  session.pending[position] = promise

proc unregisterPendingPromise*(session: Session; position: int64) =
  session.pending.del(position)

proc exportOwned*(session: Session; behavior: Behavior;
                  owner: ExportOwner): CapabilityRef =
  if session.references.exportCount() >= session.limits.maxExports:
    raise newException(SessionError, "export table limit exceeded")
  session.references.allocateExport(behavior, owner)

proc publishObject*(session: Session; name: string; behavior: Behavior): CapabilityRef =
  result = session.exportObject(behavior)
  session.publications[name] = result

proc exportActor*(session: Session; behavior: ActorBehavior): CapabilityRef =
  result = session.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
  session.actors[result.position] = behavior

proc exportListenerActor*(session: Session; behavior: ActorBehavior): CapabilityRef =
  result = session.exportOwned(proc(args: seq[SyrupValue]): SyrupValue = list(),
    eoListenerResolver)
  session.actors[result.position] = behavior
  session.listenerResolverExports[result.position] = true


proc retireListenerResolver(session: Session; position: int64) =
  if not session.listenerResolverExports.getOrDefault(position) or
      not session.listenerResolverDone.getOrDefault(position):
    return
  if not session.references.exports.hasKey(position) or
      session.references.exports[position].wireRefs != 0:
    return
  discard session.references.releaseExport(position)
  session.listenerResolverExports.del(position)
  session.listenerResolverDone.del(position)
  session.retiredListenerResolvers[position] = true

proc completeListenerResolver*(session: Session; reference: CapabilityRef) =
  if reference.kind != rkExport: return
  session.listenerResolverDone[reference.position] = true
  session.retireListenerResolver(reference.position)




proc publishActor*(session: Session; name: string; behavior: ActorBehavior): CapabilityRef =
  result = session.exportActor(behavior)
  session.publications[name] = result

proc depositGift*(session: Session; giftId, receiverKey: string; value: SyrupValue;
                  provenance = GiftProvenance()) =
  session.gifts.deposit(giftId, receiverKey, value, provenance,
    cast[pointer](session))

proc exportCapabilityProxy*(targetSession, sourceSession: Session;
                            sourceReference: CapabilityRef): CapabilityRef
proc exportLocalCapabilityProxy*(targetSession, sourceSession: Session;
                                 sourceReference: CapabilityRef): CapabilityRef

proc rehomeCapability*(targetSession, sourceSession: Session;
                       value: SyrupValue): SyrupValue =
  ## Convert a capability descriptor from sourceSession's namespace into a
  ## descriptor that is valid on targetSession's connection.
  let reference = value.descriptor()
  if targetSession == sourceSession:
    return reference.payloadDescriptor()
  let proxy = if reference.kind == rkExport:
      targetSession.exportLocalCapabilityProxy(sourceSession, reference)
    elif reference.kind == rkImportObject:
      targetSession.exportCapabilityProxy(sourceSession, reference)
    else:
      raise newException(SessionError, "cannot rehome a non-object capability")
  targetSession.traceLifecycle("capability:rehome",
    $reference.kind & ":" & $reference.position, "mapped",
    "source=" & sourceSession.sessionId())
  proxy.payloadDescriptor()

proc mapGiftCapability(session: Session; value: SyrupValue; owner: pointer): SyrupValue =
  let reference = try: value.descriptor()
                  except ReferenceError: return value
  if reference.kind notin {rkImportObject, rkExport} or owner.isNil:
    return value
  let sourceSession = cast[Session](owner)
  if sourceSession.isNil or sourceSession.state == ssClosed:
    raise newException(SessionError, "gift capability owner session is closed")
  if sourceSession == session:
    return if reference.kind == rkExport:
        importObject(reference.position).descriptor()
      else:
        exportRef(reference.position).descriptor()
  let proxy = if reference.kind == rkExport:
      session.exportLocalCapabilityProxy(sourceSession, reference)
    else:
      session.exportCapabilityProxy(sourceSession, reference)
  proxy.payloadDescriptor()

proc withdrawGift*(session: Session; giftId, receiverKey: string;
                   provenance = GiftProvenance()): Promise =
  result = session.gifts.withdraw(giftId, receiverKey, provenance,
    proc(value: SyrupValue; owner: pointer): SyrupValue =
      session.mapGiftCapability(value, owner))
  session.giftPromises.add(result)
  result.onSettle(proc(promise: Promise) =
    for index, tracked in session.giftPromises:
      if tracked == promise:
        session.giftPromises.delete(index)
        break)

proc sideId*(publicKey: string): string =
  if publicKey.len != 32:
    raise newException(SessionError, "session public key must be 32 bytes")
  let encodedKey = glowcapPublicKey(publicKey).encoded()
  crypto.sha256(crypto.sha256(encodedKey))

proc localSideId*(session: Session): string = sideId(session.localPublicKey)

proc remoteSideId*(session: Session): string =
  if session.remotePublicKey.len != 32:
    raise newException(SessionError, "remote session identity is not available")
  sideId(session.remotePublicKey)

proc verifyPeerPolicy(session: Session): bool =
  if session.enforceExpectedPeer:
    try:
      let encodedLocation = decoded(session.remoteLocation)
      let advertised = if encodedLocation.kind in {skBytes, skString}:
          parsePeerUri(encodedLocation.data)
        else:
          peerLocator(encodedLocation)
      if not samePeer(session.expectedPeer, advertised):
        raise newException(SessionError, "remote locator does not match expected peer")
    except LocatorError:
      raise newException(SessionError, "remote peer did not advertise a valid locator")
  case session.verificationPolicy.mode
  of pvmTestingOnly:
    false
  of pvmExactIdentity:
    if session.verificationPolicy.expectedPublicKey != session.remotePublicKey:
      raise newException(SessionError, "unexpected peer identity")
    true
  of pvmAuthenticatedNetlayer:
    let evidence = session.transport.authenticationEvidence()
    if evidence.peerIdentity.len == 0 and
        not session.transport.bindPeerIdentity(session.remotePublicKey):
      raise newException(SessionError, "authenticated netlayer cannot bind CapTP identity")
    let boundEvidence = session.transport.authenticationEvidence()
    if not boundEvidence.authenticated or not boundEvidence.channelIntegrity or
        boundEvidence.proofType != externalAuthenticatedChannel or
        boundEvidence.peerIdentity.len != 32 or
        boundEvidence.peerIdentity != session.remotePublicKey or
        session.verificationPolicy.transportVerifier.isNil or
        not session.verificationPolicy.transportVerifier(boundEvidence, session.remotePublicKey):
      raise newException(SessionError, "authenticated netlayer identity is unavailable")
    session.transportAuthenticated = true
    true

proc isPeerVerified*(session: Session): bool =
  session.peerVerified

proc isTransportAuthenticated*(session: Session): bool =
  session.transportAuthenticated

proc setExpectedPeer*(session: Session; peer: PeerLocator; enforce = true) =
  discard peer.peerSyrup()
  session.expectedPeer = peer
  session.enforceExpectedPeer = enforce

proc sessionId*(session: Session): string =
  let local = session.localSideId()
  let remote = session.remoteSideId()
  let ordered = if local <= remote: local & remote else: remote & local
  crypto.sha256(crypto.sha256("prot0" & ordered))

proc callbackMessage*(session: Session; target: SyrupValue;
                      args: openArray[SyrupValue]): SyrupValue
proc responseTarget*(resolver: CapabilityRef): CapabilityRef
proc flushPipelines(session: Session; answerPosition: int64)
proc sendFulfillment(session: Session; resolver, value: SyrupValue;
                     listenMode: int64; legacy: bool)
proc retainOutboundCapability(session: Session; value: SyrupValue)
proc settleAnswerSlot(session: Session; position: int64; args: seq[SyrupValue])

proc signLocal*(session: Session; payload: string): string =
  crypto.sign(session.localSecret, payload)

proc deferAnswer*(session: Session): AnswerContext =
  if session.activeResolver.isNil:
    raise newException(SessionError, "no active answer to defer")
  result = AnswerContext(answerPosition: session.activeAnswerPosition,
    resolver: session.activeResolver, listenMode: session.activeListenMode)
  session.deferredAnswers[result.answerPosition] = true

proc hasActiveAnswer*(session: Session): bool = not session.activeResolver.isNil

proc usesGlowcapV1*(session: Session): bool = session.glowcapV1

proc gcResolverWire(session: Session; resolver: SyrupValue)

proc fulfillAnswer*(session: Session; context: AnswerContext; value: SyrupValue) =
  if context.answerPosition >= 0:
    session.resolvedAnswers[context.answerPosition] = value
    if session.answerSlots.hasKey(context.answerPosition):
      session.settleAnswerSlot(context.answerPosition, @[symbol("fulfill"), value])
  session.sendFulfillment(context.resolver, value, context.listenMode, false)
  session.gcResolverWire(context.resolver)
  if context.answerPosition >= 0:
    session.flushPipelines(context.answerPosition)

proc breakAnswer*(session: Session; context: AnswerContext; reason: string) =
  if context.answerPosition >= 0:
    session.brokenAnswers[context.answerPosition] = reason
    if session.answerSlots.hasKey(context.answerPosition):
      session.settleAnswerSlot(context.answerPosition,
        @[symbol("break"), text(reason)])
  session.send(session.callbackMessage(
    responseTarget(context.resolver.descriptor()).descriptor(),
    [symbol("break"), text(reason)]))
  session.gcResolverWire(context.resolver)
  if context.answerPosition >= 0:
    session.flushPipelines(context.answerPosition)

proc isPromiseDescriptor(value: SyrupValue): bool =
  value.kind == skRecord and value.label.kind == skSymbol and
    value.label.data in ["desc:import-promise", "desc:answer"]

proc sendFulfillment(session: Session; resolver, value: SyrupValue;
                     listenMode: int64; legacy: bool) =
  session.retainOutboundCapability(value)
  if not isPromiseDescriptor(value):
    if legacy or listenMode in [2'i64, 3'i64]:
      let message = if legacy:
          deliverV1Callback(responseTarget(resolver.descriptor()).descriptor(),
            [symbol("fulfill"), value])
        else:
          session.callbackMessage(responseTarget(resolver.descriptor()).descriptor(),
            [symbol("fulfill"), value])
      session.send(message)
    return
  if listenMode in [1'i64, 3'i64]:
    session.send(session.callbackMessage(responseTarget(resolver.descriptor()).descriptor(),
      [symbol("fulfill"), value]))

proc notifyListener(session: Session; slot: PromiseSlot; listener: PromiseListener)
proc accountOutboundExport*(session: Session; reference: CapabilityRef)

proc queuePipelineRequest(session: Session; position: int64;
                         request: PipelineRequest) =
  var queued = 0
  for requests in session.pipelines.values:
    queued += requests.len
  if queued >= session.limits.maxPendingPromises:
    session.diagnostic(dekResourceLimit, decResource,
      "pipeline request limit exceeded")
    raise newException(SessionError, "pipeline request limit exceeded")
  session.pipelines.mgetOrPut(position, @[]).add(request)

proc executePipelineRequest(session: Session; capability: SyrupValue;
                            request: PipelineRequest)


proc listenerLifecycle(session: Session; resolver: SyrupValue;
                       mode: int64): ListenerLifecycle =
  let reference = resolver.descriptor()
  if reference.kind notin {rkImportObject, rkImportPromise, rkExport}:
    raise newException(SessionError, "invalid op:listen resolver reference")
  let key = reference.referenceKey()
  if session.listenerLifecycles.hasKey(key):
    result = session.listenerLifecycles[key]
  else:
    result = ListenerLifecycle(resolverKey: key, resolverPosition: reference.position)
    session.listenerLifecycles[key] = result
  if mode in [1'i64, 3'i64] and result.shorteningActive: return nil
  if mode in [2'i64, 3'i64] and result.settlingActive: return nil
  if mode in [1'i64, 3'i64]:
    result.shorteningActive = true
  if mode in [2'i64, 3'i64]:
    result.settlingActive = true

proc maybeGcListener(session: Session; lifecycle: ListenerLifecycle) =
  if lifecycle.isNil or lifecycle.gcSent or lifecycle.shorteningActive or
      lifecycle.settlingActive:
    return
  lifecycle.callbackComplete = true
  if session.listenerGcSent.hasKey(lifecycle.resolverKey):
    session.listenerLifecycles.del(lifecycle.resolverKey)
    return
  lifecycle.gcSent = true
  session.listenerGcSent[lifecycle.resolverKey] = true
  session.traceLifecycle("listener:gc", $lifecycle.resolverPosition,
    "complete", "listener-resolver")
  session.send(gcExports([lifecycle.resolverPosition], [1'i64]))
  session.listenerLifecycles.del(lifecycle.resolverKey)

proc finishListenerMode(session: Session; listener: PromiseListener;
                        shortening, settling: bool) =
  if listener.lifecycle.isNil: return
  if shortening: listener.lifecycle.shorteningActive = false
  if settling: listener.lifecycle.settlingActive = false
  session.maybeGcListener(listener.lifecycle)

proc addPromiseListener(session: Session; position: int64;
                        listener: PromiseListener): bool =
  if not session.promiseSlots.hasKey(position): return false
  var slot = session.promiseSlots[position]
  if not slot.pending:
    session.notifyListener(slot, listener)
    return true
  slot.listeners.add(listener)
  session.promiseSlots[position] = slot
  true

proc continueSettlingListener(session: Session; value: SyrupValue;
                              listener: PromiseListener): bool =
  if not isPromiseDescriptor(value): return false
  try:
    let next = value.descriptor()
    if next.kind == rkImportPromise:
      return session.addPromiseListener(next.position,
        PromiseListener(resolver: listener.resolver, mode: 2,
          lifecycle: listener.lifecycle))
  except CatchableError:
    discard
  false

proc notifyListener(session: Session; slot: PromiseSlot; listener: PromiseListener) =
  if slot.broken:
    if listener.mode != 1:
      session.send(session.callbackMessage(
        responseTarget(listener.resolver.descriptor()).descriptor(),
        [symbol("break"), slot.reason]))
    session.finishListenerMode(listener, true, listener.mode in [2'i64, 3'i64])
  elif isPromiseDescriptor(slot.value) and listener.mode in [1'i64, 3'i64]:
    try:
      let valueReference = slot.value.descriptor()
      if valueReference.kind in {rkImportObject, rkImportPromise}:
        session.accountOutboundExport(exportRef(valueReference.position))
    except ReferenceError:
      discard
    session.send(session.callbackMessage(
      responseTarget(listener.resolver.descriptor()).descriptor(),
      [symbol("fulfill"), slot.value]))
    session.finishListenerMode(listener, true, listener.mode == 3)
  elif isPromiseDescriptor(slot.value) and listener.mode == 2:
    let continued = session.continueSettlingListener(slot.value, listener)
    if not continued: session.finishListenerMode(listener, false, true)
  elif not isPromiseDescriptor(slot.value) and listener.mode == 1:
    session.finishListenerMode(listener, true, false)
  elif not isPromiseDescriptor(slot.value) and listener.mode in [2'i64, 3'i64]:
    session.send(session.callbackMessage(
      responseTarget(listener.resolver.descriptor()).descriptor(),
      [symbol("fulfill"), slot.value]))
    session.finishListenerMode(listener, listener.mode == 3, true)

proc settlePromiseSlot(session: Session; position: int64; args: seq[SyrupValue]) =
  if not session.promiseSlots.hasKey(position) or args.len != 2 or
      args[0].kind != skSymbol or args[0].data notin ["fulfill", "break"]:
    raise newException(SessionError, "invalid promise resolver operation")
  var slot = session.promiseSlots[position]
  if not slot.pending: return
  slot.pending = false
  slot.broken = args[0].data == "break"
  if slot.broken:
    slot.reason = args[1]
  else:
    slot.value = args[1]
  for listener in slot.listeners:
    session.notifyListener(slot, listener)
  slot.listeners.setLen(0)
  session.promiseSlots[position] = slot
  session.flushPipelines(position)

proc settleAnswerSlot(session: Session; position: int64; args: seq[SyrupValue]) =
  if not session.answerSlots.hasKey(position) or args.len != 2 or
      args[0].kind != skSymbol or args[0].data notin ["fulfill", "break"]:
    raise newException(SessionError, "invalid answer resolver operation")
  var slot = session.answerSlots[position]
  if not slot.pending: return
  slot.pending = false
  slot.broken = args[0].data == "break"
  if slot.broken:
    slot.reason = args[1]
  else:
    slot.value = args[1]
  for listener in slot.listeners:
    session.notifyListener(slot, listener)
  slot.listeners.setLen(0)
  session.answerSlots[position] = slot
  session.flushPipelines(position)

proc newPromisePair*(session: Session): tuple[vow, resolver: CapabilityRef] =
  var vowPosition = -1'i64
  result.vow = session.exportActor(proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
    list())
  vowPosition = result.vow.position
  session.promiseSlots[vowPosition] = PromiseSlot(pending: true)
  result.resolver = session.exportActor(proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
    actorSession.settlePromiseSlot(vowPosition, args)
    list())

proc registerForwardedPromise*(session: Session; local: CapabilityRef;
                               sourceSession: Session; source: Promise) =
  if local.kind != rkExport or source.isNil:
    raise newException(SessionError, "invalid forwarded promise origin")
  session.forwardedRegistry.origins[session.forwardedPromiseKey(local)] = ForwardedPromiseOrigin(
    sourceSession: sourceSession, sourcePromise: source, targetWireRefs: 1,
    hasSourceReference: false)

proc retain*(session: Session; reference: CapabilityRef)

proc registerForwardedPromiseReference*(session: Session; local: CapabilityRef;
                                        sourceSession: Session;
                                        sourceReference: CapabilityRef;
                                        source: Promise) =
  if local.kind != rkExport or source.isNil or
      sourceReference.kind notin {rkImportObject, rkImportPromise, rkExport}:
    raise newException(SessionError, "invalid forwarded promise reference")
  session.forwardedRegistry.origins[session.forwardedPromiseKey(local)] =
    ForwardedPromiseOrigin(sourceSession: sourceSession,
      sourcePromise: source, sourceReference: sourceReference,
      hasSourceReference: true, sourceWireRefs: 0, targetWireRefs: 1)
  session.traceLifecycle("forward:register", $local.position,
    "pending", $sourceReference.kind & ":" & $sourceReference.position &
      ",origins=" & $session.forwardedRegistry.origins.len &
      ",registry=" & $cast[uint](session.forwardedRegistry))



proc release*(session: Session; reference: CapabilityRef)

proc accountOutboundExport*(session: Session; reference: CapabilityRef) =
  ## allocateExport supplies the first wire reference; later descriptor sends add refs.
  if reference.kind != rkExport or not session.references.exports.hasKey(reference.position):
    return
  let uses = session.outboundDescriptorUses.getOrDefault(reference.position)
  if uses > 0 or session.references.exports[reference.position].wireRefs == 0:
    session.references.retainExport(reference.position)
  session.outboundDescriptorUses[reference.position] = uses + 1
  session.traceLifecycle("reference:wire-retain", $reference.position, "-",
    "wire=" & $session.references.exports[reference.position].wireRefs)

proc retainOutboundCapability(session: Session; value: SyrupValue) =
  let reference = try: value.descriptor()
                  except ReferenceError: return
  if reference.kind notin {rkImportObject, rkImportPromise} or
      not session.references.exports.hasKey(reference.position):
    return
  session.references.retainExport(reference.position)
  session.traceLifecycle("reference:wire-retain", $reference.position,
    "result", "wire=" & $session.references.exports[reference.position].wireRefs)

proc maybeRetireForwardedPromise(session: Session; local: CapabilityRef;
                                 origin: ForwardedPromiseOrigin) =
  if origin.isNil or not origin.settled or origin.targetWireRefs != 0 or
      origin.sourceWireRefs != 0:
    return
  if origin.latePipelineActive != 0:
    return
  var retiredKey = false
  if origin.broken and origin.reason.len > 0:
    if session.forwardedRegistry.retired.len == 0:
      session.forwardedRegistry.retired = initTable[ForwardedPromiseKey, string]()
    let retireKey = session.forwardedPromiseKey(local)
    session.forwardedRegistry.retired[retireKey] = origin.reason
    retiredKey = session.forwardedRegistry.retired.hasKey(retireKey)
  let retireDetail = origin.reason & ",retired=" & $session.forwardedRegistry.retired.len &
    ",has=" & $retiredKey & ",registry=" & $cast[uint](session.forwardedRegistry)
  session.traceLifecycle("forward:retire", $local.position,
    if origin.broken: "broken" else: "settled", retireDetail)
  session.forwardedRegistry.origins.del(session.forwardedPromiseKey(local))

proc releaseForwardedSourceWire(session: Session; local: CapabilityRef;
                                origin: ForwardedPromiseOrigin) =
  if origin.isNil or origin.targetWireRefs != 0 or origin.sourceWireRefs == 0:
    return
  if origin.sourceSession.state != ssClosed:
    try: origin.sourceSession.release(origin.sourceReference)
    except CatchableError: discard
  origin.sourceWireRefs = 0
  session.maybeRetireForwardedPromise(local, origin)

proc settleForwardedPromise*(session: Session; local: CapabilityRef;
                            source: Promise) =
  let origin = session.forwardedRegistry.origins.getOrDefault(session.forwardedPromiseKey(local))
  if origin.isNil or origin.sourcePromise != source: return
  origin.settled = true
  origin.broken = source.state == psBroken
  origin.reason = if origin.broken:
      if source.reason.len > 0: source.reason else: "forwarded source promise broken"
    else:
      source.reason
  if source.state == psFulfilled:
    try:
      origin.sourceReference = source.value.descriptor()
      if origin.sourceReference.kind in {rkImportObject, rkImportPromise} and
          (not origin.hasSourceReference or origin.sourceWireRefs > 0):
        origin.sourceWireRefs = 1
        session.releaseForwardedSourceWire(local, origin)
      else:
        session.maybeRetireForwardedPromise(local, origin)
    except ReferenceError: discard

proc forwardedWireRefs*(session: Session; local: CapabilityRef): int64 =
  let origin = session.forwardedRegistry.origins.getOrDefault(session.forwardedPromiseKey(local))
  if origin.isNil: return 0
  origin.targetWireRefs

proc settlePromise*(session: Session; promise: CapabilityRef; value: SyrupValue) =
  if promise.kind != rkExport or not session.promiseSlots.hasKey(promise.position):
    raise newException(SessionError, "unknown local promise")
  session.settlePromiseSlot(promise.position, @[symbol("fulfill"), value])
  session.traceLifecycle("promise:settle", $promise.position, "fulfilled", "application")

proc breakPromise*(session: Session; promise: CapabilityRef; reason: string) =
  if promise.kind != rkExport or not session.promiseSlots.hasKey(promise.position):
    raise newException(SessionError, "unknown local promise")
  session.settlePromiseSlot(promise.position, @[symbol("break"), text(reason)])
  session.traceLifecycle("promise:settle", $promise.position, "broken", "application")

proc promisePayloadDescriptor*(session: Session; reference: CapabilityRef): SyrupValue =
  if reference.kind == rkExport and session.promiseSlots.hasKey(reference.position):
    session.accountOutboundExport(reference)
    return importPromise(reference.position).descriptor()
  session.accountOutboundExport(reference)
  reference.payloadDescriptor()

proc retain*(session: Session; reference: CapabilityRef) =
  case reference.kind
  of rkImportObject, rkImportPromise:
    if session.references.importCount() >= session.limits.maxImports and
        session.references.importRefCount(reference.position) == 0:
      raise newException(SessionError, "import table limit exceeded")
    session.references.retainImport(reference.position)
  else:
    raise newException(SessionError, "only imported capabilities can be retained")

proc release*(session: Session; reference: CapabilityRef) =
  session.traceLifecycle("reference:release", $reference.kind & ":" & $reference.position,
    "-", "wire")
  case reference.kind
  of rkImportObject, rkImportPromise:
    if not session.references.releaseImport(reference.position):
      raise newException(SessionError, "unknown or released import position " & $reference.position)
    session.send(gcExports([reference.position], [1'i64]))
  of rkExport:
    if not session.references.releaseExport(reference.position):
      raise newException(SessionError, "unknown or released export position " & $reference.position)
  else:
    raise newException(SessionError, "answer references are released with their promise")

proc releaseAnswerResolver(session: Session; position: int64) =
  if not session.references.exports.hasKey(position): return
  if session.references.exports[position].owner != eoAnswerResolver: return
  discard session.references.releaseExport(position)

proc gcResolverWire(session: Session; resolver: SyrupValue) =
  let reference = try: resolver.descriptor()
                  except ReferenceError: return
  if reference.kind in {rkExport, rkImportObject, rkImportPromise} and
      session.state != ssClosed:
    session.send(gcExports([reference.position], [1'i64]))

proc recycleAnswerPosition(session: Session; position: int64) =
  if position >= 0 and position notin session.freeAnswers:
    session.freeAnswers.add(position)

proc responseTarget*(resolver: CapabilityRef): CapabilityRef =
  case resolver.kind
  of rkExport: reference(rkImportObject, resolver.position)
  of rkImportObject: reference(rkExport, resolver.position)
  of rkImportPromise, rkAnswer: resolver

proc send*(session: Session; message: SyrupValue) =
  session.traceMessage(tdOut, message)
  session.transport.send(frame(message.encoded()))

proc voidValue(): SyrupValue = list()

proc collectDeliveryImports(value: SyrupValue; counts: var Table[int64, int64]) =
  case value.kind
  of skRecord:
    if value.label.kind == skSymbol and
        value.label.data in ["desc:import-object", "desc:import-promise"] and
        value.fields.len == 1 and value.fields[0].kind == skInteger and
        not value.fields[0].negative:
      try:
        let position = parseInt(value.fields[0].magnitude)
        counts[position] = counts.getOrDefault(position) + 1
      except ValueError:
        raise newException(SessionError, "invalid delivery import position")
    else:
      for field in value.fields:
        collectDeliveryImports(field, counts)
  of skList:
    for item in value.items:
      collectDeliveryImports(item, counts)
  of skSet:
    for item in value.elements:
      collectDeliveryImports(item, counts)
  of skDict:
    for item in value.pairs:
      collectDeliveryImports(item.key, counts)
      collectDeliveryImports(item.value, counts)
  else:
    discard

proc releaseDeliveryImports(session: Session; args: SyrupValue) =
  if not session.glowcapV1 or args.kind != skList: return
  var counts = initTable[int64, int64]()
  # A resolver callback transfers its fulfillment value into the promise. The
  # resolver retains that value before this cleanup runs; do not release the
  # same descriptor as a temporary delivery import.
  let resolution = args.items.len > 0 and args.items[0].kind == skSymbol and
      args.items[0].data in ["fulfill", "break"]
  for index, value in args.items:
    if resolution and index == 1: continue
    collectDeliveryImports(value, counts)
  if counts.len == 0: return
  var positions, deltas: seq[int64]
  for position, count in counts:
    positions.add(position)
    deltas.add(count)
  session.send(gcExports(positions, deltas))

proc callbackMessage*(session: Session; target: SyrupValue;
                      args: openArray[SyrupValue]): SyrupValue =
  if session.glowcapV1:
    deliverV1Callback(target, args)
  else:
    deliverOnly(target, args)

proc sendCall(session: Session; target: CapabilityRef; callArgs: openArray[SyrupValue]): Promise =
  if session.state != ssOpen:
    raise newException(SessionError, "cannot call before handshake completes")
  if session.pending.len >= session.limits.maxPendingPromises:
    session.diagnostic(dekResourceLimit, decResource, "pending promise limit exceeded")
    raise newException(SessionError, "pending promise limit exceeded")
  let promise = newPromise()
  result = promise
  var resolverPosition = -1'i64
  var answerPosition = -1'i64
  let resolver = exportOwned(session, proc(values: seq[SyrupValue]): SyrupValue =
    if values.len != 2 or values[0].kind != skSymbol:
      raise newException(SessionError, "invalid promise resolution")
    if promise.cancelled:
      if session.answers.getOrDefault(answerPosition, -1'i64) == resolverPosition:
        session.pending.del(resolverPosition)
        session.releaseAnswerResolver(resolverPosition)
        session.answers.del(answerPosition)
        if session.state != ssClosed:
          session.send(gcAnswers([answerPosition]))
        session.recycleAnswerPosition(answerPosition)
      return voidValue()
    case values[0].data
    of "fulfill":
      if values[1].kind == skRecord and values[1].label.kind == skSymbol and
          values[1].label.data in ["desc:import-object", "desc:import-promise"]:
        session.retain(values[1].descriptor())
      promise.fulfill(values[1])
      session.pending.del(resolverPosition)
      session.releaseAnswerResolver(resolverPosition)
      session.answers.del(answerPosition)
      session.send(gcAnswers([answerPosition]))
      session.recycleAnswerPosition(answerPosition)
    of "break":
      if values[1].kind != skString: raise newException(SessionError, "invalid break reason")
      promise.breakPromise(values[1].data)
      session.pending.del(resolverPosition)
      session.releaseAnswerResolver(resolverPosition)
      session.answers.del(answerPosition)
      session.send(gcAnswers([answerPosition]))
      session.recycleAnswerPosition(answerPosition)
    else: raise newException(SessionError, "unknown promise resolution")
    voidValue(), eoAnswerResolver)
  resolverPosition = resolver.position
  session.accountOutboundExport(resolver)
  session.pending[resolver.position] = promise
  var answer: int64
  if session.freeAnswers.len > 0:
    answer = session.freeAnswers.pop()
  else:
    answer = session.nextAnswer
    inc session.nextAnswer
  answerPosition = answer
  promise.answerPosition = answer
  session.answers[answer] = resolver.position
  let resolverRef = if session.glowcapV1: importObject(resolver.position) else: resolver
  let message = if session.glowcapV1:
      deliverV1(target.targetDescriptor(), callArgs, answer, resolverRef.descriptor())
    else:
      deliver(target.targetDescriptor(), callArgs, answer, resolverRef.descriptor(), 3)
  session.send(message)

proc call*(session: Session; target: CapabilityRef; verb: string;
           args: openArray[SyrupValue]): Promise =
  if target.kind notin {rkExport, rkImportObject}:
    raise newException(SessionError, "prototype calls require an export descriptor")
  var callArgs = @[symbol(verb)]
  for arg in args: callArgs.add(arg)
  sendCall(session, target, callArgs)

proc deliverCall*(session: Session; target: CapabilityRef;
                  args: openArray[SyrupValue]): Promise =
  if target.kind notin {rkExport, rkImportObject, rkImportPromise}:
    raise newException(SessionError, "deliver target must be an object reference")
  sendCall(session, target, args)

proc exportCapabilityProxy*(targetSession, sourceSession: Session;
                            sourceReference: CapabilityRef): CapabilityRef =
  if sourceReference.kind notin {rkImportObject, rkExport}:
    raise newException(SessionError, "capability proxy requires an object reference")
  # The actor behavior is installed below on the allocated proxy export.
  result = targetSession.exportOwned(proc(values: seq[SyrupValue]): SyrupValue = list(),
    eoForwardedProxy)
  targetSession.actors[result.position] = proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    let answer = actor.deferAnswer()
    let forwarded = try:
      sourceSession.deliverCall(sourceReference, args)
    except CatchableError as error:
      actor.breakAnswer(answer, error.msg)
      return list()
    forwarded.onSettle(proc(result: Promise) =
      if actor.state == ssClosed: return
      if result.state == psFulfilled:
        actor.fulfillAnswer(answer, result.value)
      else:
        actor.breakAnswer(answer, result.reason))
    list()

proc exportLocalCapabilityProxy*(targetSession, sourceSession: Session;
                                 sourceReference: CapabilityRef): CapabilityRef =
  if sourceReference.kind != rkExport:
    raise newException(SessionError, "local capability proxy requires an export")
  let behavior = sourceSession.references.exportBehavior(sourceReference.position)
  if behavior.isNil:
    raise newException(SessionError, "cannot proxy an unknown local capability")
  result = targetSession.exportOwned(proc(values: seq[SyrupValue]): SyrupValue = list(),
    eoForwardedProxy)
  targetSession.actors[result.position] = proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    if sourceSession.actors.hasKey(sourceReference.position):
      sourceSession.actors[sourceReference.position](sourceSession, args)
    else:
      let behaviorArgs = if args.len > 0 and args[0].kind == skSymbol and
          args[0].data notin ["fulfill", "break"]:
        args[1 ..^ 1]
      else:
        args
      sourceSession.traceArgumentShapes("export:" & $sourceReference.position,
        behaviorArgs)
      behavior(behaviorArgs)

proc routeForwardedPipeline(session: Session; target: CapabilityRef;
                            args: seq[SyrupValue]; resolver: SyrupValue): bool =
  let lookup = if target.kind == rkImportPromise: exportRef(target.position) else: target
  let origin = session.forwardedRegistry.findForwardedOrigin(
    session.remotePublicKey, target)
  if origin.isNil:
    let reason = session.forwardedRegistry.retired.getOrDefault(
      session.forwardedPromiseKey(lookup))
    if reason.len > 0:
      session.traceLifecycle("forward:retired", $target.position, "broken", reason)
      session.send(session.callbackMessage(
        responseTarget(resolver.descriptor()).descriptor(),
        [symbol("break"), text(reason)]))
      session.gcResolverWire(resolver)
      return true
    var provenance = "origins=" & $session.forwardedRegistry.origins.len &
      ",retired=" & $session.forwardedRegistry.retired.len &
      ",registry=" & $cast[uint](session.forwardedRegistry)
    for key in session.forwardedRegistry.origins.keys:
      provenance.add(",ref=" & $key.reference.kind & ":" & $key.reference.position)
    session.traceLifecycle("forward:route-miss", $target.position, "pending", provenance)
    return false
  if origin.settled and origin.broken:
    let reason = if origin.reason.len > 0: origin.reason
                 else: "forwarded source promise broken"
    session.traceLifecycle("forward:retired", $target.position, "broken", reason)
    session.send(session.callbackMessage(
      responseTarget(resolver.descriptor()).descriptor(),
      [symbol("break"), text(reason)]))
    session.gcResolverWire(resolver)
    session.forwardedRegistry.origins.del(session.forwardedPromiseKey(lookup))
    return true
  if not origin.hasSourceReference or origin.sourceSession.state == ssClosed:
    let reason = if origin.reason.len > 0: origin.reason
                 else: "forwarded promise source disconnected"
    origin.settled = true
    origin.broken = true
    origin.reason = reason
    session.traceLifecycle("forward:source-closed", $target.position, "broken", reason)
    session.send(session.callbackMessage(
      responseTarget(resolver.descriptor()).descriptor(),
      [symbol("break"), text(reason)]))
    session.gcResolverWire(resolver)
    session.maybeRetireForwardedPromise(lookup, origin)
    return true
  session.traceLifecycle("forward:route-hit", $target.position, "pending",
    $origin.sourceReference.kind & ":" & $origin.sourceReference.position)
  origin.latePipelineSeen = true
  inc origin.latePipelineActive
  let forwarded = try:
    origin.sourceSession.deliverCall(origin.sourceReference, args)
  except CatchableError as error:
    dec origin.latePipelineActive
    session.send(session.callbackMessage(
      responseTarget(resolver.descriptor()).descriptor(),
      [symbol("break"), text(error.msg)]))
    session.gcResolverWire(resolver)
    session.maybeRetireForwardedPromise(lookup, origin)
    return true
  let response = responseTarget(resolver.descriptor()).descriptor()
  forwarded.onSettle(proc(result: Promise) =
    dec origin.latePipelineActive
    if session.state != ssClosed:
      if result.state == psFulfilled:
        session.send(session.callbackMessage(response,
          [symbol("fulfill"), result.value]))
        session.gcResolverWire(resolver)
      else:
        session.send(session.callbackMessage(response,
          [symbol("break"), text(result.reason)]))
        session.gcResolverWire(resolver)
    session.maybeRetireForwardedPromise(lookup, origin)
  )
  true

proc callPipelined*(session: Session; promise: Promise; verb: string;
                    args: openArray[SyrupValue]): Promise =
  if promise.isNil or promise.state != psPending or promise.answerPosition < 0:
    raise newException(SessionError, "can only pipeline through a pending promise")
  var callArgs = @[symbol(verb)]
  for arg in args: callArgs.add(arg)
  sendCall(session, reference(rkAnswer, promise.answerPosition), callArgs)

proc close*(session: Session; reason = "session closed") =
  if session.state == ssClosed: return
  session.diagnostic(dekSessionClosed, decNone, "session closed")
  session.traceLifecycle("session:close", "-", "closed",
    "registry=" & $cast[uint](session.forwardedRegistry))
  session.state = ssClosed
  var ownKeys: seq[ForwardedPromiseKey]
  for key, origin in session.forwardedRegistry.origins:
    if key.sessionIdentity != session.forwardedSessionIdentity(): continue
    ownKeys.add(key)
    if not origin.isNil and origin.sourceWireRefs > 0 and
        origin.sourceSession.state != ssClosed:
      try: origin.sourceSession.release(origin.sourceReference)
      except CatchableError: discard
      origin.sourceWireRefs = 0
  for _, promise in session.pending.mpairs:
    if not settled(promise): promise.breakPromise(reason)
  session.pending.clear()
  session.answers.clear()
  session.freeAnswers.setLen(0)
  session.inboundAnswers.clear()
  session.answerSlots.clear()
  session.resolvedAnswers.clear()
  session.brokenAnswers.clear()
  session.pipelines.clear()
  for key in ownKeys:
    session.forwardedRegistry.origins.del(key)
  session.references.exports.clear()
  session.outboundDescriptorUses.clear()
  session.references.imports.clear()
  session.publications.clear()
  session.actors.clear()
  session.promiseSlots.clear()
  session.listenerLifecycles.clear()
  session.listenerGcSent.clear()
  session.listenerResolverExports.clear()
  session.listenerResolverDone.clear()
  session.retiredListenerResolvers.clear()
  session.deferredAnswers.clear()
  session.activeResolver = nil
  session.activeAnswerPosition = -1
  session.seenHandoffCounts.clear()
  let giftPromises = session.giftPromises
  session.giftPromises.setLen(0)
  for promise in giftPromises:
    discard session.gifts.cancel(promise)
  if session.ownsGifts:
    session.gifts.clear()
  session.transport.close()

proc stats*(session: Session): SessionStats =
  result.pendingPromises = session.pending.len
  result.importCount = session.references.importCount()
  result.exportCount = session.references.exportCount()
  result.answerCount = session.answers.len
  result.inboundAnswerCount = session.inboundAnswers.len
  result.promiseSlotCount = session.promiseSlots.len
  result.promiseSlotCount += session.answerSlots.len
  result.listenerLifecycleCount = session.listenerLifecycles.len
  let giftStats = session.gifts.stats()
  result.depositedGifts = giftStats.deposited
  result.pendingGiftWithdraws = giftStats.pendingWithdraws
  for key in session.forwardedRegistry.origins.keys:
    if key.sessionIdentity == session.forwardedSessionIdentity():
      inc result.forwardedPromiseCount
  for slot in session.references.exports.values:
    if slot.owner == eoForwardedProxy and slot.live:
      inc result.forwardedProxyCount
  for slot in session.promiseSlots.values:
    result.promiseListenerCount += slot.listeners.len
  result.queuedBytes = session.transport.queuedBytes()

proc fetch*(session: Session; swissName: string): Promise =
  session.call(exportRef(0), "fetch", [bytes(swissName)])

proc pump*(session: Session): bool
proc cancel*(session: Session; promise: Promise; reason = "call cancelled"): bool

proc handshakeStarted*(session: Session): bool = session.sentHello
proc handshakeReceived*(session: Session): bool = session.sawHello

proc waitFor*(session: Session; promise: Promise; maxPumps = 10000): SyrupValue =
  if promise.isNil:
    raise newException(SessionError, "cannot wait for a nil promise")
  var remaining = maxPumps
  while not settled(promise):
    if remaining <= 0:
      discard session.cancel(promise, "call timeout")
      session.diagnostic(dekPromiseTimeout, decPromise, "promise wait timeout")
      raise newException(PromiseTimeoutError, "promise wait limit exceeded")
    discard session.pump()
    dec remaining
  if promise.state == psBroken:
    raise newException(SessionError, promise.reason)
  promise.value

proc cancel*(session: Session; promise: Promise;
             reason = "call cancelled"): bool =
  if promise.isNil or promise.state != psPending:
    return false
  session.diagnostic(dekPromiseCancellation, decPromise, "promise cancelled")
  var resolverPosition = -1'i64
  for position, pending in session.pending:
    if pending == promise:
      resolverPosition = position
      break
  if resolverPosition >= 0:
    session.pending.del(resolverPosition)
    session.releaseAnswerResolver(resolverPosition)
    for answer, resolver in session.answers:
      if resolver == resolverPosition:
        session.answers.del(answer)
        if session.state != ssClosed:
          session.send(gcAnswers([answer]))
        session.recycleAnswerPosition(answer)
        break
  promise.cancel(reason)

proc waitForTimeout*(session: Session; promise: Promise; timeoutMs: int): SyrupValue =
  if promise.isNil:
    raise newException(SessionError, "cannot wait for a nil promise")
  if timeoutMs < 0:
    raise newException(SessionError, "timeout must not be negative")
  let deadline = getMonoTime().ticks + int64(timeoutMs) * 1_000_000
  while not settled(promise):
    let remaining = deadline - getMonoTime().ticks
    if remaining <= 0:
      discard session.cancel(promise, "call timeout")
      session.diagnostic(dekPromiseTimeout, decPromise, "promise wait timeout")
      raise newException(PromiseTimeoutError, "promise wait timeout")
    let progressed = session.pump()
    if not progressed:
      let waitMs = min(1, int(remaining div 1_000_000))
      if waitMs > 0:
        discard session.transport.waitReadable(waitMs)
  if promise.state == psBroken:
    raise newException(SessionError, promise.reason)
  promise.value

proc processMessage(session: Session; message: SyrupValue)

proc validateHandoffValues(session: Session; value: SyrupValue) =
  case value.kind
  of skList, skSet:
    let values = if value.kind == skList: value.items else: value.elements
    for item in values:
      session.validateHandoffValues(item)
  of skDict:
    for item in value.pairs:
      session.validateHandoffValues(item.key)
      session.validateHandoffValues(item.value)
  of skRecord:
    if value.label.kind == skSymbol:
      case value.label.data
      of "desc:handoff-give":
        if not validHandoffGive(value):
          raise newException(SessionError, "invalid desc:handoff-give")
      of "desc:handoff-receive":
        if not validHandoffReceive(value):
          raise newException(SessionError, "invalid desc:handoff-receive")
        if value.fields[0].data != session.sessionId():
          raise newException(SessionError, "handoff receive session mismatch")
        if value.fields[1].data != session.remoteSideId():
          raise newException(SessionError, "handoff receive side mismatch")
        let count = try:
            parseInt(value.fields[2].magnitude)
          except ValueError:
            raise newException(SessionError, "invalid handoff count")
        if session.seenHandoffCounts.hasKey(count):
          raise newException(SessionError, "duplicate handoff count")
        session.seenHandoffCounts[count] = true
      of "desc:sig-envelope":
        if value.fields.len != 2:
          raise newException(SessionError, "invalid desc:sig-envelope")
        if value.fields[0].kind == skRecord and value.fields[0].label.kind == skSymbol and
            value.fields[0].label.data == "desc:handoff-give":
          if not validHandoffGive(value.fields[0]):
            raise newException(SessionError, "invalid signed handoff-give")
        elif value.fields[0].kind == skRecord and value.fields[0].label.kind == skSymbol and
            value.fields[0].label.data == "desc:handoff-receive":
          if not verifyHandoffReceive(value):
            raise newException(SessionError, "invalid signed handoff-receive")
        else:
          raise newException(SessionError, "invalid desc:sig-envelope object")
      else:
        discard
    for field in value.fields:
      session.validateHandoffValues(field)
  else:
    discard

proc flushPipelines(session: Session; answerPosition: int64) =
  if session.promiseSlots.hasKey(answerPosition):
    let slot = session.promiseSlots[answerPosition]
    if slot.pending or not session.pipelines.hasKey(answerPosition): return
    let queued = session.pipelines[answerPosition]
    session.pipelines.del(answerPosition)
    for request in queued:
      if slot.broken:
        let reason = if slot.reason.kind == skString: slot.reason.data
                     else: "promise broken"
        session.send(session.callbackMessage(
          responseTarget(request.resolver.descriptor()).descriptor(),
          [symbol("break"), text(reason)]))
        if request.answerPosition >= 0:
          session.brokenAnswers[request.answerPosition] = reason
          session.flushPipelines(request.answerPosition)
      else:
        session.executePipelineRequest(slot.value, request)
    return
  if session.answerSlots.hasKey(answerPosition):
    let slot = session.answerSlots[answerPosition]
    if slot.pending or not session.pipelines.hasKey(answerPosition): return
    let queued = session.pipelines[answerPosition]
    session.pipelines.del(answerPosition)
    for request in queued:
      if slot.broken:
        let reason = if slot.reason.kind == skString: slot.reason.data
                     else: "promise broken"
        session.send(session.callbackMessage(
          responseTarget(request.resolver.descriptor()).descriptor(),
          [symbol("break"), text(reason)]))
        if request.answerPosition >= 0:
          session.brokenAnswers[request.answerPosition] = reason
          session.flushPipelines(request.answerPosition)
      else:
        session.executePipelineRequest(slot.value, request)
    return
  if not session.pipelines.hasKey(answerPosition): return
  let queued = session.pipelines[answerPosition]
  session.pipelines.del(answerPosition)
  for request in queued:
    if session.brokenAnswers.hasKey(answerPosition):
      let reason = session.brokenAnswers[answerPosition]
      session.send(session.callbackMessage(responseTarget(request.resolver.descriptor()).descriptor(),
        [symbol("break"), text(reason)]))
      session.gcResolverWire(request.resolver)
      if request.answerPosition >= 0:
        session.brokenAnswers[request.answerPosition] = reason
        session.flushPipelines(request.answerPosition)
    else:
      let capability = session.resolvedAnswers[answerPosition]
      session.executePipelineRequest(capability, request)

proc executePipelineRequest(session: Session; capability: SyrupValue;
                            request: PipelineRequest) =
  let resolvedTarget = try: capability.descriptor()
                       except ReferenceError:
                         let reason = "pipeline result is not a capability"
                         session.send(session.callbackMessage(responseTarget(request.resolver.descriptor()).descriptor(),
                           [symbol("break"), text(reason)]))
                         session.gcResolverWire(request.resolver)
                         if request.answerPosition >= 0:
                           session.brokenAnswers[request.answerPosition] = reason
                           session.flushPipelines(request.answerPosition)
                         return
  let behavior = session.references.exportBehavior(resolvedTarget.position)

  if behavior.isNil:
    let reason = "pipeline resolved to unknown capability"
    session.send(session.callbackMessage(responseTarget(request.resolver.descriptor()).descriptor(),
      [symbol("break"), text(reason)]))
    session.gcResolverWire(request.resolver)
    if request.answerPosition >= 0:
      session.brokenAnswers[request.answerPosition] = reason
      session.flushPipelines(request.answerPosition)
    return
  let pipelineArgs = if request.args.len > 0 and request.args[0].kind == skSymbol:
      request.args[1 ..^ 1]
    else:
      request.args
  var reply: SyrupValue
  try:
    reply = if session.actors.hasKey(resolvedTarget.position):
        session.actors[resolvedTarget.position](session, pipelineArgs)
      else:
        behavior(pipelineArgs)
  except CatchableError as error:
    session.send(session.callbackMessage(responseTarget(request.resolver.descriptor()).descriptor(),
      [symbol("break"), text(error.msg)]))
    session.gcResolverWire(request.resolver)
    if request.answerPosition >= 0:
      session.brokenAnswers[request.answerPosition] = error.msg
      session.flushPipelines(request.answerPosition)
    return
  if request.answerPosition >= 0:
    session.resolvedAnswers[request.answerPosition] = reply
  session.send(session.callbackMessage(responseTarget(request.resolver.descriptor()).descriptor(),
    [symbol("fulfill"), reply]))
  session.gcResolverWire(request.resolver)
  if request.answerPosition >= 0:
    session.flushPipelines(request.answerPosition)

proc pumpImpl(session: Session): bool =
  let chunk = session.transport.receive()
  if chunk.len == 0:
    if session.transport.isClosed():
      session.diagnostic(dekTransportDisconnect, decTransport, "transport disconnected")
      session.close("transport disconnected")
    return false
  let frames = session.decoder.feed(chunk)
  if frames.len == 0: return false
  for wire in frames:
    if session.state == ssClosed: return true
    let message = decoded(wire)
    if message.kind != skRecord or message.label.kind != skSymbol:
      raise newException(SessionError, "session received a non-record message")
    if message.label.data == "op:start-session":
      if session.sawHello: raise newException(SessionError, "duplicate start-session")
      var verified = false
      if message.fields.len == 5 and message.fields[0].kind == skString and
          message.fields[0].data == "1.0" and message.fields[1].kind == skString and
          message.fields[1].data == "Ed25519_SHA256" and
          message.fields[2].kind == skBytes and message.fields[3].kind == skBytes and
          message.fields[4].kind == skBytes and message.fields[2].data.len == 32 and
          message.fields[4].data.len == 64:
        verified = crypto.verify(message.fields[2].data, message.fields[3].data, message.fields[4].data)
      elif message.fields.len == 4 and message.fields[0].kind == skString and
          message.fields[0].data == "1.0":
        let publicKey = message.fields[1].extractGlowcapPublicKey()
        let signature = message.fields[3].extractGlowcapSignature()
        if publicKey.len == 32 and signature.len == 64:
          let signedLocation = record(symbol("my-location"), message.fields[2]).encoded()
          verified = crypto.verify(publicKey, signedLocation, signature)
      if not verified:
        raise newException(SessionError, "invalid start-session hello")
      session.remotePublicKey = if message.fields.len == 5:
          message.fields[2].data
        else:
          message.fields[1].extractGlowcapPublicKey()
      session.remoteLocation = if message.fields.len == 5:
          message.fields[3].encoded()
        else:
          message.fields[2].encoded()
      try:
        session.peerVerified = session.verifyPeerPolicy()
      except CatchableError:
        session.diagnostic(dekPeerVerificationFailure, decVerification,
          "peer verification failed")
        raise
      session.sawHello = true
      session.identityVerified = true
      session.state = ssOpen
      session.diagnostic(dekHandshakeSuccess, decHandshake, "handshake complete")
      session.diagnostic(dekSessionOpened, decNone, "session open")
      continue
    if message.label.data == "op:abort":
      session.close("remote abort")
      return true
    if session.state != ssOpen:
      raise newException(SessionError, "application message before handshake")
    session.processMessage(message)
  true

proc pump*(session: Session): bool =
  try:
    discard session.transport.flushOutput()
    result = session.pumpImpl()
    discard session.transport.flushOutput()
  except CatchableError as error:
    if error.msg.contains("frame") or error.msg.contains("queue limit"):
      session.diagnostic(dekResourceLimit, decResource, "session resource limit exceeded")
    elif session.state == ssNegotiating:
      session.diagnostic(dekHandshakeFailure, decHandshake, "handshake failed: " & error.msg)
    else:
      session.diagnostic(dekTransportError, decTransport, "transport or protocol error: " & error.msg)
    session.traceLifecycle("protocol:error", "-", "closed", error.msg)
    if session.state != ssClosed:
      try:
        session.send(abort(error.msg))
      except CatchableError:
        discard
    session.close("protocol or transport error: " & error.msg)
    raise

proc processMessage(session: Session; message: SyrupValue) =
  session.traceMessage(tdIn, message)
  if message.kind != skRecord or message.label.kind != skSymbol:
    raise newException(SessionError, "session received a non-record message")
  if message.label.data == "op:gc-exports":
    if message.fields.len != 2 or message.fields[0].kind != skList or
        message.fields[1].kind != skList or message.fields[0].items.len != message.fields[1].items.len:
      raise newException(SessionError, "invalid op:gc-exports")
    for index, position in message.fields[0].items:
      if position.kind != skInteger or position.negative or
          message.fields[1].items[index].kind != skInteger or
          message.fields[1].items[index].negative:
        raise newException(SessionError, "invalid op:gc-exports positions")
      try:
        let pos = parseInt(position.magnitude)
        let delta = parseInt(message.fields[1].items[index].magnitude)
        let forwarded = session.forwardedRegistry.origins.getOrDefault(
          session.forwardedPromiseKey(exportRef(pos)))
        if not forwarded.isNil and delta > forwarded.targetWireRefs:
          raise newException(ReferenceError,
            "forwarded promise wire release underflow at position " & $pos)
        discard session.references.releaseWireExport(exportRef(pos), delta)
        session.traceLifecycle("reference:wire-release", $pos, "-",
          "delta=" & $delta & ",wire=" &
          (if session.references.exports.hasKey(pos):
             $session.references.exports[pos].wireRefs else: "0,deleted"))
        if session.references.exports.hasKey(pos) and
            session.references.exports[pos].owner == eoForwardedProxy and
            session.references.exports[pos].wireRefs == 0:
          discard session.references.releaseExport(pos)
        if not forwarded.isNil:
          forwarded.targetWireRefs -= delta
          session.releaseForwardedSourceWire(exportRef(pos), forwarded)
          session.maybeRetireForwardedPromise(exportRef(pos), forwarded)
        session.retireListenerResolver(pos)
      except ValueError:
        raise newException(SessionError, "invalid op:gc-exports integer")
    return
  if message.label.data == "op:gc-answers":
    if message.fields.len != 1 or message.fields[0].kind != skList:
      raise newException(SessionError, "invalid op:gc-answers")
    for value in message.fields[0].items:
      if value.kind != skInteger or value.negative:
        raise newException(SessionError, "invalid op:gc-answers position")
      try:
        let answer = parseInt(value.magnitude)
        if session.answers.hasKey(answer):
          let resolver = session.answers[answer]
          session.answers.del(answer)
          session.pending.del(resolver)
          session.releaseAnswerResolver(resolver)
        elif session.inboundAnswers.hasKey(answer):
          session.inboundAnswers.del(answer)
          session.answerSlots.del(answer)
          session.resolvedAnswers.del(answer)
          session.brokenAnswers.del(answer)
        else:
          raise newException(SessionError, "unknown or released answer " & $answer)
      except ValueError:
        raise newException(SessionError, "invalid op:gc-answers integer")
    return
  if message.label.data == "op:listen":
    if message.fields.len != 3:
      raise newException(SessionError, "invalid op:listen")
    let target = message.fields[0].descriptor()
    let resolver = message.fields[1].descriptor()
    var listenMode: int64
    case message.fields[2].kind
    of skInteger:
      if message.fields[2].negative:
        raise newException(SessionError, "invalid op:listen mode")
      try: listenMode = parseInt(message.fields[2].magnitude)
      except ValueError: raise newException(SessionError, "invalid op:listen mode")
      if listenMode notin [1'i64, 2'i64, 3'i64]:
        raise newException(SessionError, "invalid op:listen mode")
    of skBool:
      # Glowcap's legacy wire profile uses wants-partial instead of mode.
      listenMode = if message.fields[2].boolean: 1 else: 3
    else:
      raise newException(SessionError, "invalid op:listen mode")
    let answerTarget = target.kind == rkAnswer
    if answerTarget and not session.answerSlots.hasKey(target.position):
      raise newException(SessionError, "listen target is not an active answer")
    if not answerTarget and not session.promiseSlots.hasKey(target.position):
      raise newException(SessionError, "listen target is not a promise")
    let lifecycle = session.listenerLifecycle(message.fields[1], listenMode)
    if lifecycle.isNil: return
    let listener = PromiseListener(resolver: message.fields[1], mode: listenMode,
      lifecycle: lifecycle)
    var slot = if answerTarget: session.answerSlots[target.position]
               else: session.promiseSlots[target.position]
    if slot.pending:
      discard session.addPromiseListener(target.position, listener)
    else:
      session.notifyListener(slot, listener)
    return
  if message.label.data != "op:deliver" and message.label.data != "op:deliver-only":
    raise newException(SessionError, "unsupported prototype operation " & message.label.data)
  if message.fields.len < 2: raise newException(SessionError, "short deliver message")
  let target = message.fields[0].descriptor()
  let argsValue = message.fields[1]
  if argsValue.kind != skList: raise newException(SessionError, "deliver args are not a list")
  let isBootstrapWithdraw = target.kind == rkExport and target.position == 0 and
    argsValue.items.len == 2 and argsValue.items[0].kind == skSymbol and
    argsValue.items[0].data == "withdraw-gift"
  if not isBootstrapWithdraw:
    session.validateHandoffValues(argsValue)
  if message.label.data == "op:deliver" and message.fields.len >= 3 and
      message.fields[2].kind == skInteger and not message.fields[2].negative:
    try:
      let answerPosition = parseInt(message.fields[2].magnitude)
      if session.answerSlots.hasKey(answerPosition) or
          session.inboundAnswers.hasKey(answerPosition) or
          session.resolvedAnswers.hasKey(answerPosition) or
          session.brokenAnswers.hasKey(answerPosition):
        raise newException(SessionError, "duplicate inbound answer position")
      if session.answerSlots.len >= session.limits.maxPendingPromises:
        session.diagnostic(dekResourceLimit, decResource,
          "inbound answer limit exceeded")
        raise newException(SessionError, "inbound answer limit exceeded")
      session.inboundAnswers[answerPosition] = true
      session.answerSlots[answerPosition] = PromiseSlot(pending: true)
    except ValueError:
      raise newException(SessionError, "invalid inbound answer position")
  if target.kind == rkExport and target.position == 0 and argsValue.items.len == 2 and
      argsValue.items[0].kind == skSymbol and argsValue.items[0].data == "fetch" and
      argsValue.items[1].kind == skBytes and message.fields.len >= 4:
    let published = session.publications.getOrDefault(argsValue.items[1].data)
    var answerPosition = -1'i64
    if message.fields[2].kind == skInteger and not message.fields[2].negative:
      try:
        answerPosition = parseInt(message.fields[2].magnitude)
      except ValueError:
        raise newException(SessionError, "invalid bootstrap answer position")
    if published.kind == rkExport:
      let resolver = message.fields[3].descriptor()
      session.accountOutboundExport(published)
      let reply = published.payloadDescriptor()
      if answerPosition >= 0: session.resolvedAnswers[answerPosition] = reply
      session.send(deliverV1Callback(responseTarget(resolver).descriptor(), [symbol("fulfill"), reply]))
      session.gcResolverWire(message.fields[3])
    else:
      let resolver = message.fields[3].descriptor()
      let reply = text("unknown swissnum")
      if answerPosition >= 0: session.resolvedAnswers[answerPosition] = reply
      session.send(deliverV1Callback(responseTarget(resolver).descriptor(), [symbol("break"), reply]))
      session.gcResolverWire(message.fields[3])
    if answerPosition >= 0: session.flushPipelines(answerPosition)
    return
  if target.kind == rkExport and target.position == 0 and
      argsValue.items.len == 3 and argsValue.items[0].kind == skSymbol and
      argsValue.items[0].data == "deposit-gift" and
      message.label.data in ["op:deliver", "op:deliver-only"]:
    if argsValue.items[1].kind != skBytes or argsValue.items[1].data.len == 0:
      raise newException(SessionError, "invalid deposit-gift id")
    try:
      let capability = argsValue.items[2].descriptor()
      if capability.kind in {rkExport, rkImportObject, rkImportPromise}:
        session.depositGift(argsValue.items[1].data, "", capability.descriptor(),
          GiftProvenance(sessionId: session.sessionId(),
            gifterSide: session.remoteSideId(), gifterKey: session.remotePublicKey))
      else:
        raise newException(ReferenceError, "gift must contain an imported capability")
      session.traceLifecycle("handoff:deposit", traceId(argsValue.items[1].data),
        "deposited", "gift")
    except ReferenceError:
      raise newException(SessionError, "invalid deposit-gift capability")
    return
  if target.kind == rkExport and target.position == 0 and
      argsValue.items.len == 2 and argsValue.items[0].kind == skSymbol and
      argsValue.items[0].data == "withdraw-gift":
    if message.label.data != "op:deliver" or message.fields.len < 4 or
        (message.fields[2].kind != skInteger and
         not (message.fields[2].kind == skBool and not message.fields[2].boolean)):
      raise newException(SessionError, "withdraw-gift requires an answer")
    let signedReceive = argsValue.items[1]
    let answerPosition = if message.fields[2].kind == skBool:
        -1'i64
      else:
        try:
          if message.fields[2].negative: raise newException(SessionError, "invalid withdraw-gift answer")
          parseInt(message.fields[2].magnitude)
        except ValueError:
          raise newException(SessionError, "invalid withdraw-gift answer")
    let resolver = message.fields[3].descriptor()
    try:
      session.validateHandoffValues(argsValue)
      if signedReceive.kind != skRecord or signedReceive.fields.len != 2 or
          not verifyHandoffReceive(signedReceive):
        raise newException(SessionError, "invalid withdraw-gift certificate")
      let receive = signedReceive.fields[0]
      let giveEnvelope = receive.fields[3]
      let give = giveEnvelope.fields[0]
      let giftId = give.fields[4].data
      let deposited = session.gifts.hasGift(giftId)
      let provenance = session.gifts.provenance(giftId)
      if deposited and provenance.sessionId.len == 0:
        raise newException(SessionError, "gift has no verified provenance")
      if deposited and
          (provenance.sessionId != give.fields[2].data or
           provenance.gifterSide != give.fields[3].data or
           provenance.gifterKey.len != 32):
        raise newException(SessionError, "handoff gifter session mismatch")
      if deposited and
          not crypto.verify(provenance.gifterKey, give.encoded(),
            extractGlowcapSignature(giveEnvelope.fields[1])):
        raise newException(SessionError, "invalid handoff give signature")
      let receiverKey = extractGlowcapPublicKey(give.fields[0])
      let giftPromise = session.withdrawGift(giftId, receiverKey,
        GiftProvenance(sessionId: give.fields[2].data,
          gifterSide: give.fields[3].data))
      session.traceLifecycle("handoff:withdraw", traceId(giftId),
        if giftPromise.state == psPending: "pending" else: "ready", "gift")
      giftPromise.onSettle(proc(promise: Promise) =
        if session.state == ssOpen:
          if promise.state == psFulfilled:
            session.resolvedAnswers[answerPosition] = promise.value
            session.retainOutboundCapability(promise.value)
            session.send(session.callbackMessage(responseTarget(resolver).descriptor(),
              [symbol("fulfill"), promise.value]))
            session.traceLifecycle("handoff:resolved", traceId(giftId),
              "resolved", "gift")
            session.gcResolverWire(message.fields[3])
          else:
            session.brokenAnswers[answerPosition] = promise.reason
            session.send(session.callbackMessage(responseTarget(resolver).descriptor(),
              [symbol("break"), text(promise.reason)]))
            session.traceLifecycle("handoff:broken", traceId(giftId),
              "broken", "gift")
            session.gcResolverWire(message.fields[3])
          session.flushPipelines(answerPosition))
    except CatchableError as error:
      session.brokenAnswers[answerPosition] = error.msg
      session.send(session.callbackMessage(responseTarget(resolver).descriptor(),
        [symbol("break"), text(error.msg)]))
      session.gcResolverWire(message.fields[3])
      session.flushPipelines(answerPosition)
    return
  if target.kind == rkAnswer:
    if message.label.data != "op:deliver" or message.fields.len < 4 or
        (message.fields[2].kind != skInteger and
         not (message.fields[2].kind == skBool and not message.fields[2].boolean)):
      raise newException(SessionError, "invalid pipelined deliver message")
    let answer = if message.fields[2].kind == skBool:
        -1'i64
      else:
        if message.fields[2].negative:
          raise newException(SessionError, "invalid pipeline answer position")
        try: parseInt(message.fields[2].magnitude)
        except ValueError: raise newException(SessionError, "invalid pipeline answer position")
    let request = PipelineRequest(args: argsValue.items, answerPosition: answer,
      resolver: message.fields[3])
    if session.brokenAnswers.hasKey(target.position):
      let reason = session.brokenAnswers[target.position]
      session.send(session.callbackMessage(responseTarget(request.resolver.descriptor()).descriptor(),
        [symbol("break"), text(reason)]))
      session.gcResolverWire(request.resolver)
      if answer >= 0:
        session.brokenAnswers[answer] = reason
        session.flushPipelines(answer)
    elif session.resolvedAnswers.hasKey(target.position):
      session.executePipelineRequest(session.resolvedAnswers[target.position], request)
    elif not session.inboundAnswers.hasKey(target.position):
      raise newException(SessionError,
        "unknown or released answer " & $target.position)
    else:
      session.queuePipelineRequest(target.position, request)
    return
  if target.kind == rkImportPromise and message.label.data == "op:deliver" and
      message.fields.len >= 4 and message.fields[3].kind != skBool:
    if session.routeForwardedPipeline(target, argsValue.items, message.fields[3]):
      return
  if target.kind == rkImportPromise and message.label.data == "op:deliver" and
      message.fields.len >= 4 and message.fields[3].kind != skBool and
      session.promiseSlots.hasKey(target.position):
    let answer = if message.fields[2].kind == skBool:
        -1'i64
      else:
        if message.fields[2].kind != skInteger or message.fields[2].negative:
          raise newException(SessionError, "invalid pipeline answer position")
        try: parseInt(message.fields[2].magnitude)
        except ValueError: raise newException(SessionError, "invalid pipeline answer position")
    let request = PipelineRequest(args: argsValue.items, answerPosition: answer,
      resolver: message.fields[3])
    let slot = session.promiseSlots[target.position]
    if slot.pending:
      session.queuePipelineRequest(target.position, request)
    elif slot.broken:
      let reason = if slot.reason.kind == skString: slot.reason.data
                   else: "promise broken"
      session.send(session.callbackMessage(
        responseTarget(request.resolver.descriptor()).descriptor(),
        [symbol("break"), text(reason)]))
      session.gcResolverWire(request.resolver)
    else:
      session.executePipelineRequest(slot.value, request)
    return
  let behavior = session.references.exportBehavior(target.position)
  if behavior.isNil:
    if session.retiredListenerResolvers.getOrDefault(target.position): return
    var activeExports = ""
    for position, slot in session.references.exports:
      if activeExports.len > 0: activeExports.add(",")
      activeExports.add($position & ":" & $slot.owner & ":wire=" & $slot.wireRefs)
    session.traceProtocol("protocol:unknown-export", traceDescriptor(message.fields[0]),
      "closed", "direction=in,session=" & session.traceSessionId() &
      ",exports=[" & activeExports & "]")
    raise newException(SessionError, "unknown exported capability")
  let behaviorArgs = if not session.glowcapV1 or
      (argsValue.items.len > 0 and argsValue.items[0].kind == skSymbol and
       argsValue.items[0].data in ["fulfill", "break"]):
      argsValue.items
    else:
      if argsValue.items.len < 1: @[] else: argsValue.items[1 ..^ 1]
  session.activeAnswerPosition = -1
  session.activeListenMode = 3
  session.activeResolver = nil
  if message.label.data == "op:deliver" and message.fields.len >= 4 and
      message.fields[3].kind != skBool:
    session.activeResolver = message.fields[3]
    if message.fields[2].kind == skInteger and not message.fields[2].negative:
      try:
        session.activeAnswerPosition = parseInt(message.fields[2].magnitude)
      except ValueError:
        raise newException(SessionError, "invalid active answer position")
    if message.fields.len == 5:
      if message.fields[4].kind != skInteger or message.fields[4].negative:
        raise newException(SessionError, "invalid listen mode")
      try: session.activeListenMode = parseInt(message.fields[4].magnitude)
      except ValueError: raise newException(SessionError, "invalid listen mode")
      if session.activeListenMode notin [1'i64, 3'i64]:
        raise newException(SessionError, "invalid listen mode")
  let reply = if session.actors.hasKey(target.position):
      session.actors[target.position](session, argsValue.items)
    else:
      behavior(behaviorArgs)
  let dispatchedArgs = if session.actors.hasKey(target.position):
      argsValue.items
    else:
      behaviorArgs
  session.traceArgumentShapes(traceDescriptor(message.fields[0]), dispatchedArgs)
  if message.label.data == "op:deliver" and
      session.activeAnswerPosition >= 0 and
      session.deferredAnswers.hasKey(session.activeAnswerPosition):
    session.deferredAnswers.del(session.activeAnswerPosition)
    session.activeResolver = nil
    session.releaseDeliveryImports(argsValue)
    return
  session.activeResolver = nil
  session.releaseDeliveryImports(argsValue)
  if message.label.data == "op:deliver":
    var answerPosition = -1'i64
    if message.fields.len >= 3 and message.fields[2].kind == skInteger and
        not message.fields[2].negative:
      try:
        answerPosition = parseInt(message.fields[2].magnitude)
      except ValueError:
        raise newException(SessionError, "invalid answer position")
      session.resolvedAnswers[answerPosition] = reply
      if session.answerSlots.hasKey(answerPosition):
        session.settleAnswerSlot(answerPosition, @[symbol("fulfill"), reply])
    if message.fields.len == 4:
      if session.deferredAnswers.hasKey(answerPosition):
        session.deferredAnswers.del(answerPosition)
        return
      if message.fields[3].kind == skBool: return
      session.sendFulfillment(message.fields[3], reply, 3, true)
      session.gcResolverWire(message.fields[3])
      if answerPosition >= 0: session.flushPipelines(answerPosition)
      return
    if message.fields.len != 5: raise newException(SessionError, "invalid deliver field count")
    let resolver = message.fields[3].descriptor()
    session.sendFulfillment(message.fields[3], reply, session.activeListenMode, false)
    session.gcResolverWire(message.fields[3])
    if answerPosition >= 0: session.flushPipelines(answerPosition)

