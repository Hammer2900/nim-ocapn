when not defined(ssl):
  {.fatal: "compile this example with -d:ssl".}

import std/[net, os, strutils]
import ../src/[nimocapn, syrup]

if paramCount() != 5:
  quit("usage: tls_server PORT CERT KEY CA EXPECTED_CLIENT_CERT_FINGERPRINT")

let port = Port(parseInt(paramStr(1)))
let identity = newEphemeralIdentity(repeat('s', 32))
var config = defaultNodeConfig(port)
config.identity = identity
config.netlayer = nlkMutualTls
config.verificationPolicy = authenticatedNetlayerPolicy(proc(
    evidence: TransportAuthEvidence; captpKey: string): bool =
  evidence.authenticated and evidence.channelIntegrity and
    evidence.channelConfidential and evidence.peerIdentity == captpKey)
config.tlsServerConfig = TlsTransportConfig(
  certificateFile: paramStr(2), privateKeyFile: paramStr(3), caFile: paramStr(4),
  expectedPeerCertificateFingerprint: paramStr(5), expectedPeerCapTpKey: "",
  allowUnpinnedPeerCapTpKey: true, maxOutputBytes: 1024 * 1024)

let node = newNode(config)
node.publish("greeter", proc(args: seq[SyrupValue]): SyrupValue =
  if args.len == 2 and args[0].kind == skSymbol and args[0].data == "greet" and
      args[1].kind == skString:
    text("hello " & args[1].data)
  else:
    raise newException(CatchableError, "expected greet(string)"))

echo node.locator().peerUri()
stdout.flushFile()
var stopping = false
setControlCHook(proc() {.noconv.} = stopping = true)
try:
  while not stopping:
    discard node.poll(1000)
finally:
  node.close()
