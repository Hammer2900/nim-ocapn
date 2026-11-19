import std/[algorithm, strutils, tables, uri, unicode]
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

proc validPercentEncoding(value: string): bool =
  proc isHexDigit(value: char): bool =
    value in {'0'..'9', 'a'..'f', 'A'..'F'}
  var index = 0
  while index < value.len:
    if value[index] == '%':
      if index + 2 >= value.len or
          not isHexDigit(value[index + 1]) or
          not isHexDigit(value[index + 2]):
        return false
      index += 3
    else:
      inc index
  true

proc validatePeer(peer: PeerLocator) =
  if peer.transport.len == 0 or peer.transport.contains('.'):
    raise newException(LocatorError, "peer transport must be a non-empty symbol without '.'")
  if validateUtf8(peer.transport) >= 0 or validateUtf8(peer.designator) >= 0:
    raise newException(LocatorError, "peer locator fields must contain valid UTF-8")
  for key, value in peer.hints:
    if validateUtf8(key) >= 0 or validateUtf8(value) >= 0:
      raise newException(LocatorError, "peer locator hints must contain valid UTF-8")

proc newPeerLocator*(transport, designator: string;
                     hints: openArray[(string, string)] = []): PeerLocator =
  result.transport = transport
  result.designator = designator
  result.hints = initTable[string, string]()
  for hint in hints:
    result.hints[hint[0]] = hint[1]
  result.validatePeer()

proc samePeer*(left, right: PeerLocator): bool =
  ## Locator equality is based on transport and designator; hints are routing data.
  left.transport == right.transport and left.designator == right.designator

proc peerSyrup*(peer: PeerLocator): SyrupValue =
  peer.validatePeer()
  var pairs: seq[SyrupPair]
  for key, value in peer.hints:
    pairs.add(pair(text(key), text(value)))
  let hints = if pairs.len == 0: boolean(false) else: dict(pairs)
  record(symbol("ocapn-peer"), symbol(peer.transport), text(peer.designator), hints)

proc sturdySyrup*(sturdy: SturdyRef): SyrupValue =
  if sturdy.swissNum.len == 0:
    raise newException(LocatorError, "sturdyref swiss number is empty")
  record(symbol("ocapn-sturdyref"), sturdy.peer.peerSyrup(), text(sturdy.swissNum))

proc peerLocator*(value: SyrupValue): PeerLocator =
  if value.kind != skRecord or value.label.kind != skSymbol or
      value.label.data != "ocapn-peer" or value.fields.len != 3 or
      value.fields[0].kind != skSymbol or value.fields[1].kind != skString:
    raise newException(LocatorError, "invalid ocapn-peer locator")
  result.transport = value.fields[0].data
  result.designator = value.fields[1].data
  result.validatePeer()
  result.hints = initTable[string, string]()
  let hints = value.fields[2]
  if hints.kind == skBool and not hints.boolean: return
  if hints.kind != skDict:
    raise newException(LocatorError, "peer locator hints must be a dictionary or false")
  for entry in hints.pairs:
    if entry.key.kind != skString or entry.value.kind != skString:
      raise newException(LocatorError, "peer locator hints must be string pairs")
    if result.hints.hasKey(entry.key.data):
      raise newException(LocatorError, "peer locator contains duplicate hint")
    result.hints[entry.key.data] = entry.value.data

proc sturdyRef*(value: SyrupValue): SturdyRef =
  if value.kind != skRecord or value.label.kind != skSymbol or
      value.label.data != "ocapn-sturdyref" or value.fields.len != 2 or
      value.fields[1].kind notin {skString, skBytes}:
    raise newException(LocatorError, "invalid ocapn-sturdyref locator")
  if value.fields[1].data.len == 0:
    raise newException(LocatorError, "sturdyref swiss number is empty")
  result.peer = peerLocator(value.fields[0])
  result.swissNum = value.fields[1].data

proc peerUri*(peer: PeerLocator): string =
  peer.validatePeer()
  result = "ocapn://" & encodeUrl(peer.designator, false) & "." & peer.transport
  if peer.hints.len > 0:
    var keys: seq[string]
    for key in peer.hints.keys: keys.add(key)
    keys.sort()
    var query: seq[string]
    for key in keys:
      query.add(encodeUrl(key, false) & "=" & encodeUrl(peer.hints[key], false))
    result.add("?" & query.join("&"))

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
  if value.contains('#'):
    raise newException(LocatorError, "peer URI must not contain a fragment")
  var body = value[8 ..^ 1]
  var query = ""
  let queryAt = body.find('?')
  if queryAt >= 0:
    query = body[queryAt + 1 ..^ 1]
    body = body[0 ..< queryAt]
  let separator = body.rfind('.')
  if separator <= 0 or separator == body.high:
    raise newException(LocatorError, "peer URI lacks designator or transport")
  if not validPercentEncoding(body[0 ..< separator]):
    raise newException(LocatorError, "invalid percent encoding in peer designator")
  result.transport = body[separator + 1 ..^ 1]
  result.designator = decodeUrl(body[0 ..< separator], false)
  result.validatePeer()
  result.hints = initTable[string, string]()
  if query.len == 0: return
  for item in query.split('&'):
    let equals = item.find('=')
    if equals <= 0:
      raise newException(LocatorError, "invalid peer URI hint")
    let encodedKey = item[0 ..< equals]
    let encodedValue = item[equals + 1 ..^ 1]
    if not validPercentEncoding(encodedKey) or not validPercentEncoding(encodedValue):
      raise newException(LocatorError, "invalid percent encoding in peer URI hint")
    let key = decodeUrl(encodedKey, false)
    if result.hints.hasKey(key):
      raise newException(LocatorError, "peer URI contains duplicate hint")
    result.hints[key] = decodeUrl(encodedValue, false)

proc parseSturdyUri*(value: string): SturdyRef =
  if not value.startsWith("ocapn://"):
    raise newException(LocatorError, "sturdyref URI must use ocapn scheme")
  if value.contains('#'):
    raise newException(LocatorError, "sturdyref URI must not contain a fragment")
  let body = value[8 ..^ 1]
  let marker = body.find("/s/")
  if marker < 0:
    raise newException(LocatorError, "sturdyref URI lacks /s/ path")
  let peerPart = "ocapn://" & body[0 ..< marker] &
    (if body.find('?') >= 0: body[body.find('?') ..^ 1] else: "")
  result.peer = parsePeerUri(peerPart)
  let swissEnd = body.find('?', marker)
  let swiss = if swissEnd < 0: body[marker + 3 ..^ 1] else: body[marker + 3 ..< swissEnd]
  if not validPercentEncoding(swiss):
    raise newException(LocatorError, "invalid percent encoding in sturdyref swiss number")
  result.swissNum = decodeUrl(swiss, false)
  if validateUtf8(result.swissNum) >= 0:
    raise newException(LocatorError, "sturdyref swiss number must contain valid UTF-8")
  if result.swissNum.len == 0:
    raise newException(LocatorError, "sturdyref swiss number is empty")
