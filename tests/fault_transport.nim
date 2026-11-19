import ../src/transport

type
  FaultLink = ref object
    inbox: array[2, seq[string]]
    held: array[2, seq[string]]
    closed: array[2, bool]
    delayed: array[2, bool]
    duplicated: array[2, bool]
  FaultTransport* = ref object of Transport
    link: FaultLink
    side: int

proc faultPair*(): tuple[a, b: FaultTransport] =
  let link = FaultLink(inbox: [@[], @[]], held: [@[], @[]],
    closed: [false, false], delayed: [false, false], duplicated: [false, false])
  (FaultTransport(link: link, side: 0), FaultTransport(link: link, side: 1))

proc other(transport: FaultTransport): int = 1 - transport.side

method send(transport: FaultTransport; payload: string) =
  if transport.link.closed[transport.side] or transport.link.closed[transport.other()]:
    raise newException(TransportError, "fault transport is closed")
  let destination = transport.other()
  if transport.link.delayed[transport.side]:
    transport.link.held[transport.side].add(payload)
  else:
    transport.link.inbox[destination].add(payload)
    if transport.link.duplicated[transport.side]:
      transport.link.inbox[destination].add(payload)

method receive(transport: FaultTransport): string =
  for payload in transport.link.inbox[transport.side]:
    result.add(payload)
  transport.link.inbox[transport.side].setLen(0)

method isClosed(transport: FaultTransport): bool =
  transport.link.closed[transport.side] or transport.link.closed[transport.other()]

method close(transport: FaultTransport) =
  transport.link.closed[transport.side] = true

proc setDelayed*(transport: FaultTransport; value: bool) =
  transport.link.delayed[transport.side] = value

proc setDuplicated*(transport: FaultTransport; value: bool) =
  transport.link.duplicated[transport.side] = value

proc releaseHeld*(transport: FaultTransport) =
  let destination = transport.other()
  for payload in transport.link.held[transport.side]:
    transport.link.inbox[destination].add(payload)
  transport.link.held[transport.side].setLen(0)
  transport.link.delayed[transport.side] = false
