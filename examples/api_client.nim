import std/[net, os, strutils]
import ../src/[api, syrup]

if paramCount() != 2:
  quit("usage: api_client HOST PORT")
let node = newNode(port = Port(0), seedPrefix = "api-client")
let session = node.connect(paramStr(1), Port(parseInt(paramStr(2))))
let greeter = session.fetchCapability("greeter")
let answer = session.waitFor(greeter.call("greet", [text("world")]))
echo answer.data
node.close()
