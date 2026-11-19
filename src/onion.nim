import std/[monotimes, net, nativesockets, strutils, tables, times]
import ./[locators, transport]

type
  OnionError* = object of CatchableError
  OnionNetlayerConfig* = object
    socksHost*: string
    socksPort*: Port
    connectTimeoutMs*: int
    servicePort*: Port
  OnionTransport* = ref object of Transport
    inner: TcpTransport
    peer*: PeerLocator
    socksConnected*: bool
    endpointAccepted*: bool
    ## Tor routing is not CapTP identity authentication.
    authenticated*: bool
  OnionListener* = ref object
    inner: TcpListener
    peer*: PeerLocator
  OnionNetlayer* = ref object
    config*: OnionNetlayerConfig

proc defaultOnionNetlayerConfig*(): OnionNetlayerConfig =
  OnionNetlayerConfig(socksHost: "127.0.0.1", socksPort: Port(9050),
    connectTimeoutMs: 10000, servicePort: Port(9045))

proc validateConfig(config: OnionNetlayerConfig) =
  if config.socksHost.len == 0 or config.socksPort == Port(0) or
      config.connectTimeoutMs <= 0 or config.servicePort == Port(0):
    raise newException(OnionError, "invalid Tor Onion netlayer configuration")

proc newOnionNetlayer*(config = defaultOnionNetlayerConfig()): OnionNetlayer =
  config.validateConfig()
  OnionNetlayer(config: config)

proc serviceId(peer: PeerLocator): string =
  if peer.transport != "onion" or peer.designator.len == 0 or len(peer.hints) != 0:
    raise newException(OnionError, "onion locator must use transport onion and no hints")
  result = peer.designator.toLowerAscii()
  if result.endsWith(".onion"):
    result.setLen(result.len - 6)
  if result.len != 56:
    raise newException(OnionError, "onion locator requires a Tor ED25519-V3 service ID")
  for ch in result:
    if ch notin {'a'..'z', '2'..'7'}:
      raise newException(OnionError, "invalid Tor ED25519-V3 service ID")

proc onionHost(peer: PeerLocator): string = peer.serviceId() & ".onion"

proc readExact(socket: Socket; size, timeoutMs: int): string =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while result.len < size:
    let remaining = (deadline - getMonoTime()).inMilliseconds
    if remaining <= 0:
      raise newException(OnionError, "Tor SOCKS5 handshake timed out")
    let chunk = socket.recv(size - result.len, remaining.int)
    if chunk.len == 0:
      raise newException(OnionError, "Tor SOCKS5 proxy closed the connection")
    result.add(chunk)

proc socks5Connect(config: OnionNetlayerConfig; peer: PeerLocator): TcpTransport =
  let socket = newSocket(buffered = false)
  try:
    socket.connect(config.socksHost, config.socksPort, config.connectTimeoutMs)
    socket.send("\5\1\0")
    let greeting = socket.readExact(2, config.connectTimeoutMs)
    if greeting[0] != '\5' or greeting[1] != '\0':
      raise newException(OnionError, "Tor SOCKS5 proxy does not allow unauthenticated proxying")
    let host = peer.onionHost()
    var request = "\5\1\0\3" & char(host.len) & host
    request.add(char((config.servicePort.int shr 8) and 0xff))
    request.add(char(config.servicePort.int and 0xff))
    socket.send(request)
    let header = socket.readExact(4, config.connectTimeoutMs)
    if header[0] != '\5' or header[1] != '\0':
      raise newException(OnionError, "Tor SOCKS5 proxy rejected onion connection")
    let addressLength =
      if header[3] == '\1': 4
      elif header[3] == '\4': 16
      elif header[3] == '\3': ord(socket.readExact(1, config.connectTimeoutMs)[0])
      else: raise newException(OnionError, "invalid Tor SOCKS5 address type")
    discard socket.readExact(addressLength + 2, config.connectTimeoutMs)
    socket.getFd().setBlocking(false)
    result = newTcpTransportFromSocket(socket)
  except CatchableError as error:
    socket.close()
    if error of OnionError: raise
    raise newException(OnionError, "Tor SOCKS5 connection failed: " & error.msg)

proc dial*(netlayer: OnionNetlayer; peer: PeerLocator): OnionTransport =
  if netlayer.isNil: raise newException(OnionError, "onion netlayer is nil")
  result = OnionTransport(inner: netlayer.config.socks5Connect(peer), peer: peer,
    authenticated: false, socksConnected: true)

proc listen*(netlayer: OnionNetlayer; localHost = "127.0.0.1";
             localPort = Port(9045); advertised: PeerLocator): OnionListener =
  if netlayer.isNil: raise newException(OnionError, "onion netlayer is nil")
  discard advertised.serviceId()
  if localPort == Port(0):
    raise newException(OnionError, "onion service listener requires a fixed local port")
  result = OnionListener(inner: listenTcp(localHost, localPort), peer: advertised)
  result.inner.setNonBlocking()

proc acceptIfReady*(listener: OnionListener): OnionTransport =
  if listener.isNil or listener.inner.isNil:
    raise newException(OnionError, "onion listener is closed")
  if not listener.inner.waitReadable(0): return nil
  try:
    let accepted = listener.inner.acceptTcp()
    accepted.setNonBlocking()
    result = OnionTransport(inner: accepted, peer: listener.peer, authenticated: false,
      endpointAccepted: true)
  except TransportError:
    return nil

proc accept*(listener: OnionListener; timeoutMs = 10000): OnionTransport =
  if listener.isNil or listener.inner.isNil:
    raise newException(OnionError, "onion listener is closed")
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    let remaining = (deadline - getMonoTime()).inMilliseconds.int
    if remaining <= 0: break
    if listener.inner.waitReadable(min(remaining, 50)):
      result = listener.acceptIfReady()
      if not result.isNil: return
  raise newException(OnionError, "Onion listener accept timed out")

proc close*(listener: OnionListener) =
  if not listener.isNil: listener.inner.close()

proc peerLocator*(transport: OnionTransport): PeerLocator = transport.peer
proc isAuthenticated*(transport: OnionTransport): bool = transport.authenticated
proc socksEstablished*(transport: OnionTransport): bool = transport.socksConnected
proc endpointWasAccepted*(transport: OnionTransport): bool = transport.endpointAccepted
proc socketHandle*(transport: OnionTransport): SocketHandle = transport.inner.socketHandle()
proc socketHandle*(listener: OnionListener): SocketHandle = listener.inner.socketHandle()
proc localPort*(listener: OnionListener): Port = listener.inner.localPort()

method send*(transport: OnionTransport; payload: string) = transport.inner.send(payload)
method receive*(transport: OnionTransport): string = transport.inner.receive()
method isClosed*(transport: OnionTransport): bool = transport.inner.isClosed()
method close*(transport: OnionTransport) = transport.inner.close()
method flushOutput*(transport: OnionTransport): bool = transport.inner.flushOutput()
method wantsWrite*(transport: OnionTransport): bool = transport.inner.wantsWrite()
method queuedBytes*(transport: OnionTransport): int = transport.inner.queuedBytes()
method waitReadable*(transport: OnionTransport; timeoutMs: int): bool =
  transport.inner.waitReadable(timeoutMs)

method peerIdentity*(transport: OnionTransport): string = ""

method peerAuthenticated*(transport: OnionTransport): bool = transport.authenticated
