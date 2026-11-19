import std/[strutils, tables, unittest]
import ../src/[locators, syrup]

suite "OCapN locators":
  test "peer locator has canonical Syrup and URI golden vectors":
    let peer = newPeerLocator("tcp-testing-only", "a.b/café",
      [("z key", "a+b"), ("x", "ü")])
    check peer.peerSyrup().encoded() ==
      "<10'ocapn-peer16'tcp-testing-only9\"a.b/café{1\"x2\"ü5\"z key3\"a+b}>"
    check peer.peerUri() ==
      "ocapn://a.b%2Fcaf%C3%A9.tcp-testing-only?x=%C3%BC&z%20key=a%2Bb"
    check parsePeerUri(peer.peerUri()).samePeer(peer)

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

  test "rejects a transport containing the URI separator":
    expect LocatorError:
      discard newPeerLocator("not.a.netlayer", "peer-id")
    for uri in ["http://peer.tcp", "ocapn://.tcp", "ocapn://peer.",
                "ocapn://peer.tcp?broken", "ocapn://peer.tcp?=value"]:
      expect LocatorError:
        discard parsePeerUri(uri)

  test "preserves unicode and escaped sturdyref fields":
    let sturdy = SturdyRef(peer: newPeerLocator("onion", "служба"),
      swissNum: "объект/1+2")
    let roundTrip = parseSturdyUri(sturdy.sturdyUri())
    check roundTrip.peer.samePeer(sturdy.peer)
    check roundTrip.peer.designator == sturdy.peer.designator
    check roundTrip.swissNum == sturdy.swissNum

  test "unknown transport is syntactically valid but not locally supported":
    let peer = newPeerLocator("future-netlayer", "designator")
    check peer.peerSyrup().peerLocator().samePeer(peer)

  test "strict locator shape rejects wrong field types and empty swiss numbers":
    for value in [
      record(symbol("ocapn-peer"), text("tcp"), bytes("id"), boolean(false)),
      record(symbol("ocapn-peer"), symbol("tcp"), text("id"), list()),
      record(symbol("ocapn-sturdyref"),
        record(symbol("ocapn-peer"), symbol("tcp"), text("id"), boolean(false)),
        text(""))
    ]:
      expect LocatorError:
        if value.label.data == "ocapn-peer": discard value.peerLocator()
        else: discard value.sturdyRef()
    expect LocatorError:
      discard SturdyRef(peer: newPeerLocator("tcp", "peer"), swissNum: "").sturdySyrup()

  test "strict URI parsing rejects malformed percent escapes and duplicates":
    for uri in ["ocapn://peer.tcp?hint=%", "ocapn://peer.tcp?hint=%A",
                "ocapn://peer.tcp?hint=%GG", "ocapn://peer.tcp?k=one&k=two",
                "ocapn://peer.tcp#fragment"]:
      expect LocatorError:
        discard parsePeerUri(uri)
    for uri in ["ocapn://peer.tcp/s/object%", "ocapn://peer.tcp/s/object#fragment"]:
      expect LocatorError:
        discard parseSturdyUri(uri)
    for uri in ["ocapn://%FF.tcp", "ocapn://peer.tcp/s/%FF"]:
      expect LocatorError:
        if uri.find("/s/") >= 0: discard parseSturdyUri(uri)
        else: discard parsePeerUri(uri)

  test "strict locator constructors reject invalid UTF-8":
    expect LocatorError:
      discard newPeerLocator("tcp", "peer\xff")
    expect LocatorError:
      discard newPeerLocator("tcp", "peer", [("hint\xff", "value")])

  test "strict URI vectors preserve empty hint values and escaped octets":
    let peer = parsePeerUri("ocapn://a%2Fb.tcp?empty=&slash=%2F")
    check peer.designator == "a/b"
    check peer.hints["empty"] == ""
    check peer.hints["slash"] == "/"
    check peer.peerUri() == "ocapn://a%2Fb.tcp?empty=&slash=%2F"

  test "strict Syrup locator rejects duplicate hint keys":
    let value = record(symbol("ocapn-peer"), symbol("tcp"), text("peer"),
      dict([pair(text("hint"), text("one")), pair(text("hint"), text("two"))]))
    expect LocatorError:
      discard value.peerLocator()

  test "peer identity ignores routing hints":
    let left = newPeerLocator("onion", "service", [("host", "one")])
    let right = newPeerLocator("onion", "service", [("host", "two")])
    check left.samePeer(right)
