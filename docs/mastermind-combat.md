# Mastermind combat workflow

Canonical reference for how combat decisions flow from brain ticks to minion wire commands.
Written for human operators and for LLM agents editing `src/mastermind/combat/`.

**Related docs:** [`CLAUDE.md`](../CLAUDE.md) (repo-wide build/architecture), wire protocol in [`src/protocol/protocol.zig`](../src/protocol/protocol.zig).

---

## 1. Mental model

Combat is **not** "pick a spell every tick and send it". It is three separable questions:

| Question                                    | Answered by                                       | Persists across ticks? |
| ------------------------------------------- | ------------------------------------------------- | ---------------------- |
| **What should this bot accomplish?**        | `ActiveIntent` in `IntentStore`                   | Yes                    |
| **What wire command this tick?**            | `Action` → `MastermindMsg` in `brain` dispatch    | No (derived each tick) |
| **May we send it yet?** (debounce, latency) | `DispatchStore` + `ActiveIntent.confirm`          | Yes (short-lived)      |

```
  ┌─────────────┐     propose      ┌──────────────┐    dispatch     ┌─────────────┐
  │  Proposers  │ ───────────────► │ IntentStore  │ ───────────────►│   Orders    │
  │ encounter/  │   (priority)     │ ActiveIntent │  action+confirm │  (per bot)  │
  │ role/spec/  │                  └──────────────┘                 └──────┬──────┘
  │ heal/tank   │                                                          │
  └─────────────┘                                                          ▼
                                                                       minion TCP
```

**Layering (who proposes what):**

| Layer     | Directory / module                                                   | Priority         | Responsibility                                                  |
| --------- | -------------------------------------------------------------------- | ---------------- | --------------------------------------------------------------- |
| Role      | `proposers/role.zig`, `proposers/heal.zig`                           | `.role` (1)      | Raid placement / auto-attack, healing                           |
| Spec      | `proposers/spec.zig`, `proposers/tank_engage.zig`, `tank_rescue.zig` | `.spec` (2)      | Rotation, pull/engage, taunt-rescue                             |
| Encounter | `proposers/encounter.zig`, `encounters/`                             | `.encounter` (3) | Boss scripts (routes, stacks, swaps, pull targets)              |
| Operator  | GUI / tests                                                          | `.operator` (4)  | Start fight, clean orders, test sequences                       |

Higher **numeric** priority wins (`operator` > `encounter` > `spec` > `role` > `idle`). See `Priority.supersedes` in `intent/mod.zig`.

**Hard rule (from `CLAUDE.md`):** encounters override constraints; they must not reimplement full rotations unless a boss truly requires it.

---

## 2. End-to-end pipeline

### 2.1 Processes

```
launcher.exe ──injects──► minion.dll (in WoW) ◄──TCP──► mastermind
```

- **Minion** reads game memory, sends `STATE` / `SCAN` / `SPELL_EVENT` frames, executes `NetCmd` on the render thread (`EndScene`).
- **Mastermind** holds fused world state, runs `brain.run()` (≈67 ms tick, `proto.brain_tick_ms`), dispatches orders.

### 2.2 Combat slice of a brain tick

This document covers **only** the path from snapshot to combat wire orders. `brain.run()` also runs formation, nav, GUI publish, and world prune in the same loop — see [`CLAUDE.md`](../CLAUDE.md) (`formation.zig` is separate; no `combat/` imports).

```
Registry.snapshot + WorldMemory.snapshot + SpellEventStore.snapshot
  → brain.compute  → Registry.dispatch per order
                   → GUI commands (Start fight / Clean / Test jump) via gui/brain_dispatch.zig
```

Entry: `brain.run()` → `dispatchCombatOrders` → `compute()` in `src/mastermind/brain/mod.zig`.

Combat-related state (brain lifetime):

| Store            | Type            | Role                                                |
| ---------------- | --------------- | --------------------------------------------------- |
| `intent_store`   | `IntentStore`   | Current objective per bot                           |
| `dispatch_store` | `DispatchStore` | Per-action debounce + threat holds + `hardStop`     |
| `follow_store`   | `FollowStore`   | Per-bot position anchors (encounter placement)      |
| `is_fighting`    | `bool`          | Operator clicked **Start fight**                    |

A `TargetStore` is **rebuilt every compute pass** (not brain-lifetime) — encounters write per-bot forced targets into it each tick. Encounter-specific state (e.g. Thaddius) lives in `encounters/<boss>/state.zig`, not in a global store.

### 2.3 Data into `compute`

```zig
pub fn compute(
    bots: []const BotSnapshot,
    world: []const WorldSnapshot,
    events: []const proto.SpellEvent,
    out: *[max_bots]Order,
    dispatch_store: *DispatchStore,
    follow_store: *FollowStore,
    intent_store: *IntentStore,
    operator_fight_started: bool,
) []const Order
```

