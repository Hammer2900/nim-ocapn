import std/[strutils, tables]
import ./[crypto, framing, gifts, locators, messages, promises, references, syrup, transport]

type
  SessionError* = object of CatchableError
  SessionLimits* = object
    maxFrameBytes*: int
    maxPendingPromises*: int
    maxExports*: int
    maxImports*: int
    maxOutboundBytes*: int
  SessionStats* = object
    pendingPromises*: int
    importCount*: int
    exportCount*: int
    queuedBytes*: int
  SessionState* = enum ssNegotiating, ssOpen, ssClosed
  AnswerContext* = object
    answerPosition*: int64
    resolver*: SyrupValue
  Behavior* = BehaviorRef
  ActorBehavior* = proc(session: Session; args: seq[SyrupValue]): SyrupValue {.closure.}
  PromiseSlot = object
    pending: bool
    broken: bool
    value: SyrupValue
    reason: SyrupValue
    listeners: seq[SyrupValue]
  PipelineRequest = object
    args: seq[SyrupValue]
    answerPosition: int64
    resolver: SyrupValue
  Session* = ref object
    transport*: Transport
    state*: SessionState
    identityVerified*: bool
    localPublicKey*: string
    localSecret: string
    remotePublicKey*: string
    remoteLocation*: string
    remotePeer*: PeerLocator
    references*: ReferenceTables
    nextAnswer: int64
    decoder: FrameDecoder
    sawHello: bool
    sentHello: bool
    glowcapV1: bool
    publications: Table[string, CapabilityRef]
    actors: Table[int64, ActorBehavior]
    promiseSlots: Table[int64, PromiseSlot]
    pending: Table[int64, Promise]
    answers: Table[int64, int64]
    inboundAnswers: Table[int64, bool]
    resolvedAnswers: Table[int64, SyrupValue]
    brokenAnswers: Table[int64, string]
    pipelines: Table[int64, seq[PipelineRequest]]
    seenHandoffCounts: Table[int64, bool]
    gifts*: GiftTable
    ownsGifts*: bool
    giftPromises: seq[Promise]
    activeAnswerPosition: int64
    activeResolver: SyrupValue
    deferredAnswers: Table[int64, bool]
    limits*: SessionLimits

proc defaultSessionLimits*(): SessionLimits =
  SessionLimits(maxFrameBytes: 1024 * 1024, maxPendingPromises: 4096,
    maxExports: 4096, maxImports: 4096, maxOutboundBytes: 1024 * 1024)

proc validateSessionLimits*(limits: SessionLimits) =
  if limits.maxFrameBytes <= 0:
    raise newException(SessionError, "maxFrameBytes must be positive")
  if limits.maxPendingPromises < 0 or limits.maxExports < 0 or limits.maxImports < 0:
    raise newException(SessionError, "session limits must not be negative")
  if limits.maxOutboundBytes <= 0:
    raise newException(SessionError, "maxOutboundBytes must be positive")

proc send*(session: Session; message: SyrupValue)

proc newSession*(transport: Transport; seed = "nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn";
                 location = "nim://in-memory";
                 limits = defaultSessionLimits()): Session =
  if seed.len != 32: raise newException(SessionError, "session seed must be 32 bytes")
  validateSessionLimits(limits)
  let actualPublicKey = crypto.publicKey(seed)
  let actualSignature = crypto.sign(seed, location)
  result = Session(transport: transport, state: ssNegotiating, identityVerified: false,
    localPublicKey: actualPublicKey,
    localSecret: seed,
    references: initReferenceTables(), nextAnswer: 0,
    publications: initTable[string, CapabilityRef](), pending: initTable[int64, Promise](),
    answers: initTable[int64, int64](),
    inboundAnswers: initTable[int64, bool](),
    resolvedAnswers: initTable[int64, SyrupValue](),
    brokenAnswers: initTable[int64, string](),
    pipelines: initTable[int64, seq[PipelineRequest]](),
    actors: initTable[int64, ActorBehavior](),
    promiseSlots: initTable[int64, PromiseSlot](),
    seenHandoffCounts: initTable[int64, bool](),
    gifts: newGiftTable(),
    ownsGifts: true,
    giftPromises: @[],
    activeAnswerPosition: -1,
    deferredAnswers: initTable[int64, bool](),
    decoder: newFrameDecoder(limits.maxFrameBytes), limits: limits)
  if transport of TcpTransport:
    TcpTransport(transport).maxOutputBytes = limits.maxOutboundBytes
  result.send(startSession(bytes(location), bytes(actualPublicKey), bytes(actualSignature)))
  result.sentHello = true

