# Mastermind REPL

While running, the mastermind exposes a REPL on stdin (`mastermind> `). Each line
is parsed once and either dispatched as a wire command or pasted into WoW's chat
box via Lua. By default a command is **broadcast** to every connected bot; an
optional `@<name>` prefix targets a single bot.

Implementation: `src/mastermind/repl.zig` (parser) + the drain loop in
`src/mastermind/brain/mod.zig`.

## Targeting a single bot

Prefix any line with `@<name>` to address one bot. `<name>` is a
case-insensitive **prefix** match against the bot id or the player name; the
first match wins. A bare `@` (followed by whitespace) falls back to broadcast.

```
@Sangboulon ctm_move 1234.5 567.8 90.0
@mage1 cast 12345
ctm_stop                      # no prefix → broadcast to all bots
```

If no bot matches the name, the line is dropped with a warning.

## Wire commands

Sent directly to the minion(s) as `MastermindMsg` frames, without going through
WoW's chat box.

| Command | Example |
|---|---|
| `ctm_stop` | `ctm_stop` |
| `jump` | `jump` |
| `ctm_move <x> <y> <z>` | `ctm_move 1234.5 567.8 90.0` |
| `ctm_attack <guid_hex>` | `ctm_attack 0xF130004B2A` |
| `ctm_interact <guid_hex>` | `ctm_interact 0xF130004B2A` |
| `cast <spell_id>` | `cast 48817` |
| `cast <spell_id> <guid_hex>` | `cast 48817 0xF130004B2A` |
| `cast_ground <spell_id> <x> <y> <z>` | `cast_ground 42208 1234.5 567.8 90.0` |
| `face <radians>` | `face 3.14` |
| `walk <dir> <ms>` | `walk backward 2000` |
| `lua <code>` | `lua SendChatMessage("hi")` |

Valid directions for `walk`: `forward`, `backward`, `strafe_left`,
`strafe_right`.

`lua <code>` sends a `lua_exec` frame directly (the code runs verbatim in the
client), as opposed to the chat-box fallback below.

## Special commands

| Command | Effect |
|---|---|
| `reform` | Reset the formation FSM (restarts invites from the first bot) |
| *(anything else)* | Pasted into WoW's chat box via Lua (GM commands, slash commands, …) |

Any line that is not a recognized wire command and is not `reform` is escaped
into a Lua snippet that types it into the default chat edit box and presses
enter (`lineToLuaExecChat` → `ChatEdit_SendText`). This is how GM slashes reach
the server.

GM example: typing `.additem 19019 1` goes through the chat box and runs the
command server-side. With targeting: `@Lumibarbe .additem 21177 800`.

Lines starting with `#` are treated as comments and ignored, so setup scripts
can be pasted with section headers.