- **Pure:** no mutex, no I/O, no fibers, no wall-clock inside `compute` (unit-test friendly). Time comes from `bot.state.game_time_ms`.
- Inputs are a **frozen** snapshot; recv fibers mutate `Registry` / `WorldMemory` / `SpellEventStore` under lock elsewhere.
- `compute` delegates to `computeWithProposers(...)` so tests can inject custom role/spec proposers.

---

## 3. `CombatContext` (per bot, per tick)

Built in `combat/context.zig` via `CombatContext.build(bot, bots, world, events, operator_fight_started)`.

| Field                    | Meaning                                                  |
| ------------------------ | -------------------------------------------------------- |
| `bot`, `bots`, `world`   | Snapshot pointers                                        |
| `spell_events`           | Frozen spell-event slice (cast confirmation, mechanics)  |
| `spec`, `role`           | From talents + `spec_registry`                           |
| `primary_target`         | Cached hostile GUID from world scan                      |
| `heal_priority`          | Ranked heal target (healers only)                        |
| `assigned_tank_guid`     | Encounter tank assignment for healer maintenance         |
| `threat_high`            | DPS safety gate (`aggro.highThreat`)                     |
| `game_time_ms`           | From bot `STATE`                                          |
| `operator_fight_started` | GUI **Start fight** flag                                 |

Expensive queries (heal ranking, threat) run **once** at build time. Proposers take `*const CombatContext`, not raw `(bot, world)`, and must not re-scan ad hoc. Convenience helpers: `spellReady`, `runeReady`, `auraOnSelf`, `auraOnTarget`, `hpPct`, `manaPct`, `runicPower`, `targetHpPct`.

---

## 4. Intent system

### 4.1 `ActiveIntent`

```zig
pub const ActiveIntent = struct {
    intent: Intent,                              // WHAT to accomplish
    priority: Priority,
    cancellable_by_priority: Priority = .operator, // who may preempt on the force=false path
    created_at_ms: u32,
    max_age_ms: u32 = 0,                          // 0 = never auto-expire
    source: Reason,                               // logging / arbitration
    confirm: Confirm = .{},                       // latency / event guard (see §6)
};
```

### 4.2 Intent variants (`Intent` / `SimpleIntent`)

`IntentTag` (`intent/mod.zig`):

| Tag                       | Purpose                                                  |
| ------------------------- | -------------------------------------------------------- |
| `idle`                    | No objective                                             |
| `moving_to`               | Reach a fixed world point (`MovingTo`, optional `non_blocking`) |
| `following`               | Legacy follow intent; dispatches no movement             |
| `stacking`                | Stand on a stack point (encounter)                       |
| `targeting`               | Select a GUID without attacking                          |
| `attacking`               | `CTM_ATTACK` on GUID                                      |
| `casting_scripted`        | Cast spell (optional target, `instant`/`one_shot` flags) |
| `casting_scripted_ground` | Ground-targeted cast (x/y/z)                             |
| `facing`                  | Set orientation                                          |
| `start_attack`/`stop_attack` | Toggle auto-attack                                    |
| `jump`                    | Jump in place                                            |
| `use_inventory_item`      | Use item slot                                            |
| `apply_poison`            | Apply weapon poison (item id)                            |
| `jump_near`               | Jump once within XY tolerance                            |
| `waiting_for`             | Hold until a `Predicate`                                 |
| `sequenced`               | Ordered list of `SimpleIntent` steps                     |

`SimpleIntent` mirrors `Intent` but cannot itself be `sequenced` (no recursion).

### 4.3 `IntentStore`

One slot per connected bot (`entries: [max_bots]?IntentEntry`). Methods:

- `replaceAt` — used by proposers each tick: equal priority **refreshes** in place; higher priority **preempts** and calls `dispatch_store.hardStop`; lower is rejected. A finished sequence is treated as replaceable.
- `replace(..., force)` — GUI / encounter install; `force=true` bypasses priority (also honors `cancellable_by_priority`).
- `clear` — reset to `idle(prio=0)` + `hardStop`.
- `clearByPriority(bot_id, priority, source, game_time_ms)` — reset to `idle(prio=0)` **only if** current priority matches; no `hardStop`. Used by `compute` when spec returns null (see §4.5).
- `pruneExpired` — drop intents past `max_age_ms` (skips in-flight non-instant confirms).
- `current` / `currentMut` — read / mutate the active intent.

### 4.4 Proposer pass (phase 1 of `compute`)

`computeWithProposers` runs, in order:

1. `clearPrepGatedEncounterIntents` if the fight has not started (drops encounter intents on prep-gated maps).
2. `intent_encounter.beginTick` — encounter-global state (Thaddius tank refresh, phase, Magnetic Pull) decided **once** per frozen snapshot.
3. For **each** bot, `proposeIntentsForBot`:
   - Dead bot → `intent_store.clear`, skip.
   - `intent_encounter.proposeIntent` — may install an encounter intent (writes forced targets into `TargetStore`).
   - **Target-loss handling:** if there is no primary target and no forced target, and the current intent is a target-scoped combat intent, record a target-loss action (`ctm_stop` / `stop_attack`) and clear the slot.
   - If a sequenced/confirming intent is in flight → **dispatch-locked**, return (role/spec/heal do not overwrite it).
   - `intent_tank_rescue.proposeIntent` (taunt to rescue) unless an encounter sequence is active.
   - `intent_tank_engage.proposeIntentForTarget` (pull/engage) unless already engaging or in an encounter sequence.
   - `intent_heal.proposeIntent` (healers only).
   - Otherwise `proposeRoleAndSpecIntents`: role first, then spec.
