# CLAUDE.md

Guidance for Claude Code working in this repo. Current focus: **mastermind**.

## Build & test

```bash
zig build -Dgui=false                       # mastermind only (no raylib)
zig build test -Dgui=false --summary all    # run tests; --summary all surfaces empty suites
zig build run-mastermind                    # build + run server
zig build gen-protocol                      # regenerate wire_layout.json after protocol changes
```

Full build (`zig build`) also compiles `minion.dll` + `launcher.exe` cross to `x86-windows-gnu`. Min Zig: **0.16.0**. GUI build requires `raylib` (`brew install raylib`).

## Mastermind architecture

```
types.zig              BotId, MsgQueue, max_bots, queue_capacity
net/registry.zig       Slot / Registry / Handle / BotSnapshot — bot table with stable
                       (index+generation) handles, dispatch, snapshot, reconnect eviction
net/connection.zig     per-connection serve(): sendLoop fiber + recvLoop; handleState, handleScan
world/memory.zig       guid-keyed fused view of all bots' scans; last-write-wins; TTL prune
world/spell_events.zig dedup ring buffer for spell start/go/failed events
brain/mod.zig          run() tick loop: snapshot → compute → dispatch + prune.
brain/log.zig          combat decision / dispatch debug logging.
brain/combat_debug.zig trace buffers for arbitration and decision tracking.
brain/action_msg.zig   Action → wire MastermindMsg mapping (pure).
brain/compute_tests.zig integration tests for the compute pipeline.
combat/mod.zig         package entry: Action, IntentStore, DispatchStore exports.
combat/action.zig      Action union (one wire action per tick).
combat/dispatch.zig    DispatchThrottleKey + per-class debounce constants.
combat/dispatch_store.zig  anti-spam ring buffer for dispatched orders.
combat/role.zig        CombatRole / RangeProfile enums + FollowStore.
combat/cast_range.zig  client spell range check (in-range / out-of-range / missing).
combat/positioning.zig desired-position model (melee back-arc, ranged band, …).
combat/spec_routine.zig dispatches to per-spec rotation function.
combat/world_query.zig scan lookups (guid, name) + hostile/friendly predicates.
combat/threat.zig      threat-based DPS safety gate.
combat/heal_select.zig heal-target ranking (cached per healer per tick).
combat/intent/         WHAT each bot should accomplish.
   mod.zig                Intent / Priority / Reason data + IntentStore.
   dispatch.zig           actionForIntent (Intent → Action mapper).
   confirm.zig            per-intent latency / event confirmation.
combat/proposers/      WHO decides the next intent (priority order):
   encounter.zig          map-id routed encounter proposer (priority .encounter).
   tank_engage.zig        pull spell intent (priority .spec, source .tank_engage).
   role.zig               generic raid role (heal, kick, positioning) (priority .role).
   spec.zig               spec rotation → intent (priority .spec).
combat/encounters/     encounter registry + boss scripts.
   mod.zig                map-id constants + prep-gate routing.
   thaddius/              full Thaddius driver (phases, swap, polarity, …).
combat/specs/          per-spec rotation files (one per spec).
formation.zig          Lua invite/raid FSM, operator-triggered (GUI / repl `reform`).
gui/                   raylib shell, double-buffered snapshots, map view.
nav/                   detour pathfinding bridge (optional, via -Dpathfinding).
repl.zig               stdin REPL for manual commands.
lua_output.zig         ring buffer of bot-side Lua print() output for the GUI.
fight_log.zig          stderr log formatter with optional `[mm:ss]` fight clock.
main.zig               gpa, listen, accept loop, async brain.run + connection.serve.
```

**Brain pattern** — recv fibers write `Registry.slots[].last_state` and `WorldMemory.map` under mutex; the brain fiber calls `Registry.snapshot()` for a frozen copy, then `brain.compute(snap, world) → Plan`, then `Registry.dispatch(...)` queues messages for send fibers.

**Concurrency rule:** locks (`Registry.mutex`, `WorldMemory.mutex`) protect mutation only — **never** held across network I/O. Reconnections evict the prior slot inside the lock but close the stale queue/socket outside it (see `Registry.identify`).

**Brain rule:** combat coordination plugs into `brain.compute()` only. Frozen snapshot in, orders out — no fibers, mutexes, or syscalls. To unit-test, build a `[]BotSnapshot` literal and assert on orders.

