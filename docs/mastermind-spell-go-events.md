# Spell packet events

The minion hooks the WotLK spell packet handler, parses cast/launch/channel
packets into `proto.SpellEvent` values, and streams them to the mastermind,
where they feed both encounter mechanics and per-cast confirmation. This
document describes the pipeline as implemented.

## Packet hook (minion)

The handler at `0x0080FEE0` is hooked via an inline prologue patch
(`src/minion/inline_hook.zig`). The parsing lives in
`src/minion/spell_packets.zig`.

Validated details:

- Handler signature:

  ```zig
  fn handler(param_1: u32, opcode: u32, param_3: u32, store: *anyopaque) callconv(.c) u32
  ```

- `opcode == 0x131` is `SMSG_SPELL_START`, `opcode == 0x132` is `SMSG_SPELL_GO`.
- The safe inline patch length for the current prologue is 9 bytes:

  ```asm
  0080fee0 55                 push ebp
  0080fee1 8b ec              mov ebp, esp
  0080fee3 81 ec 7c 01 00 00  sub esp, 0x17c
  ```

- `CDataStore` must be read from its current read position, not from the start
  of `m_buffer`.
- The hook is installed by default by the minion hook thread; text logging is
  gated behind `MINION_LOG_SPELLS=1`.

`SMSG_SPELL_START` payload:

```text
PackedGuid cast_item
PackedGuid caster
u8 cast_count
u32 spell_id
u32 flags
u32 timer_ms
```

`SMSG_SPELL_GO` payload:

```text
PackedGuid cast_item
PackedGuid caster
u8 extra_casts
u32 spell_id
u32 flags
u32 timestamp_ms
```

The hook does **no** socket I/O — it parses into a native ring buffer. The
control thread drains that buffer after `sendState` / `sendScan` and sends one
`.spell_event` frame per event.

## Wire shape

`MinionMsg.spell_event = 0x03`. The payload is `proto.SpellEvent` (36 bytes,
asserted at comptime in `protocol.zig`):

```zig
pub const SpellEventKind = enum(u8) {
    start = 1,           // SMSG_SPELL_START (opcode 0x131)
    go = 2,              // SMSG_SPELL_GO    (opcode 0x132)
    failed = 3,
    interrupted = 4,
    channel_update = 5,
    channel_end = 6,
};

pub const SpellEvent = extern struct {
    kind: u8,
    _pad: [3]u8,
    observer_guid: u64,
    caster_guid: u64,
    spell_id: u32,
    flags: u32,      // spell flags (start/go), failure code (failed), 0 otherwise
    value_ms: u32,   // timer (start), server timestamp (go), remaining channel ms (channel_update)
    game_time_ms: u32,
};
```

`observer_guid` is the bot that observed the packet; `caster_guid` is the
casting unit. `game_time_ms` is the local client time from `readMsTime()`.

## SpellEventStore (mastermind)

`connection.zig` parses incoming `.spell_event` frames and pushes them into a
shared `SpellEventStore` (`src/mastermind/world/spell_events.zig`). The store:

- holds a fixed-size ring buffer (`capacity = 4096`) behind a short `std.Io.Mutex`
  section, mirroring `WorldMemory`;
- deduplicates launch events within `launch_duplicate_window_ms` (2 ×
  `proto.brain_tick_ms`) so each `start` / `go` is seen once per planning window;
- prunes events older than `event_ttl_ns` (5 s) on push and on the periodic
  brain prune;
- exposes `snapshot(io, out)` for the brain tick.

`brain.run` snapshots spell events alongside bots/world and passes the slice
into combat compute:

```zig
const event_n = spell_events.snapshot(io, &event_buf);
const events = event_buf[0..event_n];
compute(bots, world, events, ...);
```

`compute()` stays pure: frozen bot/world/event snapshots in, orders out.

## Consumers

### Boss mechanics

Encounter code matches recent events by `spell_id` (primary) with `caster_guid`
as supporting context — some scripted boss casts use unexpected caster GUIDs.
The canonical example is Thaddius' Magnetic Pull, detected only from
`SpellEventKind.go` with spell ID `54517` (see [`CLAUDE.md`](../CLAUDE.md), the
Thaddius swap rule).

### Action confirmation

`combat/intent/confirm.zig` consumes the same snapshot to confirm a bot's own
casts: `start` confirms a non-instant cast began, `go` confirms launch,
`failed` / `interrupted` cancel the intent, and `channel_update` /`channel_end`
drive channelled spells. This is snapshot input to the pure compute pass, not a
connection-time callback.

## Diagnostics

| Flag | Side | Effect |
| --- | --- | --- |
| `MINION_LOG_SPELLS=1` | minion | One line per parsed packet event |
| `MASTERMIND_LOG_SPELLS=1` | mastermind | One line per event received from any minion |