proc newGlowcapSession*(transport: Transport; seed, hostPort: string;
                        limits = defaultSessionLimits()): Session =
  if seed.len != 32: raise newException(SessionError, "session seed must be 32 bytes")
  validateSessionLimits(limits)
  let publicKey = crypto.publicKey(seed)
  let location = glowcapLocation(hostPort)
  let signedLocation = record(symbol("my-location"), location).encoded()
  let signature = crypto.sign(seed, signedLocation)
  result = Session(transport: transport, state: ssNegotiating, identityVerified: false,
    localPublicKey: publicKey,
    localSecret: seed,
    references: initReferenceTables(1), nextAnswer: 0, glowcapV1: true,
    publications: initTable[string, CapabilityRef](), pending: initTable[int64, Promise](),
    answers: initTable[int64, int64](),
    inboundAnswers: initTable[int64, bool](),
    resolvedAnswers: initTable[int64, SyrupValue](),
    brokenAnswers: initTable[int64, string](),
    pipelines: initTable[int64, seq[PipelineRequest]](),
    actors: initTable[int64, ActorBehavior](),
    promiseSlots: initTable[int64, PromiseSlot](),
    seenHandoffCounts: initTable[int64, bool](),
    gifts: newGiftTable(),
    ownsGifts: true,
    giftPromises: @[],
    activeAnswerPosition: -1,
    deferredAnswers: initTable[int64, bool](),
    decoder: newFrameDecoder(limits.maxFrameBytes), limits: limits)
  if transport of TcpTransport:
    TcpTransport(transport).maxOutputBytes = limits.maxOutboundBytes
  let hello = glowcapStartSession(location, glowcapPublicKey(publicKey), glowcapSignature(signature))
  result.send(hello)
  result.sentHello = true

proc exportObject*(session: Session; behavior: Behavior): CapabilityRef =
  if session.references.exportCount() >= session.limits.maxExports:
    raise newException(SessionError, "export table limit exceeded")
  session.references.allocateExport(behavior)

proc publishObject*(session: Session; name: string; behavior: Behavior): CapabilityRef =
  result = session.exportObject(behavior)
  session.publications[name] = result

proc exportActor*(session: Session; behavior: ActorBehavior): CapabilityRef =
  result = session.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
  session.actors[result.position] = behavior

proc publishActor*(session: Session; name: string; behavior: ActorBehavior): CapabilityRef =
  result = session.exportActor(behavior)
  session.publications[name] = result

proc depositGift*(session: Session; giftId, receiverKey: string; value: SyrupValue) =
  session.gifts.deposit(giftId, receiverKey, value)

proc withdrawGift*(session: Session; giftId, receiverKey: string): Promise =
  result = session.gifts.withdraw(giftId, receiverKey)
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

proc sessionId*(session: Session): string =
  let local = session.localSideId()
  let remote = session.remoteSideId()
  let ordered = if local <= remote: local & remote else: remote & local
  crypto.sha256(crypto.sha256("prot0" & ordered))

proc callbackMessage(session: Session; target: SyrupValue;
                     args: openArray[SyrupValue]): SyrupValue
proc responseTarget(resolver: CapabilityRef): CapabilityRef
proc flushPipelines(session: Session; answerPosition: int64)

proc signLocal*(session: Session; payload: string): string =
  crypto.sign(session.localSecret, payload)

proc deferAnswer*(session: Session): AnswerContext =
  if session.activeResolver.isNil:
    raise newException(SessionError, "no active answer to defer")
  result = AnswerContext(answerPosition: session.activeAnswerPosition,
    resolver: session.activeResolver)
  session.deferredAnswers[result.answerPosition] = true

proc hasActiveAnswer*(session: Session): bool = not session.activeResolver.isNil

proc usesGlowcapV1*(session: Session): bool = session.glowcapV1

proc fulfillAnswer*(session: Session; context: AnswerContext; value: SyrupValue) =
  if context.answerPosition >= 0:
    session.resolvedAnswers[context.answerPosition] = value
  session.send(session.callbackMessage(
    responseTarget(context.resolver.descriptor()).descriptor(),
    [symbol("fulfill"), value]))
  if context.answerPosition >= 0:
    session.flushPipelines(context.answerPosition)

