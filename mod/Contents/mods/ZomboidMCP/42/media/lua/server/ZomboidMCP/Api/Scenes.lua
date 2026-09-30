-- Zomboid MCP: scene runtime (server side) and the server half of client screen apps.
-- SDK reference and writing guide: docs/SCENES.md. Protocol rows: docs/PROTOCOL.md part 2 ("Scenes and apps").
--
-- A scene is a Lua chunk written live by Claude (scene_start {name, code, args?, persistent?}). It runs as a
-- coroutine in its own environment (setfenv: the SDK below plus, through __index, the whole engine and ZMCP),
-- ticked from ZMCP.tickHooks.scenes with a time budget per tick. wait()/waitUntil()/actor:walkTo()/sprite:moveTo()
-- yield; every()/parallel()/race()/trigger() spawn child tasks (more coroutines of the same scene).
-- Errors never reach the bridge tick: a failing main task stops that scene (event scene_error), a failing child
-- task is logged and only that task dies. A scene is "running" while any of its tasks is alive.
--
-- Persistence: scene_start {persistent = true} writes zmcp_scene_<name>.lua.txt and records the scene in ModData
-- "ZomboidMCP".scenes.persistent, so it restarts on every load of this file (server start, reloadlua, tools/pz load).
-- `state` (ModData "ZomboidMCP".scenes.state[name]) is a small table that survives restarts and re-starts.
-- Everything a scene creates (actors, sprites, lights, bubbles, triggers, event handlers, client watchers) is
-- tracked per scene and removed by scene_stop / a crash / a replacement.
--
-- Heap rules: no code or textures in ModData (files only), `state` is meant for a handful of numbers/flags.
-- Tools: scene_start, scene_stop, scene_list, scene_logs, scene_signal, app_start, app_stop, app_list.
if isClient() then return end
if not (ZMCP and ZMCP.tool) then if isClient and isClient() then return end error("Bridge.lua must be loaded before Api/Scenes.lua") end
if not (ZMCP.visuals and ZMCP.visuals.enqueue) then error("Api/Visuals.lua must be loaded before Api/Scenes.lua") end

local Z = ZMCP
local J = ZMCPJson
local V = Z.visuals
Z.scenes = Z.scenes or {}
local S = Z.scenes
S.version = Z.version
S.BUDGET_MS = 8            -- milliseconds of scene work per bridge tick (all scenes together)
S.MAX_LOGS = 200           -- log lines kept per scene
S.MAX_TASKS = 200          -- tasks (coroutines) per scene
S.MAX_SNAPSHOT = 900       -- squares per snapshotArea
S.list = S.list or {}      -- name -> scene
S.apps = S.apps or {}      -- app name -> { player, focus, started, clients = { user -> {ok, err, t} }, scores = { user -> n } }
S.handlers = S.handlers or {}
S.seq = S.seq or 0
S.current = nil            -- the task being resumed right now (SDK functions that yield read it)

