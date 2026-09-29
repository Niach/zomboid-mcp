# Server ↔ client protocol (module `zmcp`)

The server bridge talks to the Zomboid MCP client mod with `sendServerCommand([player,] "zmcp", command, args)`
(`ZMCP.toClients(command, args, player)` in `Bridge.lua`). The client receives it in `Events.OnServerCommand(module, command, args)`
with `module == "zmcp"`. In single player both sides share one Lua state and `ZMCPClient.onCommand(command, args)` is called directly.

Rules:
- `args` is a flat table: string, number and boolean values only (no nested tables). Chunk payloads above ~3000 characters.
- Commands addressed to one player are sent with the player argument; the client must not check the target itself.
- The client handler ignores unknown commands (forward compatibility) and never errors out of `OnServerCommand`.
- Every client-side action here is **client-authoritative**: the server only sends the request and cannot verify the outcome.
  Tools report `sent = true`; callers confirm with `player_info` / `status`.

## Commands sent by the game-side tools (ZOM-4)

### `teleport` (to one player)
Sent by the `teleport` tool. Move the local player to the given tile.

| arg | type | description |
| --- | --- | --- |
| `x` | number | target x (may be fractional) |
| `y` | number | target y |
| `z` | number | level (0 = ground) |

Expected client behaviour: `local p = getPlayer(); p:setX(x); p:setY(y); p:setZ(z); p:setLx(x); p:setLy(y); p:setLz(z)`
(leave a vehicle first if seated). Position syncs to the server through the normal player-update path.

### `message` (to everyone or one player)
Sent by the `server_message` tool.

| arg | type | description |
| --- | --- | --- |
| `text` | string | message text |
| `mode` | string | `halo` (floating text above the local player, `HaloTextHelper.addText`) or `chat` (a line in the chat panel) |
| `color` | string | optional `#rrggbb`; default white |

Expected client behaviour: `halo` → `HaloTextHelper.addText(getPlayer(), text, r, g, b)`;
`chat` → a line in `ISChat` (e.g. `ISChat.addLineInChat`) or a halo fallback if the chat API is unavailable.

### `appearance` (to one player)
Sent by the `set_appearance` tool **in addition to** the server-side change + `sendHumanVisual` (the server copy is
overwritten by the client if the client does not apply it too). Only the keys that changed are present.

| arg | type | description |
| --- | --- | --- |
| `hair` | string | hair model id (`getAllHairStyles`), `""` for none |
| `beard` | string | beard model id (`getAllBeardStyles`), `""` for none |
| `hair_color` | string | `#rrggbb` or `r,g,b` |
| `beard_color` | string | `#rrggbb` or `r,g,b` |
| `skin_color` | string | `#rrggbb` or `r,g,b` |

Expected client behaviour: apply to `getPlayer():getHumanVisual()` (`setHairModel`, `setBeardModel`, `setHairColor`,
`setBeardColor`, `setSkinColor` with `ImmutableColor.new(r, g, b)`), then `getPlayer():resetModelNextFrame()` and
`sendVisual(getPlayer())` so other clients and the server receive it.

## Commands owned by other issues
- `exec`, `hello`, chunking and late-join resend: ZOM-6 (client mod) / ZOM-1 (bridge).
- Visual commands (`overlay`, `texture`, `sprite`, `falling_items`, `clear`): ZOM-6.
