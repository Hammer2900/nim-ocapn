import std/[strutils, unittest]
import ../src/[framing, messages, references, session, syrup, transport]

proc nestedList(depth: int): string =
  result = "[".repeat(depth) & "0+" & "]".repeat(depth)

proc exerciseSyrupFuzz(iterations: int) =
  var state = 0x4f1bbcdc'u32
  for iteration in 0 ..< iterations:
    state = state * 1664525'u32 + 1013904223'u32
    let length = int(state mod 96)
    var input = newString(length)
    for index in 0 ..< length:
      state = state * 1664525'u32 + 1013904223'u32
      input[index] = char(state and 0x7f)
    try:
      let value = decoded(input)
      discard validHandoffGive(value)
    except SyrupError:
      discard
    try:
      var decoder = newFrameDecoder(128)
      discard decoder.feed(input)
    except FramingError:
      discard
    # Any Defect or unrelated exception is intentionally allowed to fail the
    # test: malformed peer input must not corrupt the process.
    if iteration mod 17 == 0:
      let valid = list(text("fuzz"), integer(iteration.int64))
      check decoded(valid.encoded()).encoded() == valid.encoded()

suite "protocol robustness" :
  test "rejects excessive Syrup nesting without exhausting the stack":
    expect SyrupError:
      discard decoded(nestedList(256))
    check decoded(nestedList(255)).kind == skList

  test "rejects invalid frame limits":
    expect FramingError:
      discard newFrameDecoder(0)
    expect FramingError:
      discard newFrameDecoder(-1)

  test "handles malformed frame boundaries deterministically":
    var decoder = newFrameDecoder(32)
    check decoder.feed("0:") == @[""]
    check decoder.feed("3:a").len == 0
    check decoder.feed("bc") == @["abc"]
    check decoder.feed(frame("one") & frame("two")) == @["one", "two"]
    for wire in ["", ":", "00:", "01:x", "999999999999999999999:", "1x"]:
      var malformed = newFrameDecoder(32)
      if wire == "":
        check malformed.feed(wire).len == 0
      else:
        expect FramingError:
          discard malformed.feed(wire)

  test "rejects truncated and malformed Syrup values":
    for wire in ["[1+", "{1'a}", "<1'a", "3:ab", "1'\xff", "D\x00"]:
      expect SyrupError:
        discard decoded(wire)

  test "deterministic Syrup mutation fuzz is bounded":
    exerciseSyrupFuzz(2000)

  test "malformed application operation closes only the affected session":
    let badPair = inMemoryPair()
    let healthyPair = inMemoryPair()
    let badServer = newSession(badPair.remote)
    let badClient = newSession(badPair.local)
    let healthyServer = newSession(healthyPair.remote)
    let healthyClient = newSession(healthyPair.local)
    discard badServer.pump()
    discard badClient.pump()
    discard healthyServer.pump()
    discard healthyClient.pump()
    badClient.send(record(symbol("op:gc-answers"), list(integer(999))))
    expect SessionError:
      discard badServer.pump()
    check badServer.state == ssClosed
    check healthyServer.state == ssOpen
    check healthyClient.state == ssOpen
    badClient.close("robustness cleanup")
    healthyClient.close("robustness cleanup")
    healthyServer.close("robustness cleanup")

  test "rejects duplicate answer GC without retaining state":
    let pair = inMemoryPair()
    let server = newSession(pair.remote)
    let client = newSession(pair.local)
    discard server.pump()
    discard client.pump()
    client.send(record(symbol("op:gc-answers"), list(integer(0))))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    client.close("robustness cleanup")

    var duplicateLimits = defaultSessionLimits()
    duplicateLimits.maxPendingPromises = 2
    let duplicatePair = inMemoryPair()
    let duplicateServer = newSession(duplicatePair.remote, limits = duplicateLimits)
    let duplicateClient = newSession(duplicatePair.local)
    discard duplicateServer.exportActor(proc(actor: Session;
        args: seq[SyrupValue]): SyrupValue {.closure.} =
      (discard actor.deferAnswer(); list()))
    discard duplicateServer.pump()
    discard duplicateClient.pump()
    let duplicateResolver = duplicateClient.exportObject(
      proc(args: seq[SyrupValue]): SyrupValue = list())
    duplicateClient.send(deliver(exportRef(0).descriptor(), [symbol("hold")], 7,
      duplicateResolver.descriptor(), 3))
    discard duplicateServer.pump()
    duplicateClient.send(deliver(exportRef(0).descriptor(), [symbol("hold")], 7,
      duplicateResolver.descriptor(), 3))
    expect SessionError:
      discard duplicateServer.pump()
    check duplicateServer.state == ssClosed
    duplicateClient.close("robustness cleanup")

  test "bounds inbound unresolved answers and rejects duplicate positions":
    var limits = defaultSessionLimits()
    limits.maxPendingPromises = 1
    let pair = inMemoryPair()
    let server = newSession(pair.remote, limits = limits)
    let client = newSession(pair.local)
    discard server.exportActor(proc(actor: Session; args: seq[SyrupValue]): SyrupValue =
      (discard actor.deferAnswer(); list()))
    discard server.pump()
    discard client.pump()
    let firstResolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
    client.send(deliver(exportRef(0).descriptor(), [symbol("hold")], 0,
      firstResolver.descriptor(), 3))
    discard server.pump()
    check server.stats().inboundAnswerCount == 1
    client.send(deliver(exportRef(0).descriptor(), [symbol("hold")], 1,
      firstResolver.descriptor(), 3))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    client.close("robustness cleanup")

  test "bounds pipeline requests waiting on an unresolved answer":
    var limits = defaultSessionLimits()
    limits.maxPendingPromises = 1
    let pair = inMemoryPair()
    let server = newSession(pair.remote, limits = limits)
    let client = newSession(pair.local)
    discard server.exportActor(proc(actor: Session; args: seq[SyrupValue]): SyrupValue =
      (discard actor.deferAnswer(); list()))
    discard server.pump()
    discard client.pump()
    let resolver = client.exportObject(proc(args: seq[SyrupValue]): SyrupValue = list())
    client.send(deliver(exportRef(0).descriptor(), [symbol("hold")], 0,
      resolver.descriptor(), 3))
    client.send(deliverV1Callback(reference(rkAnswer, 0).descriptor(),
      [symbol("pipelined")]))
    client.send(deliverV1Callback(reference(rkAnswer, 0).descriptor(),
      [symbol("pipelined")]))
    expect SessionError:
      discard server.pump()
    check server.state == ssClosed
    client.close("robustness cleanup")

