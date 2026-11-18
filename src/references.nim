import std/[strutils, tables]
import ./[messages, syrup]

type
  ReferenceError* = object of CatchableError
  ReferenceKind* = enum
    rkImportObject, rkImportPromise, rkExport, rkAnswer
  CapabilityRef* = object
    kind*: ReferenceKind
    position*: int64
  ReferenceKey* = object
    kind*: ReferenceKind
    position*: int64
  ExportOwner* = enum
    eoApplication, eoAnswerResolver, eoListenerResolver, eoForwardedProxy
  ExportSlot* = object
    behavior*: BehaviorRef
    live*: bool
    localRefs*: int64
    wireRefs*: int64
    owner*: ExportOwner
  BehaviorRef* = proc(args: seq[SyrupValue]): SyrupValue {.closure.}
  ReferenceTables* = object
    exports*: Table[int64, ExportSlot]
    imports*: Table[int64, int64]
    nextExport*: int64

proc reference*(kind: ReferenceKind; position: int64): CapabilityRef =
  if position < 0:
    raise newException(ReferenceError, "reference positions must be non-negative")
  CapabilityRef(kind: kind, position: position)

proc referenceKey*(reference: CapabilityRef): ReferenceKey =
  ReferenceKey(kind: reference.kind, position: reference.position)

proc importObject*(position: int64): CapabilityRef = reference(rkImportObject, position)
proc importPromise*(position: int64): CapabilityRef = reference(rkImportPromise, position)
proc exportRef*(position: int64): CapabilityRef = reference(rkExport, position)

proc initReferenceTables*(firstExport = 0'i64): ReferenceTables =
  result.exports = initTable[int64, ExportSlot]()
  result.imports = initTable[int64, int64]()
  result.nextExport = firstExport

proc allocateExport*(tables: var ReferenceTables; behavior: BehaviorRef;
                      owner = eoApplication): CapabilityRef =
  result = exportRef(tables.nextExport)
  inc tables.nextExport
  tables.exports[result.position] = ExportSlot(behavior: behavior, live: true,
    localRefs: 1, wireRefs: 1, owner: owner)

proc exportBehavior*(tables: ReferenceTables; position: int64): BehaviorRef =
  let slot = tables.exports.getOrDefault(position)
  if not slot.live: return nil
  slot.behavior

proc releaseExport*(tables: var ReferenceTables; position: int64): bool =
  if not tables.exports.hasKey(position): return false
  if tables.exports[position].localRefs <= 0: return false
  tables.exports[position].localRefs = 0
  tables.exports[position].live = tables.exports[position].wireRefs > 0
  if not tables.exports[position].live:
    tables.exports.del(position)
  true

proc retainExport*(tables: var ReferenceTables; position: int64) =
  if not tables.exports.hasKey(position):
    raise newException(ReferenceError, "unknown export position " & $position)
  inc tables.exports[position].wireRefs

proc releaseExportDelta*(tables: var ReferenceTables; position, delta: int64): bool =
  if delta <= 0: raise newException(ReferenceError, "export release delta must be positive")
  if not tables.exports.hasKey(position):
    raise newException(ReferenceError, "unknown or released export position " & $position)
  let current = tables.exports[position].wireRefs
  if delta > current:
    raise newException(ReferenceError, "export release underflow at position " & $position)
  tables.exports[position].wireRefs = current - delta
  if tables.exports[position].wireRefs == 0:
    tables.exports[position].live = tables.exports[position].localRefs > 0
    if not tables.exports[position].live:
      tables.exports.del(position)
  true

proc releaseWireExport*(tables: var ReferenceTables; reference: CapabilityRef;
                        delta: int64): bool =
  if reference.kind != rkExport:
    raise newException(ReferenceError, "wire GC requires an export descriptor")
  tables.releaseExportDelta(reference.position, delta)

proc retainImport*(tables: var ReferenceTables; position: int64) =
  tables.imports[position] = tables.imports.getOrDefault(position) + 1

proc releaseImport*(tables: var ReferenceTables; position: int64): bool =
  if not tables.imports.hasKey(position): return false
  let count = tables.imports[position]
  if count <= 1: tables.imports.del(position)
  else: tables.imports[position] = count - 1
  true

proc importRefCount*(tables: ReferenceTables; position: int64): int64 =
  tables.imports.getOrDefault(position)

proc exportCount*(tables: ReferenceTables): int = tables.exports.len
proc importCount*(tables: ReferenceTables): int = tables.imports.len

proc descriptor*(value: CapabilityRef): SyrupValue =
  let kind = case value.kind
    of rkImportObject: descImportObject
    of rkImportPromise: descImportPromise
    of rkExport: descExport
    of rkAnswer: descAnswer
  let label = case value.kind
    of rkImportObject: "desc:import-object"
    of rkImportPromise: "desc:import-promise"
    of rkExport: "desc:export"
    of rkAnswer: "desc:answer"
  record(symbol(label), integer(value.position))

proc targetDescriptor*(value: CapabilityRef): SyrupValue =
  if value.kind in {rkExport, rkImportObject}:
    return record(symbol("desc:export"), integer(value.position))
  value.descriptor()

proc payloadDescriptor*(value: CapabilityRef): SyrupValue =
  if value.kind == rkExport:
    return record(symbol("desc:import-object"), integer(value.position))
  if value.kind == rkImportObject:
    return record(symbol("desc:export"), integer(value.position))
  value.descriptor()

proc descriptor*(value: SyrupValue): CapabilityRef =
  if value.kind != skRecord or value.fields.len != 1 or
      value.label.kind != skSymbol or value.fields[0].kind != skInteger or
      value.fields[0].negative:
    raise newException(ReferenceError, "invalid capability descriptor")
  let kind = case value.label.data
    of "desc:import-object": rkImportObject
    of "desc:import-promise": rkImportPromise
    of "desc:export": rkExport
    of "desc:answer": rkAnswer
    else: raise newException(ReferenceError, "unknown capability descriptor")
  try:
    result = reference(kind, parseInt(value.fields[0].magnitude))
  except ValueError:
    raise newException(ReferenceError, "descriptor position is too large")
