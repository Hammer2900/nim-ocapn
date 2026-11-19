import std/[net, os, strutils]
import ../src/[nimocapn, syrup]

proc hexBytes(value: string): string =
  result = parseHexStr(value)

proc policy(expectedFingerprint: string): PeerVerificationPolicy =
  let verifier: TransportEvidenceVerifier = proc(
      evidence: TransportAuthEvidence; capTpKey: string): bool =
    evidence.transportIdentity == expectedFingerprint and
      evidence.peerIdentity == capTpKey and evidence.channelIntegrity and
      evidence.channelConfidential
  authenticatedNetlayerPolicy(verifier)

proc server(port: Port; certFile, keyFile, caFile, expectedClientFingerprint: string) =
  var config = defaultNodeConfig(port)
  config.netlayer = nlkMutualTls
  config.identity = newEphemeralIdentity(repeat('s', 32))
  config.diagnosticSink = proc(event: DiagnosticEvent) =
    stderr.writeLine("server diagnostic " & $event.kind & " " & event.detail)
  config.verificationPolicy = policy(hexBytes(expectedClientFingerprint))
  config.tlsServerConfig = TlsTransportConfig(
    certificateFile: certFile, privateKeyFile: keyFile, caFile: caFile,
    expectedPeerCertificateFingerprint: hexBytes(expectedClientFingerprint),
    expectedPeerCapTpKey: "", allowUnpinnedPeerCapTpKey: true,
    serverName: "localhost", maxOutputBytes: 1024 * 1024)
  let node = newNode(config)
  node.publish("greeter", proc(args: seq[SyrupValue]): SyrupValue =
    if args.len == 2 and args[0].kind == skSymbol and args[0].data == "greet" and
        args[1].kind == skString:
      text("Hello, " & args[1].data)
    else:
      raise newException(SessionError, "greeter expects one string"))
  echo "READY"
  stdout.flushFile()
  try:
    while true:
      discard node.poll(100)
  finally:
    node.close()

proc client(port: Port; certFile, keyFile, caFile, expectedServerFingerprint: string) =
  var config = defaultNodeConfig()
  config.identity = newEphemeralIdentity(repeat('c', 32))
  config.verificationPolicy = policy(hexBytes(expectedServerFingerprint))
  let tlsConfig = TlsTransportConfig(
    certificateFile: certFile, privateKeyFile: keyFile, caFile: caFile,
    expectedPeerCertificateFingerprint: hexBytes(expectedServerFingerprint),
    expectedPeerCapTpKey: "", allowUnpinnedPeerCapTpKey: true,
    serverName: "localhost", maxOutputBytes: 1024 * 1024)
  let node = newNode(config)
  try:
    for cycle in 0 .. 1:
      let session = node.connectMutualTls("127.0.0.1", port, tlsConfig)
      let greeter = node.bootstrap(session, "greeter")
      let answer = waitFor(session, greeter.call("greet", [text("cycle-" & $cycle)]))
      if answer.kind != skString or answer.data != "Hello, cycle-" & $cycle:
        raise newException(SessionError, "unexpected TLS facade response")
      closeSession(session, "TLS facade cycle complete")
    echo "PASS"
  finally:
    node.close()

if paramCount() != 6:
  quit("usage: tls_node_peer server|client port cert key ca expected-peer-fingerprint")
let role = paramStr(1)
let port = Port(parseInt(paramStr(2)))
if role == "server":
  server(port, paramStr(3), paramStr(4), paramStr(5), paramStr(6))
elif role == "client":
  client(port, paramStr(3), paramStr(4), paramStr(5), paramStr(6))
else:
  quit("unknown role")
