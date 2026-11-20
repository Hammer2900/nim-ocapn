import std/[strutils, tables, unittest]
import ../src/[crypto, framing, gifts, messages, promises, references, session, syrup, transport]

proc sendListen(session: Session; target, resolver: CapabilityRef; mode: int64) =
  session.send(listen(target.targetDescriptor(), resolver.descriptor(), mode))

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
    # The resolver remains wire-retained until the receiver's gc-exports.
    check client.references.exports.hasKey(0)
    check client.references.exports[0].wireRefs == 1
    check client.pump()
    check answer.state == psFulfilled
    check answer.value.kind == skString
    check answer.value.data == "Hello, world"
    # The answer resolver is temporary; the published application export is not.
    check client.references.exportCount() == 0
    check server.references.exports.hasKey(0)
    check server.references.exports[0].localRefs == 1
    discard server.pump() # automatic op:gc-answers from the client
    let reused = client.call(exportRef(0), "greet", [text("again")])
    check reused.answerPosition == answer.answerPosition
    discard server.pump()
    discard client.pump()
    check reused.state == psFulfilled
    check reused.value.data == "Hello, again"
    client.send(gcAnswers([0'i64]))
    expect SessionError:
      discard server.pump()

  test "duplicate callback after answer settlement aborts without pending promises":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("ok"))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let answer = client.call(exportRef(0), "value", [])
    discard server.pump()
    discard client.pump()
    check answer.state == psFulfilled
    server.send(deliverOnly(importObject(0).descriptor(),
      [symbol("fulfill"), text("duplicate")]))
    expect SessionError:
      discard client.pump()
    check client.state == ssClosed
    check client.stats().pendingPromises == 0
    server.close("duplicate callback test")

  test "stale callback after answer wire cleanup cannot revive an answer":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("ok"))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let answer = client.call(exportRef(0), "value", [])
    discard server.pump()
    discard client.pump()
    check answer.state == psFulfilled
    discard server.pump()
    server.send(deliverOnly(importObject(0).descriptor(),
      [symbol("fulfill"), text("stale")]))
    expect SessionError:
      discard client.pump()
    check client.state == ssClosed
    check client.stats().pendingPromises == 0
    server.close("stale callback test")

  test "stale pipeline after gc-answers is rejected":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("ok"))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let answer = client.call(exportRef(0), "value", [])
    discard server.pump()
    discard client.pump()
    check answer.state == psFulfilled
    discard server.pump()
    let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
    client.send(deliver(reference(rkAnswer, answer.answerPosition).descriptor(),
      [symbol("value")], 1, resolver.descriptor(), 3))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    client.close("stale pipeline test")

  test "accounts repeated outbound capability descriptors":
    let pair = inMemoryPair()
    let session = newSession(pair.local)
    let peer = newSession(pair.remote)
    discard session.pump()
    discard peer.pump()
    let capability = session.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("ok"))
    discard session.promisePayloadDescriptor(capability)
    check session.references.exports[capability.position].wireRefs == 1
    discard session.promisePayloadDescriptor(capability)
    check session.references.exports[capability.position].wireRefs == 2
    check session.references.releaseExportDelta(capability.position, 2)
    check session.references.exports[capability.position].wireRefs == 0
    discard session.promisePayloadDescriptor(capability)
    check session.references.exports[capability.position].wireRefs == 1
    check session.references.releaseExportDelta(capability.position, 1)
    check session.references.releaseExport(capability.position)
    check not session.references.exports.hasKey(capability.position)
    session.close()
    peer.close()

  test "op:listen honors settling and shortening modes":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let promisePair = server.newPromisePair()
    var settledNotified = false
    var shortenedNotified = false
    let settlingResolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      (settledNotified = true; list()))
    let shorteningResolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      (shortenedNotified = true; list()))
    client.sendListen(exportRef(promisePair.vow.position), settlingResolver, 2)
    client.sendListen(exportRef(promisePair.vow.position), shorteningResolver, 1)
    for _ in 0 ..< 6:
      discard server.pump()
    client.send(deliverOnly(exportRef(promisePair.resolver.position).targetDescriptor(),
      [symbol("fulfill"), text("done")]))
    discard server.pump()
    discard client.pump()
    check settledNotified
    check not shortenedNotified
    check server.stats().promiseListenerCount == 0

  test "op:listen rejects an invalid mode without installing a listener":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let promise = server.newPromisePair()
    let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
    client.send(record(symbol("op:listen"),
      exportRef(promise.vow.position).descriptor(), resolver.descriptor(), integer(4)))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    check server.stats().promiseListenerCount == 0
    check server.stats().listenerLifecycleCount == 0
    client.close("invalid listen mode")

  test "op:listen can observe a pipelined answer position":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("answer"))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let answer = client.call(exportRef(0), "value", [])
    var notified = 0
    let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      (inc notified; list()))
    client.sendListen(reference(rkAnswer, answer.answerPosition), resolver, 2)
    discard server.pump()
    discard client.pump()
    check answer.state == psFulfilled
    check answer.value.data == "answer"
    check notified == 1
    discard server.pump()
    check server.stats().promiseSlotCount == 0

  test "op:listen answer matrix covers direct and chained modes":
    for mode in 1'i64 .. 3:
      block direct:
        let pair = inMemoryPair()
        let server = newSession(pair.remote)
        discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("direct"))
        let client = newSession(pair.local)
        discard server.pump()
        discard client.pump()
        let answer = client.call(exportRef(0), "value", [])
        var callbacks = 0
        let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
          (inc callbacks; list()))
        client.sendListen(reference(rkAnswer, answer.answerPosition), resolver, mode)
        discard server.pump()
        discard client.pump()
        check answer.state == psFulfilled
        check answer.value.data == "direct"
        check callbacks == (if mode == 1: 0 else: 1)
        discard server.pump()
        server.close("answer listen direct")
        client.close("answer listen direct")

      block chained:
          let pair = inMemoryPair()
          let server = newSession(pair.remote)
          let next = server.newPromisePair()
          let target = server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
            server.promisePayloadDescriptor(next.vow))
          let client = newSession(pair.local)
          discard server.pump()
          discard client.pump()
          let answer = client.call(target, "value", [])
          var callbacks = 0
          let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
            (inc callbacks; list()))
          client.sendListen(reference(rkAnswer, answer.answerPosition), resolver, mode)
          discard server.pump()
          discard client.pump()
          check callbacks == (if mode in [1'i64, 3'i64]: 1 else: 0)
          check answer.state == psFulfilled
          server.settlePromise(next.vow, text("chained"))
          discard server.pump()
          discard client.pump()
          check callbacks == 1
          server.close("answer listen chained")
          client.close("answer listen chained")

  test "disconnect between answer shortening and settling cleans listeners":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let next = server.newPromisePair()
    let target = server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      server.promisePayloadDescriptor(next.vow))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let answer = client.call(target, "value", [])
    var callbacks = 0
    let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      (inc callbacks; list()))
    client.sendListen(reference(rkAnswer, answer.answerPosition), resolver, 3)
    discard server.pump()
    discard client.pump()
    check answer.state == psFulfilled
    check callbacks == 1
    check server.stats().promiseListenerCount == 0
    server.close("disconnect during answer settling")
    discard client.pump()
    check client.state == ssClosed
    check client.stats().pendingPromises == 0
    check server.stats().promiseListenerCount == 0
    client.close("answer listener disconnect cleanup")

  test "op:listen modes continue across local promise shortening":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let shortening = server.newPromisePair()
    let settling = server.newPromisePair()
    var shorteningCount = 0
    var settlingCount = 0
    let shorteningResolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      (inc shorteningCount; list()))
    let settlingResolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      (inc settlingCount; list()))
    client.sendListen(exportRef(shortening.vow.position), shorteningResolver, 1)
    client.sendListen(exportRef(shortening.vow.position), shorteningResolver, 1)
    client.sendListen(exportRef(settling.vow.position), settlingResolver, 2)
    for _ in 0 ..< 6:
      discard server.pump()
    server.settlePromise(shortening.vow, server.promisePayloadDescriptor(settling.vow))
    server.settlePromise(settling.vow, text("settled"))
    for _ in 0 ..< 6:
      discard client.pump()
    check shorteningCount == 1
    check settlingCount == 1
    check server.stats().promiseListenerCount == 0
    check server.stats().listenerLifecycleCount == 0

  test "mode 2 follows shortening to a same-peer broken promise":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let first = server.newPromisePair()
    let next = server.newPromisePair()
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    var callbacks = 0
    let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      (inc callbacks; list()))
    client.sendListen(exportRef(first.vow.position), resolver, 2)
    discard server.pump()
    server.settlePromise(first.vow, server.promisePayloadDescriptor(next.vow))
    discard server.pump()
    discard client.pump()
    check callbacks == 0
    server.breakPromise(next.vow, "shortened promise broken")
    discard server.pump()
    discard client.pump()
    check callbacks == 1
    check server.stats().promiseListenerCount == 0

  test "op:listen matrix covers direct, chains, break, and repeated shortening":
    for mode in 1'i64 .. 3:
      block direct:
        let pair = inMemoryPair()
        let server = newSession(pair.remote)
        let client = newSession(pair.local)
        discard server.pump()
        discard client.pump()
        let promise = server.newPromisePair()
        var callbacks = 0
        let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
          (inc callbacks; list()))
        client.sendListen(exportRef(promise.vow.position), resolver, mode)
        discard server.pump()
        server.settlePromise(promise.vow, text("direct"))
        discard server.pump()
        discard client.pump()
        check callbacks == (if mode == 1: 0 else: 1)
        check server.stats().promiseListenerCount == 0

      block chained:
        let pair = inMemoryPair()
        let server = newSession(pair.remote)
        let client = newSession(pair.local)
        discard server.pump()
        discard client.pump()
        let first = server.newPromisePair()
        let second = server.newPromisePair()
        let third = server.newPromisePair()
        var callbacks = 0
        let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
          (inc callbacks; list()))
        client.sendListen(exportRef(first.vow.position), resolver, mode)
        discard server.pump()
        server.settlePromise(first.vow, server.promisePayloadDescriptor(second.vow))
        discard server.pump()
        discard client.pump()
        server.settlePromise(second.vow, server.promisePayloadDescriptor(third.vow))
        discard server.pump()
        discard client.pump()
        server.settlePromise(third.vow, text("chained"))
        discard server.pump()
        discard client.pump()
        let expected = 1
        check callbacks == expected
        check server.stats().promiseListenerCount == 0

      block broken:
        let pair = inMemoryPair()
        let server = newSession(pair.remote)
        let client = newSession(pair.local)
        discard server.pump()
        discard client.pump()
        let promise = server.newPromisePair()
        var callbacks = 0
        let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
          (inc callbacks; list()))
        client.sendListen(exportRef(promise.vow.position), resolver, mode)
        discard server.pump()
        server.breakPromise(promise.vow, "broken")
        discard server.pump()
        discard client.pump()
        check callbacks == (if mode == 1: 0 else: 1)
        check server.stats().promiseListenerCount == 0

  test "gc-answers retires answer positions exactly once":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("ok"))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let answer = client.call(exportRef(0), "value", [])
    discard server.pump()
    discard client.pump()
    check answer.state == psFulfilled
    check server.stats().inboundAnswerCount == 1
    discard server.pump()
    check server.stats().inboundAnswerCount == 0
    client.send(gcAnswers([0'i64]))
    expect SessionError:
      discard server.pump()

  test "disconnect during listen clears promise listeners":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let promisePair = server.newPromisePair()
    let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
    client.sendListen(exportRef(promisePair.vow.position), resolver, 3)
    discard server.pump()
    check server.stats().promiseListenerCount == 1
    client.close("listen disconnect")
    discard server.pump()
    check server.state == ssClosed
    check server.stats().promiseSlotCount == 0
    check server.stats().listenerLifecycleCount == 0
    server.close("repeat close after listen disconnect")
    check server.stats().promiseListenerCount == 0
    check server.stats().listenerLifecycleCount == 0

  test "GC audit protects application exports and deduplicates listeners":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("application"))
    discard server.pump()
    discard client.pump()

    client.send(gcExports([0'i64], [1'i64]))
    discard server.pump()
    check server.references.exports.hasKey(0)
    check server.references.exports[0].localRefs == 1

    let promise = server.newPromisePair()
    var callbacks = 0
    let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      (inc callbacks; list()))
    client.sendListen(exportRef(promise.vow.position), resolver, 2)
    discard server.pump()
    server.settlePromise(promise.vow, text("done"))
    discard server.pump()
    discard client.pump()

    # Repeating the same listen must not emit a second GC for the resolver.
    client.sendListen(exportRef(promise.vow.position), resolver, 2)
    discard server.pump()
    for _ in 0 ..< 3:
      discard client.pump()
    check callbacks == 2
    check server.references.exports.hasKey(0)

  test "forwarded promise wire ownership rejects duplicate GC":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let local = server.newPromisePair().vow
    server.registerForwardedPromise(local, server, newPromise())
    check server.forwardedWireRefs(local) == 1
    check not server.forwardedRegistry.findForwardedOrigin(
      client.localPublicKey, importPromise(local.position)).isNil
    client.send(gcExports([local.position], [1'i64]))
    discard server.pump()
    check server.forwardedWireRefs(local) == 0
    client.send(gcExports([local.position], [1'i64]))
    expect ReferenceError:
      discard server.pump()
    check server.state == ssClosed

  test "forwarded GC releases the settled source import":
    let pair = inMemoryPair()
    let target = newSession(pair.remote)
    let sourceSession = newSession(pair.local)
    discard target.pump()
    discard sourceSession.pump()
    let sourceReference = importObject(42)
    sourceSession.retain(sourceReference)
    let source = newPromise()
    source.fulfill(sourceReference.descriptor())
    let local = target.newPromisePair().vow
    target.registerForwardedPromise(local, sourceSession, source)
    target.settleForwardedPromise(local, source)
    sourceSession.send(gcExports([local.position], [1'i64]))
    discard target.pump()
    check sourceSession.references.importRefCount(sourceReference.position) == 0
    check target.stats().forwardedPromiseCount == 0

  test "forwarded GC before settle retires after source settlement":
    let pair = inMemoryPair()
    let target = newSession(pair.remote)
    let sourceSession = newSession(pair.local)
    discard target.pump()
    discard sourceSession.pump()
    let sourceReference = importObject(43)
    sourceSession.retain(sourceReference)
    let source = newPromise()
    let local = target.newPromisePair().vow
    target.registerForwardedPromise(local, sourceSession, source)
    sourceSession.send(gcExports([local.position], [1'i64]))
    discard target.pump()
    check target.stats().forwardedPromiseCount == 1
    source.fulfill(sourceReference.descriptor())
    target.settleForwardedPromise(local, source)
    check target.stats().forwardedPromiseCount == 0
    check sourceSession.references.importRefCount(sourceReference.position) == 0

  test "closing forwarded target releases source import":
    let pair = inMemoryPair()
    let target = newSession(pair.remote)
    let sourceSession = newSession(pair.local)
    discard target.pump()
    discard sourceSession.pump()
    let sourceReference = importObject(44)
    sourceSession.retain(sourceReference)
    let source = newPromise()
    source.fulfill(sourceReference.descriptor())
    let local = target.newPromisePair().vow
    target.registerForwardedPromise(local, sourceSession, source)
    target.settleForwardedPromise(local, source)
    check sourceSession.references.importRefCount(sourceReference.position) == 1
    target.close("disconnect before wire GC")
    check sourceSession.references.importRefCount(sourceReference.position) == 0

  test "disconnect between listener callback and wire GC is bounded":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let promise = server.newPromisePair()
    let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
    client.sendListen(exportRef(promise.vow.position), resolver, 3)
    discard server.pump()
    server.settlePromise(promise.vow, text("done"))
    discard server.pump()
    client.close("disconnect before callback/GC drain")
    discard server.pump()
    check server.state == ssClosed
    check server.stats().promiseSlotCount == 0
    check server.stats().promiseListenerCount == 0

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

  test "reference keys preserve descriptor perspective":
    check referenceKey(importObject(7)) != referenceKey(importPromise(7))
    check referenceKey(importObject(7)) != referenceKey(exportRef(7))
    check referenceKey(importPromise(7)) != referenceKey(exportRef(7))

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
    let followup = client.call(exportRef(1), "make", [])
    check followup.answerPosition == factoryResult.answerPosition or
      followup.answerPosition == pipelinedResult.answerPosition
    let followupPipeline = client.callPipelined(followup, "value", [])
    discard server.pump()
    discard client.pump()
    discard client.pump()
    check followup.state == psFulfilled
    check followup.value.kind == skRecord
    check followupPipeline.state == psFulfilled
    check followupPipeline.value.data == "pipelined"

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

  test "pipelines through a remote promise reference":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let remoteThing = server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      check args.len == 0
      text("remote promise pipeline"))
    let pending = server.newPromisePair()
    let factory = server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      check args.len == 1
      check args[0].kind == skSymbol and args[0].data == "make"
      server.promisePayloadDescriptor(pending.vow))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let factoryResult = client.call(factory, "make", [])
    discard server.pump()
    discard client.pump()
    check factoryResult.state == psFulfilled
    check factoryResult.value.kind == skRecord
    check factoryResult.value.label.kind == skSymbol
    check factoryResult.value.label.data == "desc:import-promise"
    check factoryResult.value.fields.len == 1
    check factoryResult.value.fields[0].kind == skInteger
    let pipelinedResult = client.deliverCall(factoryResult.value.descriptor(),
      [symbol("value")])
    discard client.pump()
    discard server.pump()
    check pipelinedResult.state == psPending
    server.settlePromise(pending.vow, remoteThing.payloadDescriptor())
    discard server.pump()
    discard client.pump()
    check pipelinedResult.state == psFulfilled
    check pipelinedResult.value.data == "remote promise pipeline"

  test "external answer promise pipeline propagates rejection and cleans up":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let pending = server.newPromisePair()
    let factory = server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      server.promisePayloadDescriptor(pending.vow))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let answer = client.call(factory, "make", [])
    discard server.pump()
    discard client.pump()
    check answer.state == psFulfilled
    let pipelined = client.deliverCall(answer.value.descriptor(), [symbol("value")])
    discard server.pump()
    check pipelined.state == psPending
    server.breakPromise(pending.vow, "external promise rejected")
    discard server.pump()
    discard client.pump()
    check pipelined.state == psBroken
    check pipelined.reason == "external promise rejected"
    server.close("external promise rejection cleanup")
    client.close("external promise rejection cleanup")
    check server.stats().promiseSlotCount == 0

  test "external answer promise pipeline handles concurrent delivery once":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let remote = server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      text("concurrent pipeline"))
    let pending = server.newPromisePair()
    let factory = server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      server.promisePayloadDescriptor(pending.vow))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let answer = client.call(factory, "make", [])
    discard server.pump()
    discard client.pump()
    let first = client.deliverCall(answer.value.descriptor(), [symbol("value")])
    let second = client.deliverCall(answer.value.descriptor(), [symbol("value")])
    discard server.pump()
    check first.state == psPending
    check second.state == psPending
    server.settlePromise(pending.vow, remote.payloadDescriptor())
    server.settlePromise(pending.vow, remote.payloadDescriptor())
    discard server.pump()
    discard client.pump()
    check first.state == psFulfilled
    check second.state == psFulfilled
    check first.value.data == "concurrent pipeline"
    check second.value.data == "concurrent pipeline"
    check server.stats().pendingPromises == 0
    server.close("external promise duplicate settlement")
    client.close("external promise duplicate settlement")
    check server.stats().promiseSlotCount == 0

  test "external answer promise pipeline disconnect cleans pending delivery":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let pending = server.newPromisePair()
    let factory = server.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      server.promisePayloadDescriptor(pending.vow))
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    let answer = client.call(factory, "make", [])
    discard server.pump()
    discard client.pump()
    let pipelined = client.deliverCall(answer.value.descriptor(), [symbol("value")])
    discard server.pump()
    check pipelined.state == psPending
    server.close("external promise disconnect")
    discard client.pump()
    check client.state == ssClosed
    check client.stats().pendingPromises == 0
    check server.stats().promiseSlotCount == 0
    client.close("external promise disconnect cleanup")

  test "forwarded capability proxy retires after wire GC":
    let pair = inMemoryPair()
    let source = newSession(pair.remote)
    let holder = newSession(pair.local)
    let sourceObject = source.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
      text("proxy"))
    discard source.pump()
    discard holder.pump()
    let proxy = holder.exportCapabilityProxy(source, sourceObject)
    check holder.stats().forwardedProxyCount == 1
    source.send(gcExports([proxy.position], [1'i64]))
    discard holder.pump()
    check holder.stats().forwardedProxyCount == 0

  test "disconnect breaks an active forwarded capability proxy":
    let pair = inMemoryPair()
    let source = newSession(pair.remote)
    let holder = newSession(pair.local)
    let sourceObject = source.exportActor(proc(actor: Session;
        args: seq[SyrupValue]): SyrupValue =
      discard actor.deferAnswer()
      list())
    discard source.pump()
    discard holder.pump()
    let proxy = holder.exportCapabilityProxy(source, sourceObject)
    check holder.stats().forwardedProxyCount == 1
    pair.remote.close()
    discard holder.pump()
    check holder.state == ssClosed
    holder.close("downstream proxy cleanup")
    check holder.stats().forwardedProxyCount == 0
    check holder.stats().pendingPromises == 0

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
    let giftId = repeat("i", 32)
    let give = handoffGive(glowcapPublicKey(crypto.publicKey(clientSeed)),
      glowcapLocation("127.0.0.1:1"), server.sessionId(), server.remoteSideId(), giftId)
    let signedGive = signatureEnvelope(give, crypto.sign(clientSeed, give.encoded()))
    let receive = handoffReceive(server.sessionId(), server.remoteSideId(), 11, signedGive)
    let signedReceive = signatureEnvelope(receive,
      crypto.sign(clientSeed, receive.encoded()))
    server.depositGift(giftId, "", text("redeemed"),
      GiftProvenance(sessionId: server.sessionId(),
        gifterSide: server.remoteSideId(), gifterKey: client.localPublicKey))
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
    let giftId = repeat("j", 32)
    let give = handoffGive(glowcapPublicKey(crypto.publicKey(clientSeed)),
      glowcapLocation("127.0.0.1:1"), server.sessionId(), server.remoteSideId(), giftId)
    let signedGive = signatureEnvelope(give, crypto.sign(clientSeed, give.encoded()))
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

  test "withdraw rejects a give from another gifter session":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let clientSeed = repeat("c", 32)
    let client = newSession(pair.local, clientSeed)
    discard server.pump()
    discard client.pump()
    let giftId = repeat("w", 32)
    let give = handoffGive(glowcapPublicKey(crypto.publicKey(clientSeed)),
      glowcapLocation("127.0.0.1:1"), repeat("x", 32), server.remoteSideId(), giftId)
    let signedGive = signatureEnvelope(give,
      crypto.sign(clientSeed, give.encoded()))
    let receive = handoffReceive(server.sessionId(), server.remoteSideId(), 14,
      signedGive)
    let signedReceive = signatureEnvelope(receive,
      crypto.sign(clientSeed, receive.encoded()))
    server.depositGift(giftId, "", text("gift"),
      GiftProvenance(sessionId: server.sessionId(),
        gifterSide: server.remoteSideId(), gifterKey: client.localPublicKey))
    let answer = client.call(exportRef(0), "withdraw-gift", [signedReceive])
    discard server.pump()
    discard client.pump()
    check answer.state == psBroken
    check server.state == ssOpen

  test "protected withdraw rejects an unbound legacy gift":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let clientSeed = repeat("c", 32)
    let client = newSession(pair.local, clientSeed)
    discard server.pump()
    discard client.pump()
    let giftId = repeat("l", 32)
    let give = handoffGive(glowcapPublicKey(crypto.publicKey(clientSeed)),
      glowcapLocation("127.0.0.1:1"), server.sessionId(), server.remoteSideId(), giftId)
    let signedGive = signatureEnvelope(give, crypto.sign(clientSeed, give.encoded()))
    let receive = handoffReceive(server.sessionId(), server.remoteSideId(), 15,
      signedGive)
    let signedReceive = signatureEnvelope(receive,
      crypto.sign(clientSeed, receive.encoded()))
    server.depositGift(giftId, "", text("legacy"))
    let answer = client.call(exportRef(0), "withdraw-gift", [signedReceive])
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
    var decoder = newFrameDecoder()
    var sawAbort = false
    for wire in decoder.feed(pair.local.receive()):
      if decoded(wire).label.data == "op:abort":
        sawAbort = true
    check sawAbort

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
    let answerExport = tables.allocateExport(
      proc(args: seq[SyrupValue]): SyrupValue = text("answer"), eoAnswerResolver)
    let listenerExport = tables.allocateExport(
      proc(args: seq[SyrupValue]): SyrupValue = text("listener"), eoListenerResolver)
    check tables.exports[1].owner == eoApplication
    check tables.exports[answerExport.position].owner == eoAnswerResolver
    check tables.exports[listenerExport.position].owner == eoListenerResolver
    let repeated = tables.allocateExport(
      proc(args: seq[SyrupValue]): SyrupValue = text("repeated"))
    check tables.exports[repeated.position].wireRefs == 1
    tables.retainExport(repeated.position)
    tables.retainExport(repeated.position)
    check tables.exports[repeated.position].wireRefs == 3
    discard tables.releaseExportDelta(repeated.position, 1)
    check tables.exports[repeated.position].wireRefs == 2
    discard tables.releaseExportDelta(repeated.position, 1)
    check tables.exports[repeated.position].wireRefs == 1
    discard tables.releaseExportDelta(repeated.position, 1)
    check tables.exports[repeated.position].wireRefs == 0
    check tables.exports.hasKey(repeated.position)
    discard tables.releaseExport(repeated.position)
    check not tables.exports.hasKey(repeated.position)
    expect ReferenceError:
      discard tables.releaseWireExport(importObject(1), 1)
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
