# Wire Protocol

Source of truth: `src/protocol/protocol.zig` (compile-time `assertWireSize` blocks lock the byte sizes). A machine-readable layout is emitted to [`src/protocol/generated/wire_layout.json`](../src/protocol/generated/wire_layout.json) via `zig build gen-protocol` (see [`tools/gen_wire_manifest/main.zig`](../tools/gen_wire_manifest/main.zig)). Python helpers can load that file — see [`src/protocol/wire_layout.py`](../src/protocol/wire_layout.py). A tiny TCP listener that prints incoming STATE lines: [`examples/wire_protocol_demo.py`](../examples/wire_protocol_demo.py).

After changing wire types or framing, run `zig build gen-protocol` and commit the updated `wire_layout.json`. CI fails on drift (`scripts/check-protocol-artifact.sh`).

Framing: `[u32 big-endian length][u8 type][payload (little-endian fields)]`. `length` includes the type byte, so payload size = length − 1. Use `frame_length_size` (4) / `frame_header_size` (5) instead of magic offsets.

**Minion → Mastermind** (`MinionMsg`): `0x00` STATE, `0x01` SCAN, `0x02` LUA_RESULT, `0x03` SPELL_EVENT

**Mastermind → Minion** (`NetCmd`): `0x00` LUA_EXEC, `0x01` CTM_MOVE (3×f32), `0x02` LUA_GET, `0x03` CTM_INTERACT_GUID (u64), `0x04` CTM_ATTACK_GUID (u64), `0x05` CAST_SPELL_ID (u32), `0x06` CAST_SPELL_GUID (u32 spell_id + u64 target_guid), `0x07` JUMP (u8), `0x08` CTM_STOP (no body), `0x09` SET_FACING (f32), `0x0a` WALK (u8 dir + u32 duration_ms), `0x0b` SET_TARGET_GUID (u64), `0x0c` CAST_SPELL_GROUND (u32 spell_id + 3×f32 world position)

Wire sizes (asserted at comptime in `protocol.zig`; also under `constants` in `wire_layout.json`):

- `State` — 9548 B
- `ScanEntry` — 1424 B
- `AuraEntry` — 20 B
- `CooldownEntry` — 16 B
- `SpellRangeEntry` — 8 B
- `ThreatEntry` — 12 B
- `SpellEvent` — 36 B
- `TotemSlot` — 4 B
- `MastermindMsg` (union wire footprint, tag + largest variant) — 257 B

Use `proto.readWire(T, buf)` / `proto.writeWire(T, val, buf)` / `proto.wireSize(T)` — never `@sizeOf(T)` (extern padding differs from the wire layout).

## Spell events (`MinionMsg.spell_event`, 0x03)

`SpellEvent` (36 B) carries parsed `SMSG_SPELL_*` packet events from a minion to the mastermind. `kind` is a `SpellEventKind`: `start` (1), `go` (2), `failed` (3), `interrupted` (4), `channel_update` (5), `channel_end` (6). `observer_guid` is the bot that saw the packet; `caster_guid` is the unit that cast. `flags` and `value_ms` are packet-specific (cast/channel timer for `start`, server timestamp for `go`, remaining channel ms for `channel_update`, failure code for `failed`). `game_time_ms` is the local client time at observation. See [`docs/mastermind-spell-go-events.md`](mastermind-spell-go-events.md) for the parser and the mastermind-side `SpellEventStore`.
