# Architecture

Three independent processes:

```
launcher.exe  ──injects──►  minion.dll (inside WoW.exe)  ◄──TCP──►  mastermind (Zig, native)
                                       (one DLL per WoW client; many clients per mastermind)
```

**launcher** (`src/launcher/main.zig`): Starts WoW suspended, writes the embedded DLL to `C:\windows\SysWOW64\minion.dll`, injects via `CreateRemoteThread + LoadLibraryA`, resumes WoW. Reads the log named pipe and forwards it to stdout/`minion.log`.

The launcher **embeds** `minion.dll` via `@embedFile` at compile time. After every `zig build`, you must re-run `zig-out/bin/launcher.exe` — an old launcher binary always injects the old DLL.

**minion** (`src/minion/`): A Win32 DLL. `DllMain` spawns three threads on `DLL_PROCESS_ATTACH`:

- `monitorThread` — polls `update()` every 200ms: resolves ClientConnection → ObjectManager → local player object, stores in atomics (`world_object_manager`, `world_player_obj`)
- `hookThread` — hooks `IDirect3DDevice9::EndScene` (vtable slot 42) by patching the D3D9 vtable of a temporary device; all game-state writes (CTM, Lua exec, scan) must happen inside `myEndScene` on the render thread
- `controlThread` — TCP client to mastermind (port 9000); sends STATE frames every tick, dispatches incoming commands, drains the spell-event ring buffer

**mastermind** (`src/mastermind/`): Native Zig server. Uses `std.Io` fibers (cooperative coroutines) for concurrency: one fiber per bot connection (recv + send), one fiber for the brain coordinator. Listens on `127.0.0.1:9000`; many minions connect to a single mastermind. The brain plans one tick every `proto.brain_tick_ms` (≈67 ms).

## Minion file organization

```
offsets.zig       raw WoW memory addresses and offsets (constants only, no logic)
types.zig         shared types: structs, enums (CtmAction, Cmd, NetCmd…), fn pointer types, constants
log.zig           named-pipe logger: owns pipe_handle + mutex; init/deinit called by DllMain
inline_hook.zig   generic inline (prologue-patch) trampoline used to hook engine functions
world.zig         all game memory reads/writes; ObjectIterator; atomic world_player_obj / world_object_manager
ctm.zig           click-to-move operations (ctmMoveTo, ctmStop, ctmGuidAction, readCtmState)
hooks.zig         D3D9 EndScene hook; scheduleX() API for other threads; command dispatch on render thread
spell_packets.zig SMSG_SPELL_START / SMSG_SPELL_GO / channel packet hook → SpellEvent ring buffer
control.zig       TCP connection to mastermind; serialization; recvCommands → scheduleX
gameplay_log.zig  MINION_LOG_GAMEPLAY play-state recorder ([play] / [play:cast] lines)
main.zig          DllMain entry point; spawns the 3 threads; calls log_mod.init/deinit
```

**Layer rule:** only `world.zig` reads or writes raw game memory addresses. `ctm.zig`, `hooks.zig`, and `control.zig` go through `world.*` functions — they never call `world.readObject` / `world.writeObject` directly with an offset constant.

**Render-thread rule:** any write to game state (CTM, Lua execution, target GUID, scan) must happen inside `myEndScene`. Other threads call `hooks.scheduleX()` to queue work, then poll `hooks.pollXReady()` for the result.

## Object Manager Scan

The WoW object list is a **circular linked list**. Iteration terminates when:

- `next_ptr` is outside `[0x400000, 0x7F000000)` — mirrors wow-injector's `PTR_VALID`
- `next_ptr == object_manager` or `next_ptr == first_obj` — circular sentinel
- `next_ptr == obj` — self-loop
- `obj_type > 7` — end of real objects / corruption

`ObjectIterator.next()` returns `ObjRef { ptr, obj_type }` — the type comes from the iterator's own validated read to avoid a double-read race. Type-0 entries (WoW placeholder slots) are skipped silently inside the iterator.

GUIDs must be read as **u64** (not u32) — reading as u32 caused false matches during zone transitions.

## Key Offsets — WotLK 3.3.5a build 12340

All in `src/minion/offsets.zig`.

## References & Sources

Single source registry for reverse/memory work.

### Primary sources (prefer first)

- **Project offsets (`src/minion/offsets.zig`)** — canonical constants currently used by minion runtime.
- **Wowdev Wiki** — client formats/cache documentation:
  - [Main Page](https://wowdev.wiki/Main_Page)
  - [GameObjectCache.wdb](https://wowdev.wiki/GameObjectCache.wdb)
  - [DB/GameObjectDisplayInfo](https://wowdev.wiki/DB/GameObjectDisplayInfo)

### Community codebases (cross-check)

- **AzDeltaQQ/WotLKRotations** — 3.3.5a/12340 memory framework: [repo](https://github.com/AzDeltaQQ/WotLKRotations) · [offsets.py](https://raw.githubusercontent.com/AzDeltaQQ/WotLKRotations/main/offsets.py)
- **johnmoore/WoW-Object-Manager** — classic 3.3.5 object manager: [PlayerScan.cs](https://raw.githubusercontent.com/johnmoore/WoW-Object-Manager/master/WoWObjMgr/PlayerScan.cs)
- **Zz9uk3/WoW-3.3.5a-Bot** — broad 12340 bot codebase: [Offsets.cs](https://raw.githubusercontent.com/Zz9uk3/WoW-3.3.5a-Bot/master/AmeisenBot.Utilities/Offsets.cs)
- **Likon69/CopilotBuddyDocs** — Honorbuddy/Styx object API docs: [WoWObjects](https://github.com/Likon69/CopilotBuddyDocs/blob/master/api/namespaces/Styx/WoWInternals/WoWObjects.md)

### Evidence policy

- Treat forum posts as hints only until corroborated by at least one codebase or local runtime validation.
- Prefer data reproducible from local memory reads/logging over copied offset lists.

## Mastermind REPL

The `run-mastermind` binary reads stdin. Each line is parsed once and either dispatched as a wire command or pasted into the chat box on every bot (GM slashes, macros, `/say`, etc.). An optional `@<name>` prefix targets a single bot. Implementation: `src/mastermind/repl.zig` (parser) + the drain loop in `src/mastermind/brain/mod.zig`.

Recognized wire commands include `ctm_move`, `ctm_attack`, `ctm_interact`, `cast`, `cast_ground`, `face`, `walk`, `jump`, `ctm_stop`, and `lua`. The special command `reform` resets the formation FSM (restarts invites from the first bot). Everything else goes through `lineToLuaExecChat` → `ChatEdit_SendText` (e.g. `.additem 6948 1` gives every bot a Hearthstone). See [`docs/repl.md`](repl.md) for the full command list.
