import std/[net, strutils]
import ../src/[api, promises, references, server, syrup]
import ../src/session as sessionApi

proc pumpAll(a, b, c: Node) =
  discard a.poll(1)
  discard b.poll(1)
  discard c.poll(1)

let nodeA = newNode(port = Port(0), seedPrefix = "api-a")
nodeA.publish("origin", proc(args: seq[SyrupValue]): SyrupValue =
  if args.len == 1: text("Hello from A, " & args[0].data) else: text("bad args"))
let nodeC = newNode(port = Port(0), seedPrefix = "api-c")
var received: RemoteCapability
nodeC.publishTyped("register", proc(session: sessionApi.Session;
    args: seq[ReceivedArgument]): SyrupValue =
  if args.len != 1 or args[0].kind != rakCapability:
    raise newException(SessionError, "register expects a capability")
  received = args[0].capability
  text("registered"))
let nodeB = newNode(port = Port(0), seedPrefix = "api-b")
let bToA = nodeB.dial("127.0.0.1", nodeA.manager.listenPort(), repeat("b", 32))
let bToC = nodeB.dial("127.0.0.1", nodeC.manager.listenPort(), repeat("d", 32))
var spins = 0
while bToA.state != ssOpen or bToC.state != ssOpen:
  inc spins
  if spins > 5000: quit("handshake timeout")
  pumpAll(nodeA, nodeB, nodeC)

let originPromise = sessionApi.fetch(bToA, "origin")
while not settled(originPromise): pumpAll(nodeA, nodeB, nodeC)
let origin = RemoteCapability(session: bToA, reference: originPromise.value.descriptor())
let registerPromise = sessionApi.fetch(bToC, "register")
while not settled(registerPromise): pumpAll(nodeA, nodeB, nodeC)
let register = RemoteCapability(session: bToC, reference: registerPromise.value.descriptor())
let registered = nodeB.call(register, "register", [capabilityArg(origin)])
while not settled(registered): pumpAll(nodeA, nodeB, nodeC)
let answer = received.call("greet", [text("world")])
while not settled(answer): pumpAll(nodeA, nodeB, nodeC)
echo answer.value.data
nodeB.close()
nodeC.close()
nodeA.close()
