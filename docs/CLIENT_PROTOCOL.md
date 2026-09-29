# Zomboid MCP client protocol (server ⇄ client mod)

Companion to `docs/PROTOCOL.md` (MCP ⇄ server bridge). This is the command protocol between the server
(`Api/Visuals.lua`, plus any tool that calls `ZMCP.toClients`) and the client mod
(`client/ZomboidMCP/Client.lua` and its submodules). Every player with the Workshop mod runs the client.

## Transport

- **Server → client:** `sendServerCommand([player,] "zmcp", command, args)`, received by
  `Events.OnServerCommand(module, command, args)`. `ZMCP.toClients(command, args, player)` wraps it and, in
  single player (same Lua state, `sendServerCommand` is a no-op), calls `ZMCPClient.onCommand` directly.
- **Client → server:** `sendClientCommand(player, "zmcp", command, args)`, received by
  `Events.OnClientCommand(module, command, player, args)` (`ZMCP.visuals.onClientCommand`). This also
  works in single player (`SinglePlayerServer` fires the event).
- `args` is a flat table of strings, numbers and booleans. Nested data travels as a string (`"x,y,z;x,y,z"`
  paths, `"x,y,z,delay,dur;..."` drop lists, JSON for pixel-sprite definitions).
- Messages are kept under ~3 KB: long payloads (code, base64) are split into `part`/`total` chunks and
  reassembled by `id` on the client. The server sends at most `ZMCP.visuals.PER_TICK` (12) messages per
  tick through a FIFO queue, so ordering is preserved (textures before sprites on a resend).

## Client → server

| command | args | when |
|---|---|---|
| `hello` | `{version}` | `OnGameStart`. The server answers with every registered texture, client module and world sprite (late join / reconnect). Logged as event `client_hello`. |
| `execResult` | `{id, ok, res, ms, module?}` | after every `exec` chunk set ran (`res` = the return value, tables JSON-encoded, or the error; ≤ 4000 chars). Event `client_exec_result`; `client_results {id}` shows `{to, results, pending, done}`. |
| `texResult` | `{id, gen, ok, w?, h?, bytes?, err?}` | after a texture was written and loaded (or failed). Event `client_texture`. |
| `fileResult` | `{id, gen, path, ok, bytes?, err?}` | after a `file` push was written. Event `client_file`. |
| `modelResult` | `{id, gen, name, ok, err?}` | after a `model` registration. Event `client_model`. |
| `pong` | `{version, sprites, textures}` | answer to `ping` (`clients_list` sends one). Event `client_pong`. |

## Server → client

| command | args | effect |
|---|---|---|
| `exec` | `{id, part, total, code, module?}` | chunked Lua. When all parts are in: `loadstring`, `pcall`, reply `execResult`. With `module`, the source is kept in `ZMCPClient.modules[name]` (persistent client module). |
| `modRemove` | `{name}` | forget a client module and drop every hook registered under `name` (`ZMCPClient.off(name)`). |
| `file` | `{id, gen, part, total, data, path}` | base64 chunks of any file → `~/Zomboid/Lua/<path>` (parent dirs are created; `..` refused). Reply `fileResult`. |
| `model` | `{id, gen, mesh, texture, scale}` | runtime 3D model: once both files (`mesh` = `media/….x`, `texture` = `media/….png`, relative to the Lua dir) are present, `ModelScript.new()` + `setModule(Base)` + `InitLoadPP` + `Load` + `addModelScript` under the name `zmcp_<id>_<gen>`; `ZMCPClient.models.name(id)` returns it. Reply `modelResult`. |
| `capture` | `{on}` | screen apps: the overlay consumes mouse events and is brought to the top (`on`), or is released (click-through, `backMost`). |
| `tex` | `{id, gen, part, total, data}` | base64 PNG chunk. Complete → decoded (pure Lua, arithmetic only) into `~/Zomboid/Lua/zmcp_tex_<id>_<gen>.png` via `getFileOutput`, loaded with `getTexture(absolutePath)`. New generation = new file name because textures are cached by path. Reply `texResult`. |
| `pixel` | `{id, def}` | fallback art: `def` = JSON `{w, h, palette = {a = [r,g,b,a]}, rows = ["aab.", ...]}`, drawn with `drawRect`. Usable wherever a texture id is. |
| `sprite` | `{id, tex, x, y, z, scale?, tiles?, path?, speed?, loop?, bob?, bobHz?, flip?, opacity?, ttl?, fade?, anchor?}` | create/replace a world sprite (see below). |
| `spriteRemove` | `{id?}` | remove one sprite, or all without `id`. |
| `fall` | `{id, item, items, scale?, tex?}` | falling item icons; `items` = `"x,y,z,delay,dur;..."` (target tile, seconds until the drop starts, fall duration). Visual only: the server spawns the real items. |
| `draw` | `{id?, kind, anchor, x, y, z?, x2?, y2?, z2?, w?, h?, r?, g?, b?, a?, ttl?, text?, font?, centre?, fill?, thick?, tex?, flip?}` | overlay primitive: `line`, `rect`, `text`, `texture`; `anchor` = `screen` (px, negative = from right/bottom) or `world` (tiles; sizes in px at zoom 1). `ttl` seconds, absent = until cleared. |
| `notify` | `{text, ttl?, r?, g?, b?, font?}` | message box at the top of the screen (stacked, fades). |
| `halo` | `{text, r?, g?, b?, time?}` | `setHaloNote` on the local player (overhead text). |
| `say` | `{text}` | speech bubble on the local player. |
| `heal` | `{}` | client-authoritative: every body part `RestoreToFullHealth`, stiffness cleared, pain/panic/stress/fatigue/hunger/thirst reset, `sendPlayerStatsChange`. |
| `cure` | `{}` | client-authoritative: zombie infection and wound infection cleared on every body part and on `BodyDamage`. |
| `teleport` | `{x, y, z?}` | `player:teleportTo` (position is client-authoritative in MP). |
| `clear` | `{what?, id?}` | `all` (sprites, overlays, drops, notices, every script hook, capture off), `sprites`, `draw`, `fall`, `notices`, `textures` (forget loaded textures; files stay), `hooks` (one name with `id`, or all). |
| `ping` | `{}` | reply `pong`. |

