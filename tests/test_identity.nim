import std/[net, os, strutils, unittest]
import ../src/[crypto, identity, locators, references, server, session, syrup, transport]
import ../src/api except call, fetch, waitFor
when defined(ssl):
  import ../src/tls_transport

type EvidenceTransport = ref object of Transport
  inner: Transport
  evidence: TransportAuthEvidence

proc newEvidenceTransport(inner: Transport; evidence: TransportAuthEvidence): EvidenceTransport =
  EvidenceTransport(inner: inner, evidence: evidence)

method send(transport: EvidenceTransport; payload: string) = transport.inner.send(payload)
method receive(transport: EvidenceTransport): string = transport.inner.receive()
method isClosed(transport: EvidenceTransport): bool = transport.inner.isClosed()
method close(transport: EvidenceTransport) = transport.inner.close()
method flushOutput(transport: EvidenceTransport): bool = transport.inner.flushOutput()
method wantsWrite(transport: EvidenceTransport): bool = transport.inner.wantsWrite()
method queuedBytes(transport: EvidenceTransport): int = transport.inner.queuedBytes()
method authenticationEvidence(transport: EvidenceTransport): TransportAuthEvidence = transport.evidence

proc testPath(): string =
  getTempDir() / ("nim-ocapn-identity-" & $getCurrentProcessId() & ".bin")

proc cleanup(path: string) =
  for candidate in [path, path & ".lock"]:
    if fileExists(candidate): removeFile(candidate)

