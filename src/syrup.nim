import std/[algorithm, strutils, unicode]

type
  SyrupError* = object of CatchableError

  SyrupKind* = enum
    skBytes, skString, skSymbol, skInteger, skBool,
    skFloat32, skFloat64, skList, skDict, skRecord, skSet

  SyrupPair* = object
    key*, value*: SyrupValue

  SyrupValue* = ref object
    case kind*: SyrupKind
    of skBytes, skString, skSymbol:
      data*: string
    of skInteger:
      negative*: bool
      magnitude*: string
    of skBool:
      boolean*: bool
    of skFloat32:
      float32*: float32
    of skFloat64:
      float64*: float64
    of skList:
      items*: seq[SyrupValue]
    of skDict:
      pairs*: seq[SyrupPair]
    of skRecord:
      label*: SyrupValue
      fields*: seq[SyrupValue]
    of skSet:
      elements*: seq[SyrupValue]

proc requireUtf8(value: string): string =
  if validateUtf8(value) >= 0:
    raise newException(SyrupError, "strings and symbols must contain valid UTF-8")
  value

proc bytes*(value: string): SyrupValue = SyrupValue(kind: skBytes, data: value)
proc text*(value: string): SyrupValue =
  SyrupValue(kind: skString, data: requireUtf8(value))
proc symbol*(value: string): SyrupValue =
  SyrupValue(kind: skSymbol, data: requireUtf8(value))
proc integer*(value: int64): SyrupValue =
  let negative = value < 0
  let spelling = $value
  let magnitude = if negative: spelling[1 ..^ 1] else: spelling
  SyrupValue(kind: skInteger, negative: negative, magnitude: magnitude)
proc integerMagnitude*(magnitude: string; negative = false): SyrupValue =
  var validDigits = magnitude.len > 0
  for digit in magnitude:
    validDigits = validDigits and digit in {'0'..'9'}
  if not validDigits or (magnitude.len > 1 and magnitude[0] == '0') or
      (negative and magnitude == "0"):
    raise newException(SyrupError, "invalid integer magnitude")
  SyrupValue(kind: skInteger, negative: negative, magnitude: magnitude)
proc boolean*(value: bool): SyrupValue = SyrupValue(kind: skBool, boolean: value)
proc float32Value*(value: float32): SyrupValue = SyrupValue(kind: skFloat32, float32: value)
proc float64Value*(value: float64): SyrupValue = SyrupValue(kind: skFloat64, float64: value)
proc list*(values: varargs[SyrupValue]): SyrupValue = SyrupValue(kind: skList, items: @values)
proc dict*(pairs: openArray[SyrupPair]): SyrupValue = SyrupValue(kind: skDict, pairs: @pairs)
proc pair*(key, value: SyrupValue): SyrupPair = SyrupPair(key: key, value: value)
proc record*(label: SyrupValue; fields: varargs[SyrupValue]): SyrupValue =
  SyrupValue(kind: skRecord, label: label, fields: @fields)
proc setValue*(values: varargs[SyrupValue]): SyrupValue =
  SyrupValue(kind: skSet, elements: @values)

proc appendLength(result: var string; length: int; marker: char) =
  result.add($length)
  result.add(marker)