**Combat layering:**

- `combat/specs/` = rotation + spell IDs, one file per spec.
- `combat/proposers/role.zig` = generic raid behaviour (heal target, kick, positioning) — priority `.role`.
- `combat/proposers/spec.zig` = wraps `specs/<spec>.zig` rotation as a `.spec` intent.
- `combat/proposers/tank_engage.zig` = pull spell logic (priority `.spec`, source `.tank_engage`).
- `combat/proposers/encounter.zig` = map-id routed encounter proposer (priority `.encounter`).
- `combat/encounters/<boss>/` = boss script. Don't duplicate spell IDs / rotation unless a boss truly needs it.

**Combat troubleshooting rule:** placement bugs must be fixed by improving the
shared placement model, not by piling on defensive shortcuts.

- No guardrail fixes: do not add fallback behavior, clamps, retries, debounce,
  special exits, or extra gates just to hide a symptom. If a guard is truly part
  of the model, name it, justify it from engine/game behavior, and test it as a
  first-class rule.
- No magic variables: every threshold, distance, duration, angle, and sampling
  period must be a named module-level constant with units in the name where
  applicable.
- No class-specific placement fixes. Class/spec differences belong in data
  (`SpecMeta`, role/profile, spell ranges, placement policy), not in scattered
  `if class == ...` or `switch spec` branches inside decision code.
- Fix structure before symptoms: when placement is wrong, first identify which
  model is wrong (target selection, desired position, range band, arc/facing,
  intent arbitration, dispatch throttle, minion execution, or scan data) and fix
  that layer cleanly.
- More decision complexity does not mean more nested `if`s. Prefer small pure
  helpers, typed policy structs, tables, and enum-driven switches over branching
  spread across `brain.zig`, `intent_role.zig`, and encounters.
- Keep the planner explainable: one place computes desired placement, one place
  maps placement result to intent, and one place arbitrates role/spec/encounter.
  Do not duplicate placement math in specs or encounter modules.

**Spell event rule:** `SpellEventStore` deduplicates launch events (`start` / `go`) within one `proto.brain_tick_ms` window before planners see them; do not add boss-local debounce unless the mechanic truly needs different semantics.

**Thaddius swap rule:** tank swaps are encounter-global state, not per-bot heuristics. `Magnetic Pull` is detected only from `SpellEventKind.go` spell ID `54517`; ignore effect ID `30010` and legacy/variant IDs `28338` / `28339`. Never use twin `target_guid` as a fallback swap signal. `caster_guid` and `observer_guid` are diagnostics only. After Magnetic Pull, the swap intent retargets immediately, CTMs to the new platform center, then retargets again.

See [`docs/mastermind-combat.md`](docs/mastermind-combat.md) for the intent/store/compute workflow — canonical reference.

**Stores cheatsheet** — `TargetStore` (combat/target_store.zig) = which GUID the bot attacks. `IntentStore` (combat/intent/mod.zig) = what to cast/do (typed intent + priority). `DispatchStore` (combat/dispatch_store.zig) = anti-spam for network orders. `FollowStore` (combat/role.zig) = who follows whom out of combat. All mutable from `brain.compute`; on ties, the existing intent wins (priority > equal-priority replace).

**Formation is not combat:** `formation.zig` is a Lua FSM the brain ticks each loop. No `IntentStore`, no `compute()`, no `combat/`.

## Where to add X

| Task                                               | File                                                                                    |
| -------------------------------------------------- | --------------------------------------------------------------------------------------- |
| New spell / rotation change for an existing spec   | `combat/specs/<spec>.zig`                                                               |
| New spec                                           | `combat/specs/<spec>.zig` + register in `combat/specs/spec_registry.zig`                |
| Generic raid behavior (heal target, kick, dispel…) | `combat/proposers/role.zig`                                                             |
| Tank pull / engage spell behaviour                 | `combat/proposers/tank_engage.zig`                                                      |
| Spec → intent wrapping                             | `combat/proposers/spec.zig`                                                             |
| Boss-specific constraint (positioning, swap, etc.) | `combat/encounters/<boss>/mod.zig` (+ register map_id in `combat/encounters/mod.zig`)   |
| New intent kind                                    | `combat/intent/mod.zig` (variant + predicate) — wire it in `combat/intent/dispatch.zig` |
| Per-intent confirmation / latency guard            | `combat/intent/confirm.zig`                                                             |
| New spell ID / symbolic name                       | `combat/spells.zig`                                                                     |
| Spell range                                        | `combat/spell_range.zig`                                                                |
| Throttle / debounce tuning                         | `combat/dispatch.zig`                                                                   |
| New wire command (mastermind → minion)             | `src/protocol/protocol.zig` + `gen-protocol` + dispatch in minion's `control.zig`       |

