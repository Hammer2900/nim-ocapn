import std/[net, os, strutils]
import ../src/[promises, references, session, syrup, transport]

if paramCount() != 4:
  quit("usage: invoke_sturdyref ENLIVEN_HOST ENLIVEN_PORT SWISSNUM TARGET_PORT")

let host = paramStr(1)
let port = Port(parseInt(paramStr(2)))
let targetPort = paramStr(4)
let tcp = connectTcp(host, port)
let capSession = newGlowcapSession(tcp, repeat("v", 32), host & ":" & $port)
while capSession.state != ssOpen:
  discard capSession.pump()
let fetched = capSession.fetch(paramStr(3))
while not settled(fetched):
  discard capSession.pump()
if fetched.state == psBroken:
  quit("fetch failed: " & fetched.reason)
let enlivener = fetched.value.descriptor()
let sturdy = record(symbol("ocapn-sturdyref"),
  record(symbol("ocapn-peer"), symbol("tcp-testing-only"), text("target"),
    dict([pair(text("host"), text("127.0.0.1")), pair(text("port"), text(targetPort))])),
  text("target"))
let result = capSession.deliverCall(enlivener, [sturdy])
while not settled(result):
  discard capSession.pump()
if result.state == psBroken:
  quit("enlivener failed: " & result.reason)
echo result.value.encoded()
capSession.close("invoke complete")
