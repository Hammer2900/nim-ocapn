import std/[net, os, strutils, monotimes, times, tables]
import ../src/[api, crypto, handoff, identity, promises, references, server, session, syrup, tls_transport, transport]

const LifetimeMs = 60_000
const ServiceId = "protected.test"

proc pumpSession(session: Session) =
  if session.isNil or session.state == ssClosed: return
  try: discard session.pump()
  except CatchableError: session.close("protected peer pump failed")

proc waitPair(first, second: Session; done: proc(): bool {.closure.}) =
  let deadline = getMonoTime() + initDuration(milliseconds = LifetimeMs)
  while getMonoTime() < deadline and not done():
    pumpSession(first)
    pumpSession(second)
    sleep(1)
  if not done(): raise newException(SessionError, "protected handoff timed out")

proc tlsPolicy(expectedFingerprint: string): PeerVerificationPolicy =
  let verifier: TransportEvidenceVerifier = proc(
      evidence: TransportAuthEvidence; capTpKey: string): bool =
    evidence.transportIdentity == expectedFingerprint and
      evidence.peerIdentity == capTpKey and evidence.channelIntegrity and
      evidence.channelConfidential
  authenticatedNetlayerPolicy(verifier)

proc tlsSession(host: string; port: Port; config: TlsTransportConfig;
                policy: PeerVerificationPolicy): Session =
  let transport = newTlsClient(host, port, config)
  let peer = newPeerLocator("tls-testing-only", host & ":" & $port,
    [("host", host), ("port", $port)])
  result = newSession(transport, "", peer.peerUri(), defaultSessionLimits(), policy)
  result.remotePeer = peer
  result.setExpectedPeer(peer, true)

proc runA(port: Port; serverCert, serverKey, ca, clientFingerprint: string) =
  let clientFingerprintBytes = parseHexStr(clientFingerprint)
  var config = defaultNodeConfig(port)
  config.netlayer = nlkMutualTls
  config.identity = newEphemeralIdentity(repeat('a', 32))
  config.verificationPolicy = tlsPolicy(clientFingerprintBytes)
  config.tlsServerConfig = TlsTransportConfig(
    certificateFile: serverCert, privateKeyFile: serverKey, caFile: ca,
    expectedPeerCertificateFingerprint: clientFingerprintBytes,
    expectedPeerCapTpKey: "", allowUnpinnedPeerCapTpKey: true,
    serverName: "localhost", maxOutputBytes: 1024 * 1024)
  config.clientAuth = ClientAuthConfig(
    trustedClientKeys: @[crypto.publicKey(repeat('b', 32)),
      crypto.publicKey(repeat('c', 32))], onionServiceId: ServiceId,
    capabilityName: "authenticate", challengeTimeoutMs: 30_000)
  let node = newNode(config)
  node.publishProtected("protected", proc(args: seq[SyrupValue]): SyrupValue =
    if args.len == 2 and args[0].kind == skSymbol and args[0].data == "greet" and
        args[1].kind == skString:
      text("protected hello, " & args[1].data)
    else:
      raise newException(SessionError, "protected capability expects greet"))
  echo "READY A " & $node.listenPort()
  stdout.flushFile()
  try:
    let deadline = getMonoTime() + initDuration(milliseconds = LifetimeMs)
    while getMonoTime() < deadline:
      discard node.poll(20)
  finally:
    node.close()

