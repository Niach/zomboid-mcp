-- Haunted house: a PERSISTENT installation. The area is remembered (snapshotArea) so a teardown can put it back,
-- eerie lights burn every night, and whenever a player enters the house a haunting sequence plays: lights flicker,
-- a whisper, a ghost drifts through, a shambling "resident" appears and vanishes. Re-runs for every visit with a
-- cooldown; ambience only runs while someone is near (cheap on an empty server).
-- Start: scene_start {name = "haunted", persistent = true, code = <this file>, args = {x, y, z, w, h, cooldown}}
-- Stop:  scene_stop {name = "haunted"}  -> the area is restored from the snapshot, lights and puppets go away.
-- Args: x, y = north-west corner of the house (default: 5 tiles north of the first player), w, h = size in tiles
--   (default 6x6), z = floor (default 0), cooldown = seconds between hauntings (default 90).
local cfg = args or {}
local w, h, z = cfg.w or 6, cfg.h or 6, cfg.z or 0
local cooldown = cfg.cooldown or 90

waitUntil(function() return #players() > 0 end)
local x, y = cfg.x, cfg.y
if not x then
    local p = players()[1]
    x, y = math.floor(p:getX()) - 3, math.floor(p:getY()) - 8
end
local cx, cy = x + w / 2, y + h / 2
waitUntil(function() return loaded(x, y, z) and loaded(x + w, y + h, z) end)

-- first run ever: remember what the area looked like; the snapshot id lives in the saved state
if not state.snapshot then
    state.snapshot = snapshotArea(x, y, x + w, y + h, z)
    state.built = false
    log("area remembered in", state.snapshot)
end
-- permanent decoration, placed once (server-authoritative tiles, saved with the world)
if not state.built then
    placeTile("graffiti_01_3", x, y + h + 1, z, "Warning")       -- a mark in front of the door
    state.built = true
end
state.hauntings = state.hauntings or 0

-- permanent lights: lamppost lights are not saved by the engine, so a persistent scene re-adds them on every start
local lamps = {
    light(x + 1, y + 1, z, 0.9, 0.2, 0.9, 5),
    light(x + w - 1, y + h - 1, z, 0.2, 0.9, 0.3, 5),
}

local ghostTex = texture("ghost_px", {
    palette = { w = { 235, 235, 255, 200 }, e = { 20, 20, 40, 255 } },
    rows = { "..wwww..", ".wwwwww.", "wwewwe.w", "wwwwwwww", "wwwwwwww", "wwwwwwww", "w.ww.ww.", "........" },
})

-- ambience while somebody is within 25 tiles: a creak, a groan, a flicker
ambient(cx, cy, 25, 20, function()
    local pick = random(3)
    if pick == 1 then sound("WoodDoorOpen", x + 2, y + h, z)
    elseif pick == 2 then sound("ZombieSurprisedPlayer", cx, cy, z)
    else
        for _, l in ipairs(lamps) do l.remove() end
        wait(0.4)
        lamps[1] = light(x + 1, y + 1, z, 0.9, 0.2, 0.9, 5)
        lamps[2] = light(x + w - 1, y + h - 1, z, 0.2, 0.9, 0.3, 5)
    end
end)

-- the haunting: whenever a player is inside the house (re-arms when they leave, at most every `cooldown` seconds)
trigger("visit", function()
    for _, p in ipairs(players()) do
        local px, py = p:getX(), p:getY()
        if px >= x and px <= x + w and py >= y and py <= y + h and math.floor(p:getZ()) == z then return p end
    end
end, function(player)
    state.hauntings = state.hauntings + 1
    log("haunting #" .. state.hauntings .. " for", name(player))
    say(player, "...did you hear that?")
    local red = light(cx, cy, z, 1, 0.1, 0.1, 8)
    sound("HouseAlarm", nil, nil, nil, player)
    wait(2)
    red.remove()
    -- the ghost drifts across the room, twice, then fades
    local ghost = spriteActor{ texture = ghostTex, x = x + 1, y = y + h - 1, z = z, tiles = 1.2, bob = 12, bobHz = 0.6, opacity = 0.8 }
    ghost:bubble("leave...", 3)
    ghost:moveTo(x + w - 1, y + 1, { duration = 4 })
    ghost:moveTo(x + 1, y + 1, { duration = 3 })
    ghost:fade(0, 1.5)
    ghost:remove()
    -- the resident: a passive zombie who shuffles to the visitor, whispers and is gone
    local ok, resident = try(spawnActor, { kind = "zombie", outfit = "Ghillie", x = x + 1, y = y + 1, z = z, name = "Resident", passive = true })
    if ok then
        resident:say("You are not welcome here.")
        resident:walkTo(player:getX(), player:getY(), { dist = 2, timeout = 12 })
        resident:say("Get out.")
        lightning(cx, cy, { strike = false })
        wait(1)
        resident:remove()
    end
    say(player, "I should not be here.")
end, { cooldown = cooldown, interval = 0.5 })

-- teardown: scene_stop restores the area from the snapshot (lights and sprites are removed automatically)
onStop(function(reason)
    if reason == "scene_stop" and state.snapshot then
        local ok, res = try(restoreArea, state.snapshot)
        log("restore:", ok and (res.removed .. " removed, " .. res.added .. " added") or tostring(res))
        state.built = false
    end
end)
log("haunted house armed at", x, y, "hauntings so far:", state.hauntings)
