import std/[strutils, unittest]
import ../src/[crypto, messages, syrup]

suite "CapTP message constructors":
  test "builds descriptors and deliver-only":
    let bootstrap = descriptor(descExport, 0)
    check deliverOnly(bootstrap, [symbol("fetch"), text("greeter")]).encoded() ==
      "<15'op:deliver-only<11'desc:export0+>[5'fetch7\"greeter]>"

  test "builds deliver and session start messages":
    let bootstrap = descriptor(descExport, 0)
    let resolver = descriptor(descImportObject, 5)
    check deliver(bootstrap, [symbol("greet"), text("world")], 1, resolver, 3).encoded() ==
      "<10'op:deliver<11'desc:export0+>[5'greet5\"world]1+<18'desc:import-object5+>3+>"
    check startSession(bytes("location"), bytes("key"), bytes("signature")).encoded() ==
      "<16'op:start-session3\"1.014\"Ed25519_SHA2563:key8:location9:signature>"

  test "validates message constraints":
    expect CapTpMessageError:
      discard deliver(descriptor(descExport, 0), [], 1, descriptor(descImportObject, 1), 2)
    expect CapTpMessageError:
      discard gcExports([1'i64, 2], [1'i64])

  test "builds signed handoff descriptors":
    let seed = repeat("s", 32)
    let publicKey = crypto.publicKey(seed)
    let receiverSeed = repeat("r", 32)
    let receiverPublicKey = crypto.publicKey(receiverSeed)
    let give = handoffGive(glowcapPublicKey(repeat("k", 32)),
      glowcapLocation("127.0.0.1:1"), repeat("a", 32), repeat("b", 32), repeat("i", 32))
    let signed = signatureEnvelope(give, crypto.sign(seed, give.encoded()))
    let receive = handoffReceive(repeat("c", 32), repeat("d", 32), 0, signed)
    check signed.label.data == "desc:sig-envelope"
    check signed.fields.len == 2
    check give.label.data == "desc:handoff-give"
    check give.fields.len == 5
    check receive.label.data == "desc:handoff-receive"
    check receive.fields.len == 4
    check receive.fields[2].magnitude == "0"
    check validHandoffGive(give)
    check validHandoffReceive(receive)
    check verifySignatureEnvelope(signed, glowcapPublicKey(publicKey))
    check not verifySignatureEnvelope(signed, glowcapPublicKey(repeat("k", 32)))
    let receiverGive = handoffGive(glowcapPublicKey(receiverPublicKey),
      glowcapLocation("127.0.0.1:1"), repeat("a", 32), repeat("b", 32), repeat("j", 32))
    let receiverSignedGive = signatureEnvelope(receiverGive,
      crypto.sign(seed, receiverGive.encoded()))
    let receiveValue = handoffReceive(repeat("c", 32), repeat("d", 32), 1,
      receiverSignedGive)
    let signedReceive = signatureEnvelope(receiveValue,
      crypto.sign(receiverSeed, receiveValue.encoded()))
    check verifyHandoffReceive(signedReceive)
    check not verifyHandoffReceive(signatureEnvelope(receiveValue, repeat("x", 64)))
    check not validHandoffGive(handoffGive(glowcapPublicKey(publicKey), text("bad"),
      repeat("a", 32), repeat("b", 32), repeat("i", 32)))
    check not validHandoffGive(record(symbol("desc:handoff-give"), []))
    check not validHandoffReceive(record(symbol("desc:handoff-receive"), []))
    expect CapTpMessageError:
      discard handoffReceive("session", "side", -1, signed)
