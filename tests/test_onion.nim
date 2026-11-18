import std/[net, strutils, unittest]
import ../src/[locators, onion]

suite "OCapN Onion netlayer unit tests":
  test "validates onion locator and preserves provenance":
    let peer = newPeerLocator("onion", repeat('a', 56))
    let layer = newOnionNetlayer()
    let listener = layer.listen("127.0.0.1", Port(19045), peer)
    check listener.peer.samePeer(peer)
    listener.close()

  test "rejects malformed onion locators without TCP fallback":
    let layer = newOnionNetlayer()
    expect OnionError:
      discard layer.dial(newPeerLocator("tcp", repeat('a', 56)))
    expect OnionError:
      discard layer.dial(newPeerLocator("onion", "not-a-service-id"))

  test "bounds SOCKS failure without trying direct TCP":
    var config = defaultOnionNetlayerConfig()
    config.socksPort = Port(1)
    config.connectTimeoutMs = 50
    let layer = newOnionNetlayer(config)
    expect OnionError:
      discard layer.dial(newPeerLocator("onion", repeat('a', 56)))