4. `intent_store.pruneExpired`.

```zig
// Priority order (low → high): idle < role < spec < encounter < operator
```

**Role vs spec arbitration** (`proposeRoleAndSpecIntents`): if the role intent **blocks spec** (`role.blocksSpec` — a blocking `moving_to`, or any `facing`), or needs a movement stop before auto-attack, the spec slot is cleared and only the role intent installs. Otherwise role installs and spec is allowed to refine it the same tick.

### 4.5 Spec slot eviction

When `intent_spec.proposeIntent` returns `null` (condition no longer holds — buff up, no target, etc.) and there is no in-flight spec confirm, `compute` calls `intent_store.clearByPriority(.spec)`. This resets the slot to `idle(prio=0)` so the role proposer can install on the next tick. Without this eviction, a stale `casting_scripted` intent would keep generating cast actions on every `DispatchStore` debounce expiry. The `max_age_ms` TTL on spec intents is a secondary safety net (see §8).

### 4.6 Sequenced intents

```zig
pub const Sequenced = struct {
    steps: [max_seq_steps]IntentSlot,   // max_seq_steps = 24
    len: u8,
    current: u8 = 0,
    step_dispatched: bool = false,      // must be true before advance
    step_started_at_ms: u32 = 0,
};
```

Each `IntentSlot` carries:

- `intent: SimpleIntent`
- `done_when: ?Predicate` — if null, the step completes after the first successful dispatch (instant steps).
- `trigger_once: ?StepTrigger` — fire a one-off action (e.g. `jump`) once a predicate holds, without ending the step.

Advancement: `intent_dispatch.advanceSequenced`, called from `resolveIntentAction` when **not** in `confirm.active` and the step is dispatched + complete. After a blocking step completes, `compute` advances **one tick later** (does not dispatch the next step in the same tick as confirm clear). `skipUnavailableSequenced` skips undispatched cast steps whose spell is on cooldown (except operator burst / raid-buff sources).

**Production example:** `encounters/thaddius/sequences.zig` — approach route, post-twin transition, opening holds.

---

## 5. Dispatch pass (phase 2 of `compute`)

`dispatchOrdersFromIntents` → `dispatchOrderForBot` picks **one** `Action` per bot per tick, runs gates, and maps it to a wire message. The per-bot order of operations:

1. Dead bot → clear, skip. Out-of-combat rogue poison maintenance (periodic `apply_poison`).
2. `resolveIntentAction` — the intent → `Action` for this tick (confirm-aware, see §5.1).
3. `applyTargetOverride` — if an encounter forced a target in `TargetStore`, retarget the action (unless polarity-transit / in-flight encounter sequence blocks it).
4. Target-loss action (`ctm_stop` / `stop_attack`) if flagged in phase 1.
5. Polarity-transit block (no new auto-attack while stacking on Thaddius).
6. **Threat mitigation:** if `threat_high` and an encounter intent is active, run the spec's `threat_plan` (e.g. Feign Death) through range + throttle.
7. **Threat gate:** `dispatch_store.threatBlocked` — clear spec/role start-attack and emit `stop_attack` when over the threat ceiling and the tank has not recovered aggro.
8. **Prep gate** (`combat.actionAllowedEncounterPrep`).
9. **Range gate** (`combat.dispatchRangeResult`).
10. **Pre-cast stop / pre-move stop-cast** — interrupt CTM before a cast, or interrupt a cast before a move.
11. **Throttle** (`dispatch_store.dispatchAllowed`).
12. **Facing gate** (`castFacingGate` — `set_facing` before a misaligned targeted cast).
13. **Role-start / anchor-chase stops** — toggle `stop_attack` when the engine starts an unwanted chase off an anchor.
14. `actionToMsg` → enqueue order; record throttle; `onDispatched` updates confirm; advance sequence if not confirming.

### 5.1 `actionForIntent` vs `actionWhileConfirming`

These are **not** two competing planners. They are two functions for **two phases** of the same command. Only one runs per tick.

|                          | `actionForIntent`                                  | `actionWhileConfirming`                                  |
| ------------------------ | -------------------------------------------------- | -------------------------------------------------------- |
| **File**                 | `intent/dispatch.zig`                              | `intent/confirm.zig`                                     |
| **When**                 | `confirm.active == false`                          | `confirm.active == true`                                 |
| **Question it answers**  | "Given the **intent**, what should we do **now**?" | "We **already sent** something; is it done, or adjust?"  |
| **Reads mainly**         | `ai.intent` (cast, sequenced step, …)              | `confirm.last_action`, `confirm.spell_phase`, spell events |
| **Typical result**       | New `move_to`, `cast`, `attack`, …                 | Often `.none` (wait), sometimes a retry / pending cast   |

