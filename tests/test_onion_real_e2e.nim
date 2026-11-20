import std/[base64, monotimes, net, os, sequtils, strutils, times, unittest]
import ../src/[api, identity, locators, onion, promises, session, syrup, transport]

let phaseStarted = getMonoTime()

proc phase(tag: string) =
  echo "[PHASE +" & $(getMonoTime() - phaseStarted).inMilliseconds & "ms] " & tag
  stdout.flushFile()

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

proc envIdentity(): NodeIdentity =
  let encoded = getEnv("NIM_OCAPN_CLIENT_SEED_B64")
  if encoded.len == 0:
    raise newException(IdentityError, "NIM_OCAPN_CLIENT_SEED_B64 is required")
  newEphemeralIdentity(decode(encoded))

proc trustedClientKeys(): seq[string] =
  for encoded in getEnv("NIM_OCAPN_TRUSTED_CLIENT_KEYS_B64").split(','):
    if encoded.len > 0: result.add(decode(encoded))

proc socksConfig(): OnionNetlayerConfig

proc connectPair(layer: OnionNetlayer; listener: OnionListener; peer: PeerLocator;
                tag: string): tuple[client, server: Session; transports: seq[Transport]] =
  phase(tag & ": SOCKS5 CONNECT")
  var clientTransport: OnionTransport
  var lastError = ""
  for attempt in 0 ..< 30:
    try:
      clientTransport = layer.dial(peer)
      break
    except OnionError as error:
      lastError = error.msg
      if attempt < 29: sleep(1000)
  if clientTransport.isNil:
    raise newException(OnionError, "Tor Onion service did not become reachable: " & lastError)
  let serverTransport = listener.accept()
  phase(tag & ": accepted stream")
  let server = newSession(serverTransport, location = peer.peerUri())
  let client = newSession(clientTransport, location = "ocapn://client.onion",
    verificationPolicy = authenticatedOnionPolicy(peer))
  client.setExpectedPeer(peer)
  discard server.enableClientAuthentication(trustedClientKeys(), peer.designator,
    onAuthenticated = proc(authorized: Session) = authorized.publishGreeter())
  result = (client, server, @[Transport(clientTransport), Transport(serverTransport)])
  if not pump([server, client], result.transports, 10000,
      proc(): bool = server.state == ssOpen and client.state == ssOpen):
    raise newException(SessionError, "Onion handshake timeout: " & tag &
      " server=" & $server.state & " client=" & $client.state &
      " clientAuth=" & $clientTransport.peerAuthenticated() &
      " clientEvidence=" & clientTransport.authenticationEvidence().transportIdentity)
  phase(tag & ": CapTP handshake")

proc exercise(client, server: Session; tag: string) =
  phase(tag & ": client authentication")
  doAssert api.authenticateClient(client, envIdentity(), pumpPeer = server)
  phase(tag & ": protected fetch and invocation")
  let fetched = api.fetch(client, "greeter")
  let call = client.callPipelined(fetched, "greet", [text(tag)])
  if not pump([client, server], @[client.transport, server.transport], 10000,
      proc(): bool = call.settled()):
    raise newException(SessionError, "Onion promise timeout: " & tag)
  if call.state != psFulfilled or call.value.kind != skString or
      call.value.data != "Hello, " & tag:
    raise newException(SessionError, "unexpected Onion response: " & tag)
  phase(tag & ": invocation complete")

proc runAuthenticationFailure(service: string) =
  let layer = newOnionNetlayer(socksConfig())
  let peer = newPeerLocator("onion", service)
  let localPort = Port(parseInt(getEnv("NIM_OCAPN_ONION_LOCAL_PORT")))
  let listener = layer.listen(localPort = localPort, advertised = peer)
  defer: listener.close()
  let pair = layer.connectPair(listener, peer, "unknown-client")
  let denied = api.fetch(pair.client, "greeter")
  check pump([pair.client, pair.server], pair.transports, 10000,
    proc(): bool = denied.settled())
  check denied.state == psBroken
  let deniedPipeline = pair.client.callPipelined(api.fetch(pair.client, "greeter"),
    "greet", [text("unauthenticated")])
  check pump([pair.client, pair.server], pair.transports, 10000,
    proc(): bool = deniedPipeline.settled())
  check deniedPipeline.state == psBroken
  var rejected = false
  try:
    discard api.authenticateClient(pair.client, envIdentity(), pumpPeer = pair.server)
  except CatchableError:
    rejected = true
  check rejected
  check pair.server.clientAuthenticationState == casRejected or
    pair.server.clientAuthenticationState == casUnauthenticated
  check pair.server.stats().exportCount <= 1
  pair.client.close("authentication failure cleanup")
  pair.server.close("authentication failure cleanup")

