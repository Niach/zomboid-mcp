# Networking and sync

## The two channels

| direction | call | received by | notes |
|---|---|---|---|
| server → client | `sendServerCommand([player,] module, command, args)` | `Events.OnServerCommand.Add(function(module, command, args) end)` | with a player it goes to one client, without to everyone; a no-op in single player (same Lua state) |
| client → server | `sendClientCommand(player, module, command, args)` | `Events.OnClientCommand.Add(function(module, command, player, args) end)` | works in single player too (`SinglePlayerServer` fires the event) |

`args` is a **flat** table of strings, numbers and booleans. Nested data travels as a string (`"x,y,z;x,y,z"`, or JSON via
`ZMCPJson.encode` / `ZMCPClient` has `ZMCPJson` too). Keep each message under about 3 kB; split longer payloads into
`part` / `total` chunks and reassemble by id (the mod does this for code, textures and models).

The mod's own module is `zmcp`: `ZMCP.toClients(command, args[, player])` on the server sends a `zmcp` command and,
in single player, calls the client handler directly. Commands the client understands out of the box: `notify`, `halo`,
`chat`, `say`, `heal`, `cure`, `teleport`, `sprite`, `spriteRemove`, `draw`, `fall`, `capture`, `clear`, `ping`, `exec`.
On the client `ZMCPClient.send(command, args)` sends a `zmcp` command to the server (unknown ones are ignored there), so
use your **own module name** for a custom channel.

## A custom channel, both ways

```lua
-- server script "arena": receives scores from clients, broadcasts a round start
Arena = Arena or { handlers = {}, scores = {} }
local A = Arena
for ev, fn in pairs(A.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
A.handlers = {}
A.handlers.OnClientCommand = function(module, command, player, args)
    if module ~= "arena" then return end
    if command == "score" then
        A.scores[player:getUsername()] = tonumber(args.score) or 0
        ZMCP.event("arena_score", { user = player:getUsername(), score = args.score })
    end
end
for ev, fn in pairs(A.handlers) do Events[ev].Add(fn) end

function A.startRound(seconds)
    local msg = { seconds = seconds, at = ZMCP.now() }
    if isServer() then sendServerCommand("arena", "start", msg)
    elseif ArenaClient and ArenaClient.onStart then ArenaClient.onStart(msg) end   -- single player: same state
    ZMCP.toClients("notify", { text = "Round starts: " .. seconds .. " s", ttl = 4 })
end
return "arena installed"
```

```lua
-- sim: client
-- client script "arena": listens for the round, reports a score back
ArenaClient = ArenaClient or { handlers = {} }
local AC = ArenaClient
for ev, fn in pairs(AC.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
AC.handlers = {}
function AC.onStart(args) AC.roundEnds = ZMCPClient.now() + (tonumber(args.seconds) or 30) end
AC.handlers.OnServerCommand = function(module, command, args)
    if module == "arena" and command == "start" then AC.onStart(args) end
end
for ev, fn in pairs(AC.handlers) do Events[ev].Add(fn) end
ZMCPClient.off("arena")
ZMCPClient.on("arena", "render", function(ui)
    if AC.roundEnds then
        local left = math.max(0, AC.roundEnds - ZMCPClient.now())
        ui:drawTextCentre(string.format("%.0f s", left), getCore():getScreenWidth() / 2, 40, 1, 1, 0.3, 1, UIFont.Large)
    end
end)
function AC.report(score) sendClientCommand(getPlayer(), "arena", "score", { score = score }) end
return "arena client on"
```

Trigger the round from the MCP: `run_lua_server` with `Arena.startRound(60)`; watch `events_poll {kinds = ["arena_score"]}`.

## Late joiners and reconnects

When a client starts (`OnGameStart`) it sends `hello`; the server answers with every persistent thing in dependency order:
textures, models, client scripts, world sprites. So:

- `texture_upload`, `model_upload`, `script_install side=client` and `world_sprite` **without** `ttl` or `player` are
  persistent (stored in ModData + files on the server) and reach players who join later.
- `run_lua_client`, `overlay_draw`, `falling_items`, `server_message` and sprites with `ttl` or `player` are one-shot.
- A client script must therefore rebuild its own state from scratch when it runs (it will run again on reconnect), and
  a server script that owns a sequence should send the elapsed time so late clients are in phase.

## Results and events

- `run_lua_client` returns `{results = {user = {ok, value|error, ms}}, missing}` after the clients answer (timeout
  `timeout_s`). Client scripts report as `client_exec_result` events (`id = "script:<name>"`).
- `events_poll` streams `zmcp_events.log`: `client_texture`, `client_model`, `client_exec_result`, `script_error`,
  tool actions, `gap`, `bridge_loaded`, and whatever your scripts write with `ZMCP.event(kind, data)`.
- `visuals_list` shows connected clients with their mod version and what they loaded; `clients` is empty for players
  without the mod (they see none of the client-side visuals; `server_console "servermsg ..."` is the vanilla fallback).

## Sync facts verified on 42.21

- Server: `sq:transmitAddObjectToSquare(obj, -1)`, `transmitRemoveItemFromSquare(obj)`, `AddWorldInventoryItem`,
  `inv:AddItem` + `sendAddItemToContainer(inv, item)`, `addZombiesInOutfit`, `zed:Kill(p)`, `addVehicleDebug`,
  `v:repair()`, `part:setContainerContentAmount` + `v:transmitPartModData(part)`, the `transmitServer*` climate calls,
  `playServerSound`, `addXpNoMultiplier`, `setGodMod(on, true)` + `sendPlayerExtraInfo(p)`, `setTimeOfDay`: all synced.
- Client-authoritative: position, body damage and infection (a server-side cure was overwritten every second),
  appearance, stats. Send the change to that client (`run_lua_client {player}` or `ZMCP.toClients("heal", {}, p)`).
- `getOnlinePlayers()` works on the server; `getPlayerFromUsername` returned nil there: loop and compare usernames
  (`ZMCP.player(name)` does).
- `OnPlayerUpdate` / `OnZombieUpdate` do not fire on the dedicated server.
- `model_place` in multiplayer: the carrier item syncs, the model assignment (`setWorldStaticModel`) is unverified; the
  moving-entity layer is pure client side and needs no world sync.
