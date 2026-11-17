import std/[net, os, strutils]
import ../src/[promises, references, session, syrup, transport]

if paramCount() != 2:
  quit("usage: native_glowcap_client HOST PORT")

let host = paramStr(1)
let port = Port(parseInt(paramStr(2)))
let tcp = connectTcp(host, port)
let capSession = newGlowcapSession(tcp, repeat("c", 32), host & ":" & $port)
while capSession.state != ssOpen:
  discard capSession.pump()

let fetched = capSession.fetch("greeter")
while not settled(fetched):
  discard capSession.pump()
if fetched.state != psFulfilled:
  quit("fetch failed: " & fetched.reason)
let greeter = fetched.value.descriptor()
let answer = capSession.call(greeter, "greet", [text("world")])
while not settled(answer):
  discard capSession.pump()
if answer.state != psFulfilled:
  quit("remote call failed: " & answer.reason)
echo answer.value.data
tcp.close()
