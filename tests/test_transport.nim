import std/[strutils, unittest]
import ../src/transport

type
  MockTransport = ref object of Transport
    blocked: bool
    maxQueueBytes: int
    maxWriteBytes: int
    queued: seq[string]
    queuedBytes: int
    wire: string
    closed: bool

proc writeChunk(transport: MockTransport; payload: string; front = false) =
  let count = min(payload.len, transport.maxWriteBytes)
  transport.wire.add(payload[0 ..< count])
  if count < payload.len:
    let remainder = payload[count .. ^1]
    if transport.queuedBytes + remainder.len > transport.maxQueueBytes:
      raise newException(TransportError, "mock outbound queue limit exceeded")
    if front:
      transport.queued.insert(remainder, 0)
    else:
      transport.queued.add(remainder)
    transport.queuedBytes += remainder.len

method send*(transport: MockTransport; payload: string) =
  if transport.closed:
    raise newException(TransportError, "mock transport is closed")
  if transport.blocked:
    if transport.queuedBytes + payload.len > transport.maxQueueBytes:
      raise newException(TransportError, "mock outbound queue limit exceeded")
    transport.queued.add(payload)
    transport.queuedBytes += payload.len
  else:
    transport.writeChunk(payload)

method receive*(transport: MockTransport): string = ""
method isClosed*(transport: MockTransport): bool = transport.closed
method close*(transport: MockTransport) = transport.closed = true

proc flush(transport: MockTransport) =
  if transport.blocked: return
  while transport.queued.len > 0:
    let payload = transport.queued[0]
    transport.queued.delete(0)
    transport.queuedBytes -= payload.len
    transport.writeChunk(payload, front = true)

suite "controlled transport backpressure":
  test "bounds the testing-only in-memory inbox":
    let pair = inMemoryPair()
    let payload = "x".repeat(1024 * 1024)
    pair.local.send(payload)
    check pair.local.queuedBytes() == payload.len
    expect TransportError:
      pair.local.send("x")
    discard pair.remote.receive()
    check pair.local.queuedBytes() == 0

  test "bounds a would-block queue and drains partial writes":
    let transport = MockTransport(blocked: true, maxQueueBytes: 8,
      maxWriteBytes: 2, queued: @[])
    transport.send("abcd")
    transport.send("efgh")
    check transport.queuedBytes == 8
    expect TransportError:
      transport.send("i")
    transport.blocked = false
    transport.flush()
    check transport.queuedBytes == 0
    check transport.wire == "abcdefgh"
