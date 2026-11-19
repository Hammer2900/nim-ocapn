import std/[monotimes, net, os, strutils, unittest, times]
import ../src/[locators, onion, promises, session, syrup]

proc traceOnion(event: TraceEvent) =
  if event.operation in ["op:deliver", "op:listen", "promise:settle", "session:close"]:
    echo "  [TRACE] ", event.nodeId, " ", event.operation, " target=", event.target,
      " answer=", event.answer, " state=", event.promiseState

proc pumpPairUntil(server, client: Session; serverTransport, clientTransport: OnionTransport;
                   timeoutMs: int; done: proc(): bool {.closure.}): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    discard server.pump()
    discard client.pump()
    if done(): return true
    let remaining = (deadline - getMonoTime()).inMilliseconds.int
    if remaining <= 0: break
    discard serverTransport.waitReadable(min(remaining, 50))
    discard clientTransport.waitReadable(min(remaining, 50))
  done()

proc runOnionE2E(service: string) =
  var config = defaultOnionNetlayerConfig()
  if getEnv("NIM_OCAPN_TOR_SOCKS").len > 0:
    config.socksHost = getEnv("NIM_OCAPN_TOR_SOCKS")
  if getEnv("NIM_OCAPN_TOR_SOCKS_PORT").len > 0:
    config.socksPort = Port(parseInt(getEnv("NIM_OCAPN_TOR_SOCKS_PORT")))
  let layer = newOnionNetlayer(config)
  let peer = newPeerLocator("onion", service)
  let listener = layer.listen(advertised = peer)
  let clientTransport = layer.dial(peer)
  check clientTransport.socksEstablished()
  let serverTransport = listener.accept()
  check serverTransport.endpointWasAccepted()
  let server = newSession(serverTransport, repeat("s", 32), peer.peerUri())
  discard server.publishObject("greeter", proc(args: seq[SyrupValue]): SyrupValue =
    (if args.len != 1 or args[0].kind != skString:
       raise newException(SessionError, "greeter expects one string argument")
     text("Hello, " & args[0].data)))
  let client = newSession(clientTransport, repeat("c", 32), "ocapn://client.onion")
  defer:
    client.close("onion test cleanup")
    server.close("onion test cleanup")
    listener.close()

  server.setTraceSink("onion-server", traceOnion)
  client.setTraceSink("onion-client", traceOnion)
  echo "  [TRACE] SOCKS CONNECT established; Onion endpoint accepted"
  echo "  [TRACE] CapTP handshake started: server sentHello=", server.handshakeStarted(),
    " client sentHello=", client.handshakeStarted()
  discard pumpPairUntil(server, client, serverTransport, clientTransport, 10000,
    proc(): bool = server.state == ssOpen and client.state == ssOpen)
  if server.state != ssOpen or client.state != ssOpen:
    raise newException(SessionError, "Onion CapTP handshake timeout: server=" &
      $server.state & " client=" & $client.state & " serverClosed=" &
      $serverTransport.isClosed() & " clientClosed=" & $clientTransport.isClosed() &
      " serverQueued=" & $serverTransport.queuedBytes() &
      " clientQueued=" & $clientTransport.queuedBytes())
  echo "  [TRACE] CapTP handshake completed"

  let fetched = client.fetch("greeter")
  let pipelined = client.callPipelined(fetched, "greet", [text("world")])
  echo "  [TRACE] application call queued: fetch + pipelined greet"
  let completed = pumpPairUntil(server, client, serverTransport, clientTransport, 10000,
    proc(): bool = pipelined.settled())
  if not completed:
    raise newException(SessionError, "Onion application timeout: promise=" &
      $pipelined.state & " server=" & $server.state & " client=" & $client.state &
      " serverClosed=" & $serverTransport.isClosed() &
      " clientClosed=" & $clientTransport.isClosed() &
      " serverQueued=" & $serverTransport.queuedBytes() &
      " clientQueued=" & $clientTransport.queuedBytes())
  if pipelined.state != psFulfilled:
    raise newException(SessionError, "Onion pipeline broke: " & pipelined.reason)
  if pipelined.value.isNil:
    raise newException(SessionError, "Onion pipeline fulfilled with nil value")
  check pipelined.value.kind == skString
  check pipelined.value.data == "Hello, world"
  echo "  [TRACE] promise fulfilled: ", pipelined.value.data

suite "OCapN Onion netlayer integration":
  test "Nim to Nim greet and promise pipeline through Tor Onion":
    let service = getEnv("NIM_OCAPN_ONION_SERVICE")
    if service.len == 0:
      echo "  [SKIP] NIM_OCAPN_ONION_SERVICE is not set"
      skip()
    else:
      runOnionE2E(service)
