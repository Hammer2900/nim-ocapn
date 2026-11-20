import std/[net, os, strutils, times]
import ../src/[locators, references, server, session, syrup]

const ProviderSwiss = "nim-reverse-pipeline-provider"
const ProviderSwissPath = "bmltLXJldmVyc2UtcGlwZWxpbmUtcHJvdmlkZXI"

var finished = false
var pair: tuple[vow, resolver: CapabilityRef]
var havePair = false
var pendingPipeline = false
var activeSession: Session
var echoRef: CapabilityRef
var traceFile: File
let scenario = getEnv("NIM_OCAPN_REVERSE_SCENARIO", "success")
var pipelineCalls = 0

proc writeTrace(event: TraceEvent) =
  if traceFile != nil:
    traceFile.writeLine($event.number & " " & $event.direction & " " &
      event.operation & " target=" & event.target)
    traceFile.flushFile()
  if event.direction == tdIn and event.operation == "op:deliver" and
      event.target.startsWith("desc:answer:"):
    pendingPipeline = true

proc publish(session: Session) =
  let echo = session.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
    echo "reverse-pipeline: server received pipelined invocation"
    inc pipelineCalls
    if scenario notin ["repeated", "concurrent"] or pipelineCalls >= 2:
      finished = true
    text("nim-reverse-pipeline-ok"))
  echoRef = echo
  discard session.publishActor(ProviderSwiss, proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    if args.len != 1 or args[0].kind != skSymbol:
      raise newException(SessionError, "reverse provider expects one operation")
    case args[0].data
    of "make-promise":
      pair = actor.newPromisePair()
      havePair = true
      return actor.promisePayloadDescriptor(pair.vow)
    of "resolve":
      if not havePair:
        raise newException(SessionError, "reverse promise was not created")
      actor.settlePromise(pair.vow, echo.payloadDescriptor())
      return list()
    of "reject":
      if not havePair:
        raise newException(SessionError, "reverse promise was not created")
      actor.breakPromise(pair.vow, "reverse pipeline rejection")
      return list()
    else:
      raise newException(SessionError, "unknown reverse provider operation"))

let port = Port(if paramCount() > 0: parseInt(paramStr(1)) else: 0)
let locatorFile = getEnv("NIM_OCAPN_PIPELINE_LOCATOR")
let tracePath = getEnv("NIM_OCAPN_PIPELINE_TRACE")
if tracePath.len > 0:
  discard open(traceFile, tracePath, fmWrite)
let manager = newTcpSessionManager("127.0.0.1", port, "nim-reverse-pipeline",
  "127.0.0.1:" & $port, proc(session: Session) =
    activeSession = session
    session.setTraceSink("nim-reverse-pipeline", writeTrace)
    publish(session))
if locatorFile.len > 0:
  let peer = newPeerLocator("tcp-testing-only", "nim-reverse-pipeline",
    [("host", "127.0.0.1"), ("port", $manager.listenPort())])
  let peerUri = peer.peerUri()
  let queryAt = peerUri.find('?')
  let locator = if queryAt < 0:
      peerUri & "/s/" & ProviderSwissPath
    else:
      peerUri[0 ..< queryAt] & "/s/" & ProviderSwissPath & peerUri[queryAt ..^ 1]
  writeFile(locatorFile, locator)
echo "Nim reverse pipeline server listening on ", manager.listenPort()
stdout.flushFile()
let deadline = epochTime() + 30
while not finished and epochTime() < deadline:
  discard manager.poll(50)
  if pendingPipeline and havePair and not activeSession.isNil:
    pendingPipeline = false
    if scenario == "reject":
      activeSession.breakPromise(pair.vow, "reverse pipeline rejection")
      finished = true
    elif scenario != "disconnect":
      activeSession.settlePromise(pair.vow, echoRef.payloadDescriptor())
  if finished: sleep(200)
manager.close()
if traceFile != nil: traceFile.close()
if not finished: quit("reverse pipeline timeout", 1)
