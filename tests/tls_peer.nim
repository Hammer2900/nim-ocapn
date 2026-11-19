import std/[monotimes, net, os, strutils, times]
import ../src/[crypto, identity, locators, references, session, syrup, tls_transport, transport]

proc hexBytes(value: string): string =
  try:
    if value.len mod 2 != 0: raise newException(ValueError, "odd hex length")
    result = parseHexStr(value)
  except ValueError as error:
    raise newException(SessionError, "invalid hexadecimal test argument: " & error.msg)

proc fail(message: string) {.noreturn.} =
  stderr.writeLine("FAIL: " & message)
  quit(1)

proc pumpUntil(session: Session; timeoutMs: int; done: proc(): bool {.closure.}) =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    discard session.pump()
    if done(): return
    discard session.transport.waitReadable(10)
  fail("session timeout state=" & $session.state)

proc makePolicy(expectedCapTpKey, expectedFingerprint: string): PeerVerificationPolicy =
  let verifier: TransportEvidenceVerifier = proc(evidence: TransportAuthEvidence;
                                                 capTpKey: string): bool =
    evidence.transportIdentity == expectedFingerprint and
      evidence.peerIdentity == capTpKey and evidence.channelIntegrity and
      evidence.channelConfidential
  authenticatedNetlayerPolicy(verifier)

proc runServer(port: Port; certFile, keyFile, caFile, expectedFingerprint,
               expectedPeerSeed, seed: string) =
  let listener = listenTcp("127.0.0.1", port)
  listener.setNonBlocking()
  echo "READY"
  stdout.flushFile()
  let deadline = getMonoTime() + initDuration(seconds = 10)
  var raw: owned Socket
  while raw.isNil and getMonoTime() < deadline:
    if listener.waitReadable(50):
      raw = listener.acceptRawTcpSocket()
  if raw.isNil: fail("server accept timeout")
  let expectedCapTpKey = crypto.publicKey(hexBytes(expectedPeerSeed))
  let config = TlsTransportConfig(certificateFile: certFile, privateKeyFile: keyFile,
    caFile: caFile, expectedPeerCertificateFingerprint: hexBytes(expectedFingerprint),
    expectedPeerCapTpKey: expectedCapTpKey, serverName: "localhost",
    maxOutputBytes: 1024 * 1024)
  let tls = newTlsServer(raw, config)
  let policy = makePolicy(config.expectedPeerCapTpKey, config.expectedPeerCertificateFingerprint)
  let session = newSession(tls, hexBytes(seed),
    newPeerLocator("tls-testing-only", "server").peerUri(),
    verificationPolicy = policy)
  session.setExpectedPeer(newPeerLocator("tls-testing-only", "client"))
  discard session.publishActor("greeter", proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    let value = if args.len == 2 and args[0].kind == skSymbol and
        args[0].data == "greet": args[1]
      elif args.len == 1: args[0]
      else: nil
    if not value.isNil and value.kind == skString:
      text("Hello, " & value.data)
    else:
      raise newException(SessionError, "greeter expects greet(string)"))
  discard session.publishActor("reject", proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    let answer = actor.deferAnswer()
    actor.breakAnswer(answer, "expected rejection")
    list())
  echo "TLS_READY"
  stdout.flushFile()
  try:
    while session.state != ssClosed:
      discard session.pump()
      discard tls.waitReadable(10)
  except CatchableError as error:
    fail(error.msg)
  finally:
    session.close("TLS test cleanup")
    listener.close()

proc runClient(host: string; port: Port; certFile, keyFile, caFile,
               expectedFingerprint, expectedPeerSeed, seed: string) =
  let expectedCapTpKey = crypto.publicKey(hexBytes(expectedPeerSeed))
  let config = TlsTransportConfig(certificateFile: certFile, privateKeyFile: keyFile,
    caFile: caFile, expectedPeerCertificateFingerprint: hexBytes(expectedFingerprint),
    expectedPeerCapTpKey: expectedCapTpKey, serverName: "localhost",
    maxOutputBytes: 1024 * 1024)
  let tls = newTlsClient(host, port, config)
  let policy = makePolicy(config.expectedPeerCapTpKey, config.expectedPeerCertificateFingerprint)
  let session = newSession(tls, hexBytes(seed),
    newPeerLocator("tls-testing-only", "client").peerUri(),
    verificationPolicy = policy)
  session.setExpectedPeer(newPeerLocator("tls-testing-only", "server"))
  pumpUntil(session, 10000, proc(): bool = session.state == ssOpen)
  if not session.isPeerVerified() or not session.isTransportAuthenticated():
    fail("authenticated state was not established")
  let fetched = session.fetch("greeter")
  let pipelineFetch = session.fetch("greeter")
  let pipelined = session.callPipelined(pipelineFetch, "greet", [text("world")])
  let result = session.waitFor(pipelined)
  if result.kind != skString or result.data != "Hello, world":
    fail("unexpected greeting result")
  let rejectedTarget = session.waitFor(session.fetch("reject"))
  let rejected = session.call(rejectedTarget.descriptor(), "reject", [])
  try:
    discard session.waitFor(rejected)
    fail("TLS rejection unexpectedly fulfilled")
  except SessionError:
    discard
  let cancelled = session.call(fetched.value.descriptor(), "greet", [text("cancelled")])
  discard session.cancel(cancelled, "transport conformance cancellation")
  let afterCancel = session.waitFor(session.call(fetched.value.descriptor(), "greet", [text("after")]))
  if afterCancel.kind != skString or afterCancel.data != "Hello, after":
    fail("TLS call after cancellation failed")
  session.release(fetched.value.descriptor())
  session.release(pipelineFetch.value.descriptor())
  session.release(rejectedTarget.descriptor())
  pumpUntil(session, 1000, proc(): bool = session.stats().importCount == 0)
  echo "PASS"
  stdout.flushFile()
  session.close("TLS test cleanup")

if paramCount() < 8:
  fail("usage: tls_peer server|client port cert key ca expected-cert-sha256 expected-peer-seed seed")
let role = paramStr(1)
let port = Port(parseInt(paramStr(2)))
let certFile = paramStr(3)
let keyFile = paramStr(4)
let caFile = paramStr(5)
let expectedFingerprint = paramStr(6)
let expectedCapTpKey = paramStr(7)
let seed = paramStr(8)
if seed.len != 64:
  fail("seed must be 64 hexadecimal characters")
if role == "server":
  runServer(port, certFile, keyFile, caFile, expectedFingerprint, expectedCapTpKey, seed)
elif role == "client":
  runClient("127.0.0.1", port, certFile, keyFile, caFile,
    expectedFingerprint, expectedCapTpKey, seed)
else:
  fail("unknown role")
