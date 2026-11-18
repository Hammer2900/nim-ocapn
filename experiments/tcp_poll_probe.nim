import std/[net, os, strutils, times, monotimes]
import ../src/[api, messages, promises, references, server, session, syrup]
import ../src/session as sessionApi

var accepted = false
var chained: tuple[vow, resolver: CapabilityRef]
proc trace(event: TraceEvent) =
  if event.operation in ["op:deliver", "op:listen", "op:gc-answers", "op:gc-exports"] or
      event.operation.startsWith("protocol") or event.operation.startsWith("session") or
      event.operation.startsWith("reference"):
    echo "trace ", event.nodeId, " ", event.direction, " ", event.operation,
      " target=", event.target, " state=", event.promiseState,
      " ownership=", event.ownership
let manager = newTcpSessionManager("127.0.0.1", Port(0), "poll-probe",
  "127.0.0.1:0", proc(session: Session) =
    accepted = true
    chained = session.newPromisePair()
    discard session.publishActor("make", proc(actor: Session;
        args: seq[SyrupValue]): SyrupValue =
      session.promisePayloadDescriptor(chained.vow))
    discard session.publishActor("resolve", proc(actor: Session;
        args: seq[SyrupValue]): SyrupValue =
      session.settlePromise(chained.vow, text("resolved")); list()))
let client = newNode(port = Port(0), seedPrefix = "poll-client")
manager.setTraceSink("A", trace)
client.setTraceSink("B", trace)
let connection = client.dial("127.0.0.1", manager.listenPort(), repeat("p", 32))
let started = getMonoTime()
var iteration = 0
proc elapsedMs(): int64 = (getMonoTime() - started).inNanoseconds div 1_000_000

echo "port=", manager.listenPort(), " dialed state=", connection.state
while (connection.state != ssOpen or not accepted) and
    elapsedMs() < 5000:
  inc iteration
  let serverWork = manager.poll(1, 8)
  let clientWork = client.poll(1, 8)
  if iteration == 1 or iteration mod 100 == 0:
    echo "i=", iteration, " serverWork=", serverWork,
      " clientWork=", clientWork, " accepted=", accepted,
      " state=", connection.state,
      " elapsedMs=", elapsedMs()
  sleep(1)

echo "final state=", connection.state, " accepted=", accepted,
  " iterations=", iteration,
  " elapsedMs=", elapsedMs()
if connection.state != ssOpen or not accepted:
  client.close()
  manager.close()
  quit(1)
let fetched = sessionApi.fetch(connection, "make")
let resolveRef = sessionApi.fetch(connection, "resolve")
let fetchDeadline = getMonoTime() + initDuration(seconds = 5)
while (not settled(fetched) or not settled(resolveRef)) and getMonoTime() < fetchDeadline:
  discard manager.poll(1, 8)
  discard client.poll(1, 8)
  sleep(1)
echo "fetch state=", fetched.state, " resolveState=", resolveRef.state,
  " elapsedMs=", elapsedMs()
if fetched.state != psFulfilled or resolveRef.state != psFulfilled:
  client.close()
  manager.close()
  quit(1)
block mode3:
  let answer = sessionApi.call(connection, fetched.value.descriptor(), "make", [])
  var callbacks = 0
  let resolver = connection.exportObject(proc(args: seq[SyrupValue]): SyrupValue =
    (inc callbacks; list()))
  connection.send(messages.listen(reference(rkAnswer, answer.answerPosition).descriptor(),
    resolver.descriptor(), 3))
  let callDeadline = getMonoTime() + initDuration(seconds = 5)
  while (callbacks < 1 or answer.state == psPending) and getMonoTime() < callDeadline:
    discard manager.poll(1, 8)
    discard client.poll(1, 8)
    sleep(1)
  echo "call state=", answer.state, " callbacks=", callbacks,
    " elapsedMs=", elapsedMs()
  discard sessionApi.call(connection, resolveRef.value.descriptor(), "resolve", [])
  let settleDeadline = getMonoTime() + initDuration(seconds = 1)
  while getMonoTime() < settleDeadline:
    discard manager.poll(1, 8)
    discard client.poll(1, 8)
    sleep(1)
  echo "post-shortening callbacks=", callbacks, " valueKind=", answer.value.kind,
    " elapsedMs=", elapsedMs(), " connection=", connection.state,
    " clientSessions=", client.stats().activeSessions,
    " queued=", client.stats().queuedBytes,
    " sourceSessions=", manager.sessionCount()
  if callbacks != 1 or connection.state != ssOpen or client.stats().queuedBytes != 0:
    client.close()
    manager.close()
    quit(1)
client.close()
manager.close()
