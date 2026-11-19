import std/[strutils, unittest]
import ../src/[promises, references, session, syrup, transport]

when defined(endurance):
  const invocationCount = 2000
  const sessionCount = 100
else:
  const invocationCount = 250
  const sessionCount = 20

proc pumpPair(left, right: Session; rounds = 8) =
  for _ in 0 ..< rounds:
    discard left.pump()
    discard right.pump()

proc rssKiB(): int =
  when defined(linux):
    let fields = readFile("/proc/self/statm").splitWhitespace()
    if fields.len > 1:
      return (parseInt(fields[1]) * 4096) div 1024
  0

proc echoBehavior(args: seq[SyrupValue]): SyrupValue =
  if args.len == 2 and args[0].kind == skSymbol and args[1].kind == skString:
    return args[1]
  raise newException(SessionError, "invalid echo arguments")

suite "resource lifecycle":
  test "sequential calls return to bounded state":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    discard server.exportObject(echoBehavior)
    let client = newSession(pair.local)
    pumpPair(server, client)
    let startRss = rssKiB()
    var peakPending = 0
    for index in 0 ..< invocationCount:
      let result = client.call(exportRef(0), "echo", [text($index)])
      pumpPair(server, client)
      check result.state == psFulfilled
      check result.value.kind == skString
      check result.value.data == $index
      peakPending = max(peakPending, client.stats().pendingPromises)
      check client.stats().queuedBytes == 0
    let beforeClose = client.stats()
    check beforeClose.pendingPromises == 0
    check beforeClose.answerCount == 0
    check beforeClose.exportCount == 0
    check server.stats().exportCount == 1
    let endRss = rssKiB()
    echo "resource calls=", invocationCount, " peakPending=", peakPending,
      " clientExports=", beforeClose.exportCount, " rssKiB=", startRss, "->", endRss
    client.close("resource lifecycle")
    server.close("resource lifecycle")
    check client.stats().pendingPromises == 0
    check client.stats().importCount == 0
    check client.stats().exportCount == 0
    check server.stats().exportCount == 0

  test "repeated sessions release all session-local state":
    var peakSessions = 0
    for index in 0 ..< sessionCount:
      let pair = inMemoryPair()
      let server = newSession(pair.remote, repeat("s", 31) & char(ord('a') + index mod 26))
      let client = newSession(pair.local, repeat("c", 31) & char(ord('a') + index mod 26))
      pumpPair(server, client)
      check server.state == ssOpen
      check client.state == ssOpen
      peakSessions = max(peakSessions, 2)
      client.close("repeated session")
      server.close("repeated session")
      check client.stats().pendingPromises == 0
      check client.stats().importCount == 0
      check client.stats().exportCount == 0
      check server.stats().exportCount == 0
    echo "resource repeatedSessions=", sessionCount, " peakSessions=", peakSessions

  test "valid unresolved calls stop at the pending limit":
    var limits = defaultSessionLimits()
    limits.maxPendingPromises = 8
    let pair = inMemoryPair()
    let server = newSession(pair.remote, limits = limits)
    discard server.exportActor(proc(actor: Session; args: seq[SyrupValue]): SyrupValue =
      (discard actor.deferAnswer(); list()))
    let client = newSession(pair.local, limits = limits)
    pumpPair(server, client)
    var pending: seq[Promise]
    for _ in 0 ..< limits.maxPendingPromises:
      pending.add(client.call(exportRef(0), "hold", []))
    check client.stats().pendingPromises == limits.maxPendingPromises
    expect SessionError:
      discard client.call(exportRef(0), "hold", [])
    for promise in pending:
      check promise.state == psPending
    client.close("pending limit")
    server.close("pending limit")
    check client.stats().pendingPromises == 0
    check server.stats().answerCount == 0

