import std/[net, nativesockets, os, selectors]
import ./identity

type
  TransportError* = object of CatchableError
  Transport* = ref object of RootObj
  InMemoryTransport* = ref object of Transport
    peer: InMemoryTransport
    inbox: seq[string]
    closed: bool
  TcpTransport* = ref object of Transport
    socket: Socket
    closed: bool
    socketClosed: bool
    output: seq[string]
    outputBytes: int
    maxOutputBytes*: int
  TcpListener* = ref object
    socket: Socket
    closed: bool

const externalAuthenticatedChannel* = "external-authenticated-channel"

proc inMemoryPair*(): tuple[local, remote: InMemoryTransport] =
  let a = InMemoryTransport()
  let b = InMemoryTransport()
  a.peer = b
  b.peer = a
  (a, b)

proc newTcpTransportFromSocket*(socket: owned Socket;
                                maxOutputBytes = 1024 * 1024): TcpTransport =
  TcpTransport(socket: socket, maxOutputBytes: maxOutputBytes)

method send*(transport: Transport; payload: string) {.base.} =
  raise newException(TransportError, "transport send is not implemented")

method receive*(transport: Transport): string {.base.} =
  raise newException(TransportError, "transport receive is not implemented")

method isClosed*(transport: Transport): bool {.base.} = false

method close*(transport: Transport) {.base.} = discard

method flushOutput*(transport: Transport): bool {.base.} = true

method wantsWrite*(transport: Transport): bool {.base.} = false

method queuedBytes*(transport: Transport): int {.base.} = 0

method waitReadable*(transport: Transport; timeoutMs: int): bool {.base.} = false

method peerIdentity*(transport: Transport): string {.base.} = ""

method peerAuthenticated*(transport: Transport): bool {.base.} = false

method authenticationEvidence*(transport: Transport): TransportAuthEvidence {.base.} =
  TransportAuthEvidence()

method send*(transport: InMemoryTransport; payload: string) =
  if transport.closed or transport.peer.isNil or transport.peer.closed:
    raise newException(TransportError, "in-memory transport is closed")
  transport.peer.inbox.add(payload)

method receive*(transport: InMemoryTransport): string =
  if transport.inbox.len == 0:
    return ""
  for payload in transport.inbox:
    result.add(payload)
  transport.inbox.setLen(0)

method isClosed*(transport: InMemoryTransport): bool =
  transport.closed or transport.peer.isNil or transport.peer.closed

method close*(transport: InMemoryTransport) =
  transport.closed = true

proc connectTcp*(host: string; port: Port; maxOutputBytes = 1024 * 1024): TcpTransport =
  result = TcpTransport(socket: newSocket(buffered = false),
    maxOutputBytes: maxOutputBytes)
  try:
    result.socket.connect(host, port)
  except CatchableError as error:
    result.socket.close()
    raise newException(TransportError, error.msg)

proc listenTcp*(host: string; port: Port): TcpListener =
  result = TcpListener(socket: newSocket(buffered = false))
  try:
    result.socket.setSockOpt(OptReuseAddr, true)
    result.socket.bindAddr(port, host)
    result.socket.listen()
  except CatchableError as error:
    result.socket.close()
    raise newException(TransportError, error.msg)

proc acceptRawTcpSocket*(listener: TcpListener): owned Socket

proc acceptTcp*(listener: TcpListener): TcpTransport =
  result = newTcpTransportFromSocket(listener.acceptRawTcpSocket())

proc acceptRawTcpSocket*(listener: TcpListener): owned Socket =
  if listener.isNil or listener.closed:
    raise newException(TransportError, "TCP listener is closed")
  try:
    var client: owned(Socket)
    var address = ""
    listener.socket.acceptAddr(client, address)
    result = client
  except CatchableError as error:
    raise newException(TransportError, error.msg)

proc socketHandle*(transport: TcpTransport): SocketHandle = transport.socket.getFd()
proc socketHandle*(listener: TcpListener): SocketHandle = listener.socket.getFd()

proc localPort*(listener: TcpListener): Port =
  listener.socket.getLocalAddr()[1]

proc setNonBlocking*(transport: TcpTransport) =
  transport.socket.getFd().setBlocking(false)

proc setNonBlocking*(listener: TcpListener) =
  listener.socket.getFd().setBlocking(false)

proc waitReadable*(listener: TcpListener; timeoutMs: int): bool =
  if listener.isNil or listener.closed: return false
  let selector = newSelector[int]()
  defer: selector.close()
  selector.registerHandle(listener.socketHandle(), {Read}, 0)
  selector.select(timeoutMs).len > 0

proc close*(listener: TcpListener) =
  if not listener.isNil and not listener.closed:
    listener.closed = true
    listener.socket.close()

method send*(transport: TcpTransport; payload: string) =
  if transport.closed: raise newException(TransportError, "TCP transport is closed")
  if payload.len == 0: return
  if transport.output.len > 0:
    if transport.outputBytes + payload.len > transport.maxOutputBytes:
      raise newException(TransportError, "outbound queue limit exceeded")
    transport.output.add(payload)
    transport.outputBytes += payload.len
    return
  try:
    transport.socket.send(payload)
  except CatchableError as error:
    when defined(posix):
      if osLastError().int32 in [EAGAIN.int32, EWOULDBLOCK.int32]:
        if payload.len > transport.maxOutputBytes:
          raise newException(TransportError, "outbound queue limit exceeded")
        transport.output.add(payload)
        transport.outputBytes = payload.len
        return
    transport.closed = true
    raise newException(TransportError, error.msg)

method flushOutput*(transport: TcpTransport): bool =
  if transport.closed: return false
  while transport.output.len > 0:
    try:
      transport.socket.send(transport.output[0])
      transport.outputBytes -= transport.output[0].len
      transport.output.delete(0)
    except CatchableError as error:
      when defined(posix):
        if osLastError().int32 in [EAGAIN.int32, EWOULDBLOCK.int32]:
          return false
      transport.closed = true
      raise newException(TransportError, error.msg)
  true

method wantsWrite*(transport: TcpTransport): bool = transport.output.len > 0
method queuedBytes*(transport: TcpTransport): int = transport.outputBytes

method waitReadable*(transport: TcpTransport; timeoutMs: int): bool =
  if transport.closed: return false
  let selector = newSelector[int]()
  defer: selector.close()
  selector.registerHandle(transport.socketHandle(), {Read}, 0)
  selector.select(timeoutMs).len > 0

method receive*(transport: TcpTransport): string =
  if transport.closed: return ""
  try:
    result = transport.socket.recv(65536)
    if result.len == 0: transport.closed = true
  except CatchableError as error:
    when defined(posix):
      if osLastError().int32 in [EAGAIN.int32, EWOULDBLOCK.int32]:
        return ""
    transport.closed = true
    raise newException(TransportError, error.msg)

method isClosed*(transport: TcpTransport): bool = transport.closed

method close*(transport: TcpTransport) =
  if not transport.socketClosed:
    transport.socket.close()
    transport.socketClosed = true
  transport.closed = true