Unknown commands are logged and ignored. Every handler runs under `pcall`; a failing handler never breaks
the next one. Other server modules (guardian, players) reuse `heal`, `cure`, `teleport`, `halo`, `notify`
through `ZMCP.toClients(cmd, args, player)`.

## Rendering

- One full-screen `ISUIElement` (`ZMCPOverlay`) with `setConsumeMouseEvents(false)` is added to the UI
  manager and sent `backMost()` on `OnGameStart`: it draws above the world and below the vanilla UI, and
  clicks pass through. Its `render` draws, in order: world sprites, falling items, overlay primitives and
  notices, then every `ZMCPClient.renderHooks[name](ui)` registered by pushed code (a hook that errors is
  removed and logged).
- **World sprites** are drawn bottom-centre at `isoToScreenX/Y(0, x, y, z)`, always on top (owner
  preference, no occlusion), ordered by `z` then `x + y` so southern sprites overlap northern ones.
  Size: `scale` multiplies the texture's pixel size at zoom 1, or `tiles` gives the width in world tiles
  (64 px at zoom 1); both are divided by `getCore():getZoom(0)`.
  Motion: `path` waypoints (from `x,y,z`) walked at `speed` tiles/s with `loop` = `loop` | `pingpong` |
  `once`; `bob` px hop (`bobHz`); `flip` = `auto` (mirror when moving left on screen), `0`, `1`;
  `opacity`, `ttl` (seconds; a sprite with a ttl is not persisted for late joiners), `fade` (in/out seconds),
  `anchor` = `bottom` | `center`.
- **Textures** for sprites/draws are resolved through `ZMCPClient.tex.get(ref)`: an uploaded id, a pixel
  sprite id, `item:Base.Banana` (inventory icon via `instanceItem`), or any vanilla texture name/path
  accepted by `getTexture`.
- **Falling items** use the item's inventory icon (`item:<type>`), a quadratic drop from 700 px (at zoom
  1) with a growing shadow, one small bounce and a fade while the real item appears.

## Server-side registry (Api/Visuals.lua)

`ModData "ZomboidMCP".visuals = { textures = {id → {file, gen, chars} | {pixel = json}}, sprites = {id → args},
cmodules = {name → {file}} }`. Only metadata is stored; texture data lives in `zmcp_tex_<id>.b64` and client
module sources in `zmcp_cmod_<name>.lua` in the Lua cache dir, read and streamed on demand (server heap).

`models = {id → {meshSrc, texSrc, gen, scale, mesh, texture}}` is in the same table; `.x`/`.png` base64 stays in
`zmcp_model_<id>.x.b64` / `zmcp_model_<id>.png.b64`.

