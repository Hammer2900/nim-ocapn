import std/os
import ../src/[nimocapn, syrup]

if paramCount() != 1:
  quit("usage: simple_client OCAPN_PEER_URI")
let identityPath = getEnv("NIM_OCAPN_IDENTITY", "simple-client.identity")
var config = defaultNodeConfig()
config.identityPath = identityPath
config.netlayer = nlkTcpTestingOnly
config.verificationPolicy = testingOnlyPeerPolicy
let node = newNode(config)
let peer = parsePeerUri(paramStr(1))
let transport = case peer.transport
  of "tcp": nlkTcpTestingOnly
  of "onion": nlkOnionTestingOnly
  else: raise newException(CatchableError, "unsupported public transport: " & peer.transport)
let session = node.connectUsing(peer, transport)
let greeter = node.bootstrap(session, "greeter")
let answer = waitFor(session, greeter.call("greet", [text("world")]))
echo answer.data
node.close()