**Rule in `brain` (`resolveIntentAction`):** if `confirm.active`, `actionForIntent` is **not** called.

```zig
// brain/mod.zig — resolveIntentAction, simplified
if (!confirm.active) { advanceSequenced(...); }
if (confirm.active) {
    if (actionWhileConfirming(...)) |held| return held;
    if (still confirm.active) return .none;     // hold this tick
    advanceSequenced(...); return .none;        // wait one tick before next step
}
return actionForIntent(ai, ctx, follow);
```

#### Why `confirm` exists

Minion `STATE` lags the order we just sent by ~one tick, and spell launches arrive as `SpellEvent`s. `onDispatched` sets `confirm.active = true` for actions that need a latency guard (`move_to`, casts, `jump_near_xy`, `ctm_stop`). Instant actions (`attack`, `start_attack`, `move_to_nb`, instant casts without a self-aura, …) clear confirm immediately.

#### What `actionWhileConfirming` does

1. **Pending cast** — a cast that needed a `ctm_stop` first: send stop, then the pending cast once CTM is idle.
2. **Spell confirm** (`tickSpellAction`) — for cast actions, watch `spell_events` for the bot's own `go` / `channel_end` / `failed` / `interrupted`, and target/self auras. Returns `complete` (clear), `pending` (hold), or `retry` (re-dispatch). A non-instant `go` is only accepted after a short grace window; `failed`/`interrupted` cancel the intent.
3. **Move liveness** — a `move_to` only completes after the engine reports motion then idle. A CTM the engine never acted on (issued mid-channel, or to a spot the bot already occupies) is detected via a move-start grace and either re-dispatched or completed.

`actionWhileConfirming` returning `null` means **hold this tick** (no wire message). That is normal, not a bug.

#### `actionForIntent` in one line per intent type

| Intent                     | Behavior                                                            |
| -------------------------- | ------------------------------------------------------------------ |
| `.idle` / `.following`     | `.none`                                                            |
| `.moving_to` / `.stacking` | `move_to` / `move_to_nb` if outside arrival radius, else `.none`   |
| `.targeting`               | `target_guid`                                                     |
| `.attacking`               | `attack`                                                          |
| `.casting_scripted`        | `cast` / `cast_target` / instant variants (self vs target)         |
| `.casting_scripted_ground` | `cast_ground`                                                     |
| `.facing`                  | `set_facing_rad`                                                  |
| `.jump_near`               | `jump_near_xy`                                                    |
| `.waiting_for`             | `ctm_stop` while CTM busy, else `.none`                            |
| `.sequenced`               | recurse into the **current** step's sub-intent                     |

---

## 5.2 `Action` (`combat/action.zig`)

Typed intermediate between intent and wire protocol:

- `cast`, `cast_instant`, `cast_target`, `cast_target_instant`, `cast_ground`
- `attack`, `target_guid`, `start_attack`, `stop_attack`, `stop_cast`, `clear_target`
- `set_facing_rad`, `interact`, `move_to`, `move_to_nb`, `jump`, `walk`, `jump_near_xy`
- `use_inventory_item`, `apply_poison`, `ctm_stop`, `none`

`move_to` / `move_to_nb` carry an `arrival_yards` (default `default_move_arrival_yards = 3.0`) so the confirm layer uses the same tolerance the dispatch layer applied.

### 5.3 Gates before send

| Gate          | Module                       | Blocks when                                                          |
| ------------- | ---------------------------- | -------------------------------------------------------------------- |
| Prep          | `prep_gate.zig`              | On prep maps (533) before **Start fight**, only OOC spells pass      |
| Threat        | `aggro.zig` + `DispatchStore`| DPS over the threat ceiling before the tank holds aggro              |
| Range         | `cast_range.zig`             | Target out of client spell range (`blocked_out_of_range`)            |
| Throttle      | `dispatch_store.zig`         | Same action class inside its debounce window                         |
| Facing        | `brain.castFacingGate`       | Targeted cast misaligned (> 0.25 rad) → `set_facing` first           |
| Pre-cast stop | `intent/confirm`             | Cast while CTM moving → `ctm_stop` first                             |
| Pre-move stop | `brain.needsPreMoveStopCast` | Move while casting/channeling → `stop_cast` first                    |

### 5.4 `actionToMsg` (`brain/action_msg.zig`)

Maps `Action` → `proto.MastermindMsg` (`ctm_move`, `cast_spell_guid`, `cast_spell_ground`, `set_target_guid`, `walk`, …). Some actions (`start_attack`, `stop_attack`, `stop_cast`, `clear_target`, `use_inventory_item`, `apply_poison`) are emitted as `lua_exec` strings. `jump_near_xy` yields **no message** until the bot is in XY range; `trackJumpNearWithoutMsg` still updates cancel state — do not confuse with `actionWhileConfirming` returning null.

