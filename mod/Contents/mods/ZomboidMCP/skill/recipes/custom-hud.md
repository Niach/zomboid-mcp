# Custom HUD

A persistent client-side HUD: health bar, position, in-game time, zombies nearby, and a compass to a target tile.
Installed for everyone with `script_install side=client`; late joiners get it.

## Calls

```json
[
  {"tool": "script_install", "args": {"name": "hud", "side": "client", "code": "-- the script below"}},
  {"tool": "events_poll", "args": {"kinds": ["client_exec_result", "script_error"]}},
  {"tool": "script_list", "args": {}},
  {"tool": "script_remove", "args": {"name": "hud", "side": "client"}}
]
```

## The script (client)

```lua
-- sim: client
-- client script "hud": bottom-left panel; re-runnable; removed by script_remove (hooks are named "hud")
local NAME = "hud"
ZMCPClient.off(NAME)
Hud = Hud or {}
Hud.target = Hud.target or { x = 6408, y = 5502 }      -- compass target; change with run_lua_client: Hud.target = {...}
local cache = { zombies = 0, at = 0 }
ZMCPClient.on(NAME, "tick", function(now)
    if now - cache.at < 1 then return end               -- count once a second, not every frame
    cache.at = now
    local p = getPlayer()
    if not p then return end
    local n = 0
    local cell, px, py, pz = getCell(), math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
    for dx = -10, 10 do
        for dy = -10, 10 do
            local sq = cell:getGridSquare(px + dx, py + dy, pz)
            if sq then
                local mo = sq:getMovingObjects()
                for i = 0, mo:size() - 1 do
                    if instanceof(mo:get(i), "IsoZombie") then n = n + 1 end
                end
            end
        end
    end
    cache.zombies = n
end)
ZMCPClient.on(NAME, "render", function(ui)
    local p = getPlayer()
    if not p then return end
    local sw, sh = ZMCPClient.screen()
    local x, y, w, h = 16, sh - 120, 240, 104
    ui:drawRect(x, y, w, h, 0.55, 0, 0, 0)
    ui:drawRectBorder(x, y, w, h, 0.8, 0.9, 0.9, 0.9)
    local hp = p:getBodyDamage():getOverallBodyHealth() / 100
    ui:drawText("Health", x + 10, y + 6, 1, 1, 1, 1, UIFont.Small)
    ui:drawRect(x + 10, y + 24, w - 20, 10, 1, 0.25, 0.25, 0.25)
    ui:drawRect(x + 10, y + 24, (w - 20) * hp, 10, 1, 1 - hp, hp, 0.15)
    local gt = getGameTime()
    local hour = gt:getTimeOfDay()
    ui:drawText(string.format("Day %d  %02d:%02d", gt:getDay() + 1, math.floor(hour), math.floor((hour % 1) * 60)),
        x + 10, y + 40, 1, 1, 0.8, 1, UIFont.Small)
    ui:drawText(string.format("%.0f, %.0f  zombies: %d", p:getX(), p:getY(), cache.zombies), x + 10, y + 58, 1, 1, 1, 1, UIFont.Small)
    -- compass: an arrow from the panel towards the target tile (screen-space direction)
    local tx, ty = Hud.target.x, Hud.target.y
    local dxs = isoToScreenX(0, tx, ty, 0) - isoToScreenX(0, p:getX(), p:getY(), p:getZ())
    local dys = isoToScreenY(0, tx, ty, 0) - isoToScreenY(0, p:getX(), p:getY(), p:getZ())
    local len = math.sqrt(dxs * dxs + dys * dys)
    if len > 1 then
        local cx, cy = x + w - 30, y + 80
        ui:drawLine2(cx, cy, cx + dxs / len * 18, cy + dys / len * 18, 1, 1, 0.8, 0.1)
        ui:drawText(string.format("%.0f tiles", math.sqrt((tx - p:getX()) ^ 2 + (ty - p:getY()) ^ 2)), x + 10, y + 76, 1, 1, 0.8, 0.1, UIFont.Small)
    end
end)
return "hud on"
```

- The zombie count runs in `tick` once a second (a 21×21 scan per frame would be too much); `render` only draws.
- Change the target for everyone: `run_lua_client {code = "Hud.target = {x = 6500, y = 5400} return true"}`.
- Server-driven values (scores, objectives): send them with `ZMCP.toClients("draw", ...)` or a custom
  `sendServerCommand` channel the HUD listens to (`guides/networking-and-sync.md`).
