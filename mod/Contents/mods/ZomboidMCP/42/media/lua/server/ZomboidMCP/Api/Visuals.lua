-- Zomboid MCP: visual tools (server side). Pushes code, textures, 3D models, sprites, falling items and
-- overlays to every player's client mod (client/ZomboidMCP/Client.lua) through sendServerCommand("zmcp", cmd, args).
-- Protocol: docs/PROTOCOL.md part 2. Builds only on the public ZMCP API of Bridge.lua.
--
-- Persistent state (small) lives in ModData "ZomboidMCP".visuals = { textures, models, sprites, cscripts } so
-- late joiners get everything again when their client says "hello". Texture/model data stays in files in the
-- Lua cache dir (zmcp_tex_<id>.b64, zmcp_model_<id>.*.b64), never in ModData or Lua memory (server heap), and
-- is streamed in chunks.
--
-- Tools: run_lua_client, client_results, capture_input, texture_upload, texture_pixel, model_upload, model_place,
--        world_sprite, falling_items, overlay_draw, server_message, visuals_list, clear_visuals,
--        plus the client side of script_install/list/remove (ZMCP.scriptSides.client).
if isClient() then return end
if not ZMCP or not ZMCP.tool then error("Bridge.lua must be loaded before Api/Visuals.lua") end

local Z = ZMCP
local J = ZMCPJson
Z.visuals = Z.visuals or {}
local V = Z.visuals
V.version = ZMCP.version
V.CHUNK = 3000            -- characters per sendServerCommand (see docs/ENGINE_NOTES.md)
V.PER_TICK = 12           -- queued messages sent per tick (~10 ticks/s)
V.MAX_B64 = 1200000       -- refuse textures above this many base64 characters (~900 KB PNG)
V.queue = V.queue or {}   -- outgoing { player, cmd, args }
V.results = V.results or {}   -- exec id -> { to = {users}, sent, results = { [user] = { ok, res, ms, t } } }
V.resultOrder = V.resultOrder or {}
V.clients = V.clients or {}   -- user -> { version, t, textures = {id -> {ok, w, h}}, models = {id -> {ok, name}} }
V.pendingSpawns = V.pendingSpawns or {}
V.seq = V.seq or 0
V.handlers = V.handlers or {}

for ev, fn in pairs(V.handlers) do if Events[ev] then Events[ev].Remove(fn) end end
V.handlers = {}

local function arr(t) if J.array then return J.array(t) end return t end
local function num(v, d) local n = tonumber(v); if n == nil then return d end; return n end

local function store()
    local s = ModData.getOrCreate("ZomboidMCP")
    if type(s.visuals) ~= "table" then s.visuals = {} end
    local vis = s.visuals
    if type(vis.textures) ~= "table" then vis.textures = {} end
    if type(vis.sprites) ~= "table" then vis.sprites = {} end
    if type(vis.cscripts) ~= "table" then vis.cscripts = {} end
    if type(vis.models) ~= "table" then vis.models = {} end
    return vis
end
V.store = store

local function checkId(id, what)
    if type(id) ~= "string" or not id:match("^[%w_%-%.]+$") then
        error((what or "id") .. " must be a string matching [A-Za-z0-9_.-]+")
    end
    return id
end

local function nextId(prefix)
    V.seq = V.seq + 1
    return prefix .. V.seq
end

local function optPlayer(name)
    if name == nil or name == "" then return nil end
    return Z.player(name)
end

