import ./syrup

type
  PromiseState* = enum psPending, psFulfilled, psBroken
  PromiseListener* = proc(promise: Promise) {.closure.}
  Promise* = ref object
    state*: PromiseState
    value*: SyrupValue
    reason*: string
    answerPosition*: int64
    listeners: seq[PromiseListener]

proc newPromise*(): Promise = Promise(state: psPending, answerPosition: -1)

proc fulfill*(promise: Promise; value: SyrupValue) =
  if promise.state != psPending:
    raise newException(ValueError, "promise already settled")
  promise.value = value
  promise.state = psFulfilled
  let listeners = promise.listeners
  promise.listeners.setLen(0)
  for listener in listeners:
    listener(promise)

proc breakPromise*(promise: Promise; reason: string) =
  if promise.state != psPending:
    raise newException(ValueError, "promise already settled")
  promise.reason = reason
  promise.state = psBroken
  let listeners = promise.listeners
  promise.listeners.setLen(0)
  for listener in listeners:
    listener(promise)

proc onSettle*(promise: Promise; listener: PromiseListener) =
  if promise.state == psPending:
    promise.listeners.add(listener)
  else:
    listener(promise)

proc settled*(promise: Promise): bool = promise.state != psPending
