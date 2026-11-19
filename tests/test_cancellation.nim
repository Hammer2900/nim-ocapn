import std/[net, strutils, unittest]
import ../src/[api, crypto, gifts, handoff, locators, messages, promises, references, session, syrup, transport]
import ../src/session as sessionApi
import ./fault_transport

proc pumpPair(a, b: Session; limit = 64) =
  for _ in 0 ..< limit:
    discard a.pump()
    discard b.pump()

proc connectedPair(): tuple[server, client: Session; serverTransport, clientTransport: FaultTransport] =
  let pair = faultPair()
  result.serverTransport = pair.a
  result.clientTransport = pair.b
  result.server = newSession(pair.a, repeat('a', 32))
  discard result.server.publishObject("origin", proc(args: seq[SyrupValue]): SyrupValue =
    text("ok"))
  result.client = newSession(pair.b, repeat('b', 32))
  pumpPair(result.server, result.client)

suite "public call and handoff cancellation":
  test "cancellation before sending a call is local and idempotent":
    let pair = connectedPair()
    let local = newPromise()
    check pair.client.cancel(local)
    check local.state == psBroken
    check local.cancelled
    check not pair.client.cancel(local)
    check pair.client.state == ssOpen
    pair.server.close("cleanup")
    pair.client.close("cleanup")

  test "cancellation after sending retires only the pending answer":
    let pair = connectedPair()
    pair.serverTransport.setDelayed(true)
    let pending = sessionApi.fetch(pair.client, "origin")
    discard pair.server.pump()
    check pending.state == psPending
    check pair.client.cancel(pending)
    check pending.state == psBroken
    check pending.cancelled
    check pair.client.state == ssOpen
    check pair.client.stats().pendingPromises == 0
    pair.serverTransport.releaseHeld()
    pumpPair(pair.server, pair.client)
    check pending.state == psBroken
    check pair.client.state == ssOpen
    pair.server.close("cleanup")
    pair.client.close("cleanup")

  test "timeout cancels locally without claiming remote cancellation":
    let pair = connectedPair()
    pair.serverTransport.setDelayed(true)
    let pending = sessionApi.fetch(pair.client, "origin")
    expect PromiseTimeoutError:
      discard pair.client.waitForTimeout(pending, 5)
    check pending.state == psBroken
    check pending.reason == "call timeout"
    check pair.client.state == ssOpen
    check pair.client.stats().pendingPromises == 0
    pair.serverTransport.releaseHeld()
    pumpPair(pair.server, pair.client)
    check pending.state == psBroken
    pair.server.close("cleanup")
    pair.client.close("cleanup")

  test "late fulfillment after cancellation is ignored safely":
    let promise = newPromise()
    check promise.cancel("call timeout")
    promise.fulfill(text("late"))
    check promise.state == psBroken
    check promise.reason == "call timeout"
    check not promise.cancel("again")

  test "cancelling one of several calls leaves another call usable":
    let pair = connectedPair()
    let targetPromise = sessionApi.fetch(pair.client, "origin")
    pumpPair(pair.server, pair.client)
    check targetPromise.state == psFulfilled
    let target = targetPromise.value.descriptor()
    pair.serverTransport.setDelayed(true)
    let first = sessionApi.call(pair.client, target, "greet", [])
    let second = sessionApi.call(pair.client, target, "greet", [])
    discard pair.server.pump()
    check pair.client.cancel(first, "one call cancelled")
    pair.serverTransport.releaseHeld()
    pumpPair(pair.server, pair.client)
    check first.state == psBroken
    check second.state == psFulfilled
    check second.value.data == "ok"
    check pair.client.state == ssOpen
    check pair.client.stats().pendingPromises == 0
    pair.server.close("cleanup")
    pair.client.close("cleanup")

  test "handoff cancellation removes the waiter and closes only its auxiliary session":
    let listener = listenTcp("127.0.0.1", Port(0))
    let signerPair = inMemoryPair()
    let signer = newSession(signerPair.local, repeat('s', 32))
    let peer = newPeerLocator("tcp-testing-only", "exporter",
      [("host", "127.0.0.1"), ("port", $listener.localPort())])
    let give = handoffGive(glowcapPublicKey(signer.localPublicKey),
      peer.peerSyrup(), repeat('g', 32), repeat('f', 32), repeat('i', 32))
    let manager = newHandoffManager()
    let receipt = manager.startHandoffReceiver(
      signatureEnvelope(give, repeat('x', 64)), signer)
    check manager.stats().pendingReceives == 1
    check manager.cancel(receipt, "handoff timeout")
    check receipt.promise.state == psBroken
    check receipt.promise.reason == "handoff timeout"
    check receipt.session.state == ssClosed
    check manager.stats().pendingReceives == 0
    check not manager.cancel(receipt)
    manager.close("cleanup")
    signer.close("cleanup")
    listener.close()

  test "public handoff timeout cancels the receipt":
    let listener = listenTcp("127.0.0.1", Port(0))
    let signerPair = inMemoryPair()
    let signer = newSession(signerPair.local, repeat('q', 32))
    let node = newNode(port = Port(0), seedPrefix = "cancel-node")
    let peer = newPeerLocator("tcp-testing-only", "exporter",
      [("host", "127.0.0.1"), ("port", $listener.localPort())])
    let give = handoffGive(glowcapPublicKey(signer.localPublicKey),
      peer.peerSyrup(), repeat('g', 32), repeat('f', 32), repeat('j', 32))
    let receipt = node.receiveHandoff(signatureEnvelope(give, repeat('x', 64)), signer)
    expect HandoffTimeoutError:
      discard node.waitForHandoffTimeout(receipt, 5)
    check receipt.promise.state == psBroken
    check node.handoffs.stats().pendingReceives == 0
    node.close()
    signer.close("cleanup")
    listener.close()

  test "cancelled gift withdrawal can be replayed only as a fresh waiter":
    let table = newGiftTable()
    let pending = table.withdraw("gift", "receiver")
    check table.cancel(pending)
    check pending.state == psBroken
    table.deposit("gift", "receiver", text("capability"))
    let replay = table.withdraw("gift", "receiver")
    check replay.state == psFulfilled
    check replay.value.data == "capability"