Tools: `run_lua_client` (alias `client_exec`), `client_results`, `clients_list`, `capture_input`,
`module_client_install/remove/list`, `texture_upload`, `texture_pixel`, `texture_list`, `texture_remove`,
`model_upload`, `model_list`, `model_remove`, `model_place` (static carrier item + `setWorldStaticModel`),
`world_sprite`, `world_sprite_remove`, `world_sprite_list`, `falling_items`, `overlay_draw`, `overlay_clear`,
`clear_visuals`, `notify`, `halo`, `visuals_status` (descriptions in `tools_list`).

Model upload flow: `base64 -w0 star.x > <LuaDir>/zmcp_model_star.x.b64`, `base64 -w0 star.png >
<LuaDir>/zmcp_model_star.png.b64`, `model_upload {id: star, scale: 3}` → clients write
`Lua/media/zmcp_model_star_<gen>.x/.png` and register `zmcp_star_<gen>`; then `model_place {id: star, x, y, z}`
or a script doing `item:setWorldStaticModel(ZMCPClient.models.name("star"))`. Late joiners get the files and
the registration on `hello` (textures → models → modules → sprites). Moving 3D entities are ZOM-11.

Texture upload flow for the MCP: `base64 -w0 art.png > <LuaDir>/zmcp_tex_<id>.b64`, then
`texture_upload {id}`; watch `client_texture` events for `ok`. Then `world_sprite {id, texture: <id>, ...}`.

## Pushed code (run_lua_client / client modules)

`run_lua_client {code, player?, id?}` (alias `client_exec`) chunks the code, sends it as `exec`, and returns
`{id, to}`; every recipient answers with `execResult`. `client_results {id}` returns
`{to, results = {user = {ok, res, ms}}, pending, done}`, so the MCP polls until `done`. Per-script ids are
either given (`id`) or generated (`c<n>`); persistent modules use `mod:<name>`.

The chunk runs on every client with these globals: `ZMCPClient`, `ZMCPJson` and the vanilla client API.
Return a string, number or table (tables are JSON-encoded) and it comes back in the result.

Hook registry for scripts (ClientInput.lua):
```lua
ZMCPClient.on("flappy", "render", function(ui) ui:drawRect(x, y, w, h, a, r, g, b) end)
ZMCPClient.on("flappy", "tick", function(now) ... end)          -- every game tick, now in seconds
ZMCPClient.on("flappy", "keyDown", function(key) ... end)       -- OnKeyStartPressed; "keyUp" = release, "keyHeld"
ZMCPClient.on("flappy", "mouseDown", function(x, y, button) end) -- "mouseUp", "mouseMove"(x, y, dx, dy), "mouseWheel"(delta)
ZMCPClient.capture(true)     -- screen app: the overlay swallows the mouse and sits above the UI; capture(false) releases
ZMCPClient.off("flappy")     -- remove every hook of that name (module_client_remove and clear hooks do this)
ZMCPClient.input.keyDown(key), ZMCPClient.input.mouse()   -- polling: isKeyDown, getMouseX/Y, buttons
ZMCPClient.screen(), ZMCPClient.zoom(), ZMCPClient.player(), ZMCPClient.now(), ZMCPClient.send(cmd, args)
ZMCPClient.tex.get(ref), ZMCPClient.tex.draw(ui, entry, x, y, w, h, alpha, flip), ZMCPClient.sprites, ZMCPClient.draw, ZMCPClient.models.name(id)
```
A hook that throws is removed after the first error and logged once (never every frame). Keyboard hooks
fire regardless of capture; the game's own keybinds still fire too, so prefer keys the game does not use.
Convention for persistent modules: register hooks under the module name so `module_client_remove` drops them.

## Dev loop

- Single player: `dev/bundle_sp.sh [test.lua]` concatenates the whole mod (shared + server + client) into
  `~/Zomboid/Lua/zmcp_dev_exec.lua` for the `dev/ZMCPDev` watcher; then drive it with
  `dev/zmcp_local.py call <tool> '<json>'` (request files in `~/Zomboid/Lua`). The game only runs Lua while
  it is focused (single player pauses when unfocused).
- Offline: `dev/test_sim.py` runs the same files under a standalone Lua 5.1 (`pip install lupa`) with mocked
  engine globals (`dev/sim_prelude.lua`) and exercises the whole path: hello, texture chunks → PNG file →
  texture, sprites, falling items and landings, exec round trip, late-join resend, request files.
  `dev/luacheck.py` is the syntax check.