## Dev loop

Most combat work is testable without WoW:

1. Write a test in the file that owns the logic (`combat/specs/...`, `role.zig`, `brain.zig`).
2. Add `_ = @import("...");` to the parent root (`main.zig` or `combat/mod.zig`) — otherwise the test is silently ignored (see pitfalls).
3. `zig build test -Dgui=false --summary all`.
4. Build a `[]BotSnapshot` literal (and `WorldSnapshot` if needed), call `compute(...)`, assert on the returned `Order`s.

Only go in-game for: real WoW timing, unexpected aura/cooldown values, wire races. When you do, see **In-game debugging**.

## Code style (Zig)

- **Function layout** — comptime constants → `var` decls → statements. Blank line between groups.
- **No magic numbers** — every duration, size, threshold gets a named module-level constant; express related constants in terms of each other.
- **No magic offsets in framing** — use `frame_length_size` / `frame_header_size`.
- **Switch on enums, not integers** — `std.enums.fromInt(E, raw) orelse continue`, then switch. `else => {}` silently hides missing cases.
- **Prefer comptime generics over manual enumeration** — `inline for (std.meta.fields(T))` or `switch (val) { inline else => |v, tag| ... }` so adding a variant doesn't require touching the function. See `readMastermindMsg` / `writeMastermindFrame`.
- **Methods over free functions** when operating on a struct. Keep `fn` private, `pub fn` deliberate.
- **Lock outside, I/O outside, mutate inside** — mutex sections only mutate; close queues/sockets outside. See `Registry.identify`.
- **Pure planners** — `brain.compute` takes data in, returns data out. No fibers, mutexes, I/O.
- **No wall-clock inside `compute`** — never call `std.time.milliTimestamp()`; pass `game_time_ms` through the snapshot (`bot.state.game_time_ms`). Otherwise tests become non-deterministic.
- **Encounters don't carry rotation** — an encounter overrides constraints (positioning, swap, priority intent), it doesn't reimplement spec rotation. If you end up copying spell IDs from `specs/` into `encounters/`, the split is wrong.
- **Module aliases** — prefer the bare module name (`const intent = @import("intent/mod.zig");`) for new code. Append `_mod` _only_ when the bare name would shadow a common parameter or local (Zig 0.16 forbids shadowing): `action_mod`, `dispatch_store_mod`, `lua_output_mod`, `registry_mod`, `role_mod`, `world_memory_mod` are the documented exceptions. Don't pile on new `_mod` aliases without that justification.
- **Type aliases** — when a file only needs a handful of symbols from a module, lift them once at the top: `const Action = @import("../action.zig").Action;`. Avoids cluttering the body with `module_mod.X`.
- **Comments** — only on non-obvious _why_ (hidden constraint, subtle invariant, workaround for a specific bug). Not what the code does. No references to the current task or to Zig tutorials.

## Tests

Tests live **inline at the bottom of the file** they cover. This is the idiomatic Zig pattern — tests share file scope with the module and have direct access to private symbols. The only standalone test file is `brain/compute_tests.zig` (heavy integration suite for the compute pipeline) — keep new bulk integration tests in dedicated files when they outgrow their module.

The discovery chain is **explicit**: tests are only run if some `test { _ = @import("..."); }` entry transitively reaches the file. `main.zig` is the test root and `combat/mod.zig` is the combat-package root. When you add a new `.zig` file with tests, register it in the closest `mod.zig`'s `test { ... }` block.

## Zig pitfalls

**Test discovery requires explicit `_ = @import(...)` in the root file.** `zig build test` compiles a binary from the module's root. Tests in transitively imported files are NOT auto-discovered — the build silently reports `All 0 tests passed`. Add `test { _ = @import("X.zig"); ... }` to the parent `mod.zig` for every file with `test` blocks.