---

## 6. `Confirm` struct and `onDispatched`

`ActiveIntent.confirm` is the memory of "we already fired a blocking command".

```zig
pub const Confirm = struct {
    active: bool = false,
    move_started: bool = false,    // move_to: saw CTM leave idle at least once
    cast_stop_sent: bool = false,
    last_action: Action = .none,   // what actionWhileConfirming waits on
    pending: ?Action = null,       // cast waiting for CTM stop first
    expected_spell_id: u32 = 0,    // spell-event correlation
    dispatched_at_ms: u32 = 0,     // grace / retry timing
    spell_phase: SpellPhase = .none, // .waiting_go | .waiting_channel_end
};
```

| After `onDispatched(action)`                                       | `confirm.active` next tick? |
| ------------------------------------------------------------------ | --------------------------- |
| Instant, no self-aura (`attack`, `start_attack`, `move_to_nb`, …)  | No — done in one tick       |
| `cast` / `cast_target` / instants with a self-aura                 | Yes — until a spell event / aura confirms |
| `move_to`, `jump_near_xy`                                          | Yes — until motion completes / re-dispatch |
| `ctm_stop`                                                         | Yes — until a settle window elapses |
| `ctm_stop` with `pending` set                                      | Yes — then the pending cast is sent |

**Not the same as `DispatchStore`:** debounce prevents spamming the *same* action class too often across ticks. `confirm` waits for the *client* (STATE or a spell event) to reflect the *current* command.

Key timing constants (`intent/confirm.zig`): `ctm_stop_settle_ms` (3 ticks), `non_instant_event_confirm_grace_ms` (2 ticks), `move_start_grace_ms` (4 ticks), `facing_complete_tolerance_rad = 0.1`.

---

## 7. Role layer (`proposers/role.zig`, `proposers/heal.zig`, `role.zig`)

### 7.1 `proposers/role.zig`

`proposeIntent` is the generic raid placement / auto-attack proposer at priority `.role`. It **does produce movement**: honoring `FollowStore` position anchors, it computes the desired position via `positioning.computeDesiredPos` and emits:

- `moving_to` (source `.role_stack`) when out of position,
- `set_facing` (source `.role_facing`) when at an authoritative anchor but out of melee,
- `start_attack` (source `.role_start_attack`) when in melee range at an anchor.

Healers and non-ranged casters return null (no auto-attack); ranged DPS auto-attack only when `profile == .ranged`. `blocksSpec` returns true for a blocking `moving_to` and for any `facing`. `explainDecision` feeds the arbitration trace.

Arrival constants: `melee_arrival_yards = 0.75`, `tank_reposition_slack_yards`, `ranged_arrival_yards`.

### 7.2 `proposers/heal.zig`

Healer-only. Priority order: tank emergency cooldown → raid emergency cooldown (Tranquility/Divine Hymn) → maintenance (shields/totems/beacon) → ranked heal from the spec's heal kit on `ctx.heal_priority`. All emit `.casting_scripted` at priority `.role`, source `.role_heal_move`. TTLs: `heal_intent_ttl_ms` (5 ticks), `emergency_cooldown_ttl_ms` (2 ticks).

### 7.3 `FollowStore` (`role.zig`)

Per-bot `FollowEntry`. The load-bearing field today is `position_override: ?PositionOverride` — an anchor (`x/y/z`, `arrival_yards = 1.5`, `authoritative`) that encounters set so the role proposer skips back-arc placement and stays put. `target_guid` / `last_ctm_x/y` / `attack_started` are legacy follow-FSM carryover not actively driving placement. Encounter movement uses explicit `.moving_to` / `.stacking` intents plus anchors, not a follow FSM.

`CombatRole = { tank, healer, melee_dps, ranged_dps }`; `RangeProfile = { melee, ranged, caster }`; `roleForSpec` / `profileForSpec` read `spec_registry.meta`.

---

## 8. Spec layer (`proposers/spec.zig`, `spec_routine.zig`, `specs/`)

- `spec_routine.planSpecRoutineWithContext` → `Action` from the spec kit (`specs/*.zig` via `specs/spec_registry.zig`).
- `intent_spec.proposeIntent` maps that action to an intent (`attacking`, `casting_scripted`, `moving_to`, `apply_poison`) at priority `.spec`, source `.spec_attack`.
- When `threat_high`, it instead returns the spec's `threat_plan` action (source `.spec_threat`) or null.
- Respects the prep gate; targeted casts that are out of client range return null so role placement can drive the bot into range.
- Blocked while `dispatch_locked` (in-flight sequenced encounter scripts).

**Spec intent lifetime:** all spec intents carry `max_age_ms = spec_intent_ttl_ms` (`spec_intent_stale_ticks = 5` × `proto.brain_tick_ms`). As long as the spec keeps proposing, `replaceAt` refreshes `created_at_ms` each tick, so the TTL never fires. The **primary** eviction is `clearByPriority` (§4.5). Keep the TTL as a backstop for the case where `proposeIntent` is skipped for several ticks (e.g. `threat_high`).

