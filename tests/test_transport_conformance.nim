import std/[monotimes, net, strutils, times, unittest]
import ../src/[promises, references, session, syrup, transport]

import ../src/session as sessionApi

type
  PairKind = enum pkMemory, pkTcp
  SessionPair = ref object
    server, client: Session
    serverTransport, clientTransport: Transport
    listener: TcpListener

proc installActors(session: Session) =
  discard session.publishActor("greeter", proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    let value = if args.len == 2 and args[0].kind == skSymbol and
        args[0].data == "greet": args[1]
      elif args.len == 1: args[0]
      else: nil
    if not value.isNil and value.kind == skString:
      return text("Hello, " & value.data)
    raise newException(SessionError, "greeter expects greet(string)"))
  discard session.publishActor("reject", proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    let answer = actor.deferAnswer()
    actor.breakAnswer(answer, "expected rejection")
    list())

proc newPair(kind: PairKind): SessionPair =
  new(result)
  case kind
  of pkMemory:
    let pair = inMemoryPair()
    result.serverTransport = pair.remote
    result.clientTransport = pair.local
  of pkTcp:
    result.listener = listenTcp("127.0.0.1", Port(0))
    let client = connectTcp("127.0.0.1", result.listener.localPort())
    client.setNonBlocking()
    let server = result.listener.acceptTcp()
    server.setNonBlocking()
    result.serverTransport = server
    result.clientTransport = client
  result.server = newSession(result.serverTransport, repeat('s', 32),
    "ocapn://server.tcp-testing-only")
  result.client = newSession(result.clientTransport, repeat('c', 32),
    "ocapn://client.tcp-testing-only")
  installActors(result.server)

proc pump(pair: SessionPair) =
  discard pair.server.pump()
  discard pair.client.pump()

proc pumpUntil(pair: SessionPair; done: proc(): bool {.closure.}; timeoutMs = 2000) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    pair.pump()
    if done(): return
    discard pair.serverTransport.waitReadable(1)
    discard pair.clientTransport.waitReadable(1)
  raise newException(SessionError, "transport conformance timeout: server=" &
    $pair.server.state & ", client=" & $pair.client.state)

proc close(pair: SessionPair) =
  pair.client.close("transport conformance cleanup")
  pair.server.close("transport conformance cleanup")
  if not pair.listener.isNil: pair.listener.close()

proc runScenarios(kind: PairKind) =
  let pair = newPair(kind)
  defer: pair.close()
  pumpUntil(pair, proc(): bool = pair.server.state == ssOpen and pair.client.state == ssOpen)

  let fetched = sessionApi.fetch(pair.client, "greeter")
  pumpUntil(pair, proc(): bool = fetched.settled())
  check fetched.state == psFulfilled
  let greeter = fetched.value.descriptor()
  let greeting = sessionApi.call(pair.client, greeter, "greet", [text("world")])
  pumpUntil(pair, proc(): bool = greeting.settled())
  check greeting.state == psFulfilled
  check greeting.value.data == "Hello, world"

  let rejectedRef = sessionApi.fetch(pair.client, "reject")
  pumpUntil(pair, proc(): bool = rejectedRef.settled())
  let rejected = sessionApi.call(pair.client, rejectedRef.value.descriptor(), "reject", [])
  pumpUntil(pair, proc(): bool = rejected.settled())
  check rejected.state == psBroken

  let pipelineFetch = sessionApi.fetch(pair.client, "greeter")
  let pipeline = pair.client.callPipelined(pipelineFetch, "greet", [text("pipeline")])
  pumpUntil(pair, proc(): bool = pipeline.settled())
  if pipeline.state == psBroken:
    raise newException(SessionError, "pipeline rejected: " & pipeline.reason)
  check pipeline.state == psFulfilled
  check pipeline.value.data == "Hello, pipeline"

  let cancelled = sessionApi.call(pair.client, greeter, "greet", [text("cancelled")])
  check pair.client.cancel(cancelled, "test cancellation")
  check cancelled.state == psBroken
  let afterCancel = sessionApi.call(pair.client, greeter, "greet", [text("after")])
  pumpUntil(pair, proc(): bool = afterCancel.settled())
  check afterCancel.state == psFulfilled
  check afterCancel.value.data == "Hello, after"

  pair.client.release(greeter)
  pair.client.release(pipelineFetch.value.descriptor())
  pair.client.release(rejectedRef.value.descriptor())
  pumpUntil(pair, proc(): bool = pair.client.stats().importCount == 0)
  check pair.client.stats().pendingPromises == 0
  check pair.client.state == ssOpen

  let disconnected = sessionApi.call(pair.client, exportRef(0), "fetch", [bytes("greeter")])
  pair.client.close("conformance disconnect")
  check disconnected.state == psBroken
  pair.server.close("conformance disconnect")

suite "transport-neutral CapTP conformance":
  test "same scenarios over in-memory transport":
    runScenarios(pkMemory)

  test "same scenarios over raw TCP transport":
    runScenarios(pkTcp)
