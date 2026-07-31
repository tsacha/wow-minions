# wow-minions

A raid-bot orchestrator for World of Warcraft 3.3.5a (WotLK, build 12340) private servers, written in Zig. One **mastermind** process drives a full 25-man raid of bot characters: login, raid formation, per-spec combat rotations, role behavior (tanking, healing, interrupts, positioning) and scripted boss encounters.

This is a hobby project built against a local MaNGOS-style server. It is meant for experimentation on a private server you run yourself — using it on official or public servers violates their terms of service.

## Videos

A full 25-bot Naxxramas Thaddius run, from client startup to the kill:

- [WoW - Thaddius 25 bots - Client starts](https://www.youtube.com/watch?v=eyMWZiTtyfQ)
- [WoW - Thaddius 25 bots - TP+Buff](https://www.youtube.com/watch?v=k_RMM3SXf6M)
- [WoW - Thaddius 25 bots - Combat 1](https://www.youtube.com/watch?v=YxVSgjBtMDo)
- [WoW - Thaddius 25 bots - Combat 2](https://www.youtube.com/watch?v=6bME2Xv3-Zk)

## How it works

Three independent processes:

```
launcher.exe  ──injects──►  minion.dll (inside WoW.exe)  ◄──TCP──►  mastermind (Zig, native)
                            (one DLL per WoW client; many clients per mastermind)
```

- **launcher** starts a WoW client suspended, injects `minion.dll` (embedded in the binary at compile time), then resumes it.
- **minion** is an in-process agent: it hooks `IDirect3DDevice9::EndScene` to execute game actions on the render thread, scans the object manager, hooks spell packets (`SMSG_SPELL_START` / `SMSG_SPELL_GO`), and talks to the mastermind over TCP.
- **mastermind** is a native Zig server (fiber-based, one connection per bot). Its brain ticks every ~67 ms: it snapshots all bot states, fuses their scans into a shared world view, decides an intent per bot (rotation, heal target, kick, position), and dispatches wire commands back.

WoW clients run fine under Wine (DXVK configs are included in `clients/templates/`), so the whole raid can run on a Linux host.

## Features

- Coordinates up to 25 bots from a single process.
- 22 spec rotations (`src/mastermind/combat/specs/`), from Protection Paladin to Affliction Warlock.
- Role logic shared across specs: tank engage, threat-gated DPS, heal-target ranking, interrupts, melee back-arc / ranged band positioning.
- Boss encounter scripts with their own positioning and mechanics — currently Naxxramas Thaddius (platform split, tank swap on Magnetic Pull, polarity sorting).
- Automatic login and raid formation (invites, groups) driven by a Lua FSM.
- Optional raylib GUI with a live map view of the raid.
- stdin REPL: send wire commands or paste GM commands / macros to one bot or the whole raid (see [`docs/repl.md`](docs/repl.md)).
- Optional Detour navmesh pathfinding (`-Dpathfinding=true`).

## Building

Requires **Zig 0.16+**. The GUI build also needs raylib.

```bash
zig build                    # everything: mastermind + minion.dll + launcher.exe (cross to x86-windows-gnu)
zig build -Dgui=false        # mastermind only, no raylib needed
zig build run-mastermind     # build + run the server
zig build test -Dgui=false --summary all
```

Useful options: `-Dexpansion=wotlk|tbc|classic` (wotlk is the default and the only fully supported target), `-Dmax-bots=N`, `-Dpathfinding=true`.

## Running

1. Start your 3.3.5a server and create the bot accounts.
2. `zig build run-mastermind` — listens on `127.0.0.1:9000`.
3. Launch the clients with `launch-client.py` (spawns N Wine clients from the templates in `clients/`) or run `zig-out/bin/launcher.exe` per client. Each minion connects, logs in, and enters the world; the formation FSM assembles the raid.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — process layout, minion internals, object manager scan, offsets.
- [`docs/wire-protocol.md`](docs/wire-protocol.md) — framing and message types between minion and mastermind.
- [`docs/mastermind-combat.md`](docs/mastermind-combat.md) — the combat brain: intents, proposers, stores, `brain.compute`.
- [`docs/repl.md`](docs/repl.md) — REPL command reference.
