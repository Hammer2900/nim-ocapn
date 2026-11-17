import std/[net, os, strutils]
import ../src/[api, syrup]

let port = Port(if paramCount() == 1: parseInt(paramStr(1)) else: 42030)
let node = newNode(port = port, seedPrefix = "api-server")
node.publish("greeter", proc(args: seq[SyrupValue]): SyrupValue =
  if args.len == 1 and args[0].kind in {skString, skBytes}:
    text("Hello, " & args[0].data)
  else:
    text("invalid greeting"))

echo "API server listening on 127.0.0.1:", port
while true:
  discard node.poll(1000)