**`[N]u8` arrays can't be initialized with struct syntax.** `BotId = [32]u8`; `const id: BotId = .{ .id = 1 }` is a compile error. Use `[32]u8{ ... }` or `std.mem.zeroes` + index assignment. Invalid test syntax → silently dropped (0 tests, exit 0).

**`zig build test` exits 0 even when test functions fail to compile.** Type errors inside `test` blocks → silently omitted from the binary. Always check the test count is non-zero. Use `--summary all` (build runner flag, NO `--` separator) to print the count.

**`b.addTest(.{ .root_module = mod })` inherits module imports.** Named imports (`protocol`, `types`, `registry`, …) work inside tests via the build system. Running `zig test src/mastermind/brain/mod.zig` directly fails — use `zig build test -Dgui=false`.

**Zig 0.16 forbids identifier shadowing.** A function parameter or local variable can't share its name with a file-scope decl, even when the types are unambiguous. That's why a handful of modules keep the `_mod` suffix — see Code Style.

## In-game debugging

Feedback loop (compile → inject → observe in WoW) is long. **Prefer targeted `std.log.debug` over blind code changes.** The log is the primary diagnostic.

When behavior is unexpected (spell spam, wrong target, bot not moving):

1. Add `std.log.debug` at the decision point logging relevant state (aura count, spell IDs, distances, intent source/priority, flags).
2. Ship, reproduce, read the log.
3. Fix based on observed values — not assumptions.

Remove diagnostic logs before committing, unless the log has lasting value (e.g. the throttle log with intent source/priority in `brain.zig`).

### Minion environment flags

Off by default. Set before launching the launcher:

| Flag                           | What it logs                                                                                                                                                                                                                |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MINION_LOG_SPELLS=1`          | One line per spell event (`start`, `go`, `failed`, `interrupted`, `channel_update`, `channel_end`) with caster GUID, spell ID, flags and timestamp. Use to validate packet hooks or diagnose cast/channel detection issues. |
| `MINION_LOG_COMBAT_COMMANDS=1` | Mastermind commands received by the minion plus render-thread execution state (`[cmd] phase=recv/exec`), including cast args, target, player pos/yaw, CTM, casting/channeling, known-spell and cooldown state.              |
| `MINION_LOG_GAMEPLAY=1`        | `[play]` state snapshot every 200 ms (pos, target, threat %, HP, mana, resources, combo, cast/channel) + `[play:cast]` for every spell start/go cast by the local player. Use to record manual play for LLM training.      |

**Mastermind flags** (set in the shell running `zig build run-mastermind`):

| Flag                                | What it logs                                                                                                                                                      |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MASTERMIND_LOG_SPELLS=1`           | One line per spell event received from any minion, with kind, caster GUID, spell ID, flags and timestamps. Use to validate the full minion → mastermind pipeline. |
| `MASTERMIND_LOG_COMBAT_DECISIONS=1` | Combat arbitration and dispatch decisions (`combat_arbitration`, `combat_dispatch`) with intent, target, distance, facing/arc, CTM, range and throttle outcomes.  |
| `MASTERMIND_GLUE_LOG=1`             | Glue screen transitions, EnterWorld and bot identify events.                                                                                                      |
| `MASTERMIND_LOG_POLARITY_CHARGES=1` | Map 533 only: one `thaddius: [charge]` line per caster→victim pair each time a Positive/Negative Charge pulse (28062/28085) hits an opposite-charge bot in range — name, charge sign, distance, HP%, ΔHP since last hit, `game_time_ms`. Silent once the raid is sorted. Use to see **who actually takes polarity damage** without the firehose of `MASTERMIND_LOG_SPELLS`. Deliberately **ungated by fight start / phase** (only the map check applies) so the charge auras can be reproduced out of combat on a private server; self-contained GUID-keyed cache, no dependency on the encounter's per-bot state. |

## More docs

- [`docs/architecture.md`](docs/architecture.md) — three-process layout, minion internals, object manager scan, offsets, external references.
- [`docs/wire-protocol.md`](docs/wire-protocol.md) — framing, message types, wire sizes, helpers.
- [`docs/mastermind-combat.md`](docs/mastermind-combat.md) — combat workflow (intents, stores, `brain.compute`).
