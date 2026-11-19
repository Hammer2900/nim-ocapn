import std/[strutils, unittest]
import ../src/[promises, references, session, syrup, transport]

type
  PendingReply = object
    answer: AnswerContext
    index: int
  Load = ref object
    server: Session
    client: Session
    replies: seq[PendingReply]
    calls: seq[Promise]

const peerCount = 4
const callsPerPeer = 250

proc seed32(prefix: string; index: int): string =
  let raw = prefix & $index
  let repeated = raw.repeat(32 div raw.len + 1)
  repeated[0 ..< 32]

proc makeLoad(index: int; limits: SessionLimits): Load =
  let pair = inMemoryPair()
  new(result)
  result.server = newSession(pair.remote, seed32("server", index), limits = limits)
  let load = result
  discard result.server.exportActor(proc(actor: Session;
      args: seq[SyrupValue]): SyrupValue =
    let pending = PendingReply(answer: actor.deferAnswer(), index: load.replies.len)
    load.replies.add(pending)
    list())
  result.client = newSession(pair.local, seed32("client", index), limits = limits)

proc pumpAll(loads: seq[Load]; rounds = 8) =
  for _ in 0 ..< rounds:
    for load in loads:
      discard load.server.pump()
      discard load.client.pump()

suite "concurrent protocol workload":
  test "out-of-order fulfillment and rejection stay isolated across sessions":
    var limits = defaultSessionLimits()
    limits.maxPendingPromises = callsPerPeer + 8
    var loads: seq[Load]
    for index in 0 ..< peerCount:
      loads.add(makeLoad(index, limits))
    defer:
      for load in loads:
        load.client.close("concurrency cleanup")
        load.server.close("concurrency cleanup")
    pumpAll(loads)
    for load in loads:
      for index in 0 ..< callsPerPeer:
        load.calls.add(load.client.call(exportRef(0), "work", [text($index)]))
    var peakPending = 0
    var peakQueued = 0
    for load in loads:
      peakPending = max(peakPending, load.client.stats().pendingPromises)
      peakQueued = max(peakQueued, load.client.stats().queuedBytes)
    for load in loads:
      discard load.server.pump()
    for load in loads:
      for index in countdown(load.replies.high, 0):
        let reply = load.replies[index]
        if reply.index mod 13 == 0:
          load.server.breakAnswer(reply.answer, "rejected workload")
        else:
          load.server.fulfillAnswer(reply.answer, text($reply.index))
    for load in loads:
      discard load.client.pump()
    for load in loads:
      discard load.server.pump()
      for index, call in load.calls:
        if index mod 13 == 0:
          check call.state == psBroken
        else:
          check call.state == psFulfilled
          check call.value.data == $index
      check load.client.stats().pendingPromises == 0
      check load.client.stats().importCount == 0
      check load.client.stats().exportCount == 0
      check load.server.stats().inboundAnswerCount == 0
      check load.server.stats().promiseSlotCount == 0
    echo "concurrency calls=", peerCount * callsPerPeer,
      " peakPending=", peakPending, " peakQueuedBytes=", peakQueued,
      " activeSessions=", peerCount * 2

  test "disconnect cancels a loaded session without affecting another":
    var limits = defaultSessionLimits()
    limits.maxPendingPromises = 128
    let first = makeLoad(100, limits)
    let second = makeLoad(101, limits)
    defer:
      first.client.close("disconnect cleanup")
      first.server.close("disconnect cleanup")
      second.client.close("disconnect cleanup")
      second.server.close("disconnect cleanup")
    pumpAll(@[first, second])
    for index in 0 ..< 100:
      first.calls.add(first.client.call(exportRef(0), "work", [text($index)]))
      discard second.client.call(exportRef(0), "work", [text($index)])
    first.client.close("loaded disconnect")
    discard first.server.pump()
    for call in first.calls:
      check call.state == psBroken
    check first.client.stats().pendingPromises == 0
    check second.client.state == ssOpen
    check second.server.state == ssOpen
    check second.client.stats().pendingPromises == 100

