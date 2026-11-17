import std/[algorithm, strutils, tables, uri]
import ./syrup

type
  LocatorError* = object of CatchableError
  PeerLocator* = object
    transport*: string
    designator*: string
    hints*: Table[string, string]
  SturdyRef* = object
    peer*: PeerLocator
    swissNum*: string

proc newPeerLocator*(transport, designator: string;
                     hints: openArray[(string, string)] = []): PeerLocator =
  result.transport = transport
  result.designator = designator
  result.hints = initTable[string, string]()
  for hint in hints:
    result.hints[hint[0]] = hint[1]

proc peerSyrup*(peer: PeerLocator): SyrupValue =
  var pairs: seq[SyrupPair]
  for key, value in peer.hints:
    pairs.add(pair(text(key), text(value)))
  let hints = if pairs.len == 0: boolean(false) else: dict(pairs)
  record(symbol("ocapn-peer"), symbol(peer.transport), text(peer.designator), hints)

proc sturdySyrup*(sturdy: SturdyRef): SyrupValue =
  record(symbol("ocapn-sturdyref"), sturdy.peer.peerSyrup(), text(sturdy.swissNum))

proc peerLocator*(value: SyrupValue): PeerLocator =
  if value.kind != skRecord or value.label.kind != skSymbol or
      value.label.data != "ocapn-peer" or value.fields.len != 3 or
      value.fields[0].kind != skSymbol or value.fields[1].kind != skString:
    raise newException(LocatorError, "invalid ocapn-peer locator")
  result.transport = value.fields[0].data
  result.designator = value.fields[1].data
  result.hints = initTable[string, string]()
  let hints = value.fields[2]
  if hints.kind == skBool and not hints.boolean: return
  if hints.kind != skDict:
    raise newException(LocatorError, "peer locator hints must be a dictionary or false")
  for entry in hints.pairs:
    if entry.key.kind != skString or entry.value.kind != skString:
      raise newException(LocatorError, "peer locator hints must be string pairs")
    result.hints[entry.key.data] = entry.value.data

proc sturdyRef*(value: SyrupValue): SturdyRef =
  if value.kind != skRecord or value.label.kind != skSymbol or
      value.label.data != "ocapn-sturdyref" or value.fields.len != 2 or
      value.fields[1].kind notin {skString, skBytes}:
    raise newException(LocatorError, "invalid ocapn-sturdyref locator")
  result.peer = peerLocator(value.fields[0])
  result.swissNum = value.fields[1].data

proc peerUri*(peer: PeerLocator): string =
  if peer.transport.len == 0 or peer.transport.contains('.'):
    raise newException(LocatorError, "invalid peer transport")
  result = "ocapn://" & encodeUrl(peer.designator, false) & "." & peer.transport
  if peer.hints.len > 0:
    var keys: seq[string]
    for key in peer.hints.keys: keys.add(key)
    keys.sort()
    var query: seq[(string, string)]
    for key in keys: query.add((key, peer.hints[key]))
    result.add("?" & encodeQuery(query, usePlus = false))

proc sturdyUri*(sturdy: SturdyRef): string =
  let peer = sturdy.peer.peerUri()
  result = peer
  let queryAt = result.find('?')
  let suffix = "/s/" & encodeUrl(sturdy.swissNum, false)
  if queryAt < 0: result.add(suffix)
  else: result = result[0 ..< queryAt] & suffix & result[queryAt ..^ 1]

proc parsePeerUri*(value: string): PeerLocator =
  if not value.startsWith("ocapn://"):
    raise newException(LocatorError, "peer URI must use ocapn scheme")
  var body = value[8 ..^ 1]
  var query = ""
  let queryAt = body.find('?')
  if queryAt >= 0:
    query = body[queryAt + 1 ..^ 1]
    body = body[0 ..< queryAt]
  let separator = body.rfind('.')
  if separator <= 0 or separator == body.high:
    raise newException(LocatorError, "peer URI lacks designator or transport")
  result.transport = body[separator + 1 ..^ 1]
  result.designator = decodeUrl(body[0 ..< separator], false)
  result.hints = initTable[string, string]()
  if query.len == 0: return
  for item in query.split('&'):
    let equals = item.find('=')
    if equals <= 0:
      raise newException(LocatorError, "invalid peer URI hint")
    result.hints[decodeUrl(item[0 ..< equals], false)] = decodeUrl(item[equals + 1 ..^ 1], false)

proc parseSturdyUri*(value: string): SturdyRef =
  if not value.startsWith("ocapn://"):
    raise newException(LocatorError, "sturdyref URI must use ocapn scheme")
  let body = value[8 ..^ 1]
  let marker = body.find("/s/")
  if marker < 0:
    raise newException(LocatorError, "sturdyref URI lacks /s/ path")
  let peerPart = "ocapn://" & body[0 ..< marker] &
    (if body.find('?') >= 0: body[body.find('?') ..^ 1] else: "")
  result.peer = parsePeerUri(peerPart)
  let swissEnd = body.find('?', marker)
  let swiss = if swissEnd < 0: body[marker + 3 ..^ 1] else: body[marker + 3 ..< swissEnd]
  result.swissNum = decodeUrl(swiss, false)
  if result.swissNum.len == 0:
    raise newException(LocatorError, "sturdyref swiss number is empty")