suite "durable identity and peer verification":
  test "identity survives save and load":
    let path = testPath()
    cleanup(path)
    defer: cleanup(path)
    let created = createIdentity(path)
    let loaded = loadIdentity(path)
    check created.publicKey.len == 32
    check loaded.publicKey == created.publicKey
    check readFile(path).len > 32
    check getFilePermissions(path) <= {fpUserRead, fpUserWrite}

  test "corrupt, unsupported, and missing identity files are rejected":
    let path = testPath()
    cleanup(path)
    defer: cleanup(path)
    expect IdentityError:
      discard loadIdentity(path)
    discard createIdentity(path)
    var corrupt = readFile(path)
    corrupt[0] = 'X'
    writeFile(path, corrupt)
    expect IdentityError:
      discard loadIdentity(path)
    corrupt = readFile(path)
    corrupt["NIMOCAPN-ID".len] = char(99)
    writeFile(path, corrupt)
    expect IdentityError:
      discard loadIdentity(path)

  test "creation is not an implicit overwrite":
    let path = testPath()
    cleanup(path)
    defer: cleanup(path)
    let first = createIdentity(path)
    expect IdentityError:
      discard createIdentity(path)
    let replacement = createIdentity(path, replaceExisting = true)
    check replacement.publicKey != first.publicKey
    check loadIdentity(path).publicKey == replacement.publicKey

  test "locked creation fails closed":
    let path = testPath()
    cleanup(path)
    defer: cleanup(path)
    writeFile(path & ".lock", "lock")
    expect IdentityError:
      discard createIdentity(path)

  test "durable identity survives while session keys are ephemeral":
    let path = testPath()
    cleanup(path)
    defer: cleanup(path)
    let first = createIdentity(path)
    let firstSession = newSession(inMemoryPair().local)
    check first.publicKey == loadIdentity(path).publicKey
    check firstSession.localPublicKey != first.publicKey
    firstSession.close("test cleanup")
    let restarted = loadIdentity(path)
    let secondSession = newSession(inMemoryPair().local)
    check restarted.publicKey == first.publicKey
    check secondSession.localPublicKey != restarted.publicKey
    check secondSession.localPublicKey != firstSession.localPublicKey
    secondSession.close("test cleanup")

  test "one node creates a new session identity on reconnect":
    let path = testPath()
    cleanup(path)
    defer: cleanup(path)
    let identity = createIdentity(path)
    let client = newNode(port = Port(0), identity = identity)
    let server = newNode(port = Port(0))
    let first = client.dial("127.0.0.1", server.manager.listenPort())
    var remaining = 200
    while first.state != ssOpen and remaining > 0:
      discard server.poll(1)
      discard client.poll(1)
      dec remaining
    check remaining > 0
    let firstKey = first.localPublicKey
    first.close("reconnect")
    while server.manager.sessionCount > 0:
      discard server.poll(1)
    discard client.poll(1)
    let second = client.dial("127.0.0.1", server.manager.listenPort())
    remaining = 200
    while second.state != ssOpen and remaining > 0:
      discard server.poll(1)
      discard client.poll(1)
      dec remaining
    check remaining > 0
    check firstKey != second.localPublicKey
    check firstKey != identity.publicKey
    check second.localPublicKey != identity.publicKey
    check client.publicIdentity() == identity.publicKey
    second.close("reconnect cleanup")
    client.close()
    server.close()

  test "independent nodes keep independent wire identities":
    let pathA = testPath() & "-a"
    let pathB = testPath() & "-b"
    cleanup(pathA)
    cleanup(pathB)
    defer:
      cleanup(pathA)
      cleanup(pathB)
    let identityA = createIdentity(pathA)
    let identityB = createIdentity(pathB)
    check identityA.publicKey != identityB.publicKey
    let sessionA = newSession(inMemoryPair().local, identityA.sessionSeed())
    let sessionB = newSession(inMemoryPair().local, identityB.sessionSeed())
    check sessionA.localPublicKey != sessionB.localPublicKey
    sessionA.close("test cleanup")
    sessionB.close("test cleanup")

  test "incoming sessions use a per-session wire key":
    let path = testPath()
    cleanup(path)
    defer: cleanup(path)
    let identity = createIdentity(path)
    var accepted: Session
    let manager = newTcpSessionManager("127.0.0.1", Port(0), "ignored", "127.0.0.1:0",
      proc(session: Session) = accepted = session, identity = identity)
    let clientTransport = connectTcp("127.0.0.1", manager.listenPort())
    clientTransport.setNonBlocking()
    let client = newGlowcapSession(clientTransport, repeat("q", 32),
      "127.0.0.1:" & $manager.listenPort())
    var remaining = 100
    while (accepted.isNil or accepted.state != ssOpen) and remaining > 0:
      discard manager.poll(5)
      discard client.pump()
      dec remaining
    check remaining > 0
    check accepted.localPublicKey != identity.publicKey
    check accepted.remotePublicKey == client.localPublicKey
    check accepted.state == ssOpen
    client.close("test cleanup")
    while manager.sessionCount > 0:
      discard manager.poll(5)
    manager.close()

  test "legacy durable session identity requires explicit mode":
    let path = testPath()
    cleanup(path)
    defer: cleanup(path)
    let identity = createIdentity(path)
    let node = newNode(port = Port(0), identity = identity,
      sessionIdentityMode = simLegacyDurable)
    let session = node.dial("127.0.0.1", node.manager.listenPort())
    check session.localPublicKey == identity.publicKey
    session.close("legacy mode cleanup")
    node.close()

  test "strict node construction requires durable identity":
    expect IdentityError:
      discard newNode(port = Port(0),
        verificationPolicy = exactPeerPolicy(crypto.publicKey(repeat("x", 32))))

  when defined(ssl):
    test "public mutual TLS rejects testing-only policy before connect":
      let node = newNode(port = Port(0))
      let config = TlsTransportConfig(certificateFile: "missing",
        privateKeyFile: "missing", caFile: "missing",
        expectedPeerCertificateFingerprint: repeat('0', 32),
        expectedPeerCapTpKey: repeat('0', 32))
      expect SessionError:
        discard node.connectMutualTls("127.0.0.1", Port(1), config)
      node.close()

  test "exact expected peer is verified before use":
    let pair = inMemoryPair()
    let clientSeed = repeat("c", 32)
    let serverSeed = repeat("s", 32)
    let server = newSession(pair.remote, serverSeed,
      verificationPolicy = exactPeerPolicy(crypto.publicKey(clientSeed)))
    let client = newSession(pair.local, clientSeed)
    discard server.pump()
    discard client.pump()
    check server.state == ssOpen
    check server.isPeerVerified()
    check not client.isPeerVerified()
    server.close("test cleanup")
    client.close("test cleanup")

  test "expected locator and CapTP key are both verified":
    let pair = inMemoryPair()
    let clientSeed = repeat("c", 32)
    let clientLocator = newPeerLocator("tcp", "client.example",
      [("host", "client.example"), ("port", "22045")])
    let server = newSession(pair.remote, repeat("s", 32), "nim://server",
      verificationPolicy = exactPeerPolicy(crypto.publicKey(clientSeed)))
    server.setExpectedPeer(clientLocator)
    let client = newSession(pair.local, clientSeed, clientLocator.peerUri())
    discard server.pump()
    discard client.pump()
    check server.state == ssOpen
    check server.isPeerVerified()
    server.close("test cleanup")
    client.close("test cleanup")

  test "locator substitution fails before capabilities are available":
    let pair = inMemoryPair()
    let clientSeed = repeat("c", 32)
    let expected = newPeerLocator("tcp", "expected.example")
    let server = newSession(pair.remote, repeat("s", 32), "nim://server",
      verificationPolicy = exactPeerPolicy(crypto.publicKey(clientSeed)))
    server.setExpectedPeer(expected)
    let client = newSession(pair.local, clientSeed,
      newPeerLocator("tcp", "substituted.example").peerUri())
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    check server.stats().importCount == 0
    check server.stats().pendingPromises == 0
    client.close("test cleanup")

  test "unexpected peer identity fails closed and cleans state":
    let pair = inMemoryPair()
    let server = newSession(pair.remote, repeat("s", 32),
      verificationPolicy = exactPeerPolicy(crypto.publicKey(repeat("x", 32))))
    let client = newSession(pair.local, repeat("c", 32))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    check server.stats().pendingPromises == 0
    check server.stats().importCount == 0
    client.close("test cleanup")

  test "authenticated netlayer policy is fail-closed without netlayer proof":
    let pair = inMemoryPair()
    let server = newSession(pair.remote, repeat("s", 32),
      verificationPolicy = authenticatedNetlayerPolicy())
    let client = newSession(pair.local, repeat("c", 32))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    client.close("test cleanup")

  test "trusted authenticated adapter evidence is accepted":
    let pair = inMemoryPair()
    let clientSeed = repeat("c", 32)
    let clientKey = crypto.publicKey(clientSeed)
    let evidence = TransportAuthEvidence(peerIdentity: clientKey,
      proofType: externalAuthenticatedChannel, authenticated: true,
      channelIntegrity: true, channelConfidential: true)
    let verifier: TransportEvidenceVerifier = proc(
        candidate: TransportAuthEvidence; key: string): bool =
      candidate.peerIdentity == key and candidate.authenticated and
        candidate.channelIntegrity
    let serverTransport = newEvidenceTransport(pair.remote, evidence)
    let client = newSession(pair.local, clientSeed)
    let server = newSession(serverTransport, repeat("s", 32),
      verificationPolicy = authenticatedNetlayerPolicy(verifier))
    discard server.pump()
    discard client.pump()
    check server.state == ssOpen
    check server.isPeerVerified()
    check server.isTransportAuthenticated()
    server.close("test cleanup")
    client.close("test cleanup")

  test "forged or downgraded adapter evidence is rejected":
    let pair = inMemoryPair()
    let clientSeed = repeat("c", 32)
    let forged = TransportAuthEvidence(peerIdentity: crypto.publicKey(clientSeed),
      proofType: "forged", authenticated: true, channelIntegrity: true,
      channelConfidential: true)
    let server = newSession(newEvidenceTransport(pair.remote, forged), repeat("s", 32),
      verificationPolicy = authenticatedNetlayerPolicy())
    let client = newSession(pair.local, clientSeed)
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    check not server.isTransportAuthenticated()
    check server.stats().pendingPromises == 0
    client.close("test cleanup")

  test "authenticated adapter identity must match CapTP identity":
    let pair = inMemoryPair()
    let clientSeed = repeat("c", 32)
    let wrongEvidence = TransportAuthEvidence(
      peerIdentity: crypto.publicKey(repeat("w", 32)),
      proofType: externalAuthenticatedChannel, authenticated: true,
      channelIntegrity: true, channelConfidential: true)
    let verifier: TransportEvidenceVerifier = proc(
        candidate: TransportAuthEvidence; key: string): bool =
      candidate.peerIdentity == key
    let server = newSession(newEvidenceTransport(pair.remote, wrongEvidence),
      repeat("s", 32), verificationPolicy = authenticatedNetlayerPolicy(verifier))
    let client = newSession(pair.local, clientSeed)
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    check not server.isTransportAuthenticated()
    client.close("test cleanup")

  test "capabilities cannot be used before handshake verification":
    let pair = inMemoryPair()
    let server = newSession(pair.remote, repeat("s", 32),
      verificationPolicy = exactPeerPolicy(crypto.publicKey(repeat("x", 32))))
    expect SessionError:
      discard server.call(exportRef(0), "fetch", [text("origin")])
    server.close("test cleanup")
