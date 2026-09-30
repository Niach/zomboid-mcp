# Merchant actor

A passive zombie in a Trader outfit who stands at a spot, faces players who come close, greets them, and trades: give
it a "banana" (drop one on its square) and it hands you a can of beans. Server-side script; nothing to install on
clients. The scene SDK issue turns this into a scene with `spawnActor`, `actor:say`, `onPlayerNear` and choice
dialogs ([guides/scenes-and-apps.md](../guides/scenes-and-apps.md), [examples/scenes](../../../../../../examples/scenes) in the repo); this version uses the raw engine.

## Calls

```json
[
  {"tool": "players_list", "args": {}},
  {"tool": "script_install", "args": {"name": "merchant", "side": "server", "code": "-- the script below"}},
  {"tool": "events_poll", "args": {"kinds": ["merchant", "script_error"]}},
  {"tool": "world_query", "args": {"x": 6405, "y": 5500, "z": 0, "radius": 3, "what": "zombies"}},
  {"tool": "script_remove", "args": {"name": "merchant", "side": "server"}}
]
```

## The script (server)

```lua
-- server script "merchant": passive trader zombie at a fixed spot; re-runnable; Merchant.stop() cleans up
Merchant = Merchant or {}
local M = Merchant
if M.stop then M.stop() end
M.pos = { x = 6405, y = 5500, z = 0 }
M.greeted = {}

local function spawn()
    local sq = getCell():getGridSquare(M.pos.x, M.pos.y, M.pos.z)
    if not sq then return nil end
    local list = addZombiesInOutfit(M.pos.x, M.pos.y, M.pos.z, 1, "Trader", 0)
    local zed = list:get(0)
    zed:setUseless(true)
    zed:setTarget(nil)
    zed:getModData().actor = "merchant"
    ZMCP.event("merchant", { spawned = zed:getID() })
    return zed
end

local function trade(zed, p)
    local sq = zed:getCurrentSquare()
    if not sq then return end
    local wos = sq:getWorldObjects()
    for i = wos:size() - 1, 0, -1 do
        local wo = wos:get(i)
        local it = wo:getItem()
        if it and it:getFullType() == "Base.Banana" then
            sq:removeWorldObject(wo)
            local inv = p:getInventory()
            local beans = inv:AddItem("Base.CannedBeans")
            sendAddItemToContainer(inv, beans)
            zed:Say("A fine banana. Beans for you, friend.")
            ZMCP.event("merchant", { trade = p:getUsername() })
            return
        end
    end
end

M.zed = spawn()
ZMCP.tickHooks.merchant = function(t)
    if not M.zed or M.zed:isDead() then M.zed = spawn(); return end
    if t - (M.last or 0) < 1 then return end
    M.last = t
    local zed = M.zed
    for _, p in ipairs(ZMCP.players()) do
        local d = math.sqrt((p:getX() - zed:getX()) ^ 2 + (p:getY() - zed:getY()) ^ 2)
        if d < 4 then
            zed:faceLocation(p:getX(), p:getY())
            if not M.greeted[p:getUsername()] then
                M.greeted[p:getUsername()] = true
                zed:Say("Welcome, " .. p:getUsername() .. ". Drop a banana at my feet and I trade beans for it.")
            end
            trade(zed, p)
        elseif d > 12 then
            M.greeted[p:getUsername()] = nil       -- greet again next time
        end
    end
end

function M.stop()
    ZMCP.tickHooks.merchant = nil
    if M.zed then pcall(function() M.zed:removeFromWorld() end) end
    M.zed = nil
end
return "merchant open for business"
```

- The zombie is a real zombie with `setUseless(true)`: players can still hit it. `setAvoidDamage(true)` (index) makes
  it take no damage; `setHealth(999)` is the blunt alternative.
- The population system may despawn it when nobody is near; the tick hook re-spawns it.
- Stop: `run_lua_server` `Merchant.stop()` and then `script_remove {name = "merchant"}`.
- Talking back: players "answer" by actions (dropping items, standing close). For real dialog choices push a client
  script with buttons (`ISButton`, `guides/2d-overlays-and-apps.md`) that `sendClientCommand`s the choice.
