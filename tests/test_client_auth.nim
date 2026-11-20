import std/[os, strutils, unittest]
import ../src/[crypto, gifts, identity, promises, references, session, syrup, transport]

suite "CapTP client identity authentication":
  test "binding is domain-separated and session-specific":
    let nonce = repeat('n', 32)
    let durableSeed = repeat('c', 32)
    let clientSession = repeat('1', 32)
    let serverSession = repeat('2', 32)
    let sessionId = repeat('s', 32)
    let binding = clientAuthenticationBinding(nonce, crypto.publicKey(durableSeed),
      clientSession, serverSession, sessionId, repeat('a', 56))
    let signature = crypto.sign(durableSeed, binding)
    check crypto.verify(crypto.publicKey(durableSeed), binding, signature)
    check not crypto.verify(crypto.publicKey(durableSeed),
      clientAuthenticationBinding(repeat('x', 32), crypto.publicKey(durableSeed),
        clientSession, serverSession, sessionId, repeat('a', 56)), signature)
    check not crypto.verify(crypto.publicKey(durableSeed),
      clientAuthenticationBinding(nonce, crypto.publicKey(durableSeed),
        clientSession, repeat('3', 32), sessionId, repeat('a', 56)), signature)
    check not crypto.verify(repeat('x', 32), binding, signature)
    check not crypto.verify(crypto.publicKey(durableSeed),
      clientAuthenticationBinding(nonce, crypto.publicKey(durableSeed),
        clientSession, serverSession, sessionId, repeat('b', 56)), signature)

  test "durable identity signing does not expose its seed":
    let identity = newEphemeralIdentity(repeat('d', 32))
    let message = clientAuthenticationBinding(repeat('n', 32), identity.publicKey,
      repeat('1', 32), repeat('2', 32), repeat('s', 32), repeat('a', 56))
    check crypto.verify(identity.publicKey, message, identity.signIdentity(message))

  test "protected gifts require an authenticated receiver":
    let table = newGiftTable()
    let giftId = repeat('g', 32)
    let rejected = table.withdraw(giftId, repeat('r', 32), allowProtected = false)
    table.deposit(giftId, repeat('r', 32), text("protected"),
      owner = nil, protected = true)
    check rejected.state == psBroken
    let accepted = table.withdraw(giftId, repeat('r', 32), allowProtected = true)
    check accepted.state == psFulfilled
    check accepted.value.data == "protected"

  test "invalid client authentication timeout is rejected":
    let pair = inMemoryPair()
    let server = newSession(pair.remote, repeat('s', 32))
    expect SessionError:
      discard server.enableClientAuthentication([repeat('c', 32)], "service.onion",
        challengeTimeoutMs = 0)
    server.close()

  test "expired challenge cannot be redeemed":
    let pair = inMemoryPair()
    let server = newSession(pair.remote, repeat('s', 32))
    let client = newSession(pair.local, repeat('c', 32))
    discard server.enableClientAuthentication([client.localPublicKey], "service.onion",
      challengeTimeoutMs = 1)
    discard server.pump()
    discard client.pump()
    var auth = client.fetch("authenticate")
    for _ in 0 ..< 10:
      discard server.pump()
      discard client.pump()
      if auth.settled(): break
    check auth.state == psFulfilled
    let authRef = auth.value.descriptor()
    var challenge = client.call(authRef, "challenge", @[])
    for _ in 0 ..< 10:
      discard server.pump()
      discard client.pump()
      if challenge.settled(): break
    check challenge.state == psFulfilled
    sleep(5)
    let proof = client.call(authRef, "prove",
      [bytes(client.localPublicKey), bytes(repeat('x', 64))])
    for _ in 0 ..< 10:
      try: discard server.pump()
      except SessionError: discard
      try: discard client.pump()
      except SessionError: discard
      if proof.settled(): break
    check proof.state == psBroken
    check server.clientAuthenticationState == casRejected
    server.close()
    client.close()
