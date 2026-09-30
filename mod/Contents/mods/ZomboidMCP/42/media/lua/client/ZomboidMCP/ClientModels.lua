-- Zomboid MCP client: generic file push, runtime 3D model registration (static models) and moving 3D
-- entities (a transparent UI3DScene layer synced to the iso camera). See docs/ENGINE_NOTES.md "Runtime 3D".
--   "file"  {id, gen, part, total, data, path}   base64 chunks -> ~/Zomboid/Lua/<path> (subdirs are created)
--   "model" {id, gen, mesh, texture, scale}      ModelScript registration once both files are present:
--       ms = ModelScript.new(); ms:setModule(getScriptManager():getModule("Base")); ms:InitLoadPP(name)
--       ms:Load(name, "{ mesh = <abs .x under media/>, texture = <abs .png>, scale = N, }"); addModelScript(ms)
--   The model name is "zmcp_<id>_<gen>" (a new upload = new files + new name; the loader caches by path).
--   ZMCPClient.models.name(id) gives the current model name for item:setWorldStaticModel(name).
--   "place" {pid, x, y, z, model, name, gen, item, itemId, ox, oy, oz, yrot}   a model_place placement: kept in
--       ZMCPClient.models.placements; when its square is loaded (LoadGridsquare) or its model registers, the
--       carrier world item gets the model re-applied if it lost it and the chunk is marked for a redraw.
--       Until the ModelScript is registered the engine draws the carrier item's flat sprite instead
--       (ItemModelRenderer: NoModel, re-evaluated every frame, nothing is cached).
--   "placeRemove" {pid?}   forget one placement or all.
--   "e3d" {id, model, x, y, z, h, scale, rx, ry, rz, spin, roll, face, path, speed, loop, tox, toy, toz, dur,
--          ease, elapsed}      create/replace a moving 3D entity (ZMCPClient.e3d, below)
--   "e3dMove" {id, ...motion}, "e3dRotate" {id, rx, ry, rz, spin, roll, face}, "e3dRemove" {id?}
require "ISUI/ISUIElement"
ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.files = C.files or {}
local F = C.files
F.pending = F.pending or {}     -- id -> { gen, total, parts, got, path }
F.done = F.done or {}           -- path -> bytes
C.models = C.models or {}
local M = C.models
M.list = M.list or {}           -- id -> { name, gen, mesh, texture, scale, ok, err }
M.waiting = M.waiting or {}     -- id -> model args waiting for files
M.placements = M.placements or {}   -- pid -> place args (model_place registry as streamed by the server)
M.handlers = M.handlers or {}
M.stats = M.stats or { reapplied = 0, redraws = 0 }
M.DIRTY_ITEM_MODIFY = 16        -- FBORenderChunk.DIRTY_ITEM_MODIFY: redraw the cached chunk level (world items live in it)
for ev, fn in pairs(M.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
M.handlers = {}

local function log(msg) if C.log then C.log(msg) else print("[ZomboidMCP] " .. tostring(msg)) end end

function F.absPath(rel)
    local sep = getFileSeparator()
    return getMyDocumentFolder() .. sep .. "Lua" .. sep .. (rel:gsub("/", sep))
end

-- "file" command
function F.onChunk(a)
    local id = tostring(a.id)
    local gen, part, total = tonumber(a.gen) or 1, tonumber(a.part) or 1, tonumber(a.total) or 1
    local path = tostring(a.path or ("zmcp_file_" .. id))
    if path:find("%.%.") then log("file " .. id .. ": refusing path " .. path); return end
    local p = F.pending[id]
    if not p or p.gen ~= gen or p.total ~= total then
        p = { gen = gen, total = total, parts = {}, got = 0, path = path }
        F.pending[id] = p
    end
    if not p.parts[part] then p.got = p.got + 1 end
    p.parts[part] = a.data or ""
    if p.got < total then return end
    F.pending[id] = nil
    local ok, bytes = pcall(C.b64.decodeToFile, table.concat(p.parts), path)
    if not ok then
        log("file " .. path .. " write failed: " .. tostring(bytes))
        C.send("fileResult", { id = id, gen = gen, path = path, ok = false, err = tostring(bytes) })
        return
    end
    F.done[path] = bytes
    log("file " .. path .. " written (" .. bytes .. " bytes)")
    C.send("fileResult", { id = id, gen = gen, path = path, ok = true, bytes = bytes })
    M.tryRegisterWaiting()
end

function M.name(id)
    local m = M.list[tostring(id)]
    return m and m.name or nil
end

local function register(a)
    local id, gen = tostring(a.id), tonumber(a.gen) or 1
    local name = "zmcp_" .. id .. "_" .. gen
    local mesh, tex = F.absPath(tostring(a.mesh)), F.absPath(tostring(a.texture))
    local scale = tonumber(a.scale) or 1
    local ok, err = pcall(function()
        local ms = ModelScript.new()
        ms:setModule(getScriptManager():getModule("Base"))
        ms:InitLoadPP(name)
        ms:Load(name, string.format("{ mesh = %s, texture = %s, scale = %s, }", mesh, tex, tostring(scale)))
        getScriptManager():addModelScript(ms)
    end)
    M.list[id] = { name = name, gen = gen, mesh = a.mesh, texture = a.texture, scale = scale, ok = ok, err = ok and nil or tostring(err) }
    if ok then log("model " .. id .. " registered as " .. name)
    else log("model " .. id .. " failed: " .. tostring(err)) end
    C.send("modelResult", { id = id, gen = gen, name = name, ok = ok, err = ok and nil or tostring(err) })
    if ok then M.refreshPlacements(name) end
end

-- "model" command: register now if both files are here, otherwise when their "file" pushes finish
function M.onModel(a)
    local id = tostring(a.id)
    local old = M.list[id]
    if old and old.ok and old.gen == (tonumber(a.gen) or 1) then return end
    if F.done[tostring(a.mesh)] and F.done[tostring(a.texture)] then register(a)
    else M.waiting[id] = a end
end

function M.tryRegisterWaiting()
    for id, a in pairs(M.waiting) do
        if F.done[tostring(a.mesh)] and F.done[tostring(a.texture)] then
            M.waiting[id] = nil
            register(a)
        end
    end
end

function M.clear(id)
    if id then M.list[tostring(id)] = nil; M.waiting[tostring(id)] = nil
    else M.list = {}; M.waiting = {} end
end

function M.info()
    local out = {}
    for id, m in pairs(M.list) do out[#out + 1] = id .. "=" .. m.name .. (m.ok and "" or " (failed)") end
    table.sort(out)
    return out
end

---------------------------------------------------------------- static placements (model_place)
local function try(fn, ...) local ok, v = pcall(fn, ...); if ok then return v end return nil end

-- the carrier world item of a placement on a loaded square: IsoWorldInventoryObject, InventoryItem
function M.findCarrier(sq, p)
    local list = sq:getWorldObjects()
    if not list then return nil end
    local best, bestWo
    for i = 0, list:size() - 1 do
        local wo = list:get(i)
        local item = wo and wo:getItem()
        if item then
            if p.itemId and try(function() return item:getID() end) == tonumber(p.itemId) then return wo, item end
            if try(function() return item:getFullType() end) == p.item then
                local model = try(function() return item:getWorldStaticModel() end)
                if model == p.name then return wo, item end
                local ours = type(model) == "string" and string.sub(model, 1, 5) == "zmcp_"   -- another runtime model: not ours
                if not ours and not best then best, bestWo = item, wo end
            end
        end
    end
    return bestWo, best
end

-- re-apply one placement if its square is loaded: "ok" | "restored" | "missing" | nil (square not loaded)
function M.applyPlacement(p)
    if not getCell then return nil end
    local sq = getCell():getGridSquare(math.floor(tonumber(p.x) or 0), math.floor(tonumber(p.y) or 0), math.floor(tonumber(p.z) or 0))
    if not sq then return nil end
    local wo, item = M.findCarrier(sq, p)
    if not item then return "missing" end
    local result = "ok"
    if try(function() return item:getWorldStaticModel() end) ~= p.name then
        item:setWorldStaticModel(p.name)
        if p.yrot then pcall(function() item:setWorldYRotation(tonumber(p.yrot)) end) end
        M.stats.reapplied = M.stats.reapplied + 1
        result = "restored"
    end
    -- the chunk FBO may still hold the flat fallback sprite: ask for a redraw of that level
    if pcall(function() sq:invalidateRenderChunkLevel(M.DIRTY_ITEM_MODIFY) end) then M.stats.redraws = M.stats.redraws + 1 end
    return result
end

function M.onPlace(a)
    local pid = tostring(a.pid or "")
    if pid == "" then return end
    M.placements[pid] = a
    M.applyPlacement(a)
end

function M.onPlaceRemove(a)
    if a.pid then M.placements[tostring(a.pid)] = nil else M.placements = {} end
end

-- after a model registered: every placement using it on a loaded square gets a redraw / re-apply
function M.refreshPlacements(modelName)
    for _, p in pairs(M.placements) do
        if not modelName or p.name == modelName then pcall(M.applyPlacement, p) end
    end
end

function M.placementsAt(x, y, z)
    local out = {}
    for _, p in pairs(M.placements) do
        if math.floor(tonumber(p.x) or -1) == x and math.floor(tonumber(p.y) or -1) == y and math.floor(tonumber(p.z) or -1) == z then out[#out + 1] = p end
    end
    return out
end

-- a square came in (chunk load / late join): placements on it get their model back if needed
M.handlers.LoadGridsquare = function(sq)
    if C.isEmpty and C.isEmpty(M.placements) then return end
    local ok, err = pcall(function()
        for _, p in ipairs(M.placementsAt(sq:getX(), sq:getY(), sq:getZ())) do M.applyPlacement(p) end
    end)
    if not ok then log("placement reapply failed: " .. tostring(err)) end
end
for ev, fn in pairs(M.handlers) do if Events[ev] then Events[ev].Add(fn) end end

---------------------------------------------------------------- moving 3D entities: UI3DScene layer
-- Why a UI3DScene: world items live in cached chunk FBOs (animating them flickers), zombies/vehicles cannot be
-- rotated per frame from Lua. zombie.vehicles.UI3DScene (the vehicle/attachment/sprite-model editors' viewport)
-- is Lua-exposed, draws any registered ModelScript with an arbitrary translate/rotate/scale every frame, clears
-- only the depth buffer (transparent) and, with setView("UserDefined") + setViewRotation(30, 315, 0), uses the
-- same 2:1 orthographic iso projection as the game (SpriteModelEditor previews tiles that way). We keep one
-- full-screen, click-through layer below the 2D overlay, calibrate its scene->pixel matrix every frame from
-- sceneToUIX/Y and place each entity so that it lands on isoToScreenX/Y(world position). No wall occlusion
-- (owner preference), works in single player and on every MP client (pure client side, driven by server state).
C.e3d = C.e3d or {}
local E = C.e3d
E.list = E.list or {}            -- id -> entity
E.layer = E.layer or nil         -- ISUIElement whose javaObject is a UI3DScene
E.PITCH, E.YAW = 30, 315         -- iso camera (SpriteModelEditor:resetView)
E.ZOOM = 7                       -- scene zoom; the scale is calibrated per frame so the value only sets precision
E.TILE_PX = 32                   -- screen px per tile along world x at zoom 1 (isoToScreenX: (x - y) * 32)
E.LEVEL_PX = 96                  -- screen px per z level at zoom 1
E.MODEL_SCALE = 1                -- global fudge if scene models turn out larger/smaller than world models
E.RETRY = 2                      -- seconds between createModel retries (model files may still be loading)
E.stats = E.stats or { frames = 0, errors = 0, created = 0 }
E.calib = E.calib or nil

local function isEmpty(t) for _ in pairs(t) do return false end return true end
local function num(v, d) local n = tonumber(v); if n == nil then return d end; return n end
local function flag(v) return v == true or v == 1 or v == "1" or v == "true" end
local function vec3(s)
    if s == nil or s == "" then return nil end
    local x, y, z = string.match(tostring(s), "^%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)")
    if not x then return nil end
    return { tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0 }
end

-- the layer: a full-screen ISUIElement whose Java object is a UI3DScene (like vanilla ISUI3DScene), no
-- background, click-through; positions are updated in prerender so the same frame draws them
local Layer = ISUIElement:derive("ZMCP3DLayer")
function Layer:new()
    local o = ISUIElement.new(self, 0, 0, getCore():getScreenWidth(), getCore():getScreenHeight())
    o.background = false
    return o
end
function Layer:instantiate()
    self.javaObject = UI3DScene.new(self)
    self.javaObject:setX(self.x)
    self.javaObject:setY(self.y)
    self.javaObject:setWidth(self.width)
    self.javaObject:setHeight(self.height)
    self.javaObject:setAnchorLeft(self.anchorLeft)
    self.javaObject:setAnchorRight(self.anchorRight)
    self.javaObject:setAnchorTop(self.anchorTop)
    self.javaObject:setAnchorBottom(self.anchorBottom)
    self.javaObject:setConsumeMouseEvents(false)
end
function Layer:prerender()
    local ok, err = pcall(E.frame, self)
    if not ok then
        E.stats.errors = E.stats.errors + 1
        if E.stats.errors <= 3 then log("e3d frame error: " .. tostring(err)) end
    end
end
function Layer:onMouseDown() return false end
function Layer:onMouseUp() return false end
function Layer:onMouseMove() return false end
function Layer:onMouseWheel() return false end

function E.setupScene(J)
    J:fromLua1("setView", "UserDefined")
    J:fromLua3("setViewRotation", E.PITCH, E.YAW, 0)
    J:fromLua1("setMaxZoom", 100)
    J:fromLua1("setZoom", E.ZOOM)
    J:fromLua1("setDrawGrid", false)
    J:fromLua1("setDrawGridAxes", false)
    J:fromLua1("setDrawGridPlane", false)
    J:fromLua1("setGizmoVisible", "none")
end

function E.ensureLayer()
    if E.layer then return E.layer end
    if not UI3DScene then error("UI3DScene is not available in this Lua state") end
    if C.ensureOverlay then C.ensureOverlay() end
    local o = Layer:new()
    o:initialise()
    o:instantiate()
    o:addToUIManager()
    o:backMost()                      -- below the 2D overlay (added earlier), above the world
    E.setupScene(o.javaObject)
    E.layer = o
    E.calib = nil
    return o
end

-- affine scene -> screen map from the scene's own projection (orthographic, so 4 probes describe it)
function E.calibrate(J)
    local u0, v0 = J:sceneToUIX(0, 0, 0), J:sceneToUIY(0, 0, 0)
    local c = {
        u0 = u0, v0 = v0,
        ax = J:sceneToUIX(1, 0, 0) - u0, bx = J:sceneToUIY(1, 0, 0) - v0,
        ay = J:sceneToUIX(0, 1, 0) - u0, by = J:sceneToUIY(0, 1, 0) - v0,
        az = J:sceneToUIX(0, 0, 1) - u0, bz = J:sceneToUIY(0, 0, 1) - v0,
    }
    if math.abs(c.ax) < 1e-6 or math.abs(c.by) < 1e-6 then return nil end
    c.sx = c.ax > 0 and 1 or -1         -- world +x moves right on screen
    c.sz = c.az < 0 and 1 or -1         -- world +y moves left on screen
    c.sy = c.by < 0 and 1 or -1         -- up is negative screen y
    E.calib = c
    return c
end

---------------------------------------------------------------- motion (mirrored in Api/Models.lua)
-- "x,y,z;x,y,z" -> { {x,y,z}, ... }
local function parsePath(str, z)
    local pts = {}
    for seg in string.gmatch(tostring(str or ""), "[^;]+") do
        local x, y, pz = string.match(seg, "^%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,?%s*([%-%d%.]*)")
        if x and y then pts[#pts + 1] = { tonumber(x), tonumber(y), tonumber(pz) or z } end
    end
    return pts
end
E.parsePath = parsePath

local function pathLength(pts)
    local total, segs = 0, {}
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local d = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
        segs[i] = d
        total = total + d
    end
    return total, segs
end

-- world position at time t: x, y, z, dx, dy (travel direction), dist (signed distance rolled), moving
function E.positionAt(e, t)
    local m = e.motion
    if not m then return e.x, e.y, e.z, 0, 0, e.dist0 or 0, false end
    if m.kind == "path" then
        local pts = m.pts
        if #pts < 2 or m.speed <= 0 or m.length <= 0 then return pts[1][1], pts[1][2], pts[1][3], 0, 0, e.dist0 or 0, false end
        local dist = m.speed * (t - m.t0)
        local dir, rolled = 1, dist
        if m.loop == "once" then
            if dist >= m.length then local p = pts[#pts]; return p[1], p[2], p[3], 0, 0, (e.dist0 or 0) + m.length, false end
        elseif m.loop == "pingpong" then
            local cycle = dist % (2 * m.length)
            if cycle > m.length then dist = 2 * m.length - cycle; dir = -1 else dist = cycle end
            rolled = dist
        else
            dist = dist % m.length
        end
        for i = 1, #pts - 1 do
            local d = m.segs[i]
            if dist <= d or i == #pts - 1 then
                local a, b = pts[i], pts[i + 1]
                local f = d > 0 and math.min(dist / d, 1) or 0
                return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f,
                    (b[1] - a[1]) * dir, (b[2] - a[2]) * dir, (e.dist0 or 0) + rolled, true
            end
            dist = dist - d
        end
        local p = pts[#pts]
        return p[1], p[2], p[3], 0, 0, (e.dist0 or 0) + rolled, false
    elseif m.kind == "to" then
        local f = m.dur > 0 and math.min(1, math.max(0, (t - m.t0) / m.dur)) or 1
        if m.ease then f = f * f * (3 - 2 * f) end
        local dx, dy, dz = m.tx - m.fx, m.ty - m.fy, m.tz - m.fz
        local len = math.sqrt(dx * dx + dy * dy)
        return m.fx + dx * f, m.fy + dy * f, m.fz + dz * f, dx, dy, (e.dist0 or 0) + len * f, f < 1
    end
    return e.x, e.y, e.z, 0, 0, e.dist0 or 0, false
end

-- freeze the current position into the entity (before a new motion starts)
local function settle(e, t)
    local x, y, z, _, _, dist = E.positionAt(e, t)
    e.x, e.y, e.z, e.dist0 = x, y, z, dist
    e.motion = nil
end

local function applyMotion(e, a, t)
    local elapsed = num(a.elapsed, 0)
    if a.path and a.path ~= "" then
        local pts = { { e.x, e.y, e.z } }
        for _, p in ipairs(parsePath(a.path, e.z)) do pts[#pts + 1] = p end
        local length, segs = pathLength(pts)
        e.motion = { kind = "path", pts = pts, length = length, segs = segs, speed = num(a.speed, 1),
            loop = tostring(a.loop or "loop"), t0 = t - elapsed }
    elseif a.tox ~= nil or a.toy ~= nil then
        local tx, ty, tz = num(a.tox, e.x), num(a.toy, e.y), num(a.toz, e.z)
        local len = math.sqrt((tx - e.x) ^ 2 + (ty - e.y) ^ 2)
        local dur = tonumber(a.dur)
        if not dur then
            local speed = num(a.speed, 0)
            dur = speed > 0 and len / speed or 0
        end
        e.motion = { kind = "to", fx = e.x, fy = e.y, fz = e.z, tx = tx, ty = ty, tz = tz, dur = dur, ease = flag(a.ease), t0 = t - elapsed }
    end
end

local function applyRotation(e, a)
    if a.rx ~= nil then e.rx = num(a.rx, 0) end
    if a.ry ~= nil then e.ry = num(a.ry, 0) end
    if a.rz ~= nil then e.rz = num(a.rz, 0) end
    if a.spin ~= nil then e.spin = vec3(a.spin) end
    if a.roll ~= nil then e.roll = num(a.roll, 0); if e.roll <= 0 then e.roll = nil end end
    if a.face ~= nil then e.face = flag(a.face) end
    if a.h ~= nil then e.h = num(a.h, 0) end
    if a.scale ~= nil then e.scale = num(a.scale, 1) end
end

---------------------------------------------------------------- commands
function E.objName(id) return "zmcp_e3d_" .. tostring(id) end

-- "e3d": create or replace an entity
function E.set(a)
    local id = tostring(a.id or "e3d")
    local t = C.now()
    local old = E.list[id]
    local e = { id = id, modelId = tostring(a.model or ""), obj = E.objName(id),
        x = num(a.x, 0), y = num(a.y, 0), z = num(a.z, 0), h = num(a.h, 0), scale = num(a.scale, 1),
        rx = num(a.rx, 0), ry = num(a.ry, 0), rz = num(a.rz, 0), spin = vec3(a.spin), roll = tonumber(a.roll),
        face = flag(a.face), upload = flag(a.upload), t0 = t, dist0 = 0, created = false, tries = 0, nextTry = 0 }
    if e.roll and e.roll <= 0 then e.roll = nil end
    applyMotion(e, a, t)
    if old and old.created then
        -- keep the scene object, just retarget it (a new model name means re-create)
        if old.modelName == E.resolveModel(e.modelId, e.upload) then e.created, e.modelName = true, old.modelName
        else E.dropObject(old) end
    end
    E.list[id] = e
    E.ensureLayer()
    return e
end

function E.move(a)
    local e = E.list[tostring(a.id or "")]
    if not e then log("e3dMove: unknown entity " .. tostring(a.id)); return end
    local t = C.now()
    settle(e, t)
    if a.x ~= nil then e.x = num(a.x, e.x) end
    if a.y ~= nil then e.y = num(a.y, e.y) end
    if a.z ~= nil then e.z = num(a.z, e.z) end
    applyMotion(e, a, t)
end

function E.rotate(a)
    local e = E.list[tostring(a.id or "")]
    if not e then log("e3dRotate: unknown entity " .. tostring(a.id)); return end
    applyRotation(e, a)
end

function E.dropObject(e)
    if e.created and E.layer then pcall(function() E.layer.javaObject:fromLua1("removeObject", e.obj) end) end
    e.created = false
end

function E.remove(id)
    if id then
        local e = E.list[tostring(id)]
        if e then E.dropObject(e); E.list[tostring(id)] = nil end
    else
        for _, e in pairs(E.list) do E.dropObject(e) end
        E.list = {}
    end
end

-- model id (upload) -> registered ModelScript name; anything else is used verbatim (vanilla model scripts).
-- upload = the server says this id is one of its uploads: wait for the registration (files may be in flight)
function E.resolveModel(modelId, upload)
    local m = M.list[modelId]
    if m then return m.ok and m.name or nil end
    if upload or M.waiting[modelId] then return nil end
    return modelId
end

local function create(e, J, t)
    if t < e.nextTry then return false end
    local name = E.resolveModel(e.modelId, e.upload)
    if not name then e.nextTry = t + 0.5; return false end     -- files still in flight
    e.tries = e.tries + 1
    e.nextTry = t + E.RETRY
    local ok, err = pcall(function()
        if J:fromLua1("getObjectExists", e.obj) then J:fromLua1("removeObject", e.obj) end
        J:fromLua2("createModel", e.obj, name)
    end)
    if ok then
        e.created, e.modelName, e.err = true, name, nil
        E.stats.created = E.stats.created + 1
        C.send("e3dResult", { id = e.id, ok = true, model = name })
        return true
    end
    e.err = tostring(err)
    if e.tries == 1 or e.tries == 5 then
        log("e3d " .. e.id .. ": createModel(" .. name .. ") failed: " .. e.err)
        C.send("e3dResult", { id = e.id, ok = false, model = name, err = e.err, tries = e.tries })
    end
    if e.tries >= 5 then e.nextTry = t + 30 end
    return false
end

-- per frame: calibrate, then place every entity so it projects onto isoToScreenX/Y(world position)
function E.frame(layer)
    if isEmpty(E.list) then return end
    E.stats.frames = E.stats.frames + 1
    local J = layer.javaObject
    local sw, sh = C.screen()
    if layer:getWidth() ~= sw or layer:getHeight() ~= sh then layer:setWidth(sw); layer:setHeight(sh) end
    local c = E.calibrate(J)
    if not c then return end
    local zoom = C.zoom()
    local k = (E.TILE_PX / zoom) / math.abs(c.ax)             -- scene units per world tile
    local ky = (E.LEVEL_PX / zoom) / math.abs(c.by)           -- scene units per z level
    local ox, oy = 0, 0
    pcall(function() ox = layer:getAbsoluteX(); oy = layer:getAbsoluteY() end)
    local cx = screenToIsoX(0, c.u0 + ox, c.v0 + oy, 0)       -- world point under the scene origin
    local cy = screenToIsoY(0, c.u0 + ox, c.v0 + oy, 0)
    local t = C.now()
    for _, e in pairs(E.list) do
        if not e.created then create(e, J, t) end
        if e.created then
            local wx, wy, wz, dx, dy, dist = E.positionAt(e, t)
            local X = (wx - cx) * k * c.sx
            local Z = (wy - cy) * k * c.sz
            local Y = (wz * ky + e.h * k) * c.sy
            local rx, ry, rz = e.rx, e.ry, e.rz
            if e.spin then
                local age = t - e.t0
                rx, ry, rz = rx + e.spin[1] * age, ry + e.spin[2] * age, rz + e.spin[3] * age
            end
            if (e.face or e.roll) and (dx ~= 0 or dy ~= 0) then
                -- model +X points along the travel direction (rotation about Y maps +X to (cos, 0, -sin))
                e.heading = math.deg(math.atan2(-(dy * c.sz), dx * c.sx))
            end
            if (e.face or e.roll) and e.heading then ry = ry + e.heading end
            if e.roll then rz = rz - math.deg(dist / e.roll) end   -- wheel: top moves forward = negative about Z
            local s = k * e.scale * E.MODEL_SCALE
            J:fromLua1("getObjectTranslation", e.obj):set(X, Y, Z)
            J:fromLua1("getObjectRotation", e.obj):set(rx, ry, rz)
            J:fromLua1("getObjectScale", e.obj):set(s, s, s)
        end
    end
end

function E.info()
    local out = {}
    local t = C.now()
    for id, e in pairs(E.list) do
        local x, y, z = E.positionAt(e, t)
        out[#out + 1] = string.format("%s model=%s at %.1f,%.1f,%.1f %s", id, tostring(e.modelName or e.modelId), x, y, z,
            e.created and "ok" or ("pending" .. (e.err and (": " .. e.err) or "")))
    end
    table.sort(out)
    return out
end

-- command table entries (Client.lua keeps C.commands across its own load)
C.commands = C.commands or {}
C.commands.place = function(a) M.onPlace(a) end
C.commands.placeRemove = function(a) M.onPlaceRemove(a) end
C.commands.e3d = function(a) E.set(a) end
C.commands.e3dMove = function(a) E.move(a) end
C.commands.e3dRotate = function(a) E.rotate(a) end
C.commands.e3dRemove = function(a) E.remove(a.id) end