proc breakAnswer*(session: Session; context: AnswerContext; reason: string) =
  if context.answerPosition >= 0:
    session.brokenAnswers[context.answerPosition] = reason
  session.send(session.callbackMessage(
    responseTarget(context.resolver.descriptor()).descriptor(),
    [symbol("break"), text(reason)]))
  if context.answerPosition >= 0:
    session.flushPipelines(context.answerPosition)

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
    let resolution = if slot.broken: @[symbol("break"), slot.reason]
                     else: @[symbol("fulfill"), slot.value]
    session.send(session.callbackMessage(responseTarget(listener.descriptor()).descriptor(), resolution))
  slot.listeners.setLen(0)
  session.promiseSlots[position] = slot

proc newPromisePair*(session: Session): tuple[vow, resolver: CapabilityRef] =
  var vowPosition = -1'i64
  result.vow = session.exportActor(proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
    list())
  vowPosition = result.vow.position
  session.promiseSlots[vowPosition] = PromiseSlot(pending: true)
  result.resolver = session.exportActor(proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
    actorSession.settlePromiseSlot(vowPosition, args)
    list())

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

proc responseTarget(resolver: CapabilityRef): CapabilityRef =
  case resolver.kind
  of rkExport: reference(rkImportObject, resolver.position)
  of rkImportObject: reference(rkExport, resolver.position)
  of rkImportPromise, rkAnswer: resolver

proc send*(session: Session; message: SyrupValue) =
  session.transport.send(frame(message.encoded()))

proc voidValue(): SyrupValue = list()

proc releaseDeliveryImports(session: Session; args: SyrupValue) =
  if not session.glowcapV1 or args.kind != skList: return
  var counts = initTable[int64, int64]()
  for value in args.items:
    if value.kind != skRecord or value.label.kind != skSymbol or
        value.label.data notin ["desc:import-object", "desc:import-promise"] or
        value.fields.len != 1 or value.fields[0].kind != skInteger or value.fields[0].negative:
      continue
    try:
      let position = parseInt(value.fields[0].magnitude)
      counts[position] = counts.getOrDefault(position) + 1
    except ValueError:
      raise newException(SessionError, "invalid delivery import position")
  if counts.len == 0: return
  var positions, deltas: seq[int64]
  for position, count in counts:
    positions.add(position)
    deltas.add(count)
  session.send(gcExports(positions, deltas))

proc callbackMessage(session: Session; target: SyrupValue;
                     args: openArray[SyrupValue]): SyrupValue =
  if session.glowcapV1:
    deliverV1Callback(target, args)
  else:
    deliverOnly(target, args)

proc sendCall(session: Session; target: CapabilityRef; callArgs: openArray[SyrupValue]): Promise =
  if session.state != ssOpen:
    raise newException(SessionError, "cannot call before handshake completes")
  if session.pending.len >= session.limits.maxPendingPromises:
    raise newException(SessionError, "pending promise limit exceeded")
  let promise = newPromise()
  result = promise
  var resolverPosition = -1'i64
  var answerPosition = -1'i64
  let resolver = exportObject(session, proc(values: seq[SyrupValue]): SyrupValue =
    if values.len != 2 or values[0].kind != skSymbol:
      raise newException(SessionError, "invalid promise resolution")
    case values[0].data
    of "fulfill":
      if values[1].kind == skRecord and values[1].label.kind == skSymbol and
          values[1].label.data in ["desc:import-object", "desc:import-promise"]:
        session.retain(values[1].descriptor())
      promise.fulfill(values[1])
      session.pending.del(resolverPosition)
      discard session.references.releaseExport(resolverPosition)
      session.answers.del(answerPosition)
      session.send(gcAnswers([answerPosition]))
    of "break":
      if values[1].kind != skString: raise newException(SessionError, "invalid break reason")
      promise.breakPromise(values[1].data)
      session.pending.del(resolverPosition)
      discard session.references.releaseExport(resolverPosition)
      session.answers.del(answerPosition)
      session.send(gcAnswers([answerPosition]))
    else: raise newException(SessionError, "unknown promise resolution")
    voidValue())
  resolverPosition = resolver.position
  session.pending[resolver.position] = promise
  let answer = session.nextAnswer
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
  if target.kind notin {rkExport, rkImportObject}:
    raise newException(SessionError, "deliver target must be an object reference")
  sendCall(session, target, args)

