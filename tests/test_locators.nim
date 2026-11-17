import std/[tables, unittest]
import ../src/[locators, syrup]

suite "OCapN locators":
  test "round trips peer locator with hints":
    let peer = newPeerLocator("tcp-testing-only", "peer-id", [("host", "127.0.0.1"), ("port", "22045")])
    let decodedPeer = peer.peerSyrup().peerLocator()
    check decodedPeer.transport == "tcp-testing-only"
    check decodedPeer.designator == "peer-id"
    check decodedPeer.hints["host"] == "127.0.0.1"
    check decodedPeer.hints["port"] == "22045"

  test "round trips sturdyref locator":
    let sturdy = SturdyRef(peer: newPeerLocator("tcp-testing-only", "peer-id"),
      swissNum: "VMDDd1voKWarCe2GvgLbxbVFysNzRPzx")
    let decodedSturdy = sturdy.sturdySyrup().sturdyRef()
    check decodedSturdy.peer.designator == "peer-id"
    check decodedSturdy.swissNum == sturdy.swissNum

  test "accepts binary swiss numbers from conformance peers":
    let value = record(symbol("ocapn-sturdyref"),
      record(symbol("ocapn-peer"), symbol("tcp-testing-only"), text("peer-id"), boolean(false)),
      bytes("my-object"))
    check value.sturdyRef().swissNum == "my-object"

  test "round trips peer and sturdyref URIs":
    let sturdy = SturdyRef(peer: newPeerLocator("tcp-testing-only", "peer.with.dots",
      [("host", "127.0.0.1"), ("port", "22045")]), swissNum: "a/b")
    let peer = parsePeerUri(sturdy.peer.peerUri())
    let decoded = parseSturdyUri(sturdy.sturdyUri())
    check peer.designator == "peer.with.dots"
    check peer.hints["port"] == "22045"
    check decoded.swissNum == "a/b"
    check decoded.peer.transport == "tcp-testing-only"

  test "rejects malformed locators":
    expect LocatorError:
      discard record(symbol("ocapn-peer"), symbol("tcp"), text("id"), text("bad")).peerLocator()
