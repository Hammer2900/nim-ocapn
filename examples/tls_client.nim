when not defined(ssl):
  {.fatal: "compile this example with -d:ssl".}

import std/[net, os, strutils]
import ../src/[nimocapn, syrup]

if paramCount() != 7:
  quit("usage: tls_client HOST PORT CERT KEY CA EXPECTED_SERVER_CERT_FINGERPRINT IDENTITY_SEED")

let identitySeed = paramStr(7)
if identitySeed.len != 32:
  quit("IDENTITY_SEED must contain exactly 32 bytes")
var config = defaultNodeConfig()
config.identity = newEphemeralIdentity(identitySeed)
config.verificationPolicy = authenticatedNetlayerPolicy(proc(
    evidence: TransportAuthEvidence; captpKey: string): bool =
  evidence.authenticated and evidence.channelIntegrity and
    evidence.channelConfidential and evidence.peerIdentity == captpKey)
let tls = TlsTransportConfig(
  certificateFile: paramStr(3), privateKeyFile: paramStr(4), caFile: paramStr(5),
  expectedPeerCertificateFingerprint: paramStr(6), expectedPeerCapTpKey: "",
  allowUnpinnedPeerCapTpKey: true, maxOutputBytes: 1024 * 1024)
let node = newNode(config)
try:
  for cycle in 1 .. 2:
    let session = node.connectMutualTls(paramStr(1), Port(parseInt(paramStr(2))), tls)
    let greeter = node.bootstrap(session, "greeter")
    let answer = waitFor(session, greeter.call("greet", [text("cycle-" & $cycle)]))
    echo answer.data
    closeSession(session, "example cycle complete")
finally:
  node.close()