proc callPipelined*(session: Session; promise: Promise; verb: string;
                    args: openArray[SyrupValue]): Promise =
  if promise.isNil or promise.state != psPending or promise.answerPosition < 0:
    raise newException(SessionError, "can only pipeline through a pending promise")
  var callArgs = @[symbol(verb)]
  for arg in args: callArgs.add(arg)
  sendCall(session, reference(rkAnswer, promise.answerPosition), callArgs)

proc close*(session: Session; reason = "session closed") =
  if session.state == ssClosed: return
  session.state = ssClosed
  for _, promise in session.pending.mpairs:
    if not settled(promise): promise.breakPromise(reason)
  session.pending.clear()
  session.answers.clear()
  session.inboundAnswers.clear()
  session.resolvedAnswers.clear()
  session.brokenAnswers.clear()
  session.pipelines.clear()
  session.references.exports.clear()
  session.references.imports.clear()
  session.publications.clear()
  session.actors.clear()
  session.promiseSlots.clear()
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
  if session.transport of TcpTransport:
    result.queuedBytes = TcpTransport(session.transport).queuedBytes()

proc fetch*(session: Session; swissName: string): Promise =
  session.call(exportRef(0), "fetch", [bytes(swissName)])

proc pump*(session: Session): bool

proc waitFor*(session: Session; promise: Promise; maxPumps = 10000): SyrupValue =
  if promise.isNil:
    raise newException(SessionError, "cannot wait for a nil promise")
  var remaining = maxPumps
  while not settled(promise):
    if remaining <= 0:
      raise newException(SessionError, "promise wait limit exceeded")
    discard session.pump()
    dec remaining
  if promise.state == psBroken:
    raise newException(SessionError, promise.reason)
  promise.value

proc processMessage(session: Session; message: SyrupValue)
proc executePipelineRequest(session: Session; capability: SyrupValue;
                            request: PipelineRequest)

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
  if not session.pipelines.hasKey(answerPosition): return
  let queued = session.pipelines[answerPosition]
  session.pipelines.del(answerPosition)
  for request in queued:
    if session.brokenAnswers.hasKey(answerPosition):
      let reason = session.brokenAnswers[answerPosition]
      session.send(session.callbackMessage(responseTarget(request.resolver.descriptor()).descriptor(),
        [symbol("break"), text(reason)]))
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
                         if request.answerPosition >= 0:
                           session.brokenAnswers[request.answerPosition] = reason
                           session.flushPipelines(request.answerPosition)
                         return
  let behavior = session.references.exportBehavior(resolvedTarget.position)
  if behavior.isNil:
    let reason = "pipeline resolved to unknown capability"
    session.send(session.callbackMessage(responseTarget(request.resolver.descriptor()).descriptor(),
      [symbol("break"), text(reason)]))
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
    if request.answerPosition >= 0:
      session.brokenAnswers[request.answerPosition] = error.msg
      session.flushPipelines(request.answerPosition)
    return
  if request.answerPosition >= 0:
    session.resolvedAnswers[request.answerPosition] = reply
  session.send(session.callbackMessage(responseTarget(request.resolver.descriptor()).descriptor(),
    [symbol("fulfill"), reply]))
  if request.answerPosition >= 0:
    session.flushPipelines(request.answerPosition)

proc pumpImpl(session: Session): bool =
  let chunk = session.transport.receive()
  if chunk.len == 0:
    if session.transport.isClosed(): session.close("transport disconnected")
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
      session.sawHello = true
      session.identityVerified = true
      session.state = ssOpen
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
    if session.transport of TcpTransport:
      discard TcpTransport(session.transport).flushOutput()
    result = session.pumpImpl()
    if session.transport of TcpTransport:
      discard TcpTransport(session.transport).flushOutput()
  except CatchableError as error:
    if session.state != ssClosed:
      try:
        session.send(abort(error.msg))
      except CatchableError:
        discard
    session.close("protocol or transport error: " & error.msg)
    raise