### 8.1 Tank engage / rescue (`proposers/tank_engage.zig`, `tank_rescue.zig`)

Both are tank-only `.spec` proposers, dispatched ahead of role/spec in `proposeIntentsForBot`:

- **tank_engage** — pull/engage. When the target is outside melee and the pull spell is off cooldown and within client pull range, emit a one-shot instant cast (source `.tank_engage`). On a fresh pull cooldown, emit an `.idle` hold so both tanks synchronize (`pull_transit_window_ms` = 5 ticks).
- **tank_rescue** — taunt to rescue. When `aggro.rescueCandidateForTank` flags a `.rescue` whose hostile is within taunt range and the taunt is ready, emit a one-shot instant taunt (source `.tank_rescue`, `rescue_intent_age_ms` = 5 ticks).

---

## 9. Encounter layer

### 9.1 Registry (`proposers/encounter.zig`)

```zig
pub const Encounter = struct {
    map_id: u32,
    beginTick: *const fn (bots, world, events, operator_fight_started, intent_store) void,
    proposeIntent: *const fn (ctx, targets: *TargetStore, follow: *FollowStore) ?ActiveIntent,
};
const registered = [_]Encounter{ thaddius };  // map_id 533
```

`beginTick` runs on every registered encounter unconditionally (encounter-global state once per snapshot). `proposeIntent` routes by `ctx.bot.state.map_id` to the first matching encounter. Add bosses: new `encounters/<name>/mod.zig` + a row in `registered`.

`encounters/mod.zig` holds shared map metadata only: `thaddius_map_id` (533), `mapUsesOperatorPrepGate`, and the `encounterTankOwner` aggro hook.

### 9.2 Thaddius (reference implementation)

| File                  | Role                                                                |
| --------------------- | ------------------------------------------------------------------- |
| `mod.zig`             | Encounter entry / facade; dispatch to tick + planner; aggro hook    |
| `tick.zig`            | Encounter-global per-tick state: roster/tank refresh, phase, swap   |
| `planner.zig`         | Per-bot phase router for intent proposals                           |
| `phase.zig`           | Phase detection (idle / twins / transition / thaddius)              |
| `twins.zig`           | Twin-platform phase planner                                         |
| `transition.zig`      | Post-twin jump/stack transition planner                             |
| `thaddius_phase.zig`  | Thaddius boss phase planner                                         |
| `sequences.zig`       | Builders for `Sequenced` intents + timing/HP constants              |
| `polarity.zig`        | Charge polarity detection + stack anchor overrides                  |
| `diagnostics.zig`     | Polarity charge / proximity logging                                 |
| `state.zig`           | Fight-global swap state + per-bot route/side flags                  |
| `arena.zig`           | Map-533 coordinates, stack points, arrival tolerances               |
| `predicates.zig`      | Polarity auras, alive/attackable predicates, encounter spell IDs    |
| `tank_owner.zig`      | Living-twin GUID → assigned side's tank                             |
| `roster.zig`          | Static name → side mapping                                          |
| `constants.zig`       | `map_id = 533`, names, arrival yards                                |
| `lifecycle.zig`       | Operator `onStartFight` hook (reset + seed routes)                  |
| `test_fixtures.zig`   | Shared test fixtures (no test blocks)                               |

**Thaddius swap invariants** (also in `CLAUDE.md`):

- Tank swap detection is global and atomic in `beginTick`, never per bot.
- Magnetic Pull `SpellEventKind.go` spell ID `54517` is the only swap signal; effect ID `30010` and legacy/variant IDs `28338` / `28339` are ignored.
- Duplicate launch events are deduplicated by `SpellEventStore` within one `proto.brain_tick_ms` window before encounter code runs.
- `target_guid` changes are never a swap fallback; `caster_guid` / `observer_guid` are diagnostics only.
- After Magnetic Pull: retarget the new twin, recenter on the new platform, then retarget again.

**GUI lifecycle** (`combat/mod.zig` → thaddius):

- `onStartFight` — reset state, `ctm_stop`, install per-bot approach route.
- `onCleanOrders` — stop, clear intents, clear anchors.
- `onTestJump` — force the post-twin transition intent (platform + stack).

---

## 10. `DispatchStore` (`dispatch_store.zig`)

Separate from intent confirmation:

- **Debounce:** after `recordDispatch`, the same `DispatchThrottleKey` is blocked until `game_time_ms + debounceMsForClass(class)`. Keys come from `dispatchThrottleKey(action)` in `dispatch.zig` (move quantized to 1-yard cells, facing radians ×1000, spell id, target guid). Blocking actions (`cast`, `move_to`, `jump_near_xy`) return no key — they are guarded by confirm instead.
- **Threat holds:** `threatBlocked` installs a per-bot hold while the bot is over the threat ceiling and the tank has not recovered aggro; `clearThreatHolds` wipes them when the fight is not running.
- **hardStop:** on intent preempt — block `move` / `attack` / `facing` / `start_attack` / `ctm_stop` / `clear_target` for `hard_stop_quiet_ms` (800 ms).

