import std/[net, os, strutils]
when defined(posix):
  import std/posix
import ../src/[api, syrup]

let port = Port(if paramCount() > 0: parseInt(paramStr(1)) else: 0)
let identityPath = getEnv("NIM_OCAPN_IDENTITY", "simple-server.identity")
var config = defaultNodeConfig(port)
config.identityPath = identityPath
config.netlayer = nlkTcpTestingOnly
config.verificationPolicy = testingOnlyPeerPolicy
var stopping = false
setControlCHook(proc() {.noconv.} = stopping = true)
when defined(posix):
  onSignal(SIGTERM):
    stopping = true

var node: Node
try:
  node = newNode(config)
  node.publish("greeter", proc(args: seq[SyrupValue]): SyrupValue =
    if args.len == 1 and args[0].kind == skString:
      text("Hello, " & args[0].data)
    else:
      raise newException(CatchableError, "greeter expects one string"))

  echo node.locator().peerUri()
  stdout.flushFile()
  while not stopping:
    discard node.poll(1000)
finally:
  if node != nil:
    node.close()
