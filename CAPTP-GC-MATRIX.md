# CapTP GC и Reference Lifecycle Matrix

Матрица отражает проверенный профиль из `ocapn/draft-specifications/CapTP Specification.md`.

| Правило | Реализация | Тест | Статус |
|---|---|---|---|
| `op:gc-exports` содержит одинаковые списки positions и deltas | `src/messages.nim:173`, `src/session.nim:1137` | `test_messages.nim`, `test_server.nim` | Готово |
| Каждая повторная wire-передача увеличивает `wireRefs` | `src/session.nim:595`, `src/session.nim:656`, `src/api.nim:167`, `src/api.nim:388` | `test_session.nim:76` и forwarding/listener tests | Готово для core outbound paths |
| `wire-delta` должен быть положительным и не превышать wire count | `src/references.nim:71`, `src/session.nim:1153` | `forwarded promise wire ownership rejects duplicate GC`, malformed wire GC tests | Готово |
| Export нельзя удалить при живом `localRefs` | `src/references.nim:57` | `GC audit protects application exports` | Готово |
| Resolver export нельзя освобождать до wire GC | `src/session.nim:678`, `src/session.nim:692` | `remote greeter fulfills a promise` проверяет `wireRefs == 1` до callback/GC | Готово |
| После callback receiver отправляет `op:gc-exports` для resolver | `src/session.nim:409`, `src/session.nim:1446`, pipeline/bootstrap paths | `remote greeter fulfills a promise`, `gc-answers retires answer positions exactly once` | Готово в проверенных профилях |
| `op:gc-answers` удаляет answer position ровно один раз | `src/session.nim:1170` | `gc-answers retires answer positions exactly once` | Готово |
| Повторный или stale `op:gc-answers` отклоняется | `src/session.nim:1187` | тот же тест, `test_gc_answer` внешнего suite | Готово |
| `answer-pos` переиспользуется только после завершения callback и отправки `op:gc-answers` | `src/session.nim:94`, `src/session.nim:820` | `remote greeter fulfills a promise`, pipeline reuse regression | Готово для локального outbound answer state |
| Входящий `answer-pos` имеет отдельный promise slot | `src/session.nim:103`, `src/session.nim:1388` | `op:listen can observe a pipelined answer` | Готово |
| `op:listen` принимает `desc:answer` и разделяет modes 1/2/3 | `src/session.nim:1355`, `src/session.nim:581` | `op:listen answer matrix covers direct and chained modes` | Готово в Nim-профиле |
| Mode 1 уведомляет только о shortening | `src/session.nim:545` | answer matrix, local listen matrix | Готово |
| Mode 2 не уведомляет при shortening и продолжает same-peer promise до settling/break | `src/session.nim:551`, `src/session.nim:507` | `mode 2 follows shortening to a same-peer broken promise` | Готово для same-peer chain |
| Mode 3 завершается первым shortening или settling callback | `src/session.nim:545` | answer matrix, TCP probe | Готово |
| Pipeline к освобождённому `desc:answer` отклоняется | `src/session.nim:1528` | `stale pipeline after gc-answers is rejected` | Готово |
| Forwarded registry живёт до settle и обоих wire releases | `src/session.nim:590` | `forwarded GC before settle retires after source settlement`, `closing forwarded target releases source import` | Готово в проверенных сценариях |
| Source import forwarding освобождается не раньше target wire release | `src/session.nim:597` | `forwarded GC releases the settled source import` | Готово |
| Двойной wire GC вызывает underflow, а не повторное освобождение | `src/session.nim:1135` | `forwarded promise wire ownership rejects duplicate GC`, server stale/duplicate tests | Готово |
| Listener resolver GC дедуплицируется отдельно от application export | `src/session.nim:462` | `GC audit protects application exports and deduplicates listeners` | Готово в проверенном профиле |
| Disconnect/abort очищает pending answers, incoming promises, listeners и forwarding state | `src/session.nim:860`, `src/session.nim:305`, `src/api.nim:159` | `disconnect breaks an incoming remote promise`, disconnect, abort, proxy-disconnect tests | Готово в проверенных сценариях |
| Исходящий `desc:handoff-give` содержит 32-byte gift-id и receiver key; inbound принимает non-empty legacy IDs для Glowcap suite | `src/messages.nim:68`, `src/handoff.nim:79` | `builds signed handoff descriptors`, `handoff gift ids are random 32-byte values`, Glowcap handoff tests | Готово с permissive inbound compatibility |
| Receiver принимает give только для своего Gifter–Receiver public key | `src/handoff.nim:87` | `disconnect during receive breaks the handoff promise` | Готово для проверенного API |
| `desc:handoff-receive` имеет session-local receiving session/side и уникальный count | `src/session.nim:1084`, `src/handoff.nim:256` | repeated handoff-count rejection, handoff E2E | Готово для независимых TCP-сессий |
| Exporter связывает gift с исходной Gifter–Exporter сессией и проверяет Gifter signature | `src/gifts.nim:6`, `src/session.nim:1465` | `passes a capability through an intermediate peer`, wrong gifter-session regression | Готово для deposited gifts |
| Gift withdrawal остаётся pending до deposit и очищается при disconnect | `src/gifts.nim:42`, `src/session.nim:371`, `src/handoff.nim:166` | pending bootstrap withdraw, closing-session gift test, handoff disconnect test | Готово |
| Каждая новая Receiver–Exporter handoff-сессия получает независимую identity | `src/handoff.nim:97`, `src/handoff.nim:128` | `concurrent receiver handoffs use independent identities and clean up` | Готово |
| Неверный receiver-key отклоняется до установления handoff-соединения | `src/handoff.nim:87` | `receiver rejects a give addressed to another key before dialing` | Готово |
| Legacy deposit без provenance не принимается защищённым `withdraw-gift` | `src/session.nim:1470` | `protected withdraw rejects an unbound legacy gift` | Готово для protected profile |
| Handoff-created sessions сохраняют exporter PeerLocator между последующими hops | `src/handoff.nim:99`, `src/handoff.nim:132` | `four independent TCP nodes preserve a capability through handoff` | Готово |
| Четыре независимых TCP nodes сохраняют capability identity/provenance через A→B→C→D | `src/api.nim`, `src/handoff.nim`, `src/gifts.nim` | `four independent TCP nodes preserve a capability through handoff` | Готово |
| Параллельные B→C и C→D handoff chains и независимый B→D receiver | `src/api.nim`, `src/handoff.nim` | тот же four-node regression | Готово |
| Повторный withdraw redeemed gift через новую TCP-сессию не replay’ит capability и bounded cleanup | `src/gifts.nim`, `src/handoff.nim` | `passes a capability through an intermediate peer` repeat-withdraw section | Готово |
| Disconnect A/B/C до deposit, после deposit, во время withdraw и после redeem не оставляет pending state | `tests/test_handoff_disconnect.nim`, `src/handoff.nim`, `src/gifts.nim` | 12 wire-level matrix cases | Готово для testing-only TCP profile |
| Диагностика gift registry и pending withdraw доступна через Session/Node stats | `src/gifts.nim:82`, `src/session.nim:1041`, `src/api.nim:479` | handoff lifecycle and cleanup tests | Готово |

