import std/[net, os, strutils, monotimes, times]
import ../src/[handoff, locators, promises, references, server, session, syrup, transport]

const LifetimeMs = 120_000

proc mark(controlDir, name: string) =
  if controlDir.len > 0:
    writeFile(controlDir / name, "ok\n")

proc requested(controlDir, role: string): bool =
  controlDir.len > 0 and fileExists(controlDir / ("stop-" & role))

proc continueOrStop(controlDir, name, role: string): bool =
  if controlDir.len == 0: return true
  let deadline = getMonoTime() + initDuration(milliseconds = LifetimeMs)
  while getMonoTime() < deadline:
    if fileExists(controlDir / ("continue-" & name)): return true
    if requested(controlDir, role): return false
    sleep(2)
  false

proc reportState(role: string; manager: TcpSessionManager; handoffs: HandoffManager = nil) =
  let current = if manager.isNil: TcpManagerStats() else: manager.stats()
  let pendingHandoffs = if handoffs.isNil: 0 else:
    let stats = handoffs.stats()
    stats.pendingEnliven + stats.pendingReceives
  let deposited = current.depositedGifts
  let pendingGifts = current.pendingGiftWithdraws
  echo "STATE " & role & " active=" & $current.activeSessions &
    " pending=" & $current.pendingPromises & " imports=" & $current.imports &
    " exports=" & $current.exports & " handoffs=" & $pendingHandoffs &
    " gifts=" & $deposited & " pendingGifts=" & $pendingGifts
  flushFile(stdout)

proc reportSessionState(role: string; sessions: openArray[Session];
                        handoffs: HandoffManager) =
  var active, pending, imports, exports, queued, gifts, pendingGifts = 0
  for session in sessions:
    if session.isNil: continue
    let stats = session.stats()
    if session.state != ssClosed: inc active
    pending += stats.pendingPromises
    imports += stats.importCount
    exports += stats.exportCount
    queued += stats.queuedBytes
    gifts += stats.depositedGifts
    pendingGifts += stats.pendingGiftWithdraws
  let handoffStats = handoffs.stats()
  echo "STATE " & role & " active=" & $active & " pending=" & $pending &
    " imports=" & $imports & " exports=" & $exports & " handoffs=" &
    $(handoffStats.pendingEnliven + handoffStats.pendingReceives) &
    " gifts=" & $gifts & " pendingGifts=" & $pendingGifts &
    " queued=" & $queued
  flushFile(stdout)

proc pumpSession(session: Session) =
  if session.isNil or session.state == ssClosed:
    return
  try:
    discard session.pump()
  except CatchableError:
    session.close("three-node peer pump failed")

proc runNodeA(port: Port; controlDir = "") =
  let manager = newTcpSessionManager("127.0.0.1", port, "three-node-a",
    "127.0.0.1:" & $port,
    proc(session: Session) =
      mark(controlDir, "A_CONNECTED")
      discard session.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue =
        discard args
        mark(controlDir, "A_INVOCATION_STARTED")
        discard continueOrStop(controlDir, "a-invocation", "A")
        text("Hello, " & "world")))
  echo "READY A " & $manager.listenPort()
  flushFile(stdout)
  defer:
    manager.close()
    reportState("A_POST", manager)
  let deadline = getMonoTime() + initDuration(milliseconds = LifetimeMs)
  while getMonoTime() < deadline and not requested(controlDir, "A"):
    discard manager.poll(50, 64)
  if requested(controlDir, "A"):
    reportState("A", manager)

proc runNodeC(port: Port; controlDir = ""; expectedInvocations = 1) =
  let handoffs = newHandoffManager()
  var invoked = 0
  var failed = false
  let manager = newTcpSessionManager("127.0.0.1", port, "three-node-c",
    "127.0.0.1:" & $port,
    proc(session: Session) =
      mark(controlDir, "C_CONNECTED")
      discard session.publishActor("register", proc(actor: Session;
          args: seq[SyrupValue]): SyrupValue =
        if args.len != 2 or args[0].kind != skSymbol or args[0].data != "register":
          raise newException(SessionError, "register expects one signed gift")
        let answer = actor.deferAnswer()
        var receipt: HandoffReceipt
        try:
          receipt = handoffs.startHandoffReceiver(args[1], actor)
        except CatchableError as error:
          failed = true
          actor.breakAnswer(answer, error.msg)
          return list()
        mark(controlDir, "C_WITHDRAWAL_STARTED")
        if not continueOrStop(controlDir, "withdrawal", "C"):
          failed = true
          discard handoffs.cancel(receipt, "C stopped during withdrawal")
          actor.breakAnswer(answer, "C stopped during withdrawal")
          return list()
        receipt.promise.onSettle(proc(done: Promise) =
          if done.state == psBroken:
            failed = true
            actor.breakAnswer(answer, done.reason)
          else:
            mark(controlDir, "C_WITHDRAWAL_DONE")
            if not continueOrStop(controlDir, "invocation", "C"):
              failed = true
              actor.breakAnswer(answer, "C stopped before invocation")
              return
            let callResult = receipt.session.call(done.value.descriptor(), "greet",
              [text("world")])
            mark(controlDir, "C_INVOCATION_STARTED")
            callResult.onSettle(proc(result: Promise) =
              if result.state == psFulfilled:
                if result.value.kind == skString and result.value.data == "Hello, world":
                  inc invoked
                mark(controlDir, "C_INVOCATION_DONE")
                if not continueOrStop(controlDir, "release", "C"):
                  stderr.writeLine("C stopped before release")
                  failed = true
                  actor.breakAnswer(answer, "C stopped before release")
                  return
                try:
                  receipt.session.release(done.value.descriptor())
                except CatchableError:
                  stderr.writeLine("C capability release failed")
                  failed = true
                  actor.breakAnswer(answer, "C capability release failed")
                  return
                actor.fulfillAnswer(answer, result.value)
              else:
                failed = true
                actor.breakAnswer(answer, result.reason)) )
        list()))
  echo "READY C " & $manager.listenPort()
  flushFile(stdout)
  defer:
    handoffs.close("three-node C shutdown")
    manager.close()
    reportState("C_POST", manager, handoffs)
  let deadline = getMonoTime() + initDuration(milliseconds = LifetimeMs)
  while getMonoTime() < deadline and
      (invoked < expectedInvocations or handoffs.stats().pendingReceives != 0) and
      not failed and not requested(controlDir, "C"):
    discard manager.poll(10, 64)
    discard handoffs.pumpWork(64)
  if invoked == expectedInvocations and handoffs.stats().pendingReceives == 0:
    echo "THREE_NODE_PASS"
  else:
    echo "THREE_NODE_FAIL"
  if requested(controlDir, "C"):
    reportState("C", manager, handoffs)
  flushFile(stdout)

