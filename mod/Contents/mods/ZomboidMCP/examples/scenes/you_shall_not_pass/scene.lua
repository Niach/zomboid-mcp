-- "You shall not pass": a PERMANENT installation and a re-triggerable cutscene, built only with the scene SDK,
-- the curated tools and eight runtime 3D models (examples/scenes/you_shall_not_pass/, make_art.py generates them).
--
-- The hall: a dark cavern (invisible walls + rock pillars) whose floor is a lava lake (flat lava-slab models, red
-- lights). A narrow stone bridge crosses it one level up: real floor tiles at z+1 on stone piers, reached by stairs
-- at both ends, with invisible rails so nobody falls (args.rails = false leaves the edges open: a fall lands in the
-- lava lake one level down, which is walkable, so nobody gets stuck). The grey wizard stands guard on the bridge;
-- the fire demon waits half sunk in the lava at the far end. Every world change is a saved, transmitted object
-- (floors, stairs, blockers, carrier items of the models); models, lights and the entities come back on every
-- start and every join through the mod's persistence.
--
-- The cutscene (whenever a player steps onto the bridge, at most every args.cooldown seconds): letterbox bars,
-- thunder, the demon rises out of the lava and flies at the wizard, the wizard raises the staff, a flash, the
-- title, the piers under the demon crack, the demon falls back into the deep, the wizard lowers the staff.
--
-- Start (after the eight model_upload calls, see README.md):
--   scene_start {name = "ysnp", persistent = true, code = <this file>, args = {x, y, z, length, cooldown, face, rails, level}}
-- Signals: scene_signal {name = "ysnp", signal = "play"} runs the cutscene now; signal "teardown" removes
-- everything and restores the area (the default is to keep it: scene_stop only stops the ambience).
-- Args: x, y = the WEST end of the bridge deck (default: 10 tiles north of the first player), z = ground level (0),
--   length = bridge length in tiles (14), cooldown = seconds between cutscenes (180), face = rotation of the flat
--   models towards the camera in degrees (45), rails = invisible rails along the deck (true), level = 1 builds the
--   bridge one floor up with stairs (default); level = 0 is the flat fallback (deck on the ground, chasm blocked).
local cfg = args or {}
local L = math.max(6, math.floor(tonumber(cfg.length) or 14))
local cooldown = tonumber(cfg.cooldown) or 180
local face = tonumber(cfg.face) or 45
local rails = cfg.rails ~= false and cfg.rails ~= "false"
local deckUp = not (cfg.level == 0 or cfg.level == "0")
local DECK_FLOOR = cfg.deck_floor or "floors_exterior_tilesandstone_01_0"
local HALL_FLOOR = cfg.hall_floor or "floors_burnt_01_0"
local STAIRS = { "fixtures_stairs_01_8", "fixtures_stairs_01_9", "fixtures_stairs_01_10" }   -- bottom, middle, top (up towards north)
local MODELS = { "ysnp_pier", "ysnp_pier_broken", "ysnp_rock", "ysnp_stalagmite", "ysnp_lava", "ysnp_demon", "ysnp_wizard", "ysnp_wizard_up" }

