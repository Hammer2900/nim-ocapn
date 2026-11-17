import std/[net, os, strutils]
import ../src/[promises, session, syrup, transport]

if paramCount() != 3:
  quit("usage: fetch_swiss HOST PORT SWISSNUM")

let host = paramStr(1)
let port = Port(parseInt(paramStr(2)))
let tcp = connectTcp(host, port)
let capSession = newGlowcapSession(tcp, repeat("q", 32), host & ":" & $port)
while capSession.state != ssOpen:
  discard capSession.pump()
let fetched = capSession.fetch(paramStr(3))
while not settled(fetched):
  discard capSession.pump()
if fetched.state == psBroken:
  quit("fetch failed: " & fetched.reason)
echo fetched.value.encoded()
capSession.close("fetch complete")