proc runC(port, aPort: Port; clientCert, clientKey, ca, serverFingerprint,
          clientFingerprint, authMode, identitySeed: string) =
  let policy = tlsPolicy(parseHexStr(serverFingerprint))
  let tlsConfig = TlsTransportConfig(
    certificateFile: clientCert, privateKeyFile: clientKey, caFile: ca,
    expectedPeerCertificateFingerprint: parseHexStr(serverFingerprint),
    expectedPeerCapTpKey: "", allowUnpinnedPeerCapTpKey: true,
    serverName: "localhost", maxOutputBytes: 1024 * 1024)
  let cIdentity = newEphemeralIdentity(identitySeed)
  let handoffs = newHandoffManager()
  handoffs.setHandoffSessionOpener(proc(peer: PeerLocator): Session =
    try:
      tlsSession(peer.hints.getOrDefault("host"),
        Port(parseInt(peer.hints.getOrDefault("port"))), tlsConfig, policy)
    except CatchableError as error:
      stderr.writeLine("C auxiliary opener failed: " & error.msg)
      stderr.flushFile()
      raise)
  if authMode != "unauth":
    handoffs.setHandoffSessionPreparer(proc(session: Session): bool =
      try: authenticateClient(session, cIdentity, maxPumps = 10_000)
      except CatchableError: false)
  var invoked = false
  var rejected = false
  let manager = newTcpSessionManager("127.0.0.1", port, "protected-c",
    "127.0.0.1:" & $port,
    proc(session: Session) =
      discard session.publishActor("register", proc(actor: Session;
          args: seq[SyrupValue]): SyrupValue =
        if args.len != 2 or args[0].kind != skSymbol or args[0].data != "register":
          raise newException(SessionError, "protected register expects gift")
        let answer = actor.deferAnswer()
        let receipt = handoffs.startHandoffReceiver(args[1], actor)
        receipt.promise.onSettle(proc(done: Promise) =
          if done.state == psBroken:
            rejected = true
            actor.breakAnswer(answer, done.reason)
          else:
            let callResult = api.call(receipt.session, done.value.descriptor(), "greet",
              [text("receiver")])
            callResult.onSettle(proc(result: Promise) =
              if result.state == psFulfilled:
                invoked = result.value.kind == skString and
                  result.value.data == "protected hello, receiver"
                receipt.session.release(done.value.descriptor())
                actor.fulfillAnswer(answer, result.value)
              else:
                actor.breakAnswer(answer, result.reason)))
        list()))
  echo "READY C " & $manager.listenPort()
  stdout.flushFile()
  defer:
    handoffs.close("protected C shutdown")
    manager.close()
  let deadline = getMonoTime() + initDuration(milliseconds = LifetimeMs)
  while getMonoTime() < deadline and not invoked and not rejected:
    discard manager.poll(10, 64)
    discard handoffs.pumpWork(64)
  if rejected:
    echo "PROTECTED_C_REJECTED"
  elif invoked:
    echo "PROTECTED_C_PASS"
  else:
    quit("protected C invocation failed", 1)

proc runB(aPort, cPort: Port; clientCert, clientKey, ca, serverFingerprint,
          clientFingerprint: string) =
  let bIdentity = newEphemeralIdentity(repeat('b', 32))
  let policy = tlsPolicy(parseHexStr(serverFingerprint))
  let tlsConfig = TlsTransportConfig(
    certificateFile: clientCert, privateKeyFile: clientKey, caFile: ca,
    expectedPeerCertificateFingerprint: parseHexStr(serverFingerprint),
    expectedPeerCapTpKey: "", allowUnpinnedPeerCapTpKey: true,
    serverName: "localhost", maxOutputBytes: 1024 * 1024)
  let toA = tlsSession("127.0.0.1", aPort, tlsConfig, policy)
  let cTransport = connectTcp("127.0.0.1", cPort)
  cTransport.setNonBlocking()
  let toC = newGlowcapSession(cTransport, "", "127.0.0.1:" & $cPort)
  let register = newHandoffManager()
  try:
    waitPair(toA, toC, proc(): bool = toA.state == ssOpen and toC.state == ssOpen)
    if not authenticateClient(toA, bIdentity):
      raise newException(SessionError, "B authentication returned false")
    let protected = api.fetch(toA, "protected")
    waitPair(toA, toC, proc(): bool = protected.settled())
    if protected.state != psFulfilled:
      raise newException(SessionError, "B protected fetch failed: " & protected.reason)
    let reg = api.fetch(toC, "register")
    waitPair(toA, toC, proc(): bool = reg.settled())
    if reg.state != psFulfilled:
      raise newException(SessionError, "C register fetch failed")
    let give = register.handoffArgument(toA, protected.value.descriptor(), toC)
    let handoffResult = api.call(toC, reg.value.descriptor(), "register", [give])
    waitPair(toA, toC, proc(): bool = handoffResult.settled())
    if handoffResult.state != psFulfilled:
      raise newException(SessionError, "protected handoff failed: " & handoffResult.reason)
    toA.release(protected.value.descriptor())
    toA.close("B disconnected after protected handoff")
    toC.close("B disconnected after protected handoff")
    echo "PROTECTED_B_PASS"
  finally:
    register.close("protected B shutdown")
    toA.close("protected B cleanup")
    toC.close("protected B cleanup")

when isMainModule:
  when not defined(ssl):
    quit("protected three-node peer requires -d:ssl", 1)
  if paramCount() < 1: quit("usage: protected_three_node_peer A|B|C ...", 1)
  case paramStr(1)
  of "A": runA(Port(parseInt(paramStr(2))), paramStr(3), paramStr(4), paramStr(5), paramStr(6))
  of "B": runB(Port(parseInt(paramStr(2))), Port(parseInt(paramStr(3))),
      paramStr(4), paramStr(5), paramStr(6), paramStr(7), paramStr(8))
  of "C": runC(Port(parseInt(paramStr(2))), Port(parseInt(paramStr(3))),
      paramStr(4), paramStr(5), paramStr(6), paramStr(7), paramStr(8),
      if paramCount() >= 9: paramStr(9) else: "trusted",
      if paramCount() >= 10: paramStr(10) else: repeat('c', 32))
  else: quit("unknown role", 1)