for ev, fn in pairs(S.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
S.handlers = {}

local function arr(t) return J.array(t) end
local function num(v, d) local n = tonumber(v); if n == nil then return d end; return n end
local function isEmpty(t) for _ in pairs(t) do return false end return true end   -- Kahlua has no next()
local function truthy(v) return v == true or v == 1 or v == "1" or v == "true" end
local function nextId(prefix) S.seq = S.seq + 1; return prefix .. S.seq end
local function try(fn) local ok, v = pcall(fn); if ok then return v end return nil end

local function store()
    local md = ModData.getOrCreate("ZomboidMCP")
    if type(md.scenes) ~= "table" then md.scenes = {} end
    local s = md.scenes
    if type(s.persistent) ~= "table" then s.persistent = {} end
    if type(s.state) ~= "table" then s.state = {} end
    return s
end
S.store = store

local function sceneFile(name) return "zmcp_scene_" .. name .. ".lua.txt" end   -- getFileWriter refuses .lua

local function userOf(player)
    local ok, u = pcall(function() return player:getUsername() end)
    return ok and u or "?"
end

---------------------------------------------------------------- scene bookkeeping
local function log(scene, text)
    local line = string.format("%.1f %s", Z.now() - scene.started, tostring(text))
    scene.logs[#scene.logs + 1] = line
    if #scene.logs > S.MAX_LOGS then table.remove(scene.logs, 1) end
    print("[ZomboidMCP] scene " .. scene.name .. ": " .. tostring(text))
end

-- yield helper: only valid inside a scene task (never from a condition function or an event callback)
local function yieldReq(req)
    if not S.current then error("wait()/waitUntil() can only be called inside a scene task, not from a condition or event callback") end
    return coroutine.yield(req)
end

local function newTask(scene, fn, label)
    if #scene.tasks >= S.MAX_TASKS then error("scene '" .. scene.name .. "' has too many tasks (" .. S.MAX_TASKS .. ")") end
    local task = { co = coroutine.create(fn), label = label or "task", scene = scene, done = false, fresh = true, result = nil }
    scene.tasks[#scene.tasks + 1] = task
    return task
end

local function taskHandle(task)
    return {
        stop = function() task.done = true; task.stopped = true end,
        done = function() return task.done end,
        result = function() return task.result end,
        label = task.label,
    }
end

-- undo everything the scene created; safe to call twice
local function cleanup(scene, reason)
    if scene.cleaned then return end
    scene.cleaned = true
    for _, fn in ipairs(scene.onStop) do pcall(fn, reason) end
    for ev, fns in pairs(scene.handlers) do
        for _, fn in ipairs(fns) do if Events[ev] then pcall(Events[ev].Remove, fn) end end
    end
    scene.handlers = {}
    for _, actor in pairs(scene.actors) do pcall(actor.remove, actor) end
    scene.actors = {}
    for id in pairs(scene.sprites) do
        pcall(function() V.store().sprites[id] = nil end)
        V.enqueue("spriteRemove", { id = id })
    end
    scene.sprites = {}
    if not isEmpty(scene.lights) then V.enqueue("lightRemove", { scene = scene.name }) end
    scene.lights = {}
    V.enqueue("sceneClear", { scene = scene.name })     -- bubbles, dialogs, anims, click/key watchers on the clients
    for _, task in ipairs(scene.tasks) do task.done = true end
end

local function finish(scene, status, err)
    scene.status = status
    scene.error = err
    scene.ended = Z.now()
    cleanup(scene, status)
    if status == "error" then
        log(scene, "ERROR " .. tostring(err))
        Z.event("scene_error", { name = scene.name, error = tostring(err) })
    else
        Z.event("scene_" .. status, { name = scene.name, runtime = math.floor(scene.ended - scene.started) })
    end
end
S.finish = finish

---------------------------------------------------------------- SDK helpers (shared by all scenes)
local function dist(x1, y1, x2, y2) local dx, dy = x1 - x2, y1 - y2; return math.sqrt(dx * dx + dy * dy) end

local function playersNear(x, y, r, z)
    local out = {}
    for _, p in ipairs(Z.players()) do
        local ok, d = pcall(function() return dist(p:getX(), p:getY(), x, y) end)
        if ok and d <= r and (z == nil or math.floor(p:getZ()) == math.floor(z)) then out[#out + 1] = p end
    end
    return out
end

local function nearestPlayer(x, y)
    local best, bestD
    for _, p in ipairs(Z.players()) do
        local ok, d = pcall(function() return dist(p:getX(), p:getY(), x, y) end)
        if ok and (not bestD or d < bestD) then best, bestD = p, d end
    end
    return best, bestD
end

local function callTool(name, args)
    local t = Z.tools[name]
    if not t then error("tool '" .. name .. "' is not loaded on this server") end
    return t.fn(args)
end

-- easing functions (t in 0..1)
local ease = {
    linear = function(t) return t end,
    inQuad = function(t) return t * t end,
    outQuad = function(t) return t * (2 - t) end,
    inOutQuad = function(t) if t < 0.5 then return 2 * t * t end return -1 + (4 - 2 * t) * t end,
    inCubic = function(t) return t * t * t end,
    outCubic = function(t) t = t - 1; return t * t * t + 1 end,
    inOutCubic = function(t) if t < 0.5 then return 4 * t * t * t end t = 2 * t - 2; return 0.5 * t * t * t + 1 end,
    outBounce = function(t)
        if t < 1 / 2.75 then return 7.5625 * t * t
        elseif t < 2 / 2.75 then t = t - 1.5 / 2.75; return 7.5625 * t * t + 0.75
        elseif t < 2.5 / 2.75 then t = t - 2.25 / 2.75; return 7.5625 * t * t + 0.9375 end
        t = t - 2.625 / 2.75; return 7.5625 * t * t + 0.984375
    end,
    outElastic = function(t)
        if t == 0 or t == 1 then return t end
        return (2 ^ (-10 * t)) * math.sin((t - 0.075) * (2 * math.pi) / 0.3) + 1
    end,
    sine = function(t) return 0.5 - 0.5 * math.cos(t * math.pi) end,
}
S.ease = ease

---------------------------------------------------------------- the SDK environment of one scene
local function buildEnv(scene)
    local E = {}
    local name = scene.name

    local function currentTask()
        local t = S.current
        if not t or t.scene ~= scene then error("this SDK call must run inside a task of scene '" .. name .. "'") end
        return t
    end

    local function send(cmd, args, player) args.scene = name; V.enqueue(cmd, args, player) end
    E.__send = send

    ---------------- time and tasks
    E.now = function() return Z.now() end
    E.log = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            parts[#parts + 1] = type(v) == "table" and (pcall(J.encode, v) and J.encode(v) or tostring(v)) or tostring(v)
        end
        log(scene, table.concat(parts, " "))
    end
    E.wait = function(sec)
        currentTask()
        return yieldReq({ wake = Z.now() + math.max(0, num(sec, 0)) })
    end
    E.tick = function() currentTask(); return yieldReq({}) end
    E.waitUntil = function(fn, timeout)
        currentTask()
        if type(fn) ~= "function" then error("waitUntil(fn, timeout?) needs a function") end
        return yieldReq({ cond = fn, timeoutAt = timeout and (Z.now() + timeout) or nil })
    end
    E.spawn = function(fn, ...)
        if type(fn) ~= "function" then error("spawn(fn, ...) needs a function") end
        local args = { ... }
        return taskHandle(newTask(scene, function() return fn(unpack(args)) end, "spawn"))
    end
    E.parallel = function(...)
        currentTask()
        local tasks, results = {}, {}
        for i = 1, select("#", ...) do
            local fn = select(i, ...)
            if type(fn) ~= "function" then error("parallel(...) takes functions") end
            tasks[i] = newTask(scene, function() results[i] = fn(); return results[i] end, "parallel" .. i)
        end
        yieldReq({ cond = function()
            for _, t in ipairs(tasks) do if not t.done then return false end end
            return true
        end })
        return results
    end
    E.race = function(...)
        currentTask()
        local tasks, winner = {}, nil
        for i = 1, select("#", ...) do
            local fn = select(i, ...)
            if type(fn) ~= "function" then error("race(...) takes functions") end
            tasks[i] = newTask(scene, function() local r = fn(); if not winner then winner = { i = i, result = r } end; return r end, "race" .. i)
        end
        yieldReq({ cond = function()
            if winner then return true end
            for _, t in ipairs(tasks) do if t.done and not t.stopped then return true end end
            return false
        end })
        for _, t in ipairs(tasks) do if not t.done then t.done = true; t.stopped = true end end
        if winner then return winner.i, winner.result end
        for i, t in ipairs(tasks) do if t.done and not t.stopped then return i, t.result end end
        return nil
    end
    -- every(sec, fn, opts): fn runs every sec seconds in its own task; opts.near = {x, y, r} pauses it while no
    -- player is within r tiles (ambience that costs nothing when nobody is there); opts.times limits the runs.
    E.every = function(sec, fn, opts)
        if type(fn) ~= "function" then error("every(sec, fn, opts?) needs a function") end
        sec = math.max(0.05, num(sec, 1))
        opts = opts or {}
        local near = opts.near
        local task
        task = newTask(scene, function()
            local runs = 0
            while true do
                if near then
                    yieldReq({ cond = function() return #playersNear(near.x or near[1], near.y or near[2], near.r or near[3] or 20) > 0 end })
                end
                runs = runs + 1
                local r = fn(runs)
                if r == false or (opts.times and runs >= opts.times) then return runs end
                yieldReq({ wake = Z.now() + sec })
            end
        end, "every")
        return taskHandle(task)
    end
    E.ambient = function(x, y, r, sec, fn) return E.every(sec, fn, { near = { x = x, y = y, r = r } }) end
    -- trigger(label, condFn, fn, opts): whenever condFn() returns a truthy value, fn(value) runs (in its own task,
    -- so it may wait). opts.cooldown seconds between runs (default 0: re-arms as soon as the condition turns false),
    -- opts.once, opts.interval (how often the condition is checked, default 0.5 s).
    E.trigger = function(label, cond, fn, opts)
        if type(cond) ~= "function" or type(fn) ~= "function" then error("trigger(label, condFn, fn, opts?) needs two functions") end
        opts = opts or {}
        local cooldown, interval = num(opts.cooldown, 0), math.max(0.1, num(opts.interval, 0.5))
        local armed, lastRun, count = true, -1e9, 0
        local task = newTask(scene, function()
            while true do
                local ok, v = pcall(cond)
                if not ok then log(scene, "trigger '" .. tostring(label) .. "' condition error: " .. tostring(v)); v = nil end
                if v then
                    if armed and Z.now() - lastRun >= cooldown then
                        armed, lastRun, count = false, Z.now(), count + 1
                        local runner = newTask(scene, function() return fn(v, count) end, "trigger:" .. tostring(label))
                        if opts.wait ~= false then yieldReq({ cond = function() return runner.done end }) end
                        if opts.once then return count end
                    end
                else
                    armed = true
                end
                yieldReq({ wake = Z.now() + interval })
            end
        end, "trigger:" .. tostring(label))
        return taskHandle(task)
    end
    -- onPlayerNear(x, y, r, fn, opts): fn(player, count) when a player comes within r tiles. Re-arms when the area is
    -- empty again; opts.cooldown / opts.once as in trigger; opts.z restricts to a floor.
    E.onPlayerNear = function(x, y, r, fn, opts)
        opts = opts or {}
        return E.trigger("near:" .. x .. "," .. y, function()
            local list = playersNear(x, y, r, opts.z)
            return list[1]
        end, fn, opts)
    end
    E.onSignal = function(signal, fn)
        scene.signals[tostring(signal)] = scene.signals[tostring(signal)] or {}
        table.insert(scene.signals[tostring(signal)], fn)
    end
    E.waitSignal = function(signal, timeout)
        currentTask()
        local got, data = false, nil
        E.onSignal(signal, function(d) got, data = true, d end)
        local ok = yieldReq({ cond = function() return got end, timeoutAt = timeout and (Z.now() + timeout) or nil })
        return ok and data or nil, ok
    end
    local function onEvent(ev, fn)
        if not Events[ev] then error("no such event: " .. tostring(ev)) end
        local wrapped = function(...) local ok, err = pcall(fn, ...); if not ok then log(scene, ev .. " handler error: " .. tostring(err)) end end
        Events[ev].Add(wrapped)
        scene.handlers[ev] = scene.handlers[ev] or {}
        table.insert(scene.handlers[ev], wrapped)
        return { stop = function() pcall(Events[ev].Remove, wrapped) end }
    end
    E.onEvent = onEvent
    -- onDeath(fn): fn(player) when a player dies (server events OnPlayerDeath / OnCharacterDeath, de-duplicated)
    E.onDeath = function(fn)
        local seen = {}
        local function handler(character)
            if not character or not instanceof(character, "IsoPlayer") then return end
            local u = userOf(character)
            if seen[u] and Z.now() - seen[u] < 5 then return end
            seen[u] = Z.now()
            fn(character)
        end
        local a = onEvent("OnPlayerDeath", handler)
        local b = Events.OnCharacterDeath and onEvent("OnCharacterDeath", handler) or nil
        return { stop = function() a.stop(); if b then b.stop() end end }
    end
    E.onZombieDead = function(fn) return onEvent("OnZombieDead", fn) end
    -- client-forwarded input: fn(player, x, y) when a player clicks the sprite; fn(player, key) when a player presses
    -- the key (LWJGL key code; scene watchers are registered on every client and removed with the scene).
    E.onClick = function(spriteId, fn)
        spriteId = tostring(spriteId)
        scene.clicks[spriteId] = fn
        send("sceneWatch", { clicks = spriteId })
        return { stop = function() scene.clicks[spriteId] = nil end }
    end
    E.onKey = function(key, fn)
        key = tostring(math.floor(num(key, 0)))
        scene.keys[key] = fn
        send("sceneWatch", { keys = key })
        return { stop = function() scene.keys[key] = nil end }
    end
    -- ask(player, text, options, timeout): a dialog with choice buttons on that player's screen; returns the chosen
    -- option string (nil on timeout / close). Number keys 1..n work too.
    E.ask = function(player, text, options, timeout)
        currentTask()
        if type(options) ~= "table" or #options == 0 then error("ask(player, text, options, timeout?) needs a list of options") end
        local id = nextId("q")
        local answer, got = nil, false
        scene.choices[id] = function(choice) answer, got = choice, true end
        local labels = {}
        for i, o in ipairs(options) do labels[i] = tostring(o):gsub("|", "/") end
        send("dialog", { id = id, text = tostring(text), options = table.concat(labels, "|"), ttl = timeout }, player)
        local ok = yieldReq({ cond = function() return got end, timeoutAt = timeout and (Z.now() + timeout) or nil })
        scene.choices[id] = nil
        if not ok then send("dialogClose", { id = id }, player) end
        return answer
    end

    ---------------- players and positions
    E.players = function() return Z.players() end
    E.player = function(nameOrNil) return Z.player(nameOrNil) end
    E.nearestPlayer = nearestPlayer
    E.playersNear = playersNear
    E.pos = function(o) return o:getX(), o:getY(), o:getZ() end
    E.name = function(p) local ok, n = pcall(function() return p:getUsername() end); return ok and n or tostring(p) end
    E.dist = dist
    E.distTo = function(o, x, y) return dist(o:getX(), o:getY(), x, y) end
    E.random = function(a, b)
        -- math.random is nil in the single-player Lua state; ZombRandFloat exists everywhere
        if a == nil then return ZombRandFloat(0, 1) end
        if b == nil then return math.floor(ZombRandFloat(0, 1) * a) + 1 end
        return a + ZombRandFloat(0, 1) * (b - a)
    end
    E.loaded = function(x, y, z) return getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0)) ~= nil end
    E.square = function(x, y, z) return Z.square(x, y, z) end

    ---------------- world (server-authoritative, through the curated tools when present)
    E.spawnItem = function(item, x, y, z, count)
        return callTool("spawn_item", { item = item, x = math.floor(x), y = math.floor(y), z = math.floor(z or 0), count = count or 1 })
    end
    E.giveItem = function(player, item, count)
        return callTool("give_item", { player = userOf(player), item = item, count = count or 1 })
    end
    E.dropItemsFromSky = function(item, count, x, y, opts)
        opts = opts or {}
        return callTool("falling_items", { item = item, count = count or 10, x = x and math.floor(x) or nil, y = y and math.floor(y) or nil,
            z = opts.z, radius = opts.radius, duration = opts.duration, fall = opts.fall, spawn = opts.spawn, scale = opts.scale,
            player = opts.player })
    end
    E.placeTile = function(sprite, x, y, z, objName)
        return callTool("place_object", { sprite = sprite, x = math.floor(x), y = math.floor(y), z = math.floor(z or 0), name = objName })
    end
    E.removeTile = function(sprite, x, y, z, all)
        return callTool("remove_object", { sprite = sprite, x = math.floor(x), y = math.floor(y), z = math.floor(z or 0), all = all })
    end
    E.build = function(objects) return callTool("build_structure", { objects = objects }) end
    E.weather = function(kind, intensity) return callTool("set_weather", { kind = kind, intensity = intensity }) end
    E.time = function(hour, day, month, year) return callTool("set_time", { hour = hour, day = day, month = month, year = year }) end
    E.lightning = function(x, y, opts)
        opts = opts or {}
        getClimateManager():transmitServerTriggerLightning(math.floor(x), math.floor(y), opts.strike ~= false, opts.light ~= false, opts.rumble ~= false)
        return true
    end
    -- sound(name, x, y, z): a vanilla sound at a square (server-side, everyone in range hears it); without a
    -- position: a UI sound on every client (or opts.player's) through the client mod.
    E.sound = function(soundName, x, y, z, player)
        if x and y then
            local sq = Z.square(x, y, z or 0)
            playServerSound(tostring(soundName), sq)
        else
            V.enqueue("sound", { name = tostring(soundName) }, player)
        end
        return true
    end
    E.message = function(text, mode, player, opts)
        opts = opts or {}
        return callTool("server_message", { text = tostring(text), mode = mode or "notify", player = player and userOf(player) or nil,
            ttl = opts.ttl, r = opts.r, g = opts.g, b = opts.b, font = opts.font })
    end
    E.say = function(player, text) V.enqueue("say", { text = tostring(text) }, player); return true end
    E.zombies = function(x, y, z, count, outfit)
        return callTool("spawn_zombies", { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0), count = count or 1, outfit = outfit })
    end
    E.killZombies = function(x, y, z, radius)
        return callTool("kill_zombies_area", { x = math.floor(x), y = math.floor(y), z = math.floor(z or 0), radius = radius or 10 })
    end
    E.zombiesNear = function(x, y, z, radius) return Z.zombiesNear(x, y, z, radius) end
    -- texture(id): the id of an uploaded texture (errors when missing, so a scene fails early with a clear message);
    -- texture(id, def) registers a pixel sprite {palette, rows} under that id. "item:Base.X" and vanilla names pass through.
    E.texture = function(id, def)
        id = tostring(id)
        if def then callTool("texture_pixel", { id = id, def = def }); return id end
        if id:sub(1, 5) == "item:" or V.store().textures[id] then return id end
        if getTexture and pcall(getTexture, id) and getTexture(id) then return id end
        error("texture '" .. id .. "' is not uploaded (texture_upload / texture_pixel first, or use item:Base.X)")
    end
    -- sprite(args): a raw world_sprite owned by the scene (removed with it). Prefer spriteActor for motion.
    E.sprite = function(args)
        args.id = args.id or nextId("scn_" .. name .. "_")
        local r = callTool("world_sprite", args)
        scene.sprites[r.id] = true
        return r.id
    end
    E.draw = function(args) args.id = args.id or nextId("scn_" .. name .. "_d"); return callTool("overlay_draw", args) end
    E.clearDraw = function(id) return callTool("clear_visuals", { what = "overlays", id = id }) end
    -- light(x, y, z, r, g, b, radius): a light source on every client (IsoCell:addLamppost). Lights are render state
    -- and are NOT saved by the engine (IsoCell.lamppostPositions has no save/load path, verified in 42.21 bytecode),
    -- so the scene re-sends them to every client that joins while it runs; scene_stop removes them.
    E.light = function(x, y, z, r, g, b, radius)
        local id = nextId("l")
        local l = { id = id, x = math.floor(x), y = math.floor(y), z = math.floor(z or 0), r = num(r, 1), g = num(g, 0.9), b = num(b, 0.7), radius = math.floor(num(radius, 6)) }
        scene.lights[id] = l
        send("light", { id = id, x = l.x, y = l.y, z = l.z, r = l.r, g = l.g, b = l.b, radius = l.radius })
        return { id = id, remove = function() scene.lights[id] = nil; send("lightRemove", { id = id }) end }
    end

    -- snapshotArea(x1, y1, x2, y2, z): records every tile object (sprite, name, floor) of the loaded area into
    -- zmcp_snap_<scene>_<n>.json in the Lua dir and returns the snapshot id; restoreArea(id) removes objects that were
    -- not there and re-adds the ones that are missing (server-authoritative, synced). Ground items are ignored.
    E.snapshotArea = function(x1, y1, x2, y2, z)
        z = math.floor(z or 0)
        x1, x2 = math.floor(math.min(x1, x2)), math.floor(math.max(x1, x2))
        y1, y2 = math.floor(math.min(y1, y2)), math.floor(math.max(y1, y2))
        if (x2 - x1 + 1) * (y2 - y1 + 1) > S.MAX_SNAPSHOT then error("snapshotArea: area too large (max " .. S.MAX_SNAPSHOT .. " squares)") end
        local cell, squares, missing = getCell(), {}, 0
        for x = x1, x2 do
            for y = y1, y2 do
                local sq = cell:getGridSquare(x, y, z)
                if not sq then missing = missing + 1
                else
                    local floor = sq:getFloor()
                    local objs, list = sq:getObjects(), {}
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        local isItem = instanceof(o, "IsoWorldInventoryObject")
                        local sprite = not isItem and try(function() return o:getSprite():getName() end) or nil
                        if sprite then
                            list[#list + 1] = { s = sprite, n = try(function() return o:getName() end), f = (o == floor) or nil }
                        end
                    end
                    squares[#squares + 1] = { x = x, y = y, o = arr(list) }
                end
            end
        end
        if missing > 0 then error("snapshotArea: " .. missing .. " squares are not loaded (nobody near " .. x1 .. "," .. y1 .. ")") end
        local id = "zmcp_snap_" .. name .. "_" .. nextId("") .. ".json"
        Z.writeFile(id, J.encode({ x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z, t = Z.now(), squares = arr(squares) }))
        log(scene, "snapshot " .. id .. " (" .. #squares .. " squares)")
        return id
    end
    E.restoreArea = function(id)
        local text = Z.readFile(tostring(id))
        if not text then error("restoreArea: snapshot not found: " .. tostring(id)) end
        local snap = J.decode(text)
        if type(snap) ~= "table" or type(snap.squares) ~= "table" then error("restoreArea: bad snapshot file " .. tostring(id)) end
        local cell, removed, added, skipped = getCell(), 0, 0, 0
        for _, rec in ipairs(snap.squares) do
            local sq = cell:getGridSquare(rec.x, rec.y, snap.z)
            if not sq then skipped = skipped + 1
            else
                local want = {}
                for _, o in ipairs(rec.o or {}) do want[o.s] = (want[o.s] or 0) + 1 end
                local floor = sq:getFloor()
                local objs, current, toRemove = sq:getObjects(), {}, {}
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    local sprite = not instanceof(o, "IsoWorldInventoryObject") and try(function() return o:getSprite():getName() end) or nil
                    if sprite then
                        current[sprite] = (current[sprite] or 0) + 1
                        if current[sprite] > (want[sprite] or 0) and o ~= floor then toRemove[#toRemove + 1] = o end
                    end
                end
                for _, o in ipairs(toRemove) do if pcall(function() sq:transmitRemoveItemFromSquare(o) end) then removed = removed + 1 end end
                for sprite, n in pairs(want) do
                    for _ = 1, n - math.min(n, current[sprite] or 0) do
                        local ok = pcall(function()
                            local obj = IsoObject.new(sq, sprite)
                            sq:transmitAddObjectToSquare(obj, -1)
                        end)
                        if ok then added = added + 1 end
                    end
                end
            end
        end
        log(scene, string.format("restore %s: removed %d, added %d, skipped %d squares", tostring(id), removed, added, skipped))
        return { removed = removed, added = added, skipped = skipped }
    end

    ---------------- actors: passive zombie puppets
    -- spawnActor{kind = 'zombie', outfit?, x, y, z?, name?, passive = true, female?, walk?}
    E.spawnActor = function(o)
        if type(o) ~= "table" or o.x == nil or o.y == nil then error("spawnActor{x, y, outfit?, name?, passive?} needs x and y") end
        local x, y, z = math.floor(o.x), math.floor(o.y), math.floor(o.z or 0)
        Z.square(x, y, z)
        local list = addZombiesInOutfit(x, y, z, 1, o.outfit, o.female == true and 100 or (o.female == false and 0 or 50))
        local zed = list and list:size() > 0 and list:get(0) or nil
        if not zed then error("addZombiesInOutfit returned nothing at " .. x .. "," .. y) end
        local actor = { kind = "zombie", zombie = zed, name = tostring(o.name or nextId("actor")), id = nextId("a"), scene = name }
        if o.passive ~= false then pcall(function() zed:setUseless(true) end) end
        if o.walk then pcall(function() zed:setWalkType(tostring(o.walk)) end) end
        scene.actors[actor.id] = actor
        function actor.pos() return zed:getX(), zed:getY(), zed:getZ() end
        function actor.alive() local ok, d = pcall(function() return zed:isDead() end); return ok and not d end
        function actor.onlineId() local ok, v = pcall(function() return zed:getOnlineID() end); return ok and v or nil end
        function actor.face(_, fx, fy) return pcall(function() zed:faceLocationF(fx, fy) end) end
        function actor.walk(_, kind) return pcall(function() zed:setWalkType(tostring(kind)) end) end
        function actor.passive(_, on) return pcall(function() zed:setUseless(on ~= false) end) end
        -- say(text, ttl): the engine's speech line (zed:Say) plus a client bubble that follows the zombie
        function actor.say(_, text, ttl)
            pcall(function() zed:Say(tostring(text)) end)
            local px, py, pz = actor.pos()
            -- the client draws the bubble: a zombie's own Say line is not drawn in single player, and the dedicated
            -- server may not transmit it. zid (online id) finds the puppet on multiplayer clients, oid in single player.
            send("bubble", { id = actor.id, zid = actor.onlineId(), oid = try(function() return zed:getID() end),
                x = px, y = py, z = pz, text = tostring(text), ttl = num(ttl, 4) })
            return true
        end
        -- A tile that holds a player cannot be pathed to (the zombie stays idle without an error), so the goal
        -- becomes the neighbouring tile on the actor's side.
        local function tileHoldsPlayer(tx, ty, tz)
            local sq = getCell():getGridSquare(tx, ty, tz)
            if not sq then return false end
            local mo = sq:getMovingObjects()
            for i = 0, mo:size() - 1 do if instanceof(mo:get(i), "IsoPlayer") then return true end end
            return false
        end
        -- pathToLocation alone is not enough for a passive puppet: with a clear straight line the engine picks its
        -- "walk straight" mode (bMoving without bPathfind), which a useless zombie never executes, so it stays idle.
        -- Forcing bPathfind puts it into PathFindState, which walks the real path (verified in single player).
        local function pathTo(gx, gy, gz)
            zed:pathToLocation(gx, gy, gz)
            pcall(function() zed:setVariable("bPathfind", true); zed:setMoving(false) end)
        end
        local function goalTile(cx, cy, tx, ty, tz)
            local gx, gy = math.floor(tx), math.floor(ty)
            if not try(function() return tileHoldsPlayer(gx, gy, tz) end) then return gx, gy end
            local dx, dy = cx - tx, cy - ty
            if math.abs(dx) >= math.abs(dy) then gx = gx + (dx >= 0 and 1 or -1) else gy = gy + (dy >= 0 and 1 or -1) end
            return gx, gy
        end
        -- walkTo(x, y, opts): pathToLocation and wait until within opts.dist (1 tile) of the target, on the goal tile,
        -- or opts.timeout seconds (default 5 + 2 s per tile). Re-paths every 3 s. Returns true when arrived.
        function actor.walkTo(_, tx, ty, opts)
            currentTask()
            opts = type(opts) == "table" and opts or { timeout = tonumber(opts) }
            local ax, ay, az = actor.pos()
            local reach, tz = num(opts.dist, 1), math.floor(az)
            local deadline = Z.now() + num(opts.timeout, 5 + 2 * dist(ax, ay, tx, ty))
            local lastPath, gx, gy = -1e9, nil, nil
            while true do
                if not actor.alive() then return false, "dead" end
                local cx, cy = actor.pos()
                if dist(cx, cy, tx, ty) <= reach then return true end
                if gx and math.floor(cx) == gx and math.floor(cy) == gy then return true end
                if Z.now() >= deadline then return false, "timeout" end
                if Z.now() - lastPath >= 3 then
                    lastPath = Z.now()
                    gx, gy = goalTile(cx, cy, tx, ty, tz)
                    pcall(pathTo, gx, gy, tz)
                end
                yieldReq({ wake = Z.now() + 0.25 })
            end
        end
        -- follow(player, dist): keeps walking after the player (own task) until stop()
        function actor.follow(_, target, keep)
            keep = num(keep, 2)
            if actor.followTask then actor.followTask.stop() end
            actor.followTask = taskHandle(newTask(scene, function()
                while actor.alive() do
                    local ok = pcall(function()
                        local cx, cy = zed:getX(), zed:getY()
                        local d = dist(cx, cy, target:getX(), target:getY())
                        if d > keep then
                            local gx, gy = goalTile(cx, cy, target:getX(), target:getY(), math.floor(target:getZ()))
                            pathTo(gx, gy, math.floor(target:getZ()))
                        end
                    end)
                    if not ok then return end
                    yieldReq({ wake = Z.now() + 1 })
                end
            end, "follow"))
            return actor.followTask
        end
        function actor.stop()
            if actor.followTask then actor.followTask.stop(); actor.followTask = nil end
            pcall(function() local px, py, pz = actor.pos(); pathTo(math.floor(px), math.floor(py), math.floor(pz)) end)
        end
        -- onNear(r, fn, opts): trigger when a player is within r tiles of the actor
        function actor.onNear(_, r, fn, opts)
            return E.trigger("actor:" .. actor.name, function()
                if not actor.alive() then return nil end
                local px, py = actor.pos()
                return playersNear(px, py, r)[1]
            end, function(p, count) return fn(p, count) end, opts)
        end
        function actor.remove()
            actor.stop()
            scene.actors[actor.id] = nil
            send("bubbleRemove", { id = actor.id })
            local ok = pcall(function() zed:removeFromWorld(); zed:removeFromSquare() end)
            if not ok then pcall(function() zed:setAttackedBy(nil); zed:Kill(nil) end) end
            return true
        end
        log(scene, "actor " .. actor.name .. " spawned at " .. x .. "," .. y)
        return actor
    end

    ---------------- sprite actors: textures in the world with tweened motion, frame animation, bubbles
    -- spriteActor{texture, x, y, z?, scale? | tiles?, frames? = {tex1, tex2}, fps?, flip?, anchor?, opacity?, bob?}
    E.spriteActor = function(o)
        if type(o) ~= "table" or not (o.texture or o.frames) or o.x == nil or o.y == nil then
            error("spriteActor{texture|frames, x, y, scale?|tiles?, fps?} needs a texture (or frames) and x, y")
        end
        local sa = { kind = "sprite", id = nextId("scn_" .. name .. "_s"), x = o.x, y = o.y, z = num(o.z, 0), scene = name }
        sa.args = { id = sa.id, texture = o.texture or o.frames[1], scale = o.scale, tiles = o.tiles, flip = o.flip, anchor = o.anchor,
            opacity = o.opacity, bob = o.bob, bobHz = o.bobHz, fade = o.fade }
        local function push(extra)
            local a = { x = sa.x, y = sa.y, z = sa.z }
            for k, v in pairs(sa.args) do a[k] = v end
            for k, v in pairs(extra or {}) do a[k] = v end
            callTool("world_sprite", a)
            scene.sprites[sa.id] = true
        end
        sa.push = push
        push()
        if o.frames then
            sa.frames, sa.fps = o.frames, num(o.fps, 6)
            send("spriteAnim", { id = sa.id, frames = table.concat(o.frames, ","), fps = sa.fps })
        end
        function sa.pos() return sa.x, sa.y, sa.z end
        function sa.set(_, changes) for k, v in pairs(changes) do if k == "x" or k == "y" or k == "z" then sa[k] = v else sa.args[k] = v end end; push(); return sa end
        -- moveTo(x, y, opts): straight-line motion at opts.speed tiles/s or over opts.duration seconds (default 2 tiles/s);
        -- awaitable, returns when the motion time has passed and the sprite is pinned at the target.
        function sa.moveTo(_, tx, ty, opts)
            currentTask()
            opts = type(opts) == "table" and opts or { speed = tonumber(opts) }
            local tz = num(opts.z, sa.z)
            local d = dist(sa.x, sa.y, tx, ty)
            local dur = opts.duration or (d / math.max(0.01, num(opts.speed, 2)))
            if d > 0 and dur > 0 then
                push({ path = { { tx, ty, tz } }, speed = d / dur, loop = "once" })
                yieldReq({ wake = Z.now() + dur })
            end
            sa.x, sa.y, sa.z = tx, ty, tz
            push()
            return true
        end
        function sa.playAnim(_, frames, fps)
            sa.frames, sa.fps = frames, num(fps, sa.fps or 6)
            send("spriteAnim", { id = sa.id, frames = type(frames) == "table" and table.concat(frames, ",") or tostring(frames or ""), fps = sa.fps })
            return sa
        end
        function sa.stopAnim() send("spriteAnim", { id = sa.id, frames = "" }) end
        -- fade(to, dur): tween the opacity on the clients and wait for it
        function sa.fade(_, to, dur)
            currentTask()
            dur = num(dur, 1)
            send("spriteFade", { id = sa.id, to = num(to, 0), dur = dur })
            yieldReq({ wake = Z.now() + dur })
            sa.args.opacity = num(to, 0)
            return true
        end
        function sa.bubble(_, text, ttl)
            send("bubble", { id = sa.id, sid = sa.id, text = tostring(text), ttl = num(ttl, 4) })
            return true
        end
        function sa.onClick(_, fn) return E.onClick(sa.id, fn) end
        function sa.remove()
            scene.sprites[sa.id] = nil
            pcall(function() V.store().sprites[sa.id] = nil end)
            V.enqueue("spriteRemove", { id = sa.id })
            send("bubbleRemove", { id = sa.id })
            return true
        end
        return sa
    end

    ---------------- tweens
    E.ease = ease
    E.lerp = function(a, b, t) return a + (b - a) * t end
    -- tween(from, to, dur, fn, easing?): calls fn(value, t) every tick for dur seconds (awaitable)
    E.tween = function(from, to, dur, fn, easing)
        currentTask()
        easing = type(easing) == "string" and (ease[easing] or ease.linear) or (easing or ease.linear)
        local t0 = Z.now()
        dur = math.max(0.01, num(dur, 1))
        while true do
            local t = math.min(1, (Z.now() - t0) / dur)
            fn(from + (to - from) * easing(t), t)
            if t >= 1 then return to end
            yieldReq({})
        end
    end

    ---------------- scene control
    E.state = scene.state
    E.args = scene.args
    E.scene = { name = name, started = scene.started, persistent = scene.persistent }
    E.stop = function(reason) scene.stopRequested = reason or "stopped"; if S.current and S.current.scene == scene then coroutine.yield({ stop = true }) end end
    E.onStop = function(fn) if type(fn) ~= "function" then error("onStop(fn) needs a function") end; scene.onStop[#scene.onStop + 1] = fn end
    E.event = function(kind, data) Z.event("scene:" .. tostring(kind), { scene = name, data = data }) end
    E.signal = function(other, sig, data) return S.signal(other, sig, data) end
    E.tool = function(toolName, args) return callTool(toolName, args or {}) end
    E.ZMCP, E.ZMCPJson = Z, J

    setmetatable(E, { __index = _G })
    return E
end

---------------------------------------------------------------- scheduler
local function resumeTask(scene, task, ...)
    S.current = task
    local ok, req = coroutine.resume(task.co, ...)
    S.current = nil
    task.fresh = false
    if coroutine.status(task.co) == "dead" then
        task.done = true
        if ok then task.result = req end
        return ok, req
    end
    if type(req) ~= "table" then req = {} end
    task.req = req
    return ok, req
end

-- returns true when the task should be resumed now, plus the resume arguments
local function ready(task, t)
    if task.fresh then return true end
    local req = task.req or {}
    if req.stop then return false end
    if req.wake then return t >= req.wake end
    if req.cond then
        local ok, v = pcall(req.cond)
        if not ok then return true, false, "condition error: " .. tostring(v) end
        if v then return true, true, v end
        if req.timeoutAt and t >= req.timeoutAt then return true, false, "timeout" end
        return false
    end
    return true                      -- plain tick() yield
end

local function runScene(scene, t, deadline)
    if scene.status ~= "running" then return end
    local i = 1
    local n = #scene.tasks
    while i <= n do
        local task = scene.tasks[i]
        if not task.done then
            local go, a, b = ready(task, t)
            if go then
                local ok, res = resumeTask(scene, task, a, b)
                scene.stats.steps = scene.stats.steps + 1
                if not ok then
                    if task == scene.main then finish(scene, "error", res); return end
                    log(scene, task.label .. " error: " .. tostring(res))
                    Z.event("scene_error", { name = scene.name, task = task.label, error = tostring(res), fatal = false })
                    task.done = true
                elseif type(res) == "table" and res.stop then
                    scene.stopRequested = scene.stopRequested or "stopped"
                end
                if scene.stopRequested then finish(scene, "stopped", scene.stopRequested); return end
                if Z.now() >= deadline then break end
            end
        end
        i = i + 1
    end
    -- compact finished tasks; the scene ends when no task is alive and nothing waits for the world any more
    local keep, alive = {}, 0
    for _, task in ipairs(scene.tasks) do if not task.done then keep[#keep + 1] = task; alive = alive + 1 end end
    scene.tasks = keep
    if alive == 0 and not S.hasListeners(scene) then finish(scene, "done") end
end

-- event handlers, client watchers (onClick/onKey), signals and open dialogs keep an idle scene alive
function S.hasListeners(scene)
    return not (isEmpty(scene.handlers) and isEmpty(scene.clicks) and isEmpty(scene.keys) and isEmpty(scene.signals) and isEmpty(scene.choices))
end

Z.tickHooks.scenes = function(t)
    if isEmpty(S.list) then return end
    local started = Z.now()
    local deadline = started + S.BUDGET_MS / 1000
    local names = {}
    for name in pairs(S.list) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local scene = S.list[name]
        if scene and scene.status == "running" then
            local ok, err = pcall(runScene, scene, t, deadline)
            if not ok then finish(scene, "error", "scheduler: " .. tostring(err)) end
        end
        if Z.now() >= deadline then S.stats.overBudget = (S.stats.overBudget or 0) + 1; break end
    end
    S.stats.ms = S.stats.ms + (Z.now() - started) * 1000
    S.stats.ticks = S.stats.ticks + 1
end
S.stats = S.stats or { ms = 0, ticks = 0, overBudget = 0 }

---------------------------------------------------------------- start / stop
local function decodeArgs(a)
    if a == nil or a == "" then return {} end
    if type(a) == "string" then
        local ok, t = pcall(J.decode, a)
        if ok and type(t) == "table" then return t end
        return { value = a }
    end
    return a
end

-- start (or replace) a scene from source. opts: {args, persistent, file}
function S.start(name, code, opts)
    Z.checkName(name, "scene name")
    opts = opts or {}
    local old = S.list[name]
    if old and old.status == "running" then finish(old, "stopped", "replaced") end
    local fn, err = loadstring(code, "=scene:" .. name)
    if not fn then error("compile scene '" .. name .. "': " .. tostring(err)) end
    local st = store()
    if type(st.state[name]) ~= "table" then st.state[name] = {} end
    local scene = {
        name = name, args = decodeArgs(opts.args), persistent = opts.persistent and true or false, file = opts.file,
        started = Z.now(), status = "running", logs = {}, tasks = {}, actors = {}, sprites = {}, lights = {}, handlers = {},
        onStop = {}, signals = {}, choices = {}, clicks = {}, keys = {}, state = st.state[name],
        stats = { steps = 0 }, restored = opts.restored or false,
    }
    scene.env = buildEnv(scene)
    setfenv(fn, scene.env)
    scene.main = newTask(scene, fn, "main")
    S.list[name] = scene
    Z.event("scene_start", { name = name, persistent = scene.persistent, restored = scene.restored })
    -- first step right away so compile-time and immediate errors come back with the tool result
    local ok, res = resumeTask(scene, scene.main)
    if not ok then finish(scene, "error", res); return scene, res end
    if scene.stopRequested then finish(scene, "stopped", scene.stopRequested) end
    return scene
end

function S.stop(name, reason)
    local scene = S.list[name]
    if not scene then return nil end
    if scene.status == "running" then finish(scene, "stopped", reason or "scene_stop") end
    return scene
end

function S.signal(name, sig, data)
    local scene = S.list[name]
    if not scene or scene.status ~= "running" then error("scene '" .. tostring(name) .. "' is not running") end
    local fns = scene.signals[tostring(sig)]
    local n = 0
    for _, fn in ipairs(fns or {}) do
        n = n + 1
        newTask(scene, function() return fn(data) end, "signal:" .. tostring(sig))
    end
    return n
end

function S.restorePersistent()
    local st = store()
    local restored, failed = {}, {}
    local names = {}
    for name in pairs(st.persistent) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local rec = st.persistent[name]
        local running = S.list[name]
        if not (running and running.status == "running") then
            local code = Z.readFile(rec.file)
            if not code then
                failed[#failed + 1] = name
                Z.event("scene_error", { name = name, error = "persistent scene file missing: " .. tostring(rec.file) })
            else
                local ok, scene, err = pcall(S.start, name, code, { args = rec.args, persistent = true, file = rec.file, restored = true })
                if ok and scene and scene.status ~= "error" then restored[#restored + 1] = name
                else failed[#failed + 1] = name; if not ok then Z.event("scene_error", { name = name, error = tostring(scene) }) end end
            end
        end
    end
    return restored, failed
end

local function sceneInfo(scene)
    local tasks = {}
    for _, t in ipairs(scene.tasks) do if not t.done then tasks[#tasks + 1] = t.label end end
    local actors, lights = 0, 0
    for _ in pairs(scene.actors) do actors = actors + 1 end
    for _ in pairs(scene.lights) do lights = lights + 1 end
    local sprites = 0
    for _ in pairs(scene.sprites) do sprites = sprites + 1 end
    return {
        name = scene.name, status = scene.status, persistent = scene.persistent, restored = scene.restored,
        started = scene.started, runtime = math.floor((scene.ended or Z.now()) - scene.started), error = scene.error,
        tasks = arr(tasks), actors = actors, sprites = sprites, lights = lights, steps = scene.stats.steps,
        state = scene.state, logs = #scene.logs, lastLog = scene.logs[#scene.logs],
    }
end

---------------------------------------------------------------- client -> server (choices, clicks, keys, apps)
S.onClientCommand = function(module, command, player, args)
    if module ~= "zmcp" then return end
    args = args or {}
    local user = userOf(player)
    if command == "hello" then
        -- late joiner: lights, sprite animations and watchers of every running scene
        for _, scene in pairs(S.list) do
            if scene.status == "running" then
                for _, l in pairs(scene.lights) do
                    V.enqueue("light", { scene = scene.name, id = l.id, x = l.x, y = l.y, z = l.z, r = l.r, g = l.g, b = l.b, radius = l.radius }, player)
                end
                local clicks, keys = {}, {}
                for id in pairs(scene.clicks) do clicks[#clicks + 1] = id end
                for k in pairs(scene.keys) do keys[#keys + 1] = k end
                if #clicks > 0 or #keys > 0 then
                    V.enqueue("sceneWatch", { scene = scene.name, clicks = table.concat(clicks, ","), keys = table.concat(keys, ",") }, player)
                end
            end
        end
        return
    end
    local scene = args.scene and S.list[tostring(args.scene)] or nil
    if command == "sceneChoice" then
        if scene and scene.choices[tostring(args.id)] then scene.choices[tostring(args.id)](args.choice ~= "" and args.choice or nil, player) end
        Z.event("scene_choice", { scene = args.scene, id = args.id, choice = args.choice, user = user })
    elseif command == "sceneClick" then
        local fn = scene and scene.clicks[tostring(args.id)]
        if fn then newTask(scene, function() return fn(player, tonumber(args.x), tonumber(args.y)) end, "click:" .. tostring(args.id)) end
    elseif command == "sceneKey" then
        local fn = scene and scene.keys[tostring(args.key)]
        if fn then newTask(scene, function() return fn(player, tonumber(args.key)) end, "key:" .. tostring(args.key)) end
    elseif command == "appScore" then
        local app = S.apps[tostring(args.name)]
        if app then app.scores[user] = tonumber(args.score) end
        Z.event("app_score", { name = args.name, user = user, score = tonumber(args.score) })
        for _, sc in pairs(S.list) do
            if sc.status == "running" and sc.signals["app:" .. tostring(args.name)] then
                S.signal(sc.name, "app:" .. tostring(args.name), { user = user, score = tonumber(args.score), kind = "score" })
            end
        end
    elseif command == "appResult" then
        local app = S.apps[tostring(args.name)]
        if app then app.clients[user] = { ok = args.ok, err = args.err, t = Z.now(), state = args.state } end
        Z.event("app_result", { name = args.name, user = user, ok = args.ok, err = args.err, state = args.state })
    elseif command == "appMsg" then
        Z.event("app_message", { name = args.name, user = user, data = args.data })
        for _, sc in pairs(S.list) do
            if sc.status == "running" and sc.signals["app:" .. tostring(args.name)] then
                S.signal(sc.name, "app:" .. tostring(args.name), { user = user, data = args.data, kind = "message" })
            end
        end
    end
end
S.handlers.OnClientCommand = S.onClientCommand
for ev, fn in pairs(S.handlers) do if Events[ev] then Events[ev].Add(fn) end end

---------------------------------------------------------------- tools: scenes
Z.tool("scene_start", "Start (or replace) a scripted scene: args {name, code, args?, persistent?}. The Lua chunk runs as a coroutine with the scene SDK (docs/SCENES.md: wait, every, trigger, onPlayerNear, spawnActor, spriteActor, light, state, ...). persistent=true stores it and restarts it on every server start / bridge load. Returns {name, status, persistent, error?}.", function(a)
    local name = Z.checkName(a.name, "scene name")
    local code = Z.argText(a, "code")
    local persistent = truthy(a.persistent)
    local st = store()
    local file
    if persistent then
        file = sceneFile(name)
        Z.writeFile(file, code)
        st.persistent[name] = { file = file, args = type(a.args) == "table" and J.encode(a.args) or (a.args and tostring(a.args) or nil), started = Z.now() }
    else
        st.persistent[name] = nil
    end
    local ok, scene, err = pcall(S.start, name, code, { args = a.args, persistent = persistent, file = file })
    if not ok then st.persistent[name] = nil; error(scene) end        -- a scene that cannot compile is never persisted
    local info = sceneInfo(scene)
    if err then info.error = tostring(err) end
    return info
end)

Z.tool("scene_stop", "Stop a scene and remove everything it created (actors, sprites, lights, bubbles, triggers, handlers): args {name, clear_state?}. A persistent scene is forgotten (it will not restart); its saved `state` table is kept unless clear_state=true. Returns {name, status, was_running}.", function(a)
    local name = Z.checkName(a.name, "scene name")
    local st = store()
    local scene = S.list[name]
    local wasRunning = scene ~= nil and scene.status == "running"
    if scene then S.stop(name, "scene_stop") end
    local wasPersistent = st.persistent[name] ~= nil
    st.persistent[name] = nil
    if truthy(a.clear_state) then st.state[name] = nil end
    if not scene and not wasPersistent then error("no such scene: " .. name .. " (see scene_list)") end
    S.list[name] = nil
    return { name = name, status = scene and scene.status or "forgotten", was_running = wasRunning, persistent = wasPersistent, state_cleared = truthy(a.clear_state) }
end)

Z.tool("scene_list", "Every known scene with status (running|done|stopped|error), persistence, live tasks, actor/sprite/light counts, saved state and the last log line, plus scheduler stats (ms spent, ticks over budget).", function()
    local out = {}
    local st = store()
    for name, scene in pairs(S.list) do out[#out + 1] = sceneInfo(scene) end
    for name, rec in pairs(st.persistent) do
        if not S.list[name] then out[#out + 1] = { name = name, status = "not_loaded", persistent = true, file = rec.file, state = st.state[name] } end
    end
    table.sort(out, function(x, y) return x.name < y.name end)
    return { scenes = arr(out), stats = S.stats, budget_ms = S.BUDGET_MS }
end)

Z.tool("scene_logs", "The log lines of a scene (log(...) calls, errors, actor spawns, snapshots): args {name, limit?} -> {name, status, logs, error?}. Newest last; at most 200 are kept.", function(a)
    local name = Z.checkName(a.name, "scene name")
    local scene = S.list[name]
    if not scene then error("no such scene: " .. name) end
    local limit = math.floor(num(a.limit, 50))
    local logs = {}
    for i = math.max(1, #scene.logs - limit + 1), #scene.logs do logs[#logs + 1] = scene.logs[i] end
    return { name = name, status = scene.status, error = scene.error, logs = arr(logs), total = #scene.logs }
end)

Z.tool("scene_signal", "Send a signal into a running scene: args {name, signal, data?}. Every onSignal(signal, fn) handler of the scene runs fn(data) in its own task, and a waitSignal(signal) returns. Returns {name, signal, handlers}.", function(a)
    local name = Z.checkName(a.name, "scene name")
    local sig = tostring(a.signal or "")
    if sig == "" then error("args.signal required") end
    local n = S.signal(name, sig, a.data)
    return { name = name, signal = sig, handlers = n }
end)

---------------------------------------------------------------- tools: client screen apps
Z.tool("app_start", "Push a client screen app (a Lua chunk defining update(dt), draw(ui), onKey(key, down), onMouse(x, y, button, down), optional focus=true) to every client or one player: args {name, code, player?, focus?}. Esc always exits. Returns {name, to, chunks}; each client answers with an app_result event.", function(a)
    local name = Z.checkName(a.name, "app name")
    local code = Z.argText(a, "code")
    local player = (a.player and a.player ~= "") and Z.player(a.player) or nil
    local to = {}
    if player then to[1] = userOf(player) else for _, p in ipairs(Z.players()) do to[#to + 1] = userOf(p) end end
    S.apps[name] = { player = player and userOf(player) or nil, focus = a.focus, started = Z.now(), clients = {}, scores = {}, chars = #code }
    local chunks = V.enqueueChunked("appStart", { name = name, focus = a.focus }, "code", code, player)
    Z.event("app_start", { name = name, to = arr(to), chunks = chunks })
    return { name = name, to = arr(to), chunks = chunks }
end)

Z.tool("app_stop", "Stop a client screen app on every client or one player: args {name, player?}. Releases input capture and player movement. Returns {name, stopped}.", function(a)
    local name = Z.checkName(a.name, "app name")
    local player = (a.player and a.player ~= "") and Z.player(a.player) or nil
    V.enqueue("appStop", { name = name }, player)
    if not player then S.apps[name] = nil end
    Z.event("app_stop", { name = name, user = player and userOf(player) or nil })
    return { name = name, stopped = true, to = player and userOf(player) or "all" }
end)

Z.tool("app_list", "Screen apps started through app_start: [{name, player|all, focus, started, clients = {user = {ok, err, state}}, scores = {user = n}}] (client results and scores arrive as app_result / app_score events).", function()
    local out = {}
    for name, app in pairs(S.apps) do
        out[#out + 1] = { name = name, player = app.player or "all", focus = app.focus, started = Z.now() - app.started, clients = app.clients, scores = app.scores, chars = app.chars }
    end
    table.sort(out, function(x, y) return x.name < y.name end)
    return arr(out)
end)

---------------------------------------------------------------- go
do
    local restored, failed = S.restorePersistent()
    Z.event("scenes_loaded", { version = S.version, restored = arr(restored), failed = arr(failed) })
end