waitUntil(function() return #players() > 0 end)
local xs, y0, z = cfg.x, cfg.y, math.floor(tonumber(cfg.z) or 0)
if not xs then
    local p = players()[1]
    xs, y0 = math.floor(p:getX()) - math.floor(L / 2), math.floor(p:getY()) - 10
end
xs, y0 = math.floor(xs), math.floor(y0)
local xe = xs + L - 1
local deckZ = deckUp and z + 1 or z
local hall = { x1 = xs - 3, x2 = xe + 3, y1 = y0 - 4, y2 = y0 + 4 }
local lava = { x1 = xs + 1, x2 = xe - 1 }
local cx, cy = (xs + xe) / 2, y0 + 0.5
local wizX = xs + math.floor(L * 0.4)
state.runs = state.runs or 0
state.steps = state.steps or {}

-- the eight models must have been uploaded (model_upload keeps them for every restart and every join)
for _, id in ipairs(MODELS) do
    if not ZMCP.visuals.store().models[id] then
        error("model '" .. id .. "' is not uploaded: model_upload {id = '" .. id .. "', mesh_path = 'examples/scenes/you_shall_not_pass/art/" .. id .. ".x', png_path = ...} first (README.md)")
    end
end

waitUntil(function()
    return loaded(hall.x1 - 1, hall.y1 - 1, z) and loaded(hall.x2 + 1, hall.y2 + 1, z) and loaded(hall.x1 - 1, hall.y2 + 1, z) and loaded(hall.x2 + 1, hall.y1 - 1, z)
end)

---------------------------------------------------------------- building blocks (each idempotent, recorded in state.steps)
local function step(key, fn)
    if state.steps[key] then return end
    local ok, err = pcall(fn)
    if not ok then log("build step " .. key .. " failed: " .. tostring(err)); return end
    state.steps[key] = true
    log("built " .. key)
end

-- a floor tile the vanilla way (IsoGridSquare:addFloor replaces the floor object; transmitted to clients)
local function floor(x, y, fz, sprite)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, fz)
    if not sq then sq = cell:createNewGridSquare(x, y, fz, true) end
    if not sq then error("no square at " .. x .. "," .. y .. "," .. fz) end
    local obj = sq:addFloor(sprite)
    if obj then pcall(function() obj:transmitCompleteItemToClients() end) end
    pcall(function() sq:RecalcAllWithNeighbours(true) end)
    return obj
end

local function ensureSquare(x, y, fz)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, fz)
    if not sq then sq = cell:createNewGridSquare(x, y, fz, true) end
    return sq
end

local function blockers(x, y, bz, w, h, kind, label)
    return tool("collision_place", { x = x, y = y, z = bz, w = w, h = h, kind = kind, name = "ysnp:" .. label })
end

local function place(model, pid, x, y, pz, opts)
    opts = opts or {}
    local a = { id = model, pid = pid, x = x, y = y, z = pz, ox = opts.ox or 0.5, oy = opts.oy or 0.5, oz = opts.oz or 0, collide = opts.collide or "false" }
    if opts.yrot then a.yrot = opts.yrot end
    return tool("model_place", a)
end