proc connectPeer(host: string; port: Port): Session =
  let transport = connectTcp(host, port)
  transport.setNonBlocking()
  result = newGlowcapSession(transport, "", host & ":" & $port)
  result.remotePeer = newPeerLocator("tcp", host & ":" & $port,
    [("host", host), ("port", $port)])

proc pumpPair(first, second: Session; handoffs: HandoffManager; controlDir = "";
             done: proc(): bool {.closure.}): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = LifetimeMs)
  while getMonoTime() < deadline:
    if requested(controlDir, "B"): return false
    pumpSession(first)
    pumpSession(second)
    discard handoffs.pumpWork(64)
    if done(): return true
    sleep(1)
  false

proc runNodeB(aPort, cPort: Port; controlDir = ""; handoffCount = 1) =
  let handoffs = newHandoffManager()
  let toA = connectPeer("127.0.0.1", aPort)
  let toC = connectPeer("127.0.0.1", cPort)
  defer:
    handoffs.close("three-node B shutdown")
    toA.close("B source session closed after handoff")
    toC.close("B receiver session closed after handoff")
    reportSessionState("B_POST", [toA, toC], handoffs)
  let opened = pumpPair(toA, toC, handoffs, controlDir,
    proc(): bool = toA.state == ssOpen and toC.state == ssOpen)
  if not opened:
    if requested(controlDir, "B"):
      reportSessionState("B", [toA, toC], handoffs)
      return
    quit("three-node B handshake failed", 1)
  let register = toC.fetch("register")
  if not pumpPair(toA, toC, handoffs, controlDir,
      proc(): bool = register.settled()):
    if requested(controlDir, "B"):
      reportState("B", nil, handoffs)
      return
    quit("three-node B register fetch timed out", 1)
  if register.state != psFulfilled:
    quit("three-node B register fetch failed: " & register.reason, 1)
  mark(controlDir, "B_CONNECTED")
  for index in 0 ..< handoffCount:
    let fetched = toA.fetch("origin")
    if not pumpPair(toA, toC, handoffs, controlDir,
        proc(): bool = fetched.settled()):
      if requested(controlDir, "B"):
        reportSessionState("B", [toA, toC], handoffs)
        return
      quit("three-node B origin fetch timed out", 1)
    if fetched.state != psFulfilled:
      quit("three-node B origin fetch failed: " & fetched.reason, 1)
    mark(controlDir, "B_FETCHED" & $index)
    if not continueOrStop(controlDir, "fetched", "B"):
      reportSessionState("B", [toA, toC], handoffs)
      return
    let give = handoffs.handoffArgument(toA, fetched.value.descriptor(), toC)
    mark(controlDir, "B_DEPOSITED" & $index)
    if not continueOrStop(controlDir, "deposited", "B"):
      reportSessionState("B", [toA, toC], handoffs)
      return
    let handoffResult = toC.call(register.value.descriptor(), "register", [give])
    mark(controlDir, "B_WITHDRAWAL_STARTED" & $index)
    if not continueOrStop(controlDir, "b-withdrawal", "B"):
      reportSessionState("B", [toA, toC], handoffs)
      return
    if not pumpPair(toA, toC, handoffs, controlDir,
        proc(): bool = handoffResult.settled()):
      if requested(controlDir, "B"):
        reportSessionState("B", [toA, toC], handoffs)
        return
      quit("three-node B handoff timed out", 1)
    if handoffResult.state != psFulfilled:
      quit("three-node B handoff failed: " & handoffResult.reason, 1)
    toA.release(fetched.value.descriptor())
    mark(controlDir, "B_HANDOFF_DONE" & $index)
  toA.close("B disconnected after successful handoff")
  toC.close("B disconnected after successful handoff")
  mark(controlDir, "B_DISCONNECTED")
  echo "HANDOFF_PASS"
  flushFile(stdout)

when isMainModule:
  if paramCount() < 1:
    quit("usage: three_node_handoff_peer A|B|C [ports]", 1)
  case paramStr(1)
  of "A":
    runNodeA(Port(parseInt(paramStr(2))), if paramCount() >= 3: paramStr(3) else: "")
  of "C":
    runNodeC(Port(parseInt(paramStr(2))),
      if paramCount() >= 3: paramStr(3) else: "",
      if paramCount() >= 4: parseInt(paramStr(4)) else: 1)
  of "B":
    runNodeB(Port(parseInt(paramStr(2))), Port(parseInt(paramStr(3))),
      if paramCount() >= 4: paramStr(4) else: "",
      if paramCount() >= 5: parseInt(paramStr(5)) else: 1)
  else:
    quit("unknown role", 1)
