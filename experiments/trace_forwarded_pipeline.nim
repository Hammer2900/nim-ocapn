import std/[algorithm, net, os, strutils]
import ../src/[api, promises, references, server, session, syrup]
import ../src/session as sessionApi

type TraceLog = ref object
  events: seq[TraceEvent]

proc addTrace(log: TraceLog): TraceSink =
  proc(event: TraceEvent) = log.events.add(event)

proc pumpAll(a, b, c: Node) =
  discard a.poll(1, 8)
  discard b.poll(1, 8)
  discard c.poll(1, 8)

proc main() =
  let traceA = TraceLog(events: @[])
  let traceB = TraceLog(events: @[])
  let traceC = TraceLog(events: @[])
  let nodeA = newNode(port = Port(0), seedPrefix = "trace-a")
  let nodeB = newNode(port = Port(0), seedPrefix = "trace-b")
  let nodeC = newNode(port = Port(0), seedPrefix = "trace-c")
  nodeA.setTraceSink("A", traceA.addTrace())
  nodeB.setTraceSink("B", traceB.addTrace())
  nodeC.setTraceSink("C", traceC.addTrace())

  var ready = false
  var pair: tuple[vow, resolver: CapabilityRef]
  var greeter: CapabilityRef
  nodeA.publishTyped("make", proc(session: Session; args: seq[ReceivedArgument]): SyrupValue =
    if not ready:
      pair = session.newPromisePair()
      greeter = session.exportObject(proc(values: seq[SyrupValue]): SyrupValue =
        if values.len == 1 and values[0].kind == skString:
          text("Hello from A, " & values[0].data)
        else:
          text("invalid args"))
      ready = true
    session.promisePayloadDescriptor(pair.vow))
  nodeA.publishTyped("resolve", proc(session: Session; args: seq[ReceivedArgument]): SyrupValue =
    if ready:
      session.settlePromise(pair.vow, greeter.payloadDescriptor())
    list())

  var received: ReceivedArgument
  nodeC.publishTyped("accept", proc(session: Session;
      args: seq[ReceivedArgument]): SyrupValue =
    if args.len == 1: received = args[0]
    text("accepted"))

  let bToA = nodeB.dial("127.0.0.1", nodeA.manager.listenPort(), repeat("b", 32))
  let bToC = nodeB.dial("127.0.0.1", nodeC.manager.listenPort(), repeat("c", 32))
  var spins = 0
  while bToA.state != ssOpen or bToC.state != ssOpen:
    inc spins
    if spins > 2000: raise newException(CatchableError, "handshake timeout")
    pumpAll(nodeA, nodeB, nodeC)

  let makeRef = sessionApi.fetch(bToA, "make")
  let resolveRef = sessionApi.fetch(bToA, "resolve")
  let acceptRef = sessionApi.fetch(bToC, "accept")
  while not settled(makeRef) or not settled(resolveRef) or not settled(acceptRef):
    inc spins
    if spins > 5000: raise newException(CatchableError, "fetch timeout")
    pumpAll(nodeA, nodeB, nodeC)

  let make = RemoteCapability(session: bToA, reference: makeRef.value.descriptor())
  let promise = make.call("make", [])
  while not settled(promise):
    inc spins
    if spins > 7000: raise newException(CatchableError, "promise creation timeout")
    pumpAll(nodeA, nodeB, nodeC)
  let accept = RemoteCapability(session: bToC, reference: acceptRef.value.descriptor())
  let accepted = nodeB.call(accept, "accept", [promiseArg(promiseRef(bToA, promise))])
  while not settled(accepted):
    inc spins
    if spins > 9000: raise newException(CatchableError, "forward timeout")
    pumpAll(nodeA, nodeB, nodeC)
  let disconnect = paramCount() > 1 and paramStr(1) == "disconnect"
  let pipelined = received.promise.callPipelined("greet", [text("world")])
  if disconnect:
    nodeA.close()
    echo "mode=disconnect"
  else:
    try:
      discard RemoteCapability(session: bToA, reference: resolveRef.value.descriptor()).call("resolve", [])
    except CatchableError as error:
      echo "resolve_error=", error.msg
      echo "states=", $bToA.state, "/", $bToC.state
  for _ in 0 ..< 300:
    pumpAll(nodeA, nodeB, nodeC)

  echo "promise_state=", $pipelined.state
  echo "states=", $bToA.state, "/", $bToC.state
  if pipelined.state == psFulfilled: echo "result=", pipelined.value.data
  elif pipelined.state == psBroken: echo "reason=", pipelined.reason
  echo "trace:"
  var events = traceA.events & traceB.events & traceC.events
  events.sort(proc(left, right: TraceEvent): int =
    cmp(left.monotonicSeconds, right.monotonicSeconds))
  for event in events:
    echo event.nodeId, " ", event.sessionId, " ", $event.number, " ",
      $event.monotonicSeconds, " ", $event.direction, " ", event.operation,
      " target=", event.target, " answer=", event.answer,
      (if event.ownership != "-": " detail=" & event.ownership else: "")
  nodeB.close()
  nodeC.close()
  nodeA.close()
  echo "post_close_forwarded=", nodeA.stats().forwardedPromises, "/",
    nodeA.stats().forwardedProxies, ";", nodeB.stats().forwardedPromises, "/",
    nodeB.stats().forwardedProxies, ";", nodeC.stats().forwardedPromises, "/",
    nodeC.stats().forwardedProxies

when isMainModule:
  main()