proc processMessage(session: Session; message: SyrupValue) =
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
        discard session.references.releaseExportDelta(pos, delta)
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
          discard session.references.releaseExport(resolver)
        elif session.inboundAnswers.hasKey(answer):
          session.inboundAnswers.del(answer)
          session.resolvedAnswers.del(answer)
          session.brokenAnswers.del(answer)
        else:
          raise newException(SessionError, "unknown or released answer " & $answer)
      except ValueError:
        raise newException(SessionError, "invalid op:gc-answers integer")
    return
  if message.label.data == "op:listen":
    if message.fields.len != 3 or message.fields[2].kind != skBool:
      raise newException(SessionError, "invalid op:listen")
    let target = message.fields[0].descriptor()
    let resolver = message.fields[1].descriptor()
    if not session.promiseSlots.hasKey(target.position):
      raise newException(SessionError, "listen target is not a promise")
    var slot = session.promiseSlots[target.position]
    if slot.pending:
      slot.listeners.add(message.fields[1])
      session.promiseSlots[target.position] = slot
    else:
      let resolution = if slot.broken: @[symbol("break"), slot.reason]
                       else: @[symbol("fulfill"), slot.value]
      session.send(session.callbackMessage(responseTarget(resolver).descriptor(), resolution))
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
      session.inboundAnswers[parseInt(message.fields[2].magnitude)] = true
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
      let reply = published.payloadDescriptor()
      if answerPosition >= 0: session.resolvedAnswers[answerPosition] = reply
      session.send(deliverV1Callback(responseTarget(resolver).descriptor(), [symbol("fulfill"), reply]))
    else:
      let resolver = message.fields[3].descriptor()
      let reply = text("unknown swissnum")
      if answerPosition >= 0: session.resolvedAnswers[answerPosition] = reply
      session.send(deliverV1Callback(responseTarget(resolver).descriptor(), [symbol("break"), reply]))
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
      let imported = importObject(capability.position).descriptor()
      session.depositGift(argsValue.items[1].data, "", imported)
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
      let receiverKey = extractGlowcapPublicKey(give.fields[0])
      let giftPromise = session.withdrawGift(giftId, receiverKey)
      giftPromise.onSettle(proc(promise: Promise) =
        if session.state == ssOpen:
          if promise.state == psFulfilled:
            session.resolvedAnswers[answerPosition] = promise.value
            session.send(session.callbackMessage(responseTarget(resolver).descriptor(),
              [symbol("fulfill"), promise.value]))
          else:
            session.brokenAnswers[answerPosition] = promise.reason
            session.send(session.callbackMessage(responseTarget(resolver).descriptor(),
              [symbol("break"), text(promise.reason)]))
          session.flushPipelines(answerPosition))
    except CatchableError as error:
      session.brokenAnswers[answerPosition] = error.msg
      session.send(session.callbackMessage(responseTarget(resolver).descriptor(),
        [symbol("break"), text(error.msg)]))
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
      if answer >= 0:
        session.brokenAnswers[answer] = reason
        session.flushPipelines(answer)
    elif session.resolvedAnswers.hasKey(target.position):
      session.executePipelineRequest(session.resolvedAnswers[target.position], request)
    else:
      session.pipelines.mgetOrPut(target.position, @[]).add(request)
    return
  let behavior = session.references.exportBehavior(target.position)
  if behavior.isNil: raise newException(SessionError, "unknown exported capability")
  let behaviorArgs = if not session.glowcapV1 or
      (argsValue.items.len > 0 and argsValue.items[0].kind == skSymbol and
       argsValue.items[0].data in ["fulfill", "break"]):
      argsValue.items
    else:
      if argsValue.items.len < 1: @[] else: argsValue.items[1 ..^ 1]
  session.activeAnswerPosition = -1
  session.activeResolver = nil
  if message.label.data == "op:deliver" and message.fields.len >= 4 and
      message.fields[3].kind != skBool:
    session.activeResolver = message.fields[3]
    if message.fields[2].kind == skInteger and not message.fields[2].negative:
      try:
        session.activeAnswerPosition = parseInt(message.fields[2].magnitude)
      except ValueError:
        raise newException(SessionError, "invalid active answer position")
  let reply = if session.actors.hasKey(target.position):
      session.actors[target.position](session, argsValue.items)
    else:
      behavior(behaviorArgs)
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
    if message.fields.len == 4:
      if session.deferredAnswers.hasKey(answerPosition):
        session.deferredAnswers.del(answerPosition)
        return
      if message.fields[3].kind == skBool: return
      let resolver = message.fields[3].descriptor()
      session.send(deliverV1Callback(responseTarget(resolver).descriptor(), [symbol("fulfill"), reply]))
      if answerPosition >= 0: session.flushPipelines(answerPosition)
      return
    if message.fields.len != 5: raise newException(SessionError, "invalid deliver field count")
    let resolver = message.fields[3].descriptor()
    session.send(session.callbackMessage(responseTarget(resolver).descriptor(),
      [symbol("fulfill"), reply]))
    if answerPosition >= 0: session.flushPipelines(answerPosition)

