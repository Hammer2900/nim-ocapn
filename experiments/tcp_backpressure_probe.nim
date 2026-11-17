import std/[net, strutils]
import ../src/transport

let listener = listenTcp("127.0.0.1", Port(0))
let client = connectTcp("127.0.0.1", listener.localPort())
let server = listener.acceptTcp()
client.setNonBlocking()
server.setNonBlocking()
client.maxOutputBytes = 64 * 1024
let payload = repeat('x', 4096)
var attempts = 0
var overflow = false
try:
  while attempts < 100_000:
    client.send(payload)
    inc attempts
except TransportError:
  overflow = true

let queued = client.queuedBytes()
let flushed = client.flushOutput()
echo "attempts=", attempts, " overflow=", overflow,
  " queued_bytes=", queued, " flush_complete=", flushed
client.close()
server.close()
listener.close()
if not overflow or queued <= 0 or flushed:
  quit("did not observe bounded nonblocking backpressure")
