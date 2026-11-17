import std/[net, os, strutils]
import ../src/[session, syrup, transport]

if paramCount() > 1:
  quit("usage: native_greeter_server [PORT]")

let port = Port(if paramCount() == 1: parseInt(paramStr(1)) else: 42015)
let listener = listenTcp("127.0.0.1", port)
echo "Nim greeter listening on 127.0.0.1:", port
let tcp = acceptTcp(listener)
listener.close()
let capSession = newGlowcapSession(tcp, repeat("n", 32), "127.0.0.1:" & $port)
discard capSession.publishObject("nim-greeter", proc(args: seq[SyrupValue]): SyrupValue =
  if args.len != 1 or args[0].kind notin {skString, skBytes}:
    raise newException(SessionError, "greet expects one string")
  text("Hello from Nim, " & args[0].data))

while capSession.state != ssClosed:
  try:
    discard capSession.pump()
  except CatchableError as error:
    stderr.writeLine("Nim greeter session error: " & error.msg)
    break