Debounce constants (`dispatch.zig`): `instant_cast_debounce_ms = 1500`, `move_debounce_ms = 300`, `facing_debounce_ms = 400`, `ctm_stop_debounce_ms = 400`, `start_attack`/`stop_attack`/`attack_guid` = 600, `target_guid` = 300, `use_item` = 1000, plus `walk` = 3 ticks.

---

## 11. Operator / GUI (combat buttons)

`gui/brain_dispatch.zig` (`dispatchGuiCommands`) handles operator atomics (not the ring buffer):

| Button           | Effect                                                |
| ---------------- | ----------------------------------------------------- |
| **Start fight**  | `is_fighting = true`, `combat.onStartFight`           |
| **Clean orders** | `is_fighting = false`, stop all, clear intents/anchors |
| **Reset fight**  | Clean + release-spirit / teleport / revive Lua        |
| **Test jump**    | Thaddius post-twin transition intent (dev)            |

Raid invites (**Start formation**, repl `reform`) live in `formation.zig` — not documented here.

---

## 12. File map (combat package)

```
combat/
├── mod.zig              Public API, GUI hooks, plan() tests
├── action.zig           Action union
├── context.zig          CombatContext
├── class_spec.zig       Class / Spec, talent → spec
├── dispatch.zig         Throttle keys + debounce constants
├── dispatch_store.zig   Per-bot debounce + threat holds
├── cast_range.zig       Client spell-range dispatch gate
├── spell_range.zig      Static spell-table lookups
├── prep_gate.zig        Pre-pull spell whitelist (map 533)
├── aggro.zig            Threat safety gate + rescue candidate
├── role.zig             CombatRole / RangeProfile, FollowStore
├── positioning.zig      Desired-position model
├── heal_select.zig      Heal-target ranking
├── target_store.zig     Per-bot forced target (rebuilt each pass)
├── world_query.zig      Scan lookups + hostile/friendly predicates
├── spec_routine.zig     planSpecRoutine
├── spells.zig           Spell IDs / names
├── intent/
│   ├── mod.zig          Intent types, IntentStore, Priority, Predicate
│   ├── dispatch.zig     actionForIntent, advanceSequenced
│   └── confirm.zig      Confirm + spell-event / latency guards
├── proposers/
│   ├── encounter.zig    Map → encounter router + Encounter registry
│   ├── role.zig         Role proposer (placement / auto-attack)
│   ├── heal.zig         Healer proposer
│   ├── spec.zig         Spec rotation → intent
│   ├── tank_engage.zig  Pull / engage proposer
│   └── tank_rescue.zig  Taunt-to-rescue proposer
├── specs/               Per-spec spell IDs + rotations + spec_registry.zig
└── encounters/
    ├── mod.zig          Map metadata + aggro hook
    └── thaddius/        Reference boss
```

**Brain integration:** `src/mastermind/brain/mod.zig` (`compute`, dispatch, gates) and `brain/action_msg.zig` (`actionToMsg`).

---

## 13. How to change behavior (checklists)

### Add a spell to a spec rotation

1. `combat/specs/<spec>.zig` — rotation logic.
2. `specs/spec_registry.zig` — register meta if a new spec.
3. Tests in the spec file or `brain` integration via `intent_spec` / `compute`.

Do **not** touch `brain/mod.zig` unless dispatch gates need changes.

### Add generic raid placement

Update the shared placement model — `positioning.zig` (desired position), `role.zig` (profile / anchor), `proposers/role.zig` (intent) — not class-specific branches in decision code (see the combat-troubleshooting rule in `CLAUDE.md`).

### Add a boss mechanic

1. `encounters/<boss>/state.zig` — per-bot / raid state.
2. `sequences.zig` — build `ActiveIntent` (prefer `sequenced` for multi-step).
3. `mod.zig` — top-level routing; split large phase planners into focused files.
4. Register in `proposers/encounter.zig` (and `mapUsesOperatorPrepGate` if prep-gated).
5. GUI hooks in `combat/mod.zig` if operator buttons are needed.

Prefer `Predicate` + `sequenced` over ad-hoc stores in `brain`.

### Add a new intent type

1. `intent/mod.zig` — tag + payload on `Intent` and `SimpleIntent`.
2. `intent/dispatch.zig` — `actionForIntent` + sequenced sub-dispatch.
3. `intent/confirm.zig` — if blocking / latency sensitive.
4. Proposer(s) that emit it.
5. Tests in `intent/dispatch.zig` or `brain/mod.zig`.

### Debug "bot does nothing"

