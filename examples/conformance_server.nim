import std/[net, os, strutils]
import ../src/[handoff, locators, messages, references, server, session, syrup]

const
  CarFactoryBuilder = "JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ"
  EchoGc = "IO58l1laTyhcrgDKbEzFOO32MDd6zE5w"
  Greeter = "VMDDd1voKWarCe2GvgLbxbVFysNzRPzx"
  PromiseResolver = "IokCxYmMj04nos2JN1TDoY1bT8dXh6Lr"
  SturdyRefEnlivener = "gi02I1qghIwPiKGKleCQAOhpy3ZtYRpB"

var acceptedSessions: seq[Session]
var handoffs: HandoffManager

proc abortCrossed(session: Session) =
  try:
    session.send(abort("crossed hello arbitration"))
  except CatchableError:
    session.close("crossed hello arbitration")

proc requireSymbol(value: SyrupValue): string =
  if value.kind != skSymbol:
    raise newException(SessionError, "conformance object expected a symbol")
  value.data

proc publishConformance(session: Session) =
  discard session.publishActor(Greeter, proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
    if args.len != 1:
      raise newException(SessionError, "greeter expects one capability")
    if args[0].kind == skRecord and args[0].label.kind == skSymbol and
        args[0].label.data == "desc:sig-envelope" and args[0].fields.len == 2 and
        args[0].fields[0].kind == skRecord and
        args[0].fields[0].label.kind == skSymbol and
        args[0].fields[0].label.data == "desc:handoff-give":
      discard handoffs.startHandoffReceiver(args[0], actorSession)
      return list()
    let target = args[0].descriptor()
    discard actorSession.deliverCall(target, [text("Hello")])
    list())

  discard session.publishActor(EchoGc, proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
    list(args))

  discard session.publishActor(CarFactoryBuilder, proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
    if args.len != 0:
      raise newException(SessionError, "car factory builder expects no arguments")
    let factory = actorSession.exportActor(proc(factorySession: Session; factoryArgs: seq[SyrupValue]): SyrupValue =
      if factoryArgs.len != 1 or factoryArgs[0].kind != skList or factoryArgs[0].items.len != 2:
        raise newException(SessionError, "car factory expects [color, model]")
      let color = requireSymbol(factoryArgs[0].items[0])
      let model = requireSymbol(factoryArgs[0].items[1])
      let car = factorySession.exportObject(proc(carArgs: seq[SyrupValue]): SyrupValue =
        text("Vroom! I am a " & color & " " & model & " car!"))
      car.payloadDescriptor())
    factory.payloadDescriptor())

  discard session.publishActor(PromiseResolver, proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
    if args.len != 0:
      raise newException(SessionError, "promise resolver expects no arguments")
    let pair = actorSession.newPromisePair()
    list(pair.vow.payloadDescriptor(), pair.resolver.payloadDescriptor()))

  discard session.publishActor(SturdyRefEnlivener, proc(actorSession: Session; args: seq[SyrupValue]): SyrupValue =
    if args.len != 1 or args[0].kind != skRecord:
      raise newException(SessionError, "sturdyref enlivener expects one sturdyref")
    let answer = if actorSession.hasActiveAnswer(): actorSession.deferAnswer()
                 else: AnswerContext(resolver: nil, answerPosition: -1)
    discard handoffs.startSturdyRefSession(args[0].sturdyRef(), actorSession, answer,
      acceptedSessions)
    list())

let port = Port(if paramCount() == 1: parseInt(paramStr(1)) else: 42050)
handoffs = newHandoffManager()
let manager = newTcpSessionManager("127.0.0.1", port, "conformance-nim", "127.0.0.1:" & $port,
  proc(session: Session) =
    publishConformance(session)
    acceptedSessions.add(session))
echo "Nim conformance server listening on 127.0.0.1:", port
while true:
  discard manager.poll(1000)
  var liveAccepted: seq[Session]
  for session in acceptedSessions:
    if manager.hasSession(session) and session.state != ssClosed:
      liveAccepted.add(session)
  acceptedSessions = liveAccepted
  handoffs.pump()
  for inbound in acceptedSessions:
    if inbound.state != ssOpen or inbound.remoteLocation.len == 0: continue
    for outbound in handoffs.outboundSessions:
      if outbound.state == ssClosed or outbound.remoteLocation.len == 0 or
          outbound.remoteLocation != inbound.remoteLocation:
        continue
      # Compare the public identifiers of the two initiating connections:
      # our outbound session's local id versus the peer's outbound id carried
      # by the inbound session.  The lower identifier is aborted.
      if outbound.localSideId() <= inbound.remoteSideId():
        abortCrossed(outbound)
      else:
        abortCrossed(inbound)
