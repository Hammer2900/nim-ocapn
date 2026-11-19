import std/[monotimes, net, os, sequtils, strutils, times, unittest]
import ../src/[locators, onion, promises, session, syrup, transport]

proc pump(sessions: openArray[Session]; transports: openArray[Transport];
         timeoutMs: int; done: proc(): bool {.closure.}): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    for session in sessions:
      if session.state != ssClosed:
        discard session.pump()
    if done(): return true
    for transport in transports:
      if not transport.isClosed(): discard transport.waitReadable(25)
  done()

proc publishGreeter(session: Session) =
  discard session.publishObject("greeter", proc(args: seq[SyrupValue]): SyrupValue =
    if args.len == 1 and args[0].kind == skString:
      text("Hello, " & args[0].data)
    else:
      raise newException(SessionError, "greeter expects one string"))

proc connectPair(layer: OnionNetlayer; listener: OnionListener; peer: PeerLocator;
                tag: string): tuple[client, server: Session; transports: seq[Transport]] =
  var clientTransport: OnionTransport
  var lastError = ""
  for attempt in 0 ..< 12:
    try:
      clientTransport = layer.dial(peer)
      break
    except OnionError as error:
      lastError = error.msg
      if attempt < 11: sleep(1000)
  if clientTransport.isNil:
    raise newException(OnionError, "Tor Onion service did not become reachable: " & lastError)
  let serverTransport = listener.accept()
  let server = newSession(serverTransport, repeat('s', 32), peer.peerUri())
  let client = newSession(clientTransport, repeat('c', 32), "ocapn://client.onion")
  server.publishGreeter()
  result = (client, server, @[Transport(clientTransport), Transport(serverTransport)])
  if not pump([server, client], result.transports, 10000,
      proc(): bool = server.state == ssOpen and client.state == ssOpen):
    raise newException(SessionError, "Onion handshake timeout: " & tag)

proc exercise(client, server: Session; tag: string) =
  let fetched = client.fetch("greeter")
  let call = client.callPipelined(fetched, "greet", [text(tag)])
  if not pump([client, server], @[client.transport, server.transport], 10000,
      proc(): bool = call.settled()):
    raise newException(SessionError, "Onion promise timeout: " & tag)
  if call.state != psFulfilled or call.value.kind != skString or
      call.value.data != "Hello, " & tag:
    raise newException(SessionError, "unexpected Onion response: " & tag)

proc socksConfig(): OnionNetlayerConfig =
  result = defaultOnionNetlayerConfig()
  if getEnv("NIM_OCAPN_TOR_SOCKS").len > 0:
    result.socksHost = getEnv("NIM_OCAPN_TOR_SOCKS")
  if getEnv("NIM_OCAPN_TOR_SOCKS_PORT").len > 0:
    result.socksPort = Port(parseInt(getEnv("NIM_OCAPN_TOR_SOCKS_PORT")))
  if getEnv("NIM_OCAPN_ONION_SERVICE_PORT").len > 0:
    result.servicePort = Port(parseInt(getEnv("NIM_OCAPN_ONION_SERVICE_PORT")))
  result.connectTimeoutMs = 5000

proc runRealOnionE2E(service: string) =
  let layer = newOnionNetlayer(socksConfig())
  let peer = newPeerLocator("onion", service)
  let localPort = if getEnv("NIM_OCAPN_ONION_LOCAL_PORT").len == 0: Port(9045)
                  else: Port(parseInt(getEnv("NIM_OCAPN_ONION_LOCAL_PORT")))
  let listener = layer.listen(localPort = localPort, advertised = peer)
  defer: listener.close()

  for cycle in 0 .. 1:
    let pair = layer.connectPair(listener, peer, "cycle-" & $cycle)
    pair.client.exercise(pair.server, "cycle-" & $cycle)
    check pair.client.state == ssOpen
    check pair.server.state == ssOpen
    pair.client.close("real Onion cycle cleanup")
    pair.server.close("real Onion cycle cleanup")
    check pair.client.state == ssClosed
    check pair.server.state == ssClosed

  var clients: seq[Session]
  var servers: seq[Session]
  var transports: seq[Transport]
  var calls: seq[Promise]
  for index in 0 ..< 2:
    let pair = layer.connectPair(listener, peer, "concurrent-" & $index)
    clients.add(pair.client)
    servers.add(pair.server)
    for transport in pair.transports: transports.add(transport)
    let fetched = pair.client.fetch("greeter")
    calls.add(pair.client.callPipelined(fetched, "greet", [text("concurrent-" & $index)]))
  defer:
    for session in clients: session.close("concurrent Onion cleanup")
    for session in servers: session.close("concurrent Onion cleanup")
  var sessions: seq[Session]
  for session in clients: sessions.add(session)
  for session in servers: sessions.add(session)
  if not pump(sessions, transports, 10000,
      proc(): bool = calls.allIt(it.settled())):
    raise newException(SessionError, "concurrent Onion promise timeout")
  for index, call in calls:
    check call.state == psFulfilled
    check call.value.data == "Hello, concurrent-" & $index

  var unavailable = peer
  unavailable.designator[0] = if unavailable.designator[0] == 'a': 'b' else: 'a'
  expect OnionError:
    discard layer.dial(unavailable)

suite "Real Tor v3 Onion netlayer":
  test "handshake, pipelining, reconnect, concurrency, failure and cleanup":
    let service = getEnv("NIM_OCAPN_ONION_SERVICE")
    if service.len == 0:
      echo "  [SKIP] NIM_OCAPN_ONION_SERVICE is not set"
      skip()
    else:
      runRealOnionE2E(service)