-- the model placements, deterministic ids so a teardown and a re-run find them
local piers, slabs, rocks, stals = {}, {}, {}, {}
for x = lava.x1, lava.x2 do piers[#piers + 1] = { pid = "ysnp_pier_" .. (x - xs), x = x, y = y0 } end
for sx = lava.x1 + 1, lava.x2, 3 do
    for sy = hall.y1 + 1, hall.y2, 3 do slabs[#slabs + 1] = { pid = "ysnp_lava_" .. (sx - xs) .. "_" .. (sy - y0), x = math.min(sx, lava.x2), y = sy } end
end
for x = hall.x1 - 1, hall.x2 + 1, 3 do
    rocks[#rocks + 1] = { pid = "ysnp_rock_n" .. (x - xs), x = x, y = hall.y1 - 1 }
    if x < xs - 2 or (x > xs and x < xe) or x > xe + 2 then rocks[#rocks + 1] = { pid = "ysnp_rock_s" .. (x - xs), x = x, y = hall.y2 + 1 } end
end
for y = hall.y1 + 2, hall.y2 - 1, 3 do
    rocks[#rocks + 1] = { pid = "ysnp_rock_w" .. (y - y0), x = hall.x1 - 1, y = y }
    rocks[#rocks + 1] = { pid = "ysnp_rock_e" .. (y - y0), x = hall.x2 + 1, y = y }
end
for i = 1, 5 do
    local x = lava.x1 + math.floor((i - 0.5) * (lava.x2 - lava.x1) / 5)
    stals[#stals + 1] = { pid = "ysnp_stal_" .. i, x = x, y = (i % 2 == 0) and (y0 - 3) or (y0 + 3) }
end

if not state.built then
    step("snapshot", function() state.snapshot = snapshotArea(hall.x1 - 1, hall.y1 - 1, hall.x2 + 1, hall.y2 + 1, z) end)
    step("hall_floor", function()
        for x = hall.x1, hall.x2 do for y = hall.y1, hall.y2 do floor(x, y, z, HALL_FLOOR) end end
    end)
    step("lava", function()
        for _, s in ipairs(slabs) do place("ysnp_lava", s.pid, s.x, s.y, z, { oz = 0.02 }) end
    end)
    step("stalagmites", function()
        for _, s in ipairs(stals) do place("ysnp_stalagmite", s.pid, s.x, s.y, z) end
    end)
    step("piers", function()
        for _, p in ipairs(piers) do place("ysnp_pier", p.pid, p.x, p.y, z) end
    end)
    if deckUp then
        step("deck", function()
            for x = xs - 1, xe + 1 do for y = y0 - 1, y0 + 1 do ensureSquare(x, y, deckZ) end end
            for x = xs, xe do floor(x, y0, deckZ, DECK_FLOOR) end
        end)
        step("stairs", function()
            for _, sx in ipairs({ xs, xe }) do
                for i, sprite in ipairs(STAIRS) do placeTile(sprite, sx, y0 + 4 - i, z, "ysnp_stairs") end   -- y0+3 bottom .. y0+1 top
                pcall(function() square(sx, y0, deckZ):RecalcAllWithNeighbours(true) end)
            end
        end)
        if rails then
            step("rails", function()
                blockers(xs, y0, deckZ, L, 1, "wall_n", "rail-north")
                blockers(xs + 1, y0 + 1, deckZ, L - 2, 1, "wall_n", "rail-south")
                blockers(xs, y0, deckZ, 1, 1, "wall_w", "rail-west")
                blockers(xe + 1, y0, deckZ, 1, 1, "wall_w", "rail-east")
            end)
        end
    else
        step("deck", function() for x = xs, xe do floor(x, y0, z, DECK_FLOOR) end end)
        step("chasm", function()
            blockers(lava.x1, hall.y1, z, lava.x2 - lava.x1 + 1, y0 - hall.y1, "solidtrans", "chasm-north")
            blockers(lava.x1, y0 + 1, z, lava.x2 - lava.x1 + 1, hall.y2 - y0, "solidtrans", "chasm-south")
        end)
    end
    step("walls", function()
        local w, h = hall.x2 - hall.x1 + 1, hall.y2 - hall.y1 + 1
        blockers(hall.x1, hall.y1, z, w, 1, "wall_n", "wall-north")
        blockers(hall.x1, hall.y1, z, 1, h, "wall_w", "wall-west")
        blockers(hall.x2 + 1, hall.y1, z, 1, h, "wall_w", "wall-east")
        blockers(xs + 1, hall.y2 + 1, z, L - 2, 1, "wall_n", "wall-south")     -- the landings stay open to the south
    end)
    step("rocks", function()
        for _, r in ipairs(rocks) do place("ysnp_rock", r.pid, r.x, r.y, z, { collide = "solid", yrot = 0 }) end
    end)
    state.built = true
    log("hall built: bridge " .. xs .. ".." .. xe .. " at y " .. y0 .. " level " .. deckZ)
end

---------------------------------------------------------------- lights and the two figures (render state: every start)
local glow = {}                       -- { x, y, z, h = light handle }: the lava glow, pulsed by the ambience
for i = 0, 3 do
    local gx = lava.x1 + 1 + math.floor(i * (lava.x2 - lava.x1 - 2) / 3)
    glow[#glow + 1] = { x = gx, y = y0 - 2, z = z, h = light(gx, y0 - 2, z, 1, 0.35, 0.05, 8) }
    glow[#glow + 1] = { x = gx, y = y0 + 2, z = z, h = light(gx, y0 + 2, z, 1, 0.3, 0.05, 8) }
end
light(wizX, y0, deckZ, 0.75, 0.85, 1, 4)     -- a cold light on the wizard

local function entity(id, model, x, y, ez, h, extra)
    pcall(tool, "entity3d_remove", { id = id })
    local a = { id = id, model = model, x = x, y = y, z = ez, h = h, ry = face }
    for k, v in pairs(extra or {}) do a[k] = v end
    return tool("entity3d_spawn", a)
end
local DEMON_X = xe - 1.5
local function demonIdle() entity("ysnp_demon", "ysnp_demon", DEMON_X, cy, z, -1.6) end
local function wizard(raised) entity("ysnp_wizard", raised and "ysnp_wizard_up" or "ysnp_wizard", wizX + 0.5, cy, deckZ, 0) end
wizard(false)
demonIdle()

local ember = texture("ysnp_ember", { palette = { o = { 255, 170, 40, 230 }, y = { 255, 240, 140, 255 } }, rows = { ".o.", "oyo", ".o." } })
local function embers(n, x, y, ez, spread)
    for _ = 1, n do
        local ex, ey = x + random(-spread, spread), y + random(-spread, spread)
        sprite{ texture = ember, x = ex, y = ey, z = ez, tiles = 0.18, ttl = 2.5, fade = 0.8, bob = 6, bobHz = 1.5,
            path = { { ex + random(-0.5, 0.5), ey - 0.6, ez + 0.5 } }, speed = 0.5, loop = "once", opacity = 0.9 }
    end
end

-- idle ambience only while somebody is within 35 tiles
ambient(cx, cy, 35, 2.5, function(n)
    embers(2, random(lava.x1, lava.x2), random(hall.y1 + 1, hall.y2 - 1), z, 0.5)
    if n % 3 == 0 then
        local l = glow[random(#glow)]
        l.h.remove()
        l.h = light(l.x, l.y, l.z, 1, 0.3 + random(0, 0.15), 0.05, 6 + random(0, 3))
    end
    if n % 24 == 0 then sound("ZombieThumpGeneric", DEMON_X, cy, z) end
end)

---------------------------------------------------------------- the cutscene
local playing = false
local function cutscene(player)
    if playing then return end
    playing = true
    state.runs = state.runs + 1
    local who = player and name(player) or "signal"
    log("cutscene #" .. state.runs .. " for " .. who)
    local bars = 36
    draw{ kind = "rect", anchor = "screen", id = "ysnp_bar_top", x = 0, y = 0, w = 10000, h = 110, r = 0, g = 0, b = 0, a = 1, ttl = bars }
    draw{ kind = "rect", anchor = "screen", id = "ysnp_bar_bot", x = 0, y = -110, w = 10000, h = 110, r = 0, g = 0, b = 0, a = 1, ttl = bars }
    sound("Thunder", DEMON_X, cy, z)
    lightning(DEMON_X, cy, { strike = false })
    local deep = light(DEMON_X, cy, z, 1, 0.2, 0, 12)
    wait(1.5)
    -- the demon rises out of the lava (its feet end up a little above the deck) and flies at the wizard
    local hover = deckUp and 1.63 or 0.63
    tool("entity3d_move", { id = "ysnp_demon", x = DEMON_X, y = cy, z = z + hover, duration = 5, ease = true })
    local burst = every(0.4, function()
        local ex = tool("entity3d_list")
        for _, e in ipairs(ex) do if e.id == "ysnp_demon" then embers(3, e.x, e.y, math.floor(e.z), 1.2) end end
    end)
    wait(5)
    tool("entity3d_move", { id = "ysnp_demon", x = wizX + 3.5, y = cy, z = z + hover, duration = 6 })
    draw{ kind = "text", anchor = "world", x = wizX + 0.5, y = cy, z = deckZ + 0.9, text = "You cannot pass.", font = "large", r = 0.9, g = 0.95, b = 1, ttl = 4 }
    wait(6.5)
    burst.stop()
    -- the staff strike: raised staff, a white flash, the title
    wizard(true)
    local flash = light(wizX, y0, deckZ, 1, 1, 1, 18)
    lightning(wizX, cy, { strike = false })
    sound("Thunder", wizX, cy, deckZ)
    draw{ kind = "text", anchor = "world", id = "ysnp_title", x = cx, y = cy, z = deckZ + 1.4, text = "YOU SHALL NOT PASS!", font = "title", r = 1, g = 0.95, b = 0.8, ttl = 5 }
    wait(0.4)
    flash.remove()
    wait(0.3)
    flash = light(wizX, y0, deckZ, 1, 1, 1, 18)
    wait(0.5)
    flash.remove()
    -- the bridge cracks under the demon: the two piers below it become broken stumps
    local cracked = {}
    for _, p in ipairs(piers) do
        if p.x >= wizX + 2 and p.x <= wizX + 4 then
            pcall(tool, "model_remove", { pid = p.pid })
            pcall(place, "ysnp_pier_broken", p.pid, p.x, p.y, z)
            cracked[#cracked + 1] = p
        end
    end
    sound("ZombieThumpGeneric", wizX + 3, cy, z)
    embers(8, wizX + 3.5, cy, deckZ, 1.5)
    wait(1)
    -- the demon falls into the deep
    tool("entity3d_move", { id = "ysnp_demon", x = wizX + 3.5, y = cy, z = z, duration = 2.2 })
    wait(1.2)
    embers(10, wizX + 3.5, cy, z, 2)
    lightning(wizX + 3, cy, { strike = false, light = true })
    wait(1.0)
    pcall(tool, "entity3d_remove", { id = "ysnp_demon" })
    local pit = light(wizX + 3, y0, z, 1, 0.1, 0, 14)
    sound("Thunder", wizX + 3, cy, z)
    wait(3)
    pit.remove()
    deep.remove()
    -- aftermath: the staff comes down, the piers are whole again, the demon waits in the deep once more
    wizard(false)
    for _, p in ipairs(cracked) do
        pcall(tool, "model_remove", { pid = p.pid })
        pcall(place, "ysnp_pier", p.pid, p.x, p.y, z)
    end
    draw{ kind = "text", anchor = "world", x = wizX + 0.5, y = cy, z = deckZ + 0.9, text = "Fly, you fools.", font = "large", r = 0.9, g = 0.95, b = 1, ttl = 4 }
    wait(12)
    demonIdle()
    playing = false
end

-- whenever a player stands on the bridge deck (re-arms when it is empty again, at most every `cooldown` seconds)
trigger("cross", function()
    for _, p in ipairs(players()) do
        local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
        if pz == deckZ and py == y0 and px > xs and px < xe then return p end
    end
end, cutscene, { cooldown = cooldown, interval = 0.5 })
onSignal("play", function() cutscene(nil) end)

---------------------------------------------------------------- teardown (only on request; the installation is permanent)
onSignal("teardown", function()
    log("teardown requested")
    pcall(tool, "entity3d_remove", { id = "ysnp_demon" })
    pcall(tool, "entity3d_remove", { id = "ysnp_wizard" })
    for _, list in ipairs({ piers, slabs, rocks, stals }) do
        for _, p in ipairs(list) do pcall(tool, "model_remove", { pid = p.pid }) end
    end
    local w, h = hall.x2 - hall.x1 + 2, hall.y2 - hall.y1 + 2
    pcall(blockers, hall.x1, hall.y1, z, w, h, "remove", "walls")
    pcall(blockers, xs, y0, deckZ, L + 2, 2, "remove", "rails")
    for _, sx in ipairs({ xs, xe }) do
        for _, sprite in ipairs(STAIRS) do pcall(removeTile, sprite, sx, y0 + 1, z, true); pcall(removeTile, sprite, sx, y0 + 2, z, true); pcall(removeTile, sprite, sx, y0 + 3, z, true) end
    end
    if deckUp then
        for x = xs, xe do pcall(tool, "remove_object", { x = x, y = y0, z = deckZ, sprite = DECK_FLOOR, force = true, all = true }) end
    end
    if state.snapshot then
        local ok, res = pcall(restoreArea, state.snapshot)
        log("restore: " .. (ok and (res.removed .. " removed, " .. res.added .. " added") or tostring(res)))
    end
    state.built, state.steps = false, {}
    stop("teardown")
end)
onStop(function(reason) log("scene ends: " .. tostring(reason) .. " (the hall stays; signal 'teardown' removes it)") end)
log("You shall not pass: armed at " .. xs .. "," .. y0 .. " (level " .. deckZ .. "), cutscenes so far: " .. state.runs)
