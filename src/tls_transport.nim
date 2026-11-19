## Project-specific authenticated transport profile.
##
## This module is deliberately separate from the OCapN Onion/TCP profiles. It
## uses Nim's OpenSSL-backed TLS socket support with mutual certificate
## authentication and an explicit certificate-fingerprint -> CapTP-key map.

when not defined(ssl):
  {.fatal: "tls_transport requires -d:ssl and Nim's OpenSSL support".}

import std/[base64, net, nativesockets, os, selectors, strutils]
import ./[crypto, identity, transport]

type
  TlsTransportError* = object of CatchableError
  TlsTransportConfig* = object
    certificateFile*: string
    privateKeyFile*: string
    caFile*: string
    expectedPeerCertificateFingerprint*: string
    expectedPeerCapTpKey*: string
    allowUnpinnedPeerCapTpKey*: bool
    serverName*: string
    maxOutputBytes*: int
  TlsTransport* = ref object of Transport
    socket: Socket
    context: SslContext
    output: seq[string]
    outputBytes: int
    maxOutput: int
    closed: bool
    evidence: TransportAuthEvidence

proc validateConfig(config: TlsTransportConfig) =
  if config.certificateFile.len == 0 or config.privateKeyFile.len == 0 or
      config.caFile.len == 0 or config.expectedPeerCertificateFingerprint.len != 32 or
      (config.expectedPeerCapTpKey.len != 32 and
       not (config.allowUnpinnedPeerCapTpKey and config.expectedPeerCapTpKey.len == 0)):
    raise newException(TlsTransportError, "TLS config requires certificates, CA, and exact peer bindings")

proc validateTlsConfig*(config: TlsTransportConfig) =
  config.validateConfig()

proc makeContext(config: TlsTransportConfig): SslContext =
  try:
    result = newContext(protTLSv1, CVerifyPeer, config.certificateFile,
      config.privateKeyFile, caFile = config.caFile)
  except CatchableError as error:
    raise newException(TlsTransportError, "TLS context setup failed: " & error.msg)

proc certificateFingerprint*(certificateFile: string): string =
  ## SHA-256 of the DER certificate, used only as an out-of-band trust anchor.
  let pem = readFile(certificateFile)
  let beginMarker = "-----BEGIN CERTIFICATE-----"
  let endMarker = "-----END CERTIFICATE-----"
  let beginAt = pem.find(beginMarker)
  let endAt = pem.find(endMarker)
  if beginAt < 0 or endAt <= beginAt:
    raise newException(TlsTransportError, "certificate is not PEM encoded")
  let body = pem[beginAt + beginMarker.len ..< endAt]
    .replace("\r", "").replace("\n", "").replace(" ", "")
  try:
    result = crypto.sha256(decode(body))
  except CatchableError as error:
    raise newException(TlsTransportError, "cannot decode certificate: " & error.msg)

proc finishHandshake(socket: Socket; context: SslContext; server: bool;
                     config: TlsTransportConfig): TlsTransport =
  try:
    context.wrapConnectedSocket(socket, if server: handshakeAsServer else: handshakeAsClient,
      if server: "" else: config.serverName)
    let certificates = socket.getPeerCertificates()
    if certificates.len == 0:
      raise newException(TlsTransportError, "TLS peer did not present a verified certificate")
    let fingerprint = crypto.sha256(certificates[0])
    if fingerprint != config.expectedPeerCertificateFingerprint:
      raise newException(TlsTransportError, "TLS peer certificate fingerprint mismatch")
    socket.getFd().setBlocking(false)
    result = TlsTransport(socket: socket, context: context, maxOutput: config.maxOutputBytes,
      evidence: TransportAuthEvidence(
        peerIdentity: config.expectedPeerCapTpKey,
        transportIdentity: fingerprint,
        proofType: externalAuthenticatedChannel,
        authenticated: true, channelIntegrity: true, channelConfidential: true))
  except CatchableError as error:
    socket.close()
    destroyContext(context)
    if error of TlsTransportError: raise
    raise newException(TlsTransportError, "TLS handshake failed: " & error.msg)

