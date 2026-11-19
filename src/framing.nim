import std/strutils

type
  FramingError* = object of CatchableError
  FrameDecoder* = object
    pending: string
    maxFrameBytes*: int

proc frame*(body: string): string = $body.len & ":" & body

proc newFrameDecoder*(maxFrameBytes = 1024 * 1024): FrameDecoder =
  if maxFrameBytes <= 0:
    raise newException(FramingError, "frame size limit must be positive")
  FrameDecoder(maxFrameBytes: maxFrameBytes)

proc feed*(decoder: var FrameDecoder; chunk: string): seq[string] =
  decoder.pending.add(chunk)
  while decoder.pending.len > 0:
    var colon = -1
    for index, ch in decoder.pending:
      if ch == ':':
        colon = index
        break
      if ch notin {'0'..'9'}:
        raise newException(FramingError, "invalid frame length prefix")
    if colon < 0:
      if decoder.pending.len > ($decoder.maxFrameBytes).len:
        raise newException(FramingError, "frame length prefix exceeds configured limit")
      break
    if colon > 1 and decoder.pending[0] == '0':
      raise newException(FramingError, "non-canonical frame length")
    let lengthText = decoder.pending[0 ..< colon]
    if lengthText.len == 0: raise newException(FramingError, "empty frame length")
    let length = try: parseInt(lengthText)
                 except ValueError: raise newException(FramingError, "frame length overflow")
    if length > decoder.maxFrameBytes:
      raise newException(FramingError, "frame exceeds configured limit")
    let bodyStart = colon + 1
    if decoder.pending.len - bodyStart < length: break
    result.add(decoder.pending[bodyStart ..< bodyStart + length])
    let consumed = bodyStart + length
    decoder.pending = if consumed == decoder.pending.len: "" else: decoder.pending[consumed .. ^1]