---------------------------------------------------------------- outgoing queue
function V.enqueue(cmd, args, player)
    V.queue[#V.queue + 1] = { player = player, cmd = cmd, args = args or {} }
end

-- send text in ~3000-char parts: base args + {part, total, <field>}
function V.enqueueChunked(cmd, base, field, text, player)
    local total = math.max(1, math.ceil(#text / V.CHUNK))
    for part = 1, total do
        local args = {}
        for k, v in pairs(base) do args[k] = v end
        args.part, args.total = part, total
        args[field] = text:sub((part - 1) * V.CHUNK + 1, part * V.CHUNK)
        V.enqueue(cmd, args, player)
    end
    return total
end

local function flushQueue()
    local n = 0
    while #V.queue > 0 and n < V.PER_TICK do
        local m = table.remove(V.queue, 1)
        local ok, err = pcall(Z.toClients, m.cmd, m.args, m.player)
        if not ok then print("[ZomboidMCP] visuals send " .. m.cmd .. " failed: " .. tostring(err)) end
        n = n + 1
    end
end

---------------------------------------------------------------- textures
local function textureFile(id) return "zmcp_tex_" .. id .. ".b64" end

local function readTexture(id)
    local t = store().textures[id]
    if not t then error("unknown texture '" .. id .. "' (see texture_list)") end
    if t.pixel then return t, nil end
    local b64 = Z.readFile(t.file)
    if not b64 or b64 == "" then error("texture file missing in Lua dir: " .. t.file) end
    return t, b64
end

-- stream one texture to everyone or one player
function V.sendTexture(id, player)
    local t, b64 = readTexture(id)
    if t.pixel then
        V.enqueue("pixel", { id = id, def = t.pixel }, player)
        return 1
    end
    return V.enqueueChunked("tex", { id = id, gen = t.gen }, "data", b64, player)
end

-- push a base64 file from the Lua dir to clients as <path> under their Lua dir
function V.sendFile(id, srcFile, path, gen, player)
    local b64 = Z.readFile(srcFile)
    if not b64 or b64 == "" then error("file not found or empty in Lua dir: " .. srcFile) end
    if #b64 > V.MAX_B64 then error("base64 too large: " .. #b64 .. " chars (max " .. V.MAX_B64 .. ")") end
    return V.enqueueChunked("file", { id = id, gen = gen, path = path }, "data", b64, player)
end

function V.sendModel(id, player)
    local m = store().models[id]
    if not m then error("unknown model '" .. id .. "'") end
    local chunks = V.sendFile(id .. ".x", m.meshSrc, m.mesh, m.gen, player) + V.sendFile(id .. ".png", m.texSrc, m.texture, m.gen, player)
    V.enqueue("model", { id = id, gen = m.gen, mesh = m.mesh, texture = m.texture, scale = m.scale }, player)
    return chunks
end

function V.sendSprite(id, player)
    local sp = store().sprites[id]
    if sp then V.enqueue("sprite", sp, player) end
end

function V.sendScript(name, player)
    local m = store().cscripts[name]
    if not m then return 0 end
    local src = Z.readFile(m.file)
    if not src then Z.event("script_error", { name = name, side = "client", error = "file missing: " .. m.file }); return 0 end
    return V.enqueueChunked("exec", { id = "script:" .. name, module = name }, "code", src, player)
end

-- everything a (late-joining) client needs, in dependency order
function V.sendAllTo(player)
    local s = store()
    local n = { textures = 0, scripts = 0, sprites = 0 }
    for id in pairs(s.textures) do
        local ok, err = pcall(V.sendTexture, id, player)
        if ok then n.textures = n.textures + 1 else print("[ZomboidMCP] resend texture " .. id .. ": " .. tostring(err)) end
    end
    n.models = 0
    for id in pairs(s.models) do
        local ok, err = pcall(V.sendModel, id, player)
        if ok then n.models = n.models + 1 else print("[ZomboidMCP] resend model " .. id .. ": " .. tostring(err)) end
    end
    for name in pairs(s.cscripts) do V.sendScript(name, player); n.scripts = n.scripts + 1 end
    for id in pairs(s.sprites) do V.sendSprite(id, player); n.sprites = n.sprites + 1 end
    return n
end

---------------------------------------------------------------- exec result tracking
-- remember which players a script went to, so client_results can say when everyone answered
function V.track(id, to)
    local r = V.results[id]
    if not r then
        r = { to = {}, sent = Z.now(), results = {} }
        V.results[id] = r
        V.resultOrder[#V.resultOrder + 1] = id
        if #V.resultOrder > 50 then V.results[table.remove(V.resultOrder, 1)] = nil end
    end
    if to then r.to = to; r.sent = Z.now() end
    return r
end

function V.resultStatus(id)
    local r = V.results[id]
    if not r then return nil end
    local pending = {}
    for _, user in ipairs(r.to) do if not r.results[user] then pending[#pending + 1] = user end end
    return { id = id, to = arr(r.to), sent = r.sent, results = r.results, pending = arr(pending), done = #pending == 0 }
end

---------------------------------------------------------------- client -> server
local function userOf(player)
    local ok, u = pcall(function() return player:getUsername() end)
    return ok and u or "?"
end

V.onClientCommand = function(module, command, player, args)
    if module ~= "zmcp" then return end
    args = args or {}
    local user = userOf(player)
    if command == "hello" then
        V.clients[user] = { version = args.version, t = Z.now(), textures = {} }
        local n = V.sendAllTo(player)
        Z.event("client_hello", { user = user, version = args.version, sent = n })
    elseif command == "execResult" then
        local id = tostring(args.id)
        local r = V.track(id, nil)
        r.results[user] = { ok = args.ok, res = args.res, ms = args.ms, t = Z.now(), module = args.module }
        Z.event("client_exec_result", { id = id, user = user, ok = args.ok, res = args.res, ms = args.ms, module = args.module })
    elseif command == "fileResult" then
        Z.event("client_file", { id = args.id, gen = args.gen, path = args.path, user = user, ok = args.ok, bytes = args.bytes, err = args.err })
    elseif command == "modelResult" then
        local c = V.clients[user] or { textures = {} }
        V.clients[user] = c
        c.models = c.models or {}
        c.models[tostring(args.id)] = { ok = args.ok, name = args.name, gen = args.gen, err = args.err }
        Z.event("client_model", { id = args.id, gen = args.gen, name = args.name, user = user, ok = args.ok, err = args.err })
    elseif command == "texResult" then
        local c = V.clients[user] or { textures = {} }
        V.clients[user] = c
        c.textures[tostring(args.id)] = { ok = args.ok, w = args.w, h = args.h, gen = args.gen, err = args.err }
        Z.event("client_texture", { id = args.id, gen = args.gen, user = user, ok = args.ok, w = args.w, h = args.h, err = args.err })
    elseif command == "pong" then
        V.clients[user] = V.clients[user] or { textures = {} }
        V.clients[user].version = args.version
        V.clients[user].t = Z.now()
        Z.event("client_pong", { user = user, version = args.version, sprites = args.sprites, textures = args.textures })
    end
end
V.handlers.OnClientCommand = V.onClientCommand
for ev, fn in pairs(V.handlers) do if Events[ev] then Events[ev].Add(fn) end end

---------------------------------------------------------------- tick: queue + landings
Z.tickHooks.visuals = function(t)
    flushQueue()
    if #V.pendingSpawns > 0 then
        local keep = {}
        for _, s in ipairs(V.pendingSpawns) do
            if t >= s.at then
                local ok, err = pcall(function()
                    local sq = Z.square(s.x, s.y, s.z)
                    sq:AddWorldInventoryItem(s.item, s.ox, s.oy, 0)
                end)
                if not ok then Z.event("falling_spawn_error", { item = s.item, x = s.x, y = s.y, z = s.z, error = tostring(err) }) end
            else
                keep[#keep + 1] = s
            end
        end
        V.pendingSpawns = keep
    end
end

---------------------------------------------------------------- tools: code
Z.tool("run_lua_client", "Run Lua on every player's client (or args.player only). args: {code, player?, id?}. Returns {id, to}; each client answers with the chunk's return value (tables JSON-encoded) or error: poll client_results {id} until done, or watch client_exec_result events. Client script API: ZMCPClient.on(name, 'render'|'tick'|'keyDown'|'keyUp'|'keyHeld'|'mouseDown'|'mouseUp'|'mouseMove'|'mouseWheel', fn), ZMCPClient.off(name), ZMCPClient.capture(true) for screen apps, ZMCPClient.tex/sprites/draw/models, ZMCPClient.send(cmd, args), ZMCPJson, plus the whole vanilla client Lua API.", function(a)
    local code = Z.argText(a, "code")
    local player = optPlayer(a.player)
    local id = a.id and checkId(tostring(a.id), "id") or nextId("c")
    local to = {}
    if player then to[1] = userOf(player) else for _, p in ipairs(Z.players()) do to[#to + 1] = userOf(p) end end
    V.track(id, to)
    local chunks = V.enqueueChunked("exec", { id = id }, "code", code, player)
    return { id = id, chunks = chunks, to = arr(to) }
end)

Z.tool("client_results", "Results of run_lua_client / client scripts: args {id} -> {to, results = {user = {ok, res, ms}}, pending, done}. Without id: the status of every kept id (last 50).", function(a)
    if a.id then return V.resultStatus(tostring(a.id)) or error("unknown script id " .. tostring(a.id)) end
    local out = {}
    for _, id in ipairs(V.resultOrder) do out[#out + 1] = V.resultStatus(id) end
    return arr(out)
end)

Z.tool("capture_input", "Screen apps: make every client's (or args.player's) overlay swallow mouse events and sit above the UI (on=true), or release it. args: {on, player?}. Scripts can also call ZMCPClient.capture(true) themselves.", function(a)
    local on = a.on ~= false and a.on ~= 0 and a.on ~= "false"
    V.enqueue("capture", { on = on }, optPlayer(a.player))
    return { on = on }
end)

-- client side of script_install / script_list / script_remove (Bridge.lua dispatches on args.side)
Z.scriptSides.client = {
    install = function(name, code)
        local file = "zmcp_cscript_" .. name .. ".lua.txt"    -- getFileWriter refuses .lua
        Z.writeFile(file, code)
        store().cscripts[name] = { file = file, installed = Z.now() }
        local to = {}
        for _, p in ipairs(Z.players()) do to[#to + 1] = userOf(p) end
        V.track("script:" .. name, to)
        local chunks = V.sendScript(name)
        return { file = file, chunks = chunks, to = arr(to), id = "script:" .. name }
    end,
    remove = function(name)
        if not store().cscripts[name] then error("no such client script: " .. name) end
        store().cscripts[name] = nil
        V.enqueue("scriptRemove", { name = name })
    end,
    list = function()
        local out = {}
        for name, m in pairs(store().cscripts) do out[#out + 1] = { name = name, file = m.file, installed = m.installed } end
        table.sort(out, function(x, y) return x.name < y.name end)
        return arr(out)
    end,
}

---------------------------------------------------------------- tools: textures
-- store base64 text under our own file name (the MCP deletes its blob files after the response)
local function storeBase64(file, text, what)
    if #text > V.MAX_B64 then error(what .. " too large: " .. #text .. " base64 chars (max " .. V.MAX_B64 .. ")") end
    Z.writeFile(file, text)
    return #text
end

Z.tool("texture_upload", "Push a PNG to every client (or args.player) as texture <id>. args: {id, png_base64, player?}. Streamed in ~3 KB chunks and loaded with getTexture on each client; late joiners get it on hello; a re-upload of the same id makes a new generation. Keep PNGs <= 256x256 / 100 KB. Clients report client_texture events (ok, w, h).", function(a)
    local id = checkId(a.id, "id")
    local file = textureFile(id)
    local chars = storeBase64(file, Z.argText(a, "png_base64"), "png_base64")
    local s = store()
    local old = s.textures[id]
    local gen = (old and tonumber(old.gen) or 0) + 1
    s.textures[id] = { file = file, gen = gen, chars = chars, uploaded = Z.now() }
    local chunks = V.sendTexture(id, optPlayer(a.player))
    Z.event("texture_upload", { id = id, gen = gen, chars = chars, chunks = chunks })
    return { id = id, gen = gen, chars = chars, chunks = chunks }
end)

Z.tool("texture_pixel", "Art without a PNG: a pixel sprite drawn with rects. args: {id, def} where def = {w?, h?, palette = {a = {r,g,b,a}}, rows = ['aab.', ...]} ('.' transparent, colours 0-1 or 0-255). Usable wherever a texture id is.", function(a)
    local id = checkId(a.id, "id")
    local def = a.def
    if type(def) == "table" then def = J.encode(def) end
    if type(def) ~= "string" then error("args.def (object or JSON string) required") end
    store().textures[id] = { pixel = def, gen = 1, uploaded = Z.now() }
    V.enqueue("pixel", { id = id, def = def })
    return { id = id, pixel = true }
end)

---------------------------------------------------------------- tools: runtime 3D models (static)
Z.tool("model_upload", "Register a runtime 3D model on every client: args {id, mesh_base64 (PZ .x text mesh), png_base64 (texture), scale?}. Clients write both files under Lua/media/ and register a ModelScript named 'zmcp_<id>_<gen>' (ZMCPClient.models.name(id) in scripts); model_place puts it in the world. Clients report client_model events. See ENGINE_NOTES 'Runtime 3D models'.", function(a)
    local id = checkId(a.id, "id")
    local meshSrc, texSrc = "zmcp_model_" .. id .. ".x.b64", "zmcp_model_" .. id .. ".png.b64"
    storeBase64(meshSrc, Z.argText(a, "mesh_base64"), "mesh_base64")
    storeBase64(texSrc, Z.argText(a, "png_base64"), "png_base64")
    local s = store()
    local gen = (s.models[id] and tonumber(s.models[id].gen) or 0) + 1
    s.models[id] = { meshSrc = meshSrc, texSrc = texSrc, gen = gen, scale = num(a.scale, 1),
        mesh = "media/zmcp_model_" .. id .. "_" .. gen .. ".x", texture = "media/zmcp_model_" .. id .. "_" .. gen .. ".png", uploaded = Z.now() }
    local chunks = V.sendModel(id, optPlayer(a.player))
    Z.event("model_upload", { id = id, gen = gen, chunks = chunks })
    return { id = id, gen = gen, name = "zmcp_" .. id .. "_" .. gen, chunks = chunks }
end)

Z.tool("model_place", "Place a STATIC 3D model in the world: spawns a carrier world item on the square and sets its world model (server side; single player verified, MP sync of setWorldStaticModel unverified). args: {id (model id), x, y, z?, item? (carrier, default Base.TirePiece), ox?, oy?, oz? (offsets, default 0.5,0.5,0), yrot? (degrees)}. Remove it like any world item (world_query + run_lua_server).", function(a)
    local id = checkId(a.id, "id")
    local m = store().models[id]
    if not m then error("unknown model: " .. id .. " (model_upload first)") end
    local x, y = tonumber(a.x), tonumber(a.y)
    if not x or not y then error("args.x and args.y required") end
    local sq = Z.square(x, y, num(a.z, 0))
    local carrier = tostring(a.item or "Base.TirePiece")
    local item = sq:AddWorldInventoryItem(carrier, num(a.ox, 0.5), num(a.oy, 0.5), num(a.oz, 0))
    if not item then error("AddWorldInventoryItem returned nil") end
    local name = "zmcp_" .. id .. "_" .. m.gen
    item:setWorldStaticModel(name)
    if a.yrot then pcall(function() item:setWorldYRotation(tonumber(a.yrot)) end) end
    Z.event("model_place", { id = id, x = math.floor(x), y = math.floor(y), z = math.floor(num(a.z, 0)) })
    return { placed = name, x = math.floor(x), y = math.floor(y), z = math.floor(num(a.z, 0)), item = carrier }
end)

---------------------------------------------------------------- tools: world sprites
local function pathString(p)
    if p == nil or p == "" then return nil end
    if type(p) == "string" then return p end
    if type(p) ~= "table" then error("path must be 'x,y,z;x,y,z' or [[x,y,z],...]") end
    local segs = {}
    for _, pt in ipairs(p) do
        local x, y, z = pt[1] or pt.x, pt[2] or pt.y, pt[3] or pt.z
        if not x or not y then error("path point needs x and y") end
        segs[#segs + 1] = x .. "," .. y .. (z and ("," .. z) or "")
    end
    return table.concat(segs, ";")
end

Z.tool("world_sprite", "Show a texture in the world for everyone (or args.player), anchored bottom-centre at x,y,z and scaled with zoom, always drawn on top. args: {id, texture, x, y, z?, scale? (pixel multiplier at zoom 1, default 1), tiles? (width in tiles instead of scale), path? ('x,y,z;x,y,z' or [[x,y,z],...] waypoints from x,y), speed? (tiles/s along the path), loop? (loop|pingpong|once), bob? (px), bobHz?, flip? (auto|0|1), opacity?, ttl? (s), fade? (s), anchor? (bottom|center)}. texture = uploaded id, 'item:Base.X' or a vanilla texture name. Persists for late joiners unless ttl or player is set.", function(a)
    local id = checkId(a.id or nextId("s"), "id")
    if not a.texture and not a.tex then error("args.texture required") end
    local x, y = tonumber(a.x), tonumber(a.y)
    if not x or not y then error("args.x and args.y required") end
    local sp = {
        id = id, tex = tostring(a.texture or a.tex), x = x, y = y, z = num(a.z, 0),
        scale = tonumber(a.scale), tiles = tonumber(a.tiles), path = pathString(a.path), speed = tonumber(a.speed),
        loop = a.loop, bob = tonumber(a.bob), bobHz = tonumber(a.bobHz), flip = a.flip, opacity = tonumber(a.opacity),
        ttl = tonumber(a.ttl), fade = tonumber(a.fade), anchor = a.anchor,
    }
    for k, v in pairs(sp) do if v == nil then sp[k] = nil end end
    local player = optPlayer(a.player)
    if not sp.ttl and not player then store().sprites[id] = sp else store().sprites[id] = nil end
    V.enqueue("sprite", sp, player)
    return { id = id, persistent = (not sp.ttl and not player) }
end)

---------------------------------------------------------------- tools: falling items
Z.tool("falling_items", "Items rain from the sky around a point (visual on every client) and the REAL items are spawned on the ground where each lands. args: {item ('Base.Banana'), count? (default 10, max 200), x?, y?, z? (default: args.player's position), radius? (tiles, default 3), duration? (s over which they start falling, default 3), fall? (s each drop takes, default 1.2), spawn? (default true), scale? (icon size)}.", function(a)
    local item = tostring(a.item or "")
    if item == "" then error("args.item required (e.g. Base.Banana)") end
    local script = getScriptManager():getItem(item)
    if not script then error("unknown item type: " .. item) end
    local count = math.floor(math.max(1, math.min(200, num(a.count, 10))))
    local x, y, z = tonumber(a.x), tonumber(a.y), tonumber(a.z)
    if not x or not y then
        local p = Z.player(a.player)
        x, y, z = p:getX(), p:getY(), p:getZ()
    end
    z = math.floor(z or 0)
    local radius = math.max(0, num(a.radius, 3))
    local duration = math.max(0, num(a.duration, 3))
    local fall = math.max(0.3, num(a.fall, 1.2))
    local spawn = a.spawn == nil or a.spawn == true or a.spawn == 1 or a.spawn == "true"
    local id = nextId("f")
    local segs, now, landed = {}, Z.now(), 0
    for i = 1, count do
        local ang, r = ZombRandFloat(0, 2 * math.pi), math.sqrt(ZombRandFloat(0, 1)) * radius
        local tx, ty = math.floor(x + math.cos(ang) * r), math.floor(y + math.sin(ang) * r)
        local delay = duration > 0 and ZombRandFloat(0, duration) or 0
        segs[#segs + 1] = string.format("%d,%d,%d,%.2f,%.2f", tx, ty, z, delay, fall)
        if spawn then
            V.pendingSpawns[#V.pendingSpawns + 1] = { at = now + delay + fall + 0.1, item = item, x = tx, y = ty, z = z,
                ox = ZombRandFloat(0.15, 0.85), oy = ZombRandFloat(0.15, 0.85) }
            landed = landed + 1
        end
    end
    -- keep each message flat and < ~3 KB: split the list over several "fall" commands
    local perMsg, sent = 120, 0
    for i = 1, #segs, perMsg do
        local part = {}
        for k = i, math.min(i + perMsg - 1, #segs) do part[#part + 1] = segs[k] end
        V.enqueue("fall", { id = id, item = item, items = table.concat(part, ";"), scale = tonumber(a.scale) })
        sent = sent + 1
    end
    Z.event("falling_items", { id = id, item = item, count = count, x = x, y = y, z = z, radius = radius })
    return { id = id, item = item, count = count, spawning = landed, x = math.floor(x), y = math.floor(y), z = z,
        done_in = duration + fall + 0.2, messages = sent }
end)

---------------------------------------------------------------- tools: overlays and messages
local DRAW_KEYS = { "id", "kind", "anchor", "x", "y", "z", "x2", "y2", "z2", "w", "h", "r", "g", "b", "a", "ttl",
    "text", "font", "centre", "center", "fill", "thick", "tex", "flip" }

Z.tool("overlay_draw", "Draw a primitive on every client's screen (or args.player). args: {kind = line|rect|text|texture, anchor = screen|world, x, y, z?, x2?, y2?, z2? (line end), w?, h?, r?, g?, b?, a?, ttl? (s, omit = until cleared), id?, text?, font? (small|medium|large|title), centre?, fill? (rect), thick? (line), tex?, flip?}. World anchor: x,y,z in tiles, sizes in px at zoom 1. Screen anchor: px; negative x/y from the right/bottom. Returns {id}; clear with clear_visuals {what = 'overlays', id}.", function(a)
    local args = {}
    for _, k in ipairs(DRAW_KEYS) do if a[k] ~= nil then args[k] = a[k] end end
    args.id = args.id and checkId(tostring(args.id), "id") or nextId("d")
    V.enqueue("draw", args, optPlayer(a.player))
    return { id = args.id }
end)

local MESSAGE_MODES = { notify = true, halo = true, chat = true, say = true }

Z.tool("server_message", "Show a message to every player (or args.player) through the client mod. args: {text, mode? = notify|halo|chat|say, player?, ttl? (notify seconds), r?, g?, b? (0-1 or 0-255), font? (notify: small|medium|large|title), time? (halo frames)}. notify = box at the top of the screen, halo = text over the player's head, chat = a line in the chat panel, say = speech bubble. Players without the mod see nothing (the console 'servermsg' command is the vanilla fallback).", function(a)
    if not a.text then error("args.text required") end
    local mode = tostring(a.mode or "notify")
    if not MESSAGE_MODES[mode] then error("args.mode must be notify, halo, chat or say") end
    local msg = { text = tostring(a.text), ttl = tonumber(a.ttl), r = tonumber(a.r), g = tonumber(a.g), b = tonumber(a.b),
        font = a.font, time = tonumber(a.time) }
    local player = optPlayer(a.player)
    V.enqueue(mode, msg, player)
    Z.event("server_message", { text = msg.text, mode = mode, user = player and userOf(player) or nil })
    return { sent = true, mode = mode, to = player and userOf(player) or "all" }
end)

---------------------------------------------------------------- tools: registry and cleanup
local CLEAR_WHAT = { all = true, sprites = true, overlays = true, falling = true, notices = true, textures = true, models = true, hooks = true }

Z.tool("clear_visuals", "Remove client visuals everywhere (or args.player): args {what? = all|sprites|overlays|falling|notices|textures|models|hooks, id?}. 'all' clears sprites, overlays, falling items, notices, script hooks and moving 3D entities (textures, models and client scripts stay). With id only that sprite/overlay/texture/model.", function(a)
    local what = tostring(a.what or "all")
    if not CLEAR_WHAT[what] then error("args.what must be one of all, sprites, overlays, falling, notices, textures, models, hooks") end
    local id = a.id and checkId(tostring(a.id), "id") or nil
    local s = store()
    local player = optPlayer(a.player)
    if not player then
        if what == "sprites" or what == "all" then if id then s.sprites[id] = nil else s.sprites = {} end end
        if what == "textures" then if id then s.textures[id] = nil else s.textures = {} end end
        if what == "models" then if id then s.models[id] = nil else s.models = {} end end
    end
    V.enqueue("clear", { what = what, id = id }, player)
    -- moving 3D entities (Api/Models.lua) go with "all" too; their registry stays in Models.lua
    if what == "all" and not id and not player and Z.tools.entity3d_remove then pcall(Z.tools.entity3d_remove.fn, { all = true }) end
    return { cleared = what, id = id }
end)

Z.tool("visuals_list", "Everything the visual subsystem knows: textures [{id, gen, chars|pixel}], models [{id, name, gen, scale}], sprites [{id, tex, x, y, z, ...}], client scripts [{name, file}], clients {user = {version, textures, models}}, queue length and pending item landings.", function()
    local s = store()
    local textures, models, sprites = {}, {}, {}
    for id, t in pairs(s.textures) do
        textures[#textures + 1] = { id = id, gen = t.gen, chars = t.chars, pixel = t.pixel ~= nil, uploaded = t.uploaded }
    end
    for id, m in pairs(s.models) do
        models[#models + 1] = { id = id, name = "zmcp_" .. id .. "_" .. m.gen, gen = m.gen, scale = m.scale, uploaded = m.uploaded }
    end
    for _, sp in pairs(s.sprites) do sprites[#sprites + 1] = sp end
    table.sort(textures, function(x, y) return x.id < y.id end)
    table.sort(models, function(x, y) return x.id < y.id end)
    table.sort(sprites, function(x, y) return x.id < y.id end)
    V.enqueue("ping", {})
    return { textures = arr(textures), models = arr(models), sprites = arr(sprites), scripts = Z.scriptSides.client.list(),
        clients = V.clients, queue = #V.queue, pendingSpawns = #V.pendingSpawns }
end)

Z.event("visuals_loaded", { version = V.version })
