-- Zomboid MCP: moving 3D entities (server side). A registered runtime model (model_upload, Api/Visuals.lua) or any vanilla ModelScript is shown on every client's transparent 3D layer
-- (client/ZomboidMCP/ClientModels.lua, ZMCPClient.e3d) and moved/rotated smoothly there. The server owns the
-- registry (small: id -> spawn args + last motion, in ModData "ZomboidMCP".visuals.entities3d) and streams it to
-- clients through the visuals queue, so late joiners get every entity on "hello" with the motion's elapsed time.
-- Tools: entity3d_spawn, entity3d_move, entity3d_rotate, entity3d_remove, entity3d_list. Protocol: docs/PROTOCOL.md (e3d, e3dMove, e3dRotate, e3dRemove; reply e3dResult).
-- Persistence: the registry is ModData (saved with the world); entities come back after a server restart because
-- the hello path (Api/Visuals.lua V.sendAllTo) re-streams them, after the models they depend on, to every client.
-- Server only. Re-runnable (hot reload): handlers stored in ZMCP.models.handlers and removed before re-adding.
if isClient() then return end
if not ZMCP then pcall(require, "ZomboidMCP/Bridge") end            -- no-op when loaded via loadstring (tools/pz load)
if not (ZMCP and ZMCP.tool) then error("ZomboidMCP/Bridge.lua must be loaded before Api/") end
if not (ZMCP and ZMCP.util) then pcall(require, "ZomboidMCP/Api/Common") end
if not (ZMCP and ZMCP.util and ZMCP.util.pos) then error("ZomboidMCP/Api/Common.lua must be loaded first") end

local Z = ZMCP
local U = Z.util
local J = ZMCPJson
Z.models = Z.models or {}
local M = Z.models
M.version = "0.1.0"
M.seq = M.seq or 0
M.handlers = M.handlers or {}
M.clients = M.clients or {}       -- user -> { id -> { ok, model, err, t } }