proc appendFloatBits(result: var string; bits: uint64; width: int) =
  for index in countdown(width - 1, 0):
    result.add(char((bits shr (index * 8)) and 0xff'u64))

proc encoded*(value: SyrupValue): string

proc canonicalMembers(values: openArray[SyrupValue]): seq[string] =
  result = newSeqOfCap[string](values.len)
  for value in values:
    result.add(encoded(value))
  result.sort(system.cmp[string])

proc encoded*(value: SyrupValue): string =
  if value.isNil:
    raise newException(SyrupError, "cannot encode nil value")
  case value.kind
  of skBytes:
    result.appendLength(value.data.len, ':')
    result.add(value.data)
  of skString:
    result.appendLength(value.data.len, '"')
    result.add(value.data)
  of skSymbol:
    result.appendLength(value.data.len, '\'')
    result.add(value.data)
  of skInteger:
    result = value.magnitude
    result.add(if value.negative: '-' else: '+')
  of skBool:
    result = if value.boolean: "t" else: "f"
  of skFloat32:
    result = "F"
    result.appendFloatBits(cast[uint32](value.float32), 4)
  of skFloat64:
    result = "D"
    result.appendFloatBits(cast[uint64](value.float64), 8)
  of skList:
    result = "["
    for item in value.items:
      result.add(encoded(item))
    result.add(']')
  of skDict:
    var sortedPairs: seq[(string, SyrupValue)]
    for entry in value.pairs:
      let key = encoded(entry.key)
      sortedPairs.add((key, entry.value))
    sortedPairs.sort(proc(a, b: (string, SyrupValue)): int = system.cmp(a[0], b[0]))
    result = "{"
    var previous = ""
    for entry in sortedPairs:
      if entry[0] == previous:
        raise newException(SyrupError, "duplicate dictionary key")
      previous = entry[0]
      result.add(entry[0])
      result.add(encoded(entry[1]))
    result.add('}')
  of skRecord:
    result = "<" & encoded(value.label)
    for field in value.fields:
      result.add(encoded(field))
    result.add('>')
  of skSet:
    let members = canonicalMembers(value.elements)
    result = "#"
    var previous = ""
    for member in members:
      if member == previous:
        raise newException(SyrupError, "duplicate set member")
      previous = member
      result.add(member)
    result.add('$')

type Decoder = object
  input: string
  position: int

proc fail(decoder: Decoder; message: string): ref SyrupError =
  newException(SyrupError, message & " at byte " & $decoder.position)

proc skipWhitespace(decoder: var Decoder) =
  while decoder.position < decoder.input.len and decoder.input[decoder.position] in {' ', '\t', '\n'}:
    inc decoder.position

proc readValue(decoder: var Decoder): SyrupValue

proc readLength(decoder: var Decoder; marker: char): int =
  let start = decoder.position
  while decoder.position < decoder.input.len and decoder.input[decoder.position] in {'0'..'9'}:
    inc decoder.position
  if start == decoder.position or (decoder.position - start > 1 and decoder.input[start] == '0') or
      decoder.position >= decoder.input.len or decoder.input[decoder.position] != marker:
    raise decoder.fail("invalid length")
  let digits = decoder.input[start ..< decoder.position]
  inc decoder.position
  try:
    result = parseInt(digits)
  except ValueError:
    raise decoder.fail("length out of range")

proc readLengthValue(decoder: var Decoder; marker: char): string =
  let length = decoder.readLength(marker)
  if length > decoder.input.len - decoder.position:
    raise decoder.fail("truncated byte/string value")
  result = decoder.input[decoder.position ..< decoder.position + length]
  decoder.position += length

proc readFloatBits(decoder: var Decoder; width: int): uint64 =
  if width > decoder.input.len - decoder.position:
    raise decoder.fail("truncated floating-point value")
  for index in 0 ..< width:
    result = (result shl 8) or uint64(ord(decoder.input[decoder.position]))
    inc decoder.position

proc readInteger(decoder: var Decoder): SyrupValue =
  let start = decoder.position
  while decoder.position < decoder.input.len and decoder.input[decoder.position] in {'0'..'9'}:
    inc decoder.position
  if start == decoder.position or decoder.position >= decoder.input.len:
    raise decoder.fail("invalid integer")
  let magnitude = decoder.input[start ..< decoder.position]
  let sign = decoder.input[decoder.position]
  if (magnitude.len > 1 and magnitude[0] == '0') or (sign == '-' and magnitude == "0") or
      sign notin {'+', '-'}:
    raise decoder.fail("invalid integer spelling")
  inc decoder.position
  SyrupValue(kind: skInteger, negative: sign == '-', magnitude: magnitude)

proc readContainer(decoder: var Decoder; closing: char): seq[SyrupValue] =
  while true:
    decoder.skipWhitespace()
    if decoder.position >= decoder.input.len:
      raise decoder.fail("unterminated container")
    if decoder.input[decoder.position] == closing:
      inc decoder.position
      return
    result.add(decoder.readValue())

proc readValue(decoder: var Decoder): SyrupValue =
  decoder.skipWhitespace()
  if decoder.position >= decoder.input.len:
    raise decoder.fail("unexpected end of input")
  let marker = decoder.input[decoder.position]
  case marker
  of ':', '"', '\'':
    raise decoder.fail("length must precede value")
  of '0'..'9':
    let save = decoder.position
    while decoder.position < decoder.input.len and decoder.input[decoder.position] in {'0'..'9'}:
      inc decoder.position
    if decoder.position >= decoder.input.len:
      raise decoder.fail("truncated numeric value")
    let terminator = decoder.input[decoder.position]
    decoder.position = save
    if terminator in {'+', '-'}:
      return decoder.readInteger()
    if terminator notin {':', '"', '\''}:
      raise decoder.fail("invalid numeric/string marker")
    let data = decoder.readLengthValue(terminator)
    if terminator == ':': return bytes(data)
    if validateUtf8(data) >= 0:
      raise decoder.fail("invalid UTF-8 string or symbol")
    if terminator == '"': return text(data)
    symbol(data)
  of 't', 'f':
    inc decoder.position
    boolean(marker == 't')
  of 'D':
    inc decoder.position
    return float64Value(cast[float64](decoder.readFloatBits(8)))
  of 'F':
    inc decoder.position
    return float32Value(cast[float32](uint32(decoder.readFloatBits(4))))
  of '[':
    inc decoder.position
    SyrupValue(kind: skList, items: decoder.readContainer(']'))
  of '{':
    inc decoder.position
    var values = decoder.readContainer('}')
    if values.len mod 2 != 0:
      raise decoder.fail("dictionary has an odd number of values")
    var pairs: seq[SyrupPair]
    var previousKey = ""
    for index in countup(0, values.high, 2):
      let encodedKey = encoded(values[index])
      if encodedKey == previousKey:
        raise decoder.fail("duplicate dictionary key")
      previousKey = encodedKey
      pairs.add(pair(values[index], values[index + 1]))
    SyrupValue(kind: skDict, pairs: pairs)
  of '<':
    inc decoder.position
    let values = decoder.readContainer('>')
    if values.len == 0:
      raise decoder.fail("record has no label")
    SyrupValue(kind: skRecord, label: values[0], fields: values[1 ..^ 1])
  of '#':
    inc decoder.position
    let elements = decoder.readContainer('$')
    var previous = ""
    for element in elements:
      let encodedElement = encoded(element)
      if encodedElement == previous:
        raise decoder.fail("duplicate set member")
      previous = encodedElement
    SyrupValue(kind: skSet, elements: elements)
  else:
    raise decoder.fail("unexpected marker " & $marker)

proc decoded*(input: string): SyrupValue =
  var decoder = Decoder(input: input)
  result = decoder.readValue()
  decoder.skipWhitespace()
  if decoder.position != input.len:
    raise decoder.fail("trailing data")
