import std/[net, os, strutils]
import ../src/[server, session, syrup]

let port = Port(if paramCount() == 1: parseInt(paramStr(1)) else: 42016)
let manager = newTcpSessionManager("127.0.0.1", port, "multi-nim", "127.0.0.1:" & $port,
  proc(capSession: Session) =
    discard capSession.publishObject("nim-greeter", proc(args: seq[SyrupValue]): SyrupValue =
      if args.len != 1 or args[0].kind notin {skString, skBytes}:
        raise newException(SessionError, "greet expects one string")
      text("Hello from Nim, " & args[0].data)))
echo "Nim multi-session server listening on 127.0.0.1:", port
while true:
  discard manager.poll(1000)
