import std/[strutils, tables, unittest]
import ../src/[gifts, promises, references, session, syrup, transport]
import ./fault_transport

proc pumpPair(a, b: Session; limit = 64) =
  for _ in 0 ..< limit:
    discard a.pump()
    discard b.pump()

proc openPair(a, b: Session) =
  pumpPair(a, b)
  check a.state == ssOpen
  check b.state == ssOpen

suite "distributed GC and reference lifecycle":
  test "one import and repeated release are bounded":
    var tables = initReferenceTables()
    let exported = tables.allocateExport(proc(args: seq[SyrupValue]): SyrupValue = text("x"))
    tables.retainImport(exported.position)
    check tables.importRefCount(exported.position) == 1
    check tables.releaseImport(exported.position)
    check tables.importRefCount(exported.position) == 0
    check not tables.releaseImport(exported.position)

  test "multiple imports release independently":
    var tables = initReferenceTables()
    tables.retainImport(7)
    tables.retainImport(7)
    tables.retainImport(7)
    check tables.importRefCount(7) == 3
    check tables.releaseImport(7)
    check tables.importRefCount(7) == 2
    check tables.releaseImport(7)
    check tables.releaseImport(7)
    check tables.importCount() == 0

  test "nested delivery imports are released after dispatch":
    let pair = inMemoryPair()
    let server = newGlowcapSession(pair.remote, repeat('s', 32), "server")
    discard server.publishObject("accept", proc(args: seq[SyrupValue]): SyrupValue = text("ok"))
    let client = newGlowcapSession(pair.local, repeat('c', 32), "client")
    openPair(server, client)

    let fetched = client.fetch("accept")
    pumpPair(server, client)
    check fetched.state == psFulfilled

    let local = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("local"))
    let call = client.call(fetched.value.descriptor(), "use",
      [list([importObject(local.position).descriptor()])])
    pumpPair(server, client)
    check call.state == psFulfilled
    check call.value.data == "ok"
    check client.references.exports.getOrDefault(local.position).wireRefs == 0
    discard client.references.releaseExport(local.position)
    check not client.references.exports.hasKey(local.position)
    server.close("nested GC cleanup")
    client.close("nested GC cleanup")

  test "forwarding keeps the source import while downstream is alive":
    let pair = inMemoryPair()
    let source = newSession(pair.remote, repeat('a', 32))
    let holder = newSession(pair.local, repeat('b', 32))
    openPair(source, holder)
    let sourceReference = importObject(11)
    source.retain(sourceReference)
    let promise = newPromise()
    let local = holder.newPromisePair().vow
    holder.registerForwardedPromise(local, source, promise)
    promise.fulfill(sourceReference.descriptor())
    holder.settleForwardedPromise(local, promise)
    check source.references.importRefCount(sourceReference.position) == 1
    check holder.stats().forwardedPromiseCount == 1
    holder.close("downstream disconnected")
    check source.references.importRefCount(sourceReference.position) == 0
    source.close("source cleanup")

  test "handoff gift release does not retain a capability":
    let gifts = newGiftTable()
    gifts.deposit("handoff", "receiver", text("capability"))
    let received = gifts.withdraw("handoff", "receiver")
    check received.state == psFulfilled
    check gifts.stats().deposited == 0
    check gifts.stats().pendingWithdraws == 0
    check gifts.stats().redeemed == 1

  test "pending promise and delayed transport clean up on close":
    let pair = faultPair()
    let server = newSession(pair.a, repeat('d', 32))
    discard server.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("never"))
    let client = newSession(pair.b, repeat('e', 32))
    openPair(server, client)
    pair.b.setDelayed(true)
    let pending = client.call(exportRef(0), "never", [])
    client.close("pending cleanup")
    check pending.state == psBroken
    check client.stats().pendingPromises == 0
    check client.stats().importCount == 0
    check client.stats().exportCount == 0
    server.close("pending cleanup")

  test "concurrent close is idempotent and does not resurrect references":
    let pair = faultPair()
    let a = newSession(pair.a, repeat('f', 32))
    let b = newSession(pair.b, repeat('g', 32))
    openPair(a, b)
    discard a.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("owned"))
    a.close("concurrent close")
    b.close("concurrent close")
    a.close("repeat close")
    b.close("repeat close")
    check a.stats().importCount == 0
    check a.stats().exportCount == 0
    check b.stats().importCount == 0
    check b.stats().exportCount == 0

  test "reconnect after cleanup starts with empty session-local tables":
    let first = inMemoryPair()
    let oldServer = newSession(first.remote, repeat('h', 32))
    let oldClient = newSession(first.local, repeat('i', 32))
    openPair(oldServer, oldClient)
    discard oldServer.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("old"))
    oldClient.close("reconnect cleanup")
    oldServer.close("reconnect cleanup")
    check oldClient.stats().pendingPromises == 0
    check oldServer.stats().exportCount == 0

    let replacement = inMemoryPair()
    let newServer = newSession(replacement.remote, repeat('h', 32))
    let newClient = newSession(replacement.local, repeat('i', 32))
    openPair(newServer, newClient)
    discard newServer.exportObject(proc(args: seq[SyrupValue]): SyrupValue = text("new"))
    let answer = newClient.call(exportRef(0), "value", [])
    pumpPair(newServer, newClient)
    check answer.state == psFulfilled
    check answer.value.data == "new"
    newClient.close("reconnect cleanup")
    newServer.close("reconnect cleanup")

  test "release after disconnect is rejected without corrupting tables":
    let pair = inMemoryPair()
    let session = newSession(pair.local, repeat('j', 32))
    let imported = importObject(4)
    session.retain(imported)
    session.close("release after disconnect")
    expect SessionError:
      session.release(imported)
