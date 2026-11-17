import std/[net, os]
import ../src/[api, locators, syrup]

if paramCount() != 2:
  quit("usage: sturdyref_client HOST PORT")

let node = newNode(port = Port(0))
let sturdy = SturdyRef(
  peer: newPeerLocator("tcp", "127.0.0.1", [("host", paramStr(1)), ("port", paramStr(2))]),
  swissNum: "nim-greeter")
let greeter = node.enliven(sturdy)
let result = greeter.session.waitFor(greeter.call("greet", [text("world")]))
echo result.data
node.close()