proc socksConfig(): OnionNetlayerConfig =
  result = defaultOnionNetlayerConfig()
  result.authenticateServer = true
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

  var previousSessionKey = ""
  for cycle in 0 .. 1:
    let pair = layer.connectPair(listener, peer, "cycle-" & $cycle)
    pair.client.exercise(pair.server, "cycle-" & $cycle)
    check pair.client.state == ssOpen
    check pair.server.state == ssOpen
    check pair.client.transport.peerAuthenticated()
    check not pair.server.transport.peerAuthenticated()
    if previousSessionKey.len > 0:
      check pair.client.localPublicKey != previousSessionKey
    previousSessionKey = pair.client.localPublicKey
    pair.client.close("real Onion cycle cleanup")
    pair.server.close("real Onion cycle cleanup")
    check pair.client.state == ssClosed
    check pair.server.state == ssClosed

  let replayPair = layer.connectPair(listener, peer, "challenge-replay")
  phase("challenge replay")
  doAssert api.authenticateClient(replayPair.client, envIdentity(),
    pumpPeer = replayPair.server)
  var replayRejected = false
  try:
    discard api.authenticateClient(replayPair.client, envIdentity(),
      maxPumps = 100, pumpPeer = replayPair.server)
  except CatchableError:
    replayRejected = true
  check replayRejected
  replayPair.client.close("challenge replay cleanup")
  replayPair.server.close("challenge replay cleanup")

  var clients: seq[Session]
  var servers: seq[Session]
  var transports: seq[Transport]
  var calls: seq[Promise]
  for index in 0 ..< 2:
    phase("concurrent client " & $index)
    let pair = layer.connectPair(listener, peer, "concurrent-" & $index)
    clients.add(pair.client)
    servers.add(pair.server)
    for transport in pair.transports: transports.add(transport)
    doAssert api.authenticateClient(pair.client, envIdentity(), pumpPeer = pair.server)
    let fetched = api.fetch(pair.client, "greeter")
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

  let clientTransport = layer.dial(peer)
  phase("wrong Onion policy")
  let serverTransport = listener.accept()
  let server = newSession(serverTransport, location = peer.peerUri())
  let wrongPeer = newPeerLocator("onion", if peer.designator[0] == 'a':
    'b' & peer.designator[1 .. ^1] else: 'a' & peer.designator[1 .. ^1])
  let rejectedClient = newSession(clientTransport, location = peer.peerUri(),
    verificationPolicy = authenticatedOnionPolicy(wrongPeer))
  rejectedClient.setExpectedPeer(wrongPeer)
  var rejected = false
  try:
    discard pump([server, rejectedClient], @[Transport(clientTransport), Transport(serverTransport)],
      10000, proc(): bool = rejectedClient.state == ssClosed)
  except SessionError:
    rejected = true
  if rejectedClient.state == ssClosed: rejected = true
  check rejected
  check rejectedClient.state == ssClosed
  check rejectedClient.stats().pendingPromises == 0
  check rejectedClient.stats().importCount == 0
  check not serverTransport.peerAuthenticated()
  rejectedClient.close("wrong Onion policy cleanup")
  server.close("wrong Onion policy cleanup")

  var unavailable = peer
  phase("unavailable Onion service")
  unavailable.designator[0] = if unavailable.designator[0] == 'a': 'b' else: 'a'
  expect OnionError:
    discard layer.dial(unavailable)

proc runExpectedFailure(service: string) =
  let layer = newOnionNetlayer(socksConfig())
  expect OnionError:
    discard layer.dial(newPeerLocator("onion", service))

suite "Real Tor v3 Onion netlayer":
  test "handshake, pipelining, reconnect, concurrency, failure and cleanup":
    let service = getEnv("NIM_OCAPN_ONION_SERVICE")
    if service.len == 0:
      echo "  [SKIP] NIM_OCAPN_ONION_SERVICE is not set"
      skip()
    elif getEnv("NIM_OCAPN_ONION_EXPECT_FAILURE") == "1":
      runExpectedFailure(service)
    elif getEnv("NIM_OCAPN_ONION_EXPECT_AUTH_FAILURE") == "1":
      runAuthenticationFailure(service)
    else:
      runRealOnionE2E(service)
