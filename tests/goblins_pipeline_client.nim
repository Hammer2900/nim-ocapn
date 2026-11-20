import std/[net, os, strutils]
import ../src/[references, session, syrup, transport]

if paramCount() != 2:
  quit("usage: goblins_pipeline_client HOST PORT")

let host = paramStr(1)
let port = Port(parseInt(paramStr(2)))
let socket = connectTcp(host, port)
let capSession = newGlowcapSession(socket, repeat("g", 32), host & ":" & $port)

try:
  stderr.writeLine("phase handshake")
  while capSession.state != ssOpen:
    discard capSession.pump()

  stderr.writeLine("phase provider fetch")
  let provider = capSession.waitFor(
    capSession.fetch("pipeline-provider-test-swiss")).descriptor()
  # The provider returns an unresolved remote vow.  Keep the answer pending
  # and issue a named call through it before the Guile driver fulfills it.
  stderr.writeLine("phase unresolved promise")
  let providerCall = capSession.deliverCall(provider, @[])
  let pipelined = capSession.callPipelined(providerCall, "ping", @[])
  stderr.writeLine("phase pipeline wait")
  let result = capSession.waitFor(pipelined)
  if result.kind != skString or result.data != "goblins-pipeline-ok":
    raise newException(ValueError, "unexpected pipelined result: " & result.encoded())
  echo "goblins-pipeline: PASS"
finally:
  capSession.close("Goblins pipeline driver cleanup")
  socket.close()
