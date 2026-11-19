import std/[net, os, strutils]
import ../src/[references, session, syrup, transport]

if paramCount() != 2:
  quit("usage: goblins_client HOST PORT")

let host = paramStr(1)
let port = Port(parseInt(paramStr(2)))
let socket = connectTcp(host, port)
let capSession = newGlowcapSession(socket, repeat("g", 32), host & ":" & $port)
while capSession.state != ssOpen:
  discard capSession.pump()

let echoObject = capSession.waitFor(capSession.fetch("IO58l1laTyhcrgDKbEzFOO32MDd6zE5w")).descriptor()
let result = capSession.waitFor(capSession.deliverCall(echoObject, [text("nim-to-goblins")]))
echo result.encoded()
socket.close()
