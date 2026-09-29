# Server ↔ client commands (module `zmcp`)

> ZOM-1 documents the MCP ↔ server file protocol in its own `docs/PROTOCOL.md` section set; this file covers the
> commands the server sends to the Zomboid MCP client mod (ZOM-6). Merge both into one document when the branches meet.

The server bridge talks to the client mod with `sendServerCommand([player,] "zmcp", command, args)`
(`ZMCP.toClients(command, args, player)` in `Bridge.lua`). The client receives it in
`Events.OnServerCommand(module, command, args)` with `module == "zmcp"`. In single player both sides share one Lua
state and `ZMCPClient.onCommand(command, args)` is called directly.

Rules:
- `args` is a flat table: string, number and boolean values only. Chunk payloads above ~3000 characters.
- Commands addressed to one player are sent with the player argument; the client does not filter by target.
- The client handler ignores unknown commands (forward compatibility) and never lets an error escape `OnServerCommand`.
- Every client-side action is **client-authoritative**: the server only sends the request and cannot verify the
  outcome. Tools report `sent = true`; callers confirm with `player_info` / `status`.

## `teleport` (to one player)
Sent by the `teleport` tool. Move the local player to the given tile.

| arg | type | description |
| --- | --- | --- |
| `x` | number | target x (may be fractional) |
| `y` | number | target y |
| `z` | number | level (0 = ground) |

Expected client behaviour (see `docs/recipes/teleport.md`):
```lua
local p = getPlayer()
if p:getVehicle() then p:getVehicle():exit(p) end
p:setX(x); p:setY(y); p:setZ(z)
p:setLx(x); p:setLy(y); p:setLz(z)
```

## `message` (to everyone or one player) — optional
Not sent by any curated tool (messages are a scripting recipe, `docs/recipes/server_message.md`), but cheap to support:

| arg | type | description |
| --- | --- | --- |
| `text` | string | message text |
| `mode` | string | `halo` (floating text above the local player) or `chat` (a chat line) |
| `color` | string | optional `#rrggbb`; default white |

Expected client behaviour: `halo` → `HaloTextHelper.addText(getPlayer(), text, "", r, g, b)`; `chat` → a line in
`ISChat`, falling back to halo.

## Commands owned by other issues
- `exec`, `hello`, chunking and late-join resend: ZOM-6 (client mod) / ZOM-1 (bridge).
- Visual commands (overlays, textures, world sprites, 3D objects, falling items): ZOM-6 and the visuals issues.