1. `intent_store.current(bot_id)` — idle? preempted?
2. **`confirm.active`** — if true, `actionForIntent` is skipped; `actionWhileConfirming` returning `null` is normal for several ticks after `move_to` / cast.
3. `dispatch_store` — debounced? threat-held?
4. `threat_high` / prep gate / range gate?
5. Logs: `MASTERMIND_LOG_INTENT_PREEMPTIONS`, `MASTERMIND_LOG_COMBAT_DISPATCHES`, `MASTERMIND_LOG_COMBAT_ARBITRATIONS` (see §16).

---

## 14. Testing

```bash
zig build test -Dgui=false --summary all
```

**Test discovery:** tests in imported modules only run if `main.zig` (or `combat/mod.zig`) has `test { _ = @import("..."); }` transitively reaching the file.

**Brain tests** (`brain/compute_tests.zig`): build `BotSnapshot` / `WorldSnapshot` / `SpellEvent` literals, call `compute` (or `computeWithProposers` with stub proposers), assert on returned `Order`s.

**Pure tests:** build `CombatContext` literals and call `actionForIntent` / proposers / `actionWhileConfirming` directly.

---

## 15. LLM-oriented pitfalls

1. **Confusing `actionForIntent` and `actionWhileConfirming`** — mutually exclusive per tick; see §5.1.
2. **Assuming the role layer is passive** — it is not. `proposers/role.zig` produces `moving_to` / `facing` / `start_attack`. Fix placement in the shared model, not with class branches.
3. **`replaceAt` vs `replace(..., force)`** — GUI/encounter installs that must win use `force` or operator priority.
4. **Sequenced + role/spec** — dispatch-lock must stay true until the sequence finishes.
5. **`advanceSequenced` same tick as confirm clear** — intentional: wait one tick before the next step.
6. **`compute` now takes `events`** — pass the spell-event slice; confirm and Magnetic Pull depend on it.
7. **`zig build test` exit 0 with 0 tests** — add `_ = @import(...)` to the nearest `mod.zig` test block.
8. **Wire sizes** — use `proto.readWire` / `wireSize`, not `@sizeOf` on extern structs.
9. **Stale spec intent** — `casting_scripted` has no built-in completion; eviction is `clearByPriority` (spec proposes null) + `max_age_ms` TTL + spell-event confirm. Never remove these guards without a replacement.

---

## 16. Logging flags

Mastermind has separate environment flags so you can keep the signal you need without turning the whole pipeline noisy.

| Flag | Effect | Level |
| --- | --- | --- |
| `MASTERMIND_LOG_SPELLS=1` | Raw spell events received from minions (`spell_event:`) | `info` |
| `MASTERMIND_LOG_SPELL_LAUNCHES=1` | Orders accepted as spell launches (`brain: spell_launch ...`) | `info` |
| `MASTERMIND_LOG_COMBAT_DISPATCHES=1` | Combat dispatch / range diagnostics (`combat_dispatch`, `combat_range`) | `debug` |
| `MASTERMIND_LOG_COMBAT_DECISIONS=1` | Detailed combat decision traces (`combat_decision`) | `debug` |
| `MASTERMIND_LOG_INTENT_PREEMPTIONS=1` | Intent replacement / preemption traces (`intent: ... preempts ...`) | `debug` |
| `MASTERMIND_LOG_COMBAT_ARBITRATIONS=1` | Arbitration summary (`combat_arbitration`) | `info` |
| `MASTERMIND_LOG_COMBAT_SAMPLES=1` | Sample traces for combat reasoning | `debug` |
| `MASTERMIND_LOG_THREAT_TABLES=1` | Threat table dumps (`combat_threat`) | `info` |
| `MASTERMIND_LOG_POLARITY_CHARGES=1` | Map 533: one line per polarity charge pulse hit (who takes charge damage) | `info` |

Watch successful casts only:

```bash
MASTERMIND_LOG_SPELL_LAUNCHES=1
```

Add the internal reasoning:

```bash
MASTERMIND_LOG_INTENT_PREEMPTIONS=1 MASTERMIND_LOG_COMBAT_ARBITRATIONS=1 MASTERMIND_LOG_COMBAT_DISPATCHES=1
```

---

## 17. Glossary

| Term               | Meaning                                                                  |
| ------------------ | ------------------------------------------------------------------------ |
| **Intent**         | Persistent objective for a bot                                           |
| **Action**         | One logical command before wire encoding                                 |
| **Order**          | `{ bot_id, msg }` sent to one minion                                     |
| **CTM**            | Click-to-move (client navigation)                                        |
| **STATE**          | Minion → mastermind status frame (`protocol.State`)                      |
| **SCAN**           | Minion → mastermind object scan entry                                    |
| **SpellEvent**     | Parsed `SMSG_SPELL_*` packet relayed by a minion                         |
| **Preempt**        | Higher-priority intent replaces lower                                    |
| **hardStop**       | Brief dispatch suppression after preempt                                 |
| **confirm.active** | Waiting on client STATE / spell event after a blocking dispatch          |
| **anchor**         | `FollowStore.position_override` — a fixed encounter placement spot       |