## Ограничения

- Начальный bootstrap/export profile и descriptor mapping для всех внешних peer ещё не доказаны формальным exhaustive audit.
- Учёт повторных передач покрывает core API, resolver/listener, bootstrap и forwarding paths. Низкоуровневый код, который вручную строит `payloadDescriptor()` и отправляет его без Session/API helper, всё ещё обязан сам учитывать wire ownership.
- Полная distributed-GC семантика для произвольного числа forwarding hops, reorder callback frames и reconnect остаётся частично покрытой; duplicate/stale callbacks намеренно завершают protocol session.
- Mode 2/3 chained-listen через произвольное число внешних peers и reconnect требует отдельного cross-peer matrix; локальные и двухсессионные сценарии покрыты.
- Production-secure Netlayer, Locators и channel security не входят в этот этап.
- Входящие legacy gift ID длиной меньше 32 байт принимаются только для совместимости с
  Glowcap conformance fixture; исходящие Nim gift ID всегда 32-байтовые.
- Legacy API deposit без provenance остаётся доступен низкоуровневому коду, но protected
  `withdraw-gift` его отвергает.
- Полный wire-level matrix disconnect A/B/C на каждой фазе ещё не закрыт отдельными E2E-тестами.
- Matrix использует testing-only TCP и проверяет bounded cleanup; production Netlayer failure
  semantics ещё не определены.
- Production OCapN Locators, authenticated Netlayers и channel security остаются вне CapTP
  prototype profile.

## Prototype / interoperability profile

- CapTP V1.0 message, descriptor, answer, listen, handoff и reference lifecycle paths
  подтверждены Nim unit tests, TCP E2E и Glowcap conformance.
- Interoperability подтверждена для Glowcap testing profile: `24/24 × 3`.
- Legacy inbound gift IDs короче 32 байт принимаются только для внешнего Glowcap fixture;
  Nim-generated gift IDs всегда 32 байта.
- OCapN production Locators, authenticated Netlayers, channel security и persistence не входят
  в заявленный prototype profile.

Проверки этого этапа:

```text
nimble test                         # passed
nim c -r tests/test_api.nim         # passed
nim c -r tests/test_handoff.nim     # passed
python3 experiments/run_conformance_isolated.py --runs 3 --port 43500
                                      # 24/24 × 3
git diff --check                     # passed
```
