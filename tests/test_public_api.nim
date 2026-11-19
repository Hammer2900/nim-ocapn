import std/[net, os, tables]
import ../src/[api, promises, references, session, syrup]

proc identityPath(name: string): string =
  getTempDir() / ("nim-ocapn-public-" & name & "-" & $getCurrentProcessId())

proc waitForOpen(client, server: Node; session: Session) =
  var remaining = 2000
  while session.state == ssNegotiating and remaining > 0:
    discard server.poll(1, 16)
    discard client.poll(1, 16)
    dec remaining
  doAssert session.state == ssOpen

proc waitForBoth(client, server: Node; session: Session; promise: Promise): SyrupValue =
  var remaining = 2000
  while promise.state == psPending and remaining > 0:
    discard server.poll(1, 16)
    discard client.poll(1, 16)
    dec remaining
  doAssert promise.state == psFulfilled
  promise.value

block:
  let serverPath = identityPath("server")
  let clientPath = identityPath("client")
  try:
    var serverConfig = defaultNodeConfig()
    serverConfig.identityPath = serverPath
    let server = newNode(serverConfig)
    server.publish("greeter", proc(args: seq[SyrupValue]): SyrupValue =
      if args.len == 1 and args[0].kind == skString: text("Hello, " & args[0].data)
      else: raise newException(SessionError, "greeter expects one string"))

    var clientConfig = defaultNodeConfig()
    clientConfig.identityPath = clientPath
    let client = newNode(clientConfig)
    let peer = server.locator()
    let connection = client.dial(peer.hints["host"], server.listenPort())
    waitForOpen(client, server, connection)
    let greeterPromise = api.fetch(connection, "greeter")
    let greeter = RemoteCapability(session: connection,
      reference: waitForBoth(client, server, connection, greeterPromise).descriptor())
    let result = waitForBoth(client, server, connection,
      greeter.call("greet", [text("world")]))
    doAssert result.kind == skString and result.data == "Hello, world"
    doAssert client.publicIdentity() == loadNodeIdentity(clientPath).publicKey

    connection.close("public API reconnect test")
    for _ in 0 .. 1:
      let reopened = client.dial(peer.hints["host"], server.listenPort())
      waitForOpen(client, server, reopened)
      reopened.close("public API reconnect cycle")

    var onionConfig = defaultNodeConfig()
    onionConfig.netlayer = nlkOnionTestingOnly
    try:
      discard newNode(onionConfig)
      doAssert false, "non-TCP Node listener was accepted"
    except SessionError:
      discard
    try:
      discard client.connectUsing(server.locator(), nlkOnionTestingOnly)
      doAssert false, "transport mismatch was accepted"
    except SessionError:
      discard
    try:
      discard client.connectUsing(server.locator(), nlkMutualTls)
      doAssert false, "mutual TLS silently fell back to TCP"
    except SessionError:
      discard

    client.close()
    client.close()
    server.close()
    server.close()
  finally:
    for path in [serverPath, clientPath, serverPath & ".lock", clientPath & ".lock"]:
      if fileExists(path): removeFile(path)

echo "public API: PASS"
