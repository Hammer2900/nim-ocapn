import ./[crypto, locators, syrup]

type
  CapTpMessageError* = object of CatchableError
  CapTpDescriptorKind* = enum
    descImportObject, descImportPromise, descExport, descAnswer

proc valueList(values: openArray[SyrupValue]): SyrupValue =
  SyrupValue(kind: skList, items: @values)

proc extractGlowcapPublicKey*(value: SyrupValue): string

proc positivePosition(position: int64): SyrupValue =
  if position < 0:
    raise newException(CapTpMessageError, "CapTP positions must be non-negative")
  integer(position)

proc descriptor*(kind: CapTpDescriptorKind; position: int64): SyrupValue =
  let label = case kind
    of descImportObject: "desc:import-object"
    of descImportPromise: "desc:import-promise"
    of descExport: "desc:export"
    of descAnswer: "desc:answer"
  record(symbol(label), positivePosition(position))

proc startSession*(acceptableLocation, sessionPublicKey, locationSignature: SyrupValue;
                   captpVersion = "1.0"; cryptoVersion = "Ed25519_SHA256"): SyrupValue =
  record(symbol("op:start-session"), text(captpVersion), text(cryptoVersion),
    sessionPublicKey, acceptableLocation, locationSignature)

proc glowcapPublicKey*(publicKey: string): SyrupValue =
  list(symbol("public-key"), list(symbol("ecc"),
    list(symbol("curve"), symbol("Ed25519")),
    list(symbol("flags"), symbol("eddsa")),
    list(symbol("q"), bytes(publicKey))))

proc glowcapLocation*(hostPort: string; features = "pipelining,handoff,wire_delta,sturdyref,untag"): SyrupValue =
  record(symbol("ocapn-peer"), symbol("tcp"), text(hostPort),
    dict([pair(text("glowcap/features"), text(features))]))

proc glowcapSignature*(signature: string): SyrupValue =
  if signature.len != 64:
    raise newException(CapTpMessageError, "Ed25519 signature must be 64 bytes")
  list(symbol("sig-val"), list(symbol("eddsa"),
    list(symbol("r"), bytes(signature[0 ..< 32])),
    list(symbol("s"), bytes(signature[32 ..< 64]))))

proc glowcapStartSession*(location, publicKey, signature: SyrupValue): SyrupValue =
  record(symbol("op:start-session"), text("1.0"), publicKey, location, signature)

proc signatureEnvelope*(value: SyrupValue; signature: string): SyrupValue =
  if signature.len != 64:
    raise newException(CapTpMessageError, "Ed25519 signature must be 64 bytes")
  record(symbol("desc:sig-envelope"), value, glowcapSignature(signature))

proc handoffGive*(receiverKey, exporterLocation: SyrupValue; session,
                  gifterSide, giftId: string): SyrupValue =
  record(symbol("desc:handoff-give"), receiverKey, exporterLocation,
    bytes(session), bytes(gifterSide), bytes(giftId))

proc handoffReceive*(receivingSession, receivingSide: string; handoffCount: int64;
                     signedGive: SyrupValue): SyrupValue =
  if handoffCount < 0:
    raise newException(CapTpMessageError, "handoff count must be non-negative")
  record(symbol("desc:handoff-receive"), bytes(receivingSession),
    bytes(receivingSide), integer(handoffCount), signedGive)

proc validHandoffGive*(value: SyrupValue): bool =
  if value.kind != skRecord or value.label.kind != skSymbol or
      value.label.data != "desc:handoff-give" or value.fields.len != 5:
    return false
  let receiverKey = extractGlowcapPublicKey(value.fields[0])
  if receiverKey.len != 32 or value.fields[2].kind != skBytes or
      value.fields[2].data.len != 32 or value.fields[3].kind != skBytes or
      value.fields[3].data.len != 32 or value.fields[4].kind != skBytes or
      value.fields[4].data.len == 0:
    return false
  try:
    discard value.fields[1].peerLocator()
    true
  except LocatorError:
    false

proc validHandoffReceive*(value: SyrupValue): bool =
  if value.kind != skRecord or value.label.kind != skSymbol or
      value.label.data != "desc:handoff-receive" or value.fields.len != 4:
    return false
  value.fields[0].kind == skBytes and value.fields[0].data.len == 32 and
    value.fields[1].kind == skBytes and value.fields[1].data.len == 32 and
    value.fields[2].kind == skInteger and not value.fields[2].negative and
    value.fields[3].kind == skRecord and value.fields[3].label.kind == skSymbol and
    value.fields[3].label.data == "desc:sig-envelope" and
    value.fields[3].fields.len == 2 and validHandoffGive(value.fields[3].fields[0])

