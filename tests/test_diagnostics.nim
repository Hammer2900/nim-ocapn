import std/[net, sequtils]
import ../src/[api, promises, references, session, syrup]

proc waitOpen(client, server: Node; session: Session) =
  var remaining = 2000
  while session.state == ssNegotiating and remaining > 0:
    discard server.poll(1, 16)
    discard client.poll(1, 16)
    dec remaining
  doAssert session.state == ssOpen

proc waitBoth(client, server: Node; session: Session; promise: Promise): SyrupValue =
  var remaining = 2000
  while promise.state == psPending and remaining > 0:
    discard server.poll(1, 16)
    discard client.poll(1, 16)
    dec remaining
  doAssert promise.state == psFulfilled
  promise.value

proc hasEvent(events: seq[DiagnosticEvent]; kind: DiagnosticEventKind): bool =
  events.anyIt(it.kind == kind)

block:
  var serverEvents: seq[DiagnosticEvent]
  var clientEvents: seq[DiagnosticEvent]
  var serverConfig = defaultNodeConfig()
  serverConfig.maxActiveSessions = 1
  serverConfig.diagnosticSink = proc(event: DiagnosticEvent) = serverEvents.add(event)
  let server = newNode(serverConfig)
  server.publishTyped("never", proc(actor: Session; args: seq[ReceivedArgument]): SyrupValue =
    discard actor.deferAnswer()
    list())

  var clientConfig = defaultNodeConfig()
  clientConfig.diagnosticSink = proc(event: DiagnosticEvent) = clientEvents.add(event)
  let client = newNode(clientConfig)
  let connection = client.dial("127.0.0.1", server.listenPort())
  waitOpen(client, server, connection)
  doAssert hasEvent(clientEvents, dekHandshakeSuccess)
  doAssert hasEvent(clientEvents, dekSessionOpened)

  let never = RemoteCapability(session: connection,
    reference: waitBoth(client, server, connection,
      api.fetch(connection, "never")).descriptor())
  let pending = never.call("never", [])
  try:
    discard api.waitForCallTimeout(connection, pending, 1)
    doAssert false, "timeout unexpectedly fulfilled"
  except PromiseTimeoutError:
    discard
  doAssert hasEvent(clientEvents, dekPromiseTimeout)

  connection.close("diagnostics close")
  discard server.poll(1, 16)
  doAssert hasEvent(clientEvents, dekSessionClosed)

  var limitedConfig = defaultNodeConfig()
  limitedConfig.sessionLimits.maxPendingPromises = 0
  limitedConfig.diagnosticSink = proc(event: DiagnosticEvent) = clientEvents.add(event)
  let limited = newNode(limitedConfig)
  let limitedSession = limited.dial("127.0.0.1", server.listenPort())
  waitOpen(limited, server, limitedSession)
  try:
    discard api.fetch(limitedSession, "never")
    doAssert false, "pending promise limit was not enforced"
  except SessionError:
    discard
  doAssert hasEvent(clientEvents, dekResourceLimit)

  let second = client.dial("127.0.0.1", server.listenPort())
  discard server.poll(1, 16)
  doAssert hasEvent(serverEvents, dekResourceLimit)
  second.close("diagnostics rejected session")
  limited.close()
  client.close()
  server.close()

echo "diagnostics: PASS"