for ev, fn in pairs(M.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
M.handlers = {}

local function arr(t) if J.array then return J.array(t) end return t end
local function num(v, d) local n = tonumber(v); if n == nil then return d end; return n end

-- registry lives next to the visuals registry (Api/Visuals.lua owns "ZomboidMCP".visuals; we add one key)
local function store()
    local s = ModData.getOrCreate("ZomboidMCP")
    if type(s.visuals) ~= "table" then s.visuals = {} end
    if type(s.visuals.entities3d) ~= "table" then s.visuals.entities3d = {} end
    return s.visuals.entities3d
end
M.store = store

-- Visuals.lua is loaded after this file (alphabetical); resolve its queue lazily, fall back to a direct send
local function send(cmd, args, player)
    local V = Z.visuals
    if V and V.enqueue then V.enqueue(cmd, args, player) else Z.toClients(cmd, args, player) end
end

local function checkId(id)
    if type(id) ~= "string" or not id:match("^[%w_%-%.]+$") then error("id must be a string matching [A-Za-z0-9_.-]+") end
    return id
end

local function get(a)
    local id = checkId(U.str(a, "id"))
    local e = store()[id]
    if not e then error("unknown entity: " .. id .. " (see entity3d_list)") end
    return id, e
end

---------------------------------------------------------------- motion (same math as the client)
local function parsePath(str, z)
    local pts = {}
    for seg in string.gmatch(tostring(str or ""), "[^;]+") do
        local x, y, pz = string.match(seg, "^%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,?%s*([%-%d%.]*)")
        if x and y then pts[#pts + 1] = { tonumber(x), tonumber(y), tonumber(pz) or z } end
    end
    return pts
end

local function pathString(p)
    if p == nil or p == "" then return nil end
    if type(p) == "string" then return p end
    if type(p) ~= "table" then error("path must be 'x,y,z;x,y,z' or [[x,y,z],...]") end
    local segs = {}
    for _, pt in ipairs(p) do
        if type(pt) == "table" then segs[#segs + 1] = tostring(pt[1] or pt.x) .. "," .. tostring(pt[2] or pt.y) .. (pt[3] or pt.z and ("," .. tostring(pt[3] or pt.z)) or "")
        else segs[#segs + 1] = tostring(pt) end
    end
    return table.concat(segs, ";")
end

-- current world position of an entity from its stored motion: x, y, z, moving
function M.positionAt(e, t)
    local m = e.motion
    if not m then return e.x, e.y, e.z, false end
    if m.kind == "path" then
        local pts = { { e.x, e.y, e.z } }
        for _, p in ipairs(parsePath(m.path, e.z)) do pts[#pts + 1] = p end
        local length, segs = 0, {}
        for i = 1, #pts - 1 do
            segs[i] = math.sqrt((pts[i + 1][1] - pts[i][1]) ^ 2 + (pts[i + 1][2] - pts[i][2]) ^ 2)
            length = length + segs[i]
        end
        if #pts < 2 or m.speed <= 0 or length <= 0 then return e.x, e.y, e.z, false end
        local dist = m.speed * (t - m.t0)
        if m.loop == "once" then
            if dist >= length then local p = pts[#pts]; return p[1], p[2], p[3], false end
        elseif m.loop == "pingpong" then
            local cycle = dist % (2 * length)
            dist = cycle > length and (2 * length - cycle) or cycle
        else
            dist = dist % length
        end
        for i = 1, #pts - 1 do
            local d = segs[i]
            if dist <= d or i == #pts - 1 then
                local a, b = pts[i], pts[i + 1]
                local f = d > 0 and math.min(dist / d, 1) or 0
                return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f, true
            end
            dist = dist - d
        end
        local p = pts[#pts]
        return p[1], p[2], p[3], false
    elseif m.kind == "to" then
        local f = m.dur > 0 and math.min(1, math.max(0, (t - m.t0) / m.dur)) or 1
        if m.ease then f = f * f * (3 - 2 * f) end
        return e.x + (m.tx - e.x) * f, e.y + (m.ty - e.y) * f, e.z + (m.tz - e.z) * f, f < 1
    end
    return e.x, e.y, e.z, false
end

-- freeze the current position into the entity and drop the motion
local function settle(e, t)
    local x, y, z = M.positionAt(e, t)
    e.x, e.y, e.z, e.motion = x, y, z, nil
end

-- a finished tween / one-shot path becomes a static position (so resends and listings stay simple)
function M.settleIfDone(e, t)
    local m = e.motion
    if not m then return end
    local _, _, _, moving = M.positionAt(e, t)
    if not moving and (m.kind == "to" or m.loop == "once") then settle(e, t) end
end

-- is this model id one of the runtime uploads (Api/Visuals.lua registry)? Clients then wait for its registration
local function isUpload(model)
    local V = Z.visuals
    if not (V and V.store) then return false end
    local ok, s = pcall(V.store)
    return ok and s.models and s.models[model] ~= nil or false
end

-- the "e3d" args for one entity (spawn + rotation + motion with elapsed time), flat strings/numbers only
local function entityArgs(id, e, t)
    M.settleIfDone(e, t)
    local a = { id = id, model = e.model, x = e.x, y = e.y, z = e.z, h = e.h, scale = e.scale,
        rx = e.rx, ry = e.ry, rz = e.rz, spin = e.spin, roll = e.roll, face = e.face, upload = isUpload(e.model) }
    local m = e.motion
    if m then
        a.elapsed = math.max(0, t - m.t0)
        if m.kind == "path" then a.path = m.path; a.speed = m.speed; a.loop = m.loop
        else a.tox = m.tx; a.toy = m.ty; a.toz = m.tz; a.dur = m.dur; a.ease = m.ease end
    end
    return a
end

local function motionArgs(id, m, t)
    local a = { id = id, elapsed = math.max(0, t - m.t0) }
    if m.kind == "path" then a.path = m.path; a.speed = m.speed; a.loop = m.loop
    else a.tox = m.tx; a.toy = m.ty; a.toz = m.tz; a.dur = m.dur; a.ease = m.ease end
    return a
end

-- parse motion arguments (shared by spawn and move); returns a motion table or nil
local function motionFrom(a, e, t)
    local path = pathString(a.path)
    if path then
        return { kind = "path", path = path, speed = U.num(a, "speed", 1, 0), loop = U.oneOf(a, "loop", { "loop", "pingpong", "once" }, "loop"), t0 = t }
    end
    if a.tox ~= nil or a.toy ~= nil or a.toz ~= nil then
        local tx, ty, tz = num(a.tox, e.x), num(a.toy, e.y), num(a.toz, e.z)
        local dur = tonumber(a.duration) or tonumber(a.dur)
        if not dur then
            local speed = num(a.speed, 0)
            dur = speed > 0 and math.sqrt((tx - e.x) ^ 2 + (ty - e.y) ^ 2) / speed or 0
        end
        return { kind = "to", tx = tx, ty = ty, tz = tz, dur = dur, ease = U.bool(a, "ease", false), t0 = t }
    end
    return nil
end

local function rotationInto(e, a)
    if a.rx ~= nil then e.rx = U.num(a, "rx") end
    if a.ry ~= nil then e.ry = U.num(a, "ry") end
    if a.rz ~= nil then e.rz = U.num(a, "rz") end
    if a.spin ~= nil then
        local s = a.spin
        if type(s) == "table" then s = tostring(s[1] or 0) .. "," .. tostring(s[2] or 0) .. "," .. tostring(s[3] or 0) end
        e.spin = tostring(s)
        if e.spin == "" then e.spin = nil end
    end
    if a.roll ~= nil then e.roll = U.num(a, "roll", 0, 0); if e.roll <= 0 then e.roll = nil end end
    if a.face ~= nil then e.face = U.bool(a, "face", false) end
    if a.h ~= nil then e.h = U.num(a, "h") end
    if a.scale ~= nil then e.scale = U.num(a, "scale", 1, 0.001) end
end

---------------------------------------------------------------- resend + client replies
function M.sendAllTo(player)
    local t = Z.now()
    local n = 0
    for id, e in pairs(store()) do
        send("e3d", entityArgs(id, e, t), player)
        n = n + 1
    end
    return n
end

local function userOf(player)
    local ok, u = pcall(function() return player:getUsername() end)
    return ok and u or "?"
end

-- "hello" is answered by Api/Visuals.lua (V.sendAllTo), which calls M.sendAllTo LAST so that a late joiner has every
-- model registered (and every placement) before its entities arrive; only the client replies are handled here.
M.handlers.OnClientCommand = function(module, command, player, args)
    if module ~= "zmcp" then return end
    args = args or {}
    if command == "e3dResult" then
        local user = userOf(player)
        M.clients[user] = M.clients[user] or {}
        M.clients[user][tostring(args.id)] = { ok = args.ok, model = args.model, err = args.err, t = Z.now() }
        Z.event("client_entity3d", { id = args.id, user = user, ok = args.ok, model = args.model, err = args.err, tries = args.tries })
    end
end
for ev, fn in pairs(M.handlers) do if Events[ev] then Events[ev].Add(fn) end end

---------------------------------------------------------------- tools
Z.tool("entity3d_spawn", "Show a moving 3D entity on every client: a registered runtime model (model_upload id) or a vanilla ModelScript name, drawn on a transparent 3D layer synced to the iso camera (smooth, no chunk-cache flicker, always on top). args: {id?, model, x, y, z? (level), h? (height above ground in tiles), scale?, rx?, ry?, rz? (degrees), spin? ('dx,dy,dz' deg/s), roll? (wheel radius in tiles: faces the travel direction and rolls), face? (turn into the travel direction), path? ('x,y,z;x,y,z' or [[x,y,z],..] waypoints after x,y), speed? (tiles/s, default 1), loop? (loop|pingpong|once), tox?, toy?, toz?, duration?|speed? (tween instead of path), ease?}. Returns {id, model}. Clients answer client_entity3d events.", function(a)
    local id
    if a.id ~= nil and a.id ~= "" then id = checkId(tostring(a.id)) else M.seq = M.seq + 1; id = "e" .. M.seq end
    local model = U.str(a, "model")
    local t = Z.now()
    local e = { model = model, x = U.num(a, "x"), y = U.num(a, "y"), z = U.num(a, "z", 0), h = 0, scale = 1, rx = 0, ry = 0, rz = 0, created = t }
    rotationInto(e, a)
    if a.h == nil and e.roll then e.h = e.roll end
    e.motion = motionFrom(a, e, t)
    store()[id] = e
    send("e3d", entityArgs(id, e, t))
    Z.event("entity3d_spawn", { id = id, model = model, x = e.x, y = e.y, z = e.z })
    return { id = id, model = model, x = e.x, y = e.y, z = e.z, h = e.h, motion = e.motion and e.motion.kind or "static", note = "clients report client_entity3d events" }
end)

Z.tool("entity3d_move", "Move a 3D entity smoothly: tween to x,y,z over duration seconds (or at speed tiles/s, ease? for smooth start/stop), or follow a path ('x,y,z;...' from the current position) at speed with loop = loop|pingpong|once. Without motion args it jumps to x,y,z. args: {id, x?, y?, z?, duration?, speed?, ease?, path?, loop?}", function(a)
    local id, e = get(a)
    local t = Z.now()
    settle(e, t)
    local args = { id = id }
    if a.path ~= nil then
        e.motion = motionFrom(a, e, t)
    elseif a.x ~= nil or a.y ~= nil or a.z ~= nil then
        local tx, ty, tz = num(a.x, e.x), num(a.y, e.y), num(a.z, e.z)
        if a.duration ~= nil or a.dur ~= nil or a.speed ~= nil then
            e.motion = motionFrom({ tox = tx, toy = ty, toz = tz, duration = a.duration or a.dur, speed = a.speed, ease = a.ease }, e, t)
        else
            e.x, e.y, e.z = tx, ty, tz
            args.x, args.y, args.z = tx, ty, tz
        end
    end
    if e.motion then
        for k, v in pairs(motionArgs(id, e.motion, t)) do args[k] = v end
    end
    send("e3dMove", args)
    local x, y, z = M.positionAt(e, t)
    return { id = id, x = x, y = y, z = z, motion = e.motion and e.motion.kind or "static", duration = e.motion and e.motion.dur or nil }
end)

Z.tool("entity3d_rotate", "Set a 3D entity's rotation (degrees), constant spin, rolling radius, facing, height or scale. args: {id, rx?, ry?, rz?, spin? ('dx,dy,dz' deg/s, '' to stop), roll? (radius in tiles, 0 = off), face?, h?, scale?}", function(a)
    local id, e = get(a)
    rotationInto(e, a)
    local args = { id = id, rx = e.rx, ry = e.ry, rz = e.rz, spin = e.spin or "", roll = e.roll or 0, face = e.face and true or false, h = e.h, scale = e.scale }
    send("e3dRotate", args)
    return { id = id, rx = e.rx, ry = e.ry, rz = e.rz, spin = e.spin, roll = e.roll, face = e.face, h = e.h, scale = e.scale }
end)

Z.tool("entity3d_remove", "Remove one 3D entity (id) or all of them (all = true) on every client.", function(a)
    local s = store()
    if U.bool(a, "all", false) then
        local n = 0
        for id in pairs(s) do s[id] = nil; n = n + 1 end
        send("e3dRemove", {})
        return { removed = n }
    end
    local id = get(a)
    s[id] = nil
    send("e3dRemove", { id = id })
    return { removed = id }
end)

Z.tool("entity3d_list", "Registered 3D entities with their current (computed) position and motion: [{id, model, x, y, z, h, scale, rotation, spin, roll, face, motion, moving, clients}].", function()
    local out = {}
    local t = Z.now()
    for id, e in pairs(store()) do
        M.settleIfDone(e, t)
        local x, y, z, moving = M.positionAt(e, t)
        local clients = {}
        for user, list in pairs(M.clients) do if list[id] then clients[user] = list[id] end end
        out[#out + 1] = { id = id, model = e.model, x = U.round(x, 2), y = U.round(y, 2), z = U.round(z, 2), h = e.h, scale = e.scale,
            rotation = { e.rx, e.ry, e.rz }, spin = e.spin, roll = e.roll, face = e.face,
            motion = e.motion and e.motion.kind or "static", moving = moving, loop = e.motion and e.motion.loop or nil, clients = clients }
    end
    table.sort(out, function(p, q) return p.id < q.id end)
    return arr(out)
end)

Z.event("models_loaded", { version = M.version })