proc extractGlowcapPublicKey*(value: SyrupValue): string =
  if value.kind != skList or value.items.len != 2 or
      value.items[0].kind != skSymbol or value.items[0].data != "public-key" or
      value.items[1].kind != skList or value.items[1].items.len != 4:
    return ""
  let ecc = value.items[1]
  if ecc.items[0].kind != skSymbol or ecc.items[0].data != "ecc": return ""
  let fields = ecc.items[1]
  if fields.kind != skList: return ""
  let q = ecc.items[3]
  if q.kind != skList or q.items.len != 2 or q.items[0].kind != skSymbol or
      q.items[0].data != "q" or q.items[1].kind != skBytes:
    return ""
  q.items[1].data

proc extractGlowcapSignature*(value: SyrupValue): string =
  if value.kind != skList or value.items.len != 2 or
      value.items[0].kind != skSymbol or value.items[0].data != "sig-val" or
      value.items[1].kind != skList or value.items[1].items.len != 3:
    return ""
  let eddsa = value.items[1]
  if eddsa.items[0].kind != skSymbol or eddsa.items[0].data != "eddsa": return ""
  let r = eddsa.items[1]
  let s = eddsa.items[2]
  if r.kind != skList or s.kind != skList or r.items.len != 2 or s.items.len != 2 or
      r.items[0].kind != skSymbol or r.items[0].data != "r" or
      s.items[0].kind != skSymbol or s.items[0].data != "s" or
      r.items[1].kind != skBytes or s.items[1].kind != skBytes or
      r.items[1].data.len != 32 or s.items[1].data.len != 32:
    return ""
  r.items[1].data & s.items[1].data

proc verifySignatureEnvelope*(value, publicKey: SyrupValue): bool =
  if value.kind != skRecord or value.label.kind != skSymbol or
      value.label.data != "desc:sig-envelope" or value.fields.len != 2 or
      publicKey.kind != skList:
    return false
  let signature = extractGlowcapSignature(value.fields[1])
  let key = extractGlowcapPublicKey(publicKey)
  if key.len != 32 or signature.len != 64:
    return false
  crypto.verify(key, value.fields[0].encoded(), signature)

proc verifyHandoffReceive*(value: SyrupValue): bool =
  if value.kind != skRecord or value.label.kind != skSymbol or
      value.label.data != "desc:sig-envelope" or value.fields.len != 2 or
      not validHandoffReceive(value.fields[0]):
    return false
  let receive = value.fields[0]
  let signedGive = receive.fields[3]
  let give = signedGive.fields[0]
  verifySignatureEnvelope(value, give.fields[0])

proc deliverOnly*(target: SyrupValue; args: openArray[SyrupValue]): SyrupValue =
  record(symbol("op:deliver-only"), target, valueList(args))

proc deliver*(target: SyrupValue; args: openArray[SyrupValue]; answerPosition: int64;
              resolver: SyrupValue; listenMode: int64): SyrupValue =
  if listenMode notin [1'i64, 3'i64]:
    raise newException(CapTpMessageError, "op:deliver listen-mode must be 1 or 3")
  record(symbol("op:deliver"), target, valueList(args), positivePosition(answerPosition),
    resolver, integer(listenMode))

proc deliverV1*(target: SyrupValue; args: openArray[SyrupValue]; answerPosition: int64;
                resolver: SyrupValue): SyrupValue =
  record(symbol("op:deliver"), target, valueList(args), positivePosition(answerPosition), resolver)

proc deliverV1Callback*(target: SyrupValue; args: openArray[SyrupValue]): SyrupValue =
  record(symbol("op:deliver"), target, valueList(args), boolean(false), boolean(false))

proc abort*(reason: string): SyrupValue =
  record(symbol("op:abort"), text(reason))

proc listen*(target, resolver: SyrupValue; listenMode: int64): SyrupValue =
  if listenMode notin [1'i64, 2'i64, 3'i64]:
    raise newException(CapTpMessageError, "op:listen listen-mode must be 1, 2, or 3")
  record(symbol("op:listen"), target, resolver, integer(listenMode))

proc gcExports*(exportPositions, wireDeltas: openArray[int64]): SyrupValue =
  if exportPositions.len != wireDeltas.len:
    raise newException(CapTpMessageError, "gc export positions and deltas must have equal length")
  var positions, deltas: seq[SyrupValue]
  for index, position in exportPositions:
    positions.add(positivePosition(position))
    if wireDeltas[index] <= 0:
      raise newException(CapTpMessageError, "gc wire deltas must be positive")
    deltas.add(integer(wireDeltas[index]))
  record(symbol("op:gc-exports"), valueList(positions), valueList(deltas))

proc gcAnswers*(answerPositions: openArray[int64]): SyrupValue =
  var positions: seq[SyrupValue]
  for position in answerPositions:
    positions.add(positivePosition(position))
  record(symbol("op:gc-answers"), valueList(positions))
