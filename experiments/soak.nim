import std/[net, os, strutils, times, monotimes]
import ../src/[api, promises, references, syrup]
import ../src/server as serverApi
import ../src/session as sessionApi

proc rssKb(): int =
  if not fileExists("/proc/self/status"): return 0
  for line in lines("/proc/self/status"):
    if line.startsWith("VmRSS:"):
      let fields = line.splitWhitespace()
      if fields.len >= 2:
        try: return parseInt(fields[1])
        except ValueError: return 0

proc pumpAll(server, handoffNode: Node; clients: seq[Node]) =
  discard server.poll(0, 64)
  discard handoffNode.poll(0, 64)
  for client in clients:
    discard client.poll(0, 64)

proc waitOpen(server, handoffNode: Node; clients: seq[Node];
              sessions: seq[Session]; deadline: MonoTime): bool =
  while true:
    var open = true
    for session in sessions:
      if session.state != ssOpen: open = false
    if open: return true
    if getMonoTime() >= deadline: return false
    pumpAll(server, handoffNode, clients)

proc waitPromise(server, handoffNode: Node; clients: seq[Node];
                 promise: Promise; deadline: MonoTime): bool =
  while not settled(promise):
    if getMonoTime() >= deadline: return false
    pumpAll(server, handoffNode, clients)
  promise.state == psFulfilled

proc elapsedSeconds(started: MonoTime): float =
  (getMonoTime() - started).inNanoseconds.float / 1_000_000_000.0

let duration = if paramCount() >= 1: parseInt(paramStr(1)) else: 1800
let clientCount = if paramCount() >= 2: parseInt(paramStr(2)) else: 4
if duration <= 0 or clientCount <= 0:
  quit("usage: soak [SECONDS=1800] [CLIENTS=4]")
var stopRequested = false
proc onControlC() {.noconv.} = stopRequested = true
setControlCHook(onControlC)

let server = newNode(port = Port(0), seedPrefix = "soak-server")
server.publish("origin", proc(args: seq[SyrupValue]): SyrupValue =
  if args.len == 1: text("Hello from A, " & args[0].data) else: text("bad args"))
let handoffNode = newNode(port = Port(0), seedPrefix = "soak-handoff")
var received: RemoteCapability
handoffNode.publishTyped("register", proc(session: sessionApi.Session;
    args: seq[ReceivedArgument]): SyrupValue =
  if args.len != 1 or args[0].kind != rakCapability:
    raise newException(SessionError, "register expects one capability")
  received = args[0].capability
  text("registered"))

var clients: seq[Node]
var connections: seq[Session]
for index in 0 ..< clientCount:
  let client = newNode(port = Port(0), seedPrefix = "soak-client-" & $index)
  clients.add(client)
  connections.add(client.dial("127.0.0.1", server.manager.listenPort(),
    repeat(char(ord('a') + index mod 20), 32)))
connections.add(clients[0].dial("127.0.0.1", handoffNode.manager.listenPort(),
  repeat("h", 32)))
if not waitOpen(server, handoffNode, clients, connections,
    getMonoTime() + initDuration(seconds = 30)):
  quit("initial handshake timeout")

let outputPath = if paramCount() >= 3: paramStr(3) else: "soak.csv"
let output = open(outputPath, fmWrite)
output.writeLine("elapsed_s,calls,reconnects,active_sessions,pending_promises,imports,exports,pending_handoffs,queued_bytes,rss_kb")
let started = getMonoTime()
let finishAt = started + initDuration(seconds = duration)
var nextReport = started
var calls = 0
var reconnects = 0
var origin: RemoteCapability
var register: RemoteCapability
var handoffReady = false

