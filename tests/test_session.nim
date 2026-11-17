import std/[strutils, unittest]
import ../src/[crypto, framing, gifts, messages, promises, references, session, syrup, transport]

suite "in-memory Nim CapTP prototype":
  test "enforces session resource limits":
    var limits = defaultSessionLimits()
    limits.maxExports = 1
    limits.maxImports = 1
    limits.maxPendingPromises = 1
    let pair = inMemoryPair()
    let server = newSession(pair.remote, limits = limits)
    let client = newSession(pair.local, limits = limits)
    discard server.pump()
    discard client.pump()
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("ok"))
    expect SessionError:
      discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("too many"))
    let pending = client.call(exportRef(0), "wait", [])
    check pending.state == psPending
    expect SessionError:
      discard client.call(exportRef(0), "wait", [])
    let imported = reference(rkImportObject, 7)
    client.retain(imported)
    expect SessionError:
      client.retain(reference(rkImportObject, 8))
    let current = client.stats()
    check current.pendingPromises == 1
    check current.importCount == 1
    client.close("limit test complete")
    server.close("limit test complete")

  test "rejects invalid session limits":
    var limits = defaultSessionLimits()
    limits.maxFrameBytes = 0
    let pair = inMemoryPair()
    expect SessionError:
      discard newSession(pair.local, limits = limits)
    limits = defaultSessionLimits()
    limits.maxPendingPromises = -1
    expect SessionError:
      discard newSession(pair.local, limits = limits)

  test "remote greeter fulfills a promise":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      check args.len == 2
      check args[0].kind == skSymbol and args[0].data == "greet"
      text("Hello, " & args[1].data))
    let client = newSession(pair.local)
    check server.pump()
    check client.pump()
    check server.state == ssOpen
    check client.state == ssOpen
    let answer = client.call(exportRef(0), "greet", [text("world")])
    check server.pump()
    check client.pump()
    check answer.state == psFulfilled
    check answer.value.kind == skString
    check answer.value.data == "Hello, world"
    discard server.pump() # automatic op:gc-answers from the client
    client.send(gcAnswers([0'i64]))
    expect SessionError:
      discard server.pump()

  test "decodes fragmented and coalesced frames":
    var decoder = newFrameDecoder(64)
    let wire = frame("first") & frame("second")
    check decoder.feed(wire[0 .. 3]).len == 0
    check decoder.feed(wire[4 .. 8]) == @["first"]
    check decoder.feed(wire[9 .. ^1]) == @["second"]

  test "keeps incomplete frames pending and rejects bad framing":
    var decoder = newFrameDecoder(16)
    check decoder.feed("5:abc").len == 0
    check decoder.feed("de") == @["abcde"]
    expect FramingError:
      discard decoder.feed("x")

  test "bounds an incomplete decimal frame prefix":
    var decoder = newFrameDecoder(16)
    expect FramingError:
      discard decoder.feed("12345")

  test "closes a session on malformed framing":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    pair.local.send("x")
    expect FramingError:
      discard server.pump()
    check server.state == ssClosed

  test "signs and verifies the session hello material":
    let seed = repeat("a", 32)
    let publicKey = crypto.publicKey(seed)
    let signature = crypto.sign(seed, "ocapn://test")
    check publicKey.len == 32
    check signature.len == 64
    check crypto.verify(publicKey, "ocapn://test", signature)
    check not crypto.verify(publicKey, "ocapn://tampered", signature)

  test "derives the same canonical session id on both sides":
    let pair = inMemoryPair()
    let server = newSession(pair.remote, repeat("a", 32))
    let client = newSession(pair.local, repeat("b", 32))
    discard server.pump()
    discard client.pump()
    check server.localSideId() != client.localSideId()
    check server.remoteSideId() == client.localSideId()
    check client.remoteSideId() == server.localSideId()
    check server.sessionId() == client.sessionId()
    check server.sessionId().len == 32

  test "reference positions are isolated between sessions":
    let first = inMemoryPair()
    let second = inMemoryPair()
    let firstServer = newSession(first.remote)
    let secondServer = newSession(second.remote)
    discard firstServer.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      text("first"))
    discard secondServer.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      text("second"))
    let firstClient = newSession(first.local)
    let secondClient = newSession(second.local)
    discard firstServer.pump()
    discard firstClient.pump()
    discard secondServer.pump()
    discard secondClient.pump()
    let firstAnswer = firstClient.call(exportRef(0), "value", [])
    let secondAnswer = secondClient.call(exportRef(0), "value", [])
    discard firstServer.pump()
    discard firstClient.pump()
    discard secondServer.pump()
    discard secondClient.pump()
    check firstAnswer.value.data == "first"
    check secondAnswer.value.data == "second"

  test "routes concurrent calls independently":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      check args.len == 2
      text(args[1].data))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let first = client.call(exportRef(0), "echo", [text("one")])
    let second = client.call(exportRef(0), "echo", [text("two")])
    discard server.pump()
    discard server.pump()
    discard client.pump()
    discard client.pump()
    check first.state == psFulfilled
    check second.state == psFulfilled
    check first.value.data == "one"
    check second.value.data == "two"

  test "invokes an actor from op:deliver with false answer fields":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    var called = false
    discard server.exportActor(proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
      called = true
      check args.len == 1
      list())
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    client.send(record(symbol("op:deliver"), exportRef(0).targetDescriptor(),
      list(text("sturdyref")), boolean(false), boolean(false)))
    discard server.pump()
    check called
    check server.state == ssOpen

  test "actor behavior can deliver to a capability argument":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    discard server.exportActor(proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
      check args.len == 2
      let target = args[1].descriptor()
      actorSession.send(deliverOnly(target.targetDescriptor(), [text("Hello")]))
      list())
    var greeting = ""
    let client = newSession(pair.local)
    discard client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      check args.len == 1
      greeting = args[0].data
      list())
    discard server.pump()
    discard client.pump()
    let answer = client.call(exportRef(0), "greet", [exportRef(0).payloadDescriptor()])
    discard server.pump()
    discard server.pump()
    discard client.pump()
    discard client.pump()
    check answer.state == psFulfilled
    check greeting == "Hello"

  test "pipelines a call through an unresolved promise":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let remoteThing = server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      check args.len == 0
      text("pipelined"))
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      check args.len == 1
      check args[0].kind == skSymbol and args[0].data == "make"
      remoteThing.payloadDescriptor())
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let factoryResult = client.call(exportRef(1), "make", [])
    let pipelinedResult = client.callPipelined(factoryResult, "value", [])
    check factoryResult.state == psPending
    check pipelinedResult.state == psPending
    discard server.pump()
    discard server.pump()
    discard client.pump()
    discard client.pump()
    check factoryResult.state == psFulfilled
    check pipelinedResult.state == psFulfilled
    check pipelinedResult.value.kind == skString
    check pipelinedResult.value.data == "pipelined"

  test "flushes a chained pipeline":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    var second: CapabilityRef
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      check args.len == 0
      second.payloadDescriptor())
    second = server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      check args.len == 0
      text("deep pipeline"))
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      check args.len == 1
      check args[0].kind == skSymbol and args[0].data == "make"
      exportRef(0).payloadDescriptor())
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let first = client.call(exportRef(2), "make", [])
    let secondResult = client.callPipelined(first, "next", [])
    let finalResult = client.callPipelined(secondResult, "value", [])
    discard server.pump()
    discard server.pump()
    discard server.pump()
    discard client.pump()
    discard client.pump()
    discard client.pump()
    check first.state == psFulfilled
    check secondResult.state == psFulfilled
    check finalResult.state == psFulfilled
    check finalResult.value.data == "deep pipeline"

  test "disconnect breaks pending promises and clears tables":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("never"))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let answer = client.call(exportRef(0), "value", [])
    pair.remote.close()
    discard client.pump()
    check client.state == ssClosed
    check answer.state == psBroken
    check client.references.exportCount == 0
    check client.references.importCount == 0

  test "closing a session closes its transport and is idempotent":
    let pair = inMemoryPair()
    let session = newSession(pair.local)
    session.close("test close")
    session.close("second close")
    check pair.local.isClosed()
    check pair.remote.isClosed()

  test "protocol errors close the session":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    client.send(record(symbol("op:unknown")))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    check server.references.exportCount == 0

  test "rejects malformed handoff descriptors in deliveries":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    client.send(deliverOnly(exportRef(0).targetDescriptor(), [
      record(symbol("desc:handoff-receive"), bytes("bad"))]))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed

  test "rejects a repeated handoff count within one session":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
    discard server.pump()
    discard client.pump()
    let give = handoffGive(glowcapPublicKey(repeat("k", 32)),
      glowcapLocation("127.0.0.1:1"), repeat("a", 32), repeat("b", 32), repeat("i", 32))
    let receive = handoffReceive(server.sessionId(), server.remoteSideId(), 7,
      signatureEnvelope(give, repeat("s", 64)))
    client.send(deliverOnly(exportRef(0).targetDescriptor(), [receive]))
    discard server.pump()
    check server.state == ssOpen
    client.send(deliverOnly(exportRef(0).targetDescriptor(), [receive]))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed

  test "rejects a handoff receive for the wrong session identity":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
    discard server.pump()
    discard client.pump()
    let give = handoffGive(glowcapPublicKey(repeat("k", 32)),
      glowcapLocation("127.0.0.1:1"), repeat("a", 32), repeat("b", 32), repeat("i", 32))
    let wrongSession = handoffReceive(repeat("z", 32), server.remoteSideId(), 9,
      signatureEnvelope(give, repeat("s", 64)))
    client.send(deliverOnly(exportRef(0).targetDescriptor(), [wrongSession]))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed

  test "rejects a handoff receive for the wrong remote side":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
    discard server.pump()
    discard client.pump()
    let give = handoffGive(glowcapPublicKey(repeat("k", 32)),
      glowcapLocation("127.0.0.1:1"), repeat("a", 32), repeat("b", 32), repeat("i", 32))
    let wrongSide = handoffReceive(server.sessionId(), repeat("z", 32), 10,
      signatureEnvelope(give, repeat("s", 64)))
    client.send(deliverOnly(exportRef(0).targetDescriptor(), [wrongSide]))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed

  test "validates the signed handoff receive on the session path":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
    discard server.pump()
    discard client.pump()
    let gifterSeed = repeat("g", 32)
    let receiverSeed = repeat("r", 32)
    let give = handoffGive(glowcapPublicKey(crypto.publicKey(receiverSeed)),
      glowcapLocation("127.0.0.1:1"), repeat("a", 32), repeat("b", 32), repeat("i", 32))
    let signedGive = signatureEnvelope(give, crypto.sign(gifterSeed, give.encoded()))
    let receive = handoffReceive(server.sessionId(), server.remoteSideId(), 8, signedGive)
    let signedReceive = signatureEnvelope(receive, crypto.sign(receiverSeed,
      receive.encoded()))
    client.send(deliverOnly(exportRef(0).targetDescriptor(), [signedReceive]))
    discard server.pump()
    check server.state == ssOpen

    client.send(deliverOnly(exportRef(0).targetDescriptor(), [
      signatureEnvelope(receive, repeat("x", 64))]))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed

  test "session exposes pending gift deposit and withdrawal":
    let pair = inMemoryPair()
    let session = newSession(pair.local)
    let giftId = repeat("i", 32)
    let receiverKey = repeat("r", 32)
    let pending = session.withdrawGift(giftId, receiverKey)
    check pending.state == psPending
    session.depositGift(giftId, receiverKey, text("gifted"))
    check pending.state == psFulfilled
    check pending.value.data == "gifted"

  test "closing a session cancels its pending gift withdrawal":
    let session = newSession(inMemoryPair().local)
    let pending = session.withdrawGift(repeat("q", 32), repeat("r", 32))
    check session.gifts.pendingCount(repeat("q", 32)) == 1
    session.close("disconnect")
    check pending.state == psBroken
    check session.gifts.pendingCount(repeat("q", 32)) == 0

  test "bootstrap accepts deposit-gift without a receiver key":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let giftId = repeat("i", 32)
    client.send(deliverOnly(exportRef(0).targetDescriptor(),
      [symbol("deposit-gift"), bytes(giftId), descriptor(descImportObject, 5)]))
    discard server.pump()
    let pending = server.withdrawGift(giftId, repeat("r", 32))
    check pending.state == psFulfilled

  test "bootstrap withdraw-gift fulfills a CapTP answer":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let clientSeed = repeat("c", 32)
    let client = newSession(pair.local, clientSeed)
    discard server.pump()
    discard client.pump()
    let gifterSeed = repeat("g", 32)
    let giftId = repeat("i", 32)
    let give = handoffGive(glowcapPublicKey(crypto.publicKey(clientSeed)),
      glowcapLocation("127.0.0.1:1"), repeat("a", 32), repeat("b", 32), giftId)
    let signedGive = signatureEnvelope(give, crypto.sign(gifterSeed, give.encoded()))
    let receive = handoffReceive(server.sessionId(), server.remoteSideId(), 11, signedGive)
    let signedReceive = signatureEnvelope(receive,
      crypto.sign(clientSeed, receive.encoded()))
    server.depositGift(giftId, "", text("redeemed"))
    let answer = client.call(exportRef(0), "withdraw-gift", [signedReceive])
    discard server.pump()
    discard client.pump()
    check answer.state == psFulfilled
    check answer.value.data == "redeemed"

  test "pending bootstrap withdraw resolves after deposit-gift":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let clientSeed = repeat("c", 32)
    let client = newSession(pair.local, clientSeed)
    discard server.pump()
    discard client.pump()
    let gifterSeed = repeat("g", 32)
    let giftId = repeat("j", 32)
    let give = handoffGive(glowcapPublicKey(crypto.publicKey(clientSeed)),
      glowcapLocation("127.0.0.1:1"), repeat("a", 32), repeat("b", 32), giftId)
    let signedGive = signatureEnvelope(give, crypto.sign(gifterSeed, give.encoded()))
    let receive = handoffReceive(server.sessionId(), server.remoteSideId(), 12, signedGive)
    let signedReceive = signatureEnvelope(receive,
      crypto.sign(clientSeed, receive.encoded()))
    let answer = client.call(exportRef(0), "withdraw-gift", [signedReceive])
    discard server.pump()
    check answer.state == psPending
    client.send(deliverOnly(exportRef(0).targetDescriptor(),
      [symbol("deposit-gift"), bytes(giftId), descriptor(descImportObject, 5)]))
    discard server.pump()
    discard client.pump()
    check answer.state == psFulfilled
    check answer.value.kind == skRecord

  test "invalid bootstrap withdraw breaks only its answer":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let clientSeed = repeat("c", 32)
    let client = newSession(pair.local, clientSeed)
    discard server.pump()
    discard client.pump()
    let give = handoffGive(glowcapPublicKey(crypto.publicKey(clientSeed)),
      glowcapLocation("127.0.0.1:1"), repeat("a", 32), repeat("b", 32), repeat("j", 32))
    let receive = handoffReceive(server.sessionId(), server.remoteSideId(), 13,
      signatureEnvelope(give, repeat("s", 64)))
    let bad = signatureEnvelope(receive, repeat("x", 64))
    let answer = client.call(exportRef(0), "withdraw-gift", [bad])
    discard server.pump()
    discard client.pump()
    check answer.state == psBroken
    check server.state == ssOpen

  test "invalid handshake closes the session":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    pair.local.send(frame(startSession(bytes("nim://bad"), bytes(repeat("a", 32)),
      bytes(repeat("b", 64))).encoded()))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    discard pair.local.receive() # server's initial hello
    var decoder = newFrameDecoder()
    let abortMessage = decoded(decoder.feed(pair.local.receive())[0])
    check abortMessage.label.data == "op:abort"

  test "rejects application traffic before handshake":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    pair.local.send(frame(deliverOnly(exportRef(0).targetDescriptor(),
      [symbol("fetch"), bytes("not-ready")]).encoded()))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed

  test "disconnect during handshake is terminal":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    pair.local.close()
    check not server.pump()
    check server.state == ssClosed

  test "abort stops processing later frames in the same chunk":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let hello = startSession(bytes("1.0"), bytes(repeat("a", 32)),
      bytes(repeat("b", 64)))
    pair.local.send(frame(abort("stop").encoded()) & frame(hello.encoded()))
    check server.pump()
    check server.state == ssClosed

  test "reference release is idempotence-safe and rejects stale ids":
    var tables = initReferenceTables(1)
    discard tables.allocateExport(proc(args: seq[SyrupValue]): SyrupValue = text("x"))
    tables.retainImport(7)
    tables.retainImport(7)
    check tables.importRefCount(7) == 2
    check tables.releaseImport(7)
    check tables.importRefCount(7) == 1
    check tables.releaseImport(7)
    check not tables.releaseImport(7)
    expect ReferenceError:
      discard tables.releaseExportDelta(42, 1)
    expect ReferenceError:
      discard tables.releaseExportDelta(1, 2)