proc newTlsClient*(host: string; port: Port; config: TlsTransportConfig): TlsTransport =
  config.validateConfig()
  var socket = newSocket(buffered = false)
  try:
    socket.connect(host, port)
    result = finishHandshake(socket, config.makeContext(), false, config)
  except CatchableError as error:
    socket.close()
    if error of TlsTransportError: raise
    raise newException(TlsTransportError, "TLS connect failed: " & error.msg)

proc newTlsServer*(socket: owned Socket; config: TlsTransportConfig): TlsTransport =
  config.validateConfig()
  result = finishHandshake(socket, config.makeContext(), true, config)

method send*(transport: TlsTransport; payload: string) =
  if transport.closed: raise newException(TlsTransportError, "TLS transport is closed")
  if payload.len == 0: return
  if transport.output.len > 0:
    if transport.outputBytes + payload.len > transport.maxOutput:
      raise newException(TlsTransportError, "TLS outbound queue limit exceeded")
    transport.output.add(payload)
    transport.outputBytes += payload.len
    return
  try:
    transport.socket.send(payload)
  except CatchableError as error:
    when defined(posix):
      if osLastError().int32 in [EAGAIN.int32, EWOULDBLOCK.int32]:
        if payload.len > transport.maxOutput:
          raise newException(TlsTransportError, "TLS outbound queue limit exceeded")
        transport.output.add(payload)
        transport.outputBytes = payload.len
        return
    transport.closed = true
    raise newException(TlsTransportError, error.msg)

method flushOutput*(transport: TlsTransport): bool =
  if transport.closed: return false
  while transport.output.len > 0:
    try:
      transport.socket.send(transport.output[0])
      transport.outputBytes -= transport.output[0].len
      transport.output.delete(0)
    except CatchableError as error:
      when defined(posix):
        if osLastError().int32 in [EAGAIN.int32, EWOULDBLOCK.int32]: return false
      transport.closed = true
      raise newException(TlsTransportError, error.msg)
  true

method receive*(transport: TlsTransport): string =
  if transport.closed: return ""
  try:
    result = transport.socket.recv(65536)
    if result.len == 0: transport.closed = true
  except CatchableError as error:
    when defined(posix):
      if osLastError().int32 in [EAGAIN.int32, EWOULDBLOCK.int32]: return ""
    transport.closed = true
    raise newException(TlsTransportError, error.msg)

method isClosed*(transport: TlsTransport): bool =
  transport.closed or transport.socket.getFd() == osInvalidSocket
method close*(transport: TlsTransport) =
  if transport.isNil or transport.closed: return
  transport.closed = true
  transport.socket.close()
  destroyContext(transport.context)

method wantsWrite*(transport: TlsTransport): bool = transport.output.len > 0
method queuedBytes*(transport: TlsTransport): int = transport.outputBytes
method waitReadable*(transport: TlsTransport; timeoutMs: int): bool =
  if transport.isClosed(): return false
  let selector = newSelector[int]()
  defer: selector.close()
  selector.registerHandle(transport.socket.getFd(), {Read}, 0)
  selector.select(timeoutMs).len > 0
method peerIdentity*(transport: TlsTransport): string = transport.evidence.peerIdentity
method peerAuthenticated*(transport: TlsTransport): bool = transport.evidence.authenticated
method authenticationEvidence*(transport: TlsTransport): TransportAuthEvidence = transport.evidence

method bindPeerIdentity*(transport: TlsTransport; captpPublicKey: string): bool =
  if captpPublicKey.len != 32: return false
  if transport.evidence.peerIdentity.len == 0:
    transport.evidence.peerIdentity = captpPublicKey
    return true
  transport.evidence.peerIdentity == captpPublicKey

proc socketHandle*(transport: TlsTransport): SocketHandle = transport.socket.getFd()