proc establishCapabilities(): bool =
  let originPromise = sessionApi.fetch(connections[0], "origin")
  if not waitPromise(server, handoffNode, clients, originPromise,
      getMonoTime() + initDuration(seconds = 10)): return false
  origin = RemoteCapability(session: connections[0],
    reference: originPromise.value.descriptor())
  let registerPromise = sessionApi.fetch(connections[^1], "register")
  if not waitPromise(server, handoffNode, clients, registerPromise,
      getMonoTime() + initDuration(seconds = 10)): return false
  register = RemoteCapability(session: connections[^1],
    reference: registerPromise.value.descriptor())
  let registered = clients[0].call(register, "register", [capabilityArg(origin)])
  if not waitPromise(server, handoffNode, clients, registered,
      getMonoTime() + initDuration(seconds = 10)): return false
  handoffReady = true
  true

proc recordMetrics(elapsed: float) =
  let stats = clients[0].stats()
  let serverStats = server.stats()
  let handoffStats = handoffNode.stats()
  output.writeLine($elapsed & "," & $calls & "," & $reconnects & "," &
    $(serverStats.activeSessions + stats.activeSessions + handoffStats.activeSessions) & "," &
    $(serverStats.pendingPromises + stats.pendingPromises + handoffStats.pendingPromises) & "," &
    $(serverStats.imports + stats.imports + handoffStats.imports) & "," &
    $(serverStats.exports + stats.exports + handoffStats.exports) & "," &
    $(serverStats.pendingHandoffs + stats.pendingHandoffs + handoffStats.pendingHandoffs) & "," &
    $(serverStats.queuedBytes + stats.queuedBytes + handoffStats.queuedBytes) & "," & $rssKb())
  output.flushFile()

proc runSoak() =
  defer:
    try: recordMetrics(elapsedSeconds(started))
    except CatchableError: discard
    output.close()
    for client in clients: client.close()
    handoffNode.close()
    server.close()

  if not establishCapabilities():
    raise newException(CatchableError, "initial capability setup timeout")
  while not stopRequested and getMonoTime() < finishAt:
    if not handoffReady:
      raise newException(CatchableError, "handoff was not established")
    let capability = if received.session.isNil: origin else: received
    let answer = capability.call("greet", [text("soak")])
    if not waitPromise(server, handoffNode, clients, answer,
        getMonoTime() + initDuration(seconds = 10)):
      raise newException(CatchableError, "call failed or timed out")
    inc calls

    if calls mod 256 == 0:
      stderr.writeLine("reconnect at calls=", calls)
      flushFile(stderr)
      if not received.session.isNil:
        received.session.close("soak handoff reconnect")
        received = RemoteCapability()
      for session in connections: session.close("soak reconnect")
      let cleanupDeadline = getMonoTime() + initDuration(seconds = 10)
      while (server.manager.sessionCount > 0 or handoffNode.manager.sessionCount > 0) and
          getMonoTime() < cleanupDeadline:
        discard server.poll(10, 64)
        discard handoffNode.poll(0, 64)
        for client in clients: discard client.poll(0, 64)
      if server.manager.sessionCount > 0 or handoffNode.manager.sessionCount > 0:
        raise newException(CatchableError, "reconnect cleanup timeout")
      connections.setLen(0)
      for index, client in clients:
        connections.add(client.dial("127.0.0.1", server.manager.listenPort(),
          repeat(char(ord('a') + index mod 20), 32)))
      connections.add(clients[0].dial("127.0.0.1", handoffNode.manager.listenPort(),
        repeat("h", 32)))
      if not waitOpen(server, handoffNode, clients, connections,
          getMonoTime() + initDuration(seconds = 30)):
        raise newException(CatchableError, "reconnect handshake timeout")
      handoffReady = false
      if not establishCapabilities():
        raise newException(CatchableError, "reconnect capability timeout")
      inc reconnects

    if getMonoTime() >= nextReport:
      recordMetrics(elapsedSeconds(started))
      nextReport = getMonoTime() + initDuration(seconds = 30)

runSoak()
if stopRequested:
  echo "soak stopped calls=", calls, " reconnects=", reconnects, " csv=", outputPath
else:
  echo "soak complete calls=", calls, " reconnects=", reconnects, " csv=", outputPath
