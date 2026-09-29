-- Zomboid MCP: visual tools (server side). Pushes code, textures, sprites, falling items and overlays to
-- every player's client mod (client/ZomboidMCP/Client.lua) through sendServerCommand("zmcp", cmd, args).
-- Protocol: docs/CLIENT_PROTOCOL.md. Builds only on the public ZMCP API of Bridge.lua.
--
-- Persistent state (small) lives in ModData "ZomboidMCP".visuals = { textures, sprites, cmodules } so late
-- joiners get everything again when their client says "hello". Texture data stays in files in the Lua
-- cache dir (zmcp_tex_<id>.b64), never in ModData or Lua memory (server heap), and is streamed in chunks.
--
-- Tools: run_lua_client (alias client_exec), client_results, clients_list, module_client_install/remove/list,
--        texture_upload, texture_pixel, texture_list, texture_remove,
--        model_upload, model_list, model_remove, model_place,
--        world_sprite, world_sprite_remove, world_sprite_list,
--        falling_items, overlay_draw, overlay_clear, clear_visuals, notify, halo, capture_input, visuals_status
if isClient() then return end
if not ZMCP or not ZMCP.tool then error("Bridge.lua must be loaded before Api/Visuals.lua") end

local Z = ZMCP
local J = ZMCPJson
Z.visuals = Z.visuals or {}
local V = Z.visuals
V.version = "0.3.0"
V.CHUNK = 3000            -- characters per sendServerCommand (see docs/ENGINE_NOTES.md)
V.PER_TICK = 12           -- queued messages sent per tick (~10 ticks/s)
V.MAX_B64 = 1200000       -- refuse textures above this many base64 characters (~900 KB PNG)
V.queue = V.queue or {}   -- outgoing { player, cmd, args }
V.results = V.results or {}   -- exec id -> { to = {users}, sent, results = { [user] = { ok, res, ms, t } } }
V.resultOrder = V.resultOrder or {}
V.clients = V.clients or {}   -- user -> { version, t, textures = {id -> {ok, w, h}} }
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
    if type(vis.cmodules) ~= "table" then vis.cmodules = {} end
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

function V.sendModule(name, player)
    local m = store().cmodules[name]
    if not m then return 0 end
    local src = Z.readFile(m.file)
    if not src then Z.event("client_module_error", { name = name, error = "file missing: " .. m.file }); return 0 end
    return V.enqueueChunked("exec", { id = "mod:" .. name, module = name }, "code", src, player)
end

-- everything a (late-joining) client needs, in dependency order
function V.sendAllTo(player)
    local s = store()
    local n = { textures = 0, modules = 0, sprites = 0 }
    for id in pairs(s.textures) do
        local ok, err = pcall(V.sendTexture, id, player)
        if ok then n.textures = n.textures + 1 else print("[ZomboidMCP] resend texture " .. id .. ": " .. tostring(err)) end
    end
    n.models = 0
    for id in pairs(s.models) do
        local ok, err = pcall(V.sendModel, id, player)
        if ok then n.models = n.models + 1 else print("[ZomboidMCP] resend model " .. id .. ": " .. tostring(err)) end
    end
    for name in pairs(s.cmodules) do V.sendModule(name, player); n.modules = n.modules + 1 end
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
local function runLuaClient(a)
    if type(a.code) ~= "string" or a.code == "" then error("args.code (string) required") end
    local player = optPlayer(a.player)
    local id = a.id and checkId(tostring(a.id), "id") or nextId("c")
    local to = {}
    if player then to[1] = userOf(player) else for _, p in ipairs(Z.players()) do to[#to + 1] = userOf(p) end end
    V.track(id, to)
    local chunks = V.enqueueChunked("exec", { id = id }, "code", a.code, player)
    return { id = id, chunks = chunks, to = arr(to), note = "poll client_results {id} (done=true when every client answered); events client_exec_result" }
end
Z.tool("run_lua_client", "Run Lua on every player's client (or args.player only). args: {code, player?, id?}. Returns {id, to}; each client answers with the chunk's return value (tables JSON-encoded) or error: poll client_results {id} until done, or watch client_exec_result events. Script API on the client: ZMCPClient.on(name, 'render'|'tick'|'keyDown'|'keyUp'|'keyHeld'|'mouseDown'|'mouseUp'|'mouseMove'|'mouseWheel', fn), ZMCPClient.off(name), ZMCPClient.capture(true) for screen apps, ZMCPClient.tex/sprites/draw/models, ZMCPClient.send(cmd, args), ZMCPJson, plus the whole vanilla client Lua API.", runLuaClient)
Z.tool("client_exec", "Alias of run_lua_client.", runLuaClient)

Z.tool("client_results", "Results of run_lua_client / client modules: args {id} -> {to, results = {user = {ok, res, ms}}, pending, done}. Without id: the status of every kept id (last 50).", function(a)
    if a.id then return V.resultStatus(tostring(a.id)) or error("unknown script id " .. tostring(a.id)) end
    local out = {}
    for _, id in ipairs(V.resultOrder) do out[#out + 1] = V.resultStatus(id) end
    return arr(out)
end)

Z.tool("capture_input", "Screen apps: make every client's (or args.player's) overlay swallow mouse events and sit above the UI (on=true), or release it. args: {on, player?}. Scripts can also call ZMCPClient.capture(true) themselves.", function(a)
    V.enqueue("capture", { on = a.on ~= false and a.on ~= 0 and a.on ~= "false" }, optPlayer(a.player))
    return { on = a.on ~= false }
end)

Z.tool("clients_list", "Players whose Zomboid MCP client has said hello (or answered ping) this session: {user: {version, t, textures}}.", function()
    V.enqueue("ping", {})
    return V.clients
end)

Z.tool("module_client_install", "Install a persistent CLIENT module: args {name, code} (the server writes zmcp_cmod_<name>.lua) or {name, file}. It runs now on every client and again for every player who joins. Convention: register draw code as ZMCPClient.renderHooks[name] so module_client_remove can drop it.", function(a)
    local name = checkId(a.name, "name")
    local file = "zmcp_cmod_" .. name .. ".lua"
    if type(a.code) == "string" then Z.writeFile(file, a.code)
    elseif type(a.file) == "string" then
        file = a.file
        if not Z.readFile(file) then error("file not found in Lua dir: " .. file) end
    else error("args.code or args.file required") end
    store().cmodules[name] = { file = file, installed = Z.now() }
    local to = {}
    for _, p in ipairs(Z.players()) do to[#to + 1] = userOf(p) end
    V.track("mod:" .. name, to)
    local chunks = V.sendModule(name)
    Z.event("client_module_install", { name = name, file = file })
    return { name = name, file = file, chunks = chunks }
end)

Z.tool("module_client_remove", "Forget a persistent client module and tell clients to drop it (renderHooks/tickHooks under its name). args: {name}.", function(a)
    local name = checkId(a.name, "name")
    if not store().cmodules[name] then error("no such client module: " .. name) end
    store().cmodules[name] = nil
    V.enqueue("modRemove", { name = name })
    Z.event("client_module_remove", { name = name })
    return { removed = name }
end)

Z.tool("module_client_list", "List persistent client modules: [{name, file, installed}].", function()
    local out = {}
    for name, m in pairs(store().cmodules) do out[#out + 1] = { name = name, file = m.file, installed = m.installed } end
    table.sort(out, function(x, y) return x.name < y.name end)
    return arr(out)
end)

---------------------------------------------------------------- tools: textures
Z.tool("texture_upload", "Push a PNG to every client as texture <id>. args: {id, file?, base64?, player?}. Preferred: drop the base64 text of the PNG into the Lua dir as zmcp_tex_<id>.b64 (or args.file) and call with {id}. Inline base64 is written to that file. Streamed in ~3 KB chunks; late joiners get it on hello. Keep PNGs <= 256x256 / 100 KB. Clients report 'client_texture' events.", function(a)
    local id = checkId(a.id, "id")
    local file = a.file or textureFile(id)
    if type(a.base64) == "string" then
        if #a.base64 > V.MAX_B64 then error("base64 too large: " .. #a.base64 .. " chars (max " .. V.MAX_B64 .. ")") end
        file = textureFile(id)
        Z.writeFile(file, a.base64)
    end
    local b64 = Z.readFile(file)
    if not b64 or b64 == "" then error("file not found or empty in Lua dir: " .. file) end
    if #b64 > V.MAX_B64 then error("base64 too large: " .. #b64 .. " chars (max " .. V.MAX_B64 .. ")") end
    local s = store()
    local old = s.textures[id]
    local gen = (old and tonumber(old.gen) or 0) + 1
    s.textures[id] = { file = file, gen = gen, chars = #b64, uploaded = Z.now() }
    local chunks = V.sendTexture(id, optPlayer(a.player))
    Z.event("texture_upload", { id = id, gen = gen, chars = #b64, chunks = chunks })
    return { id = id, gen = gen, chars = #b64, chunks = chunks, note = "clients report load results as client_texture events" }
end)

Z.tool("texture_pixel", "Fallback art without a PNG: a pixel sprite drawn with rects. args: {id, def} where def = {w, h, palette = {a = {r,g,b,a}}, rows = ['aab.', ...]} ('.' transparent, colours 0-1 or 0-255). Usable wherever a texture id is.", function(a)
    local id = checkId(a.id, "id")
    local def = a.def
    if type(def) == "table" then def = J.encode(def) end
    if type(def) ~= "string" then error("args.def (object or JSON string) required") end
    store().textures[id] = { pixel = def, gen = 1, uploaded = Z.now() }
    V.enqueue("pixel", { id = id, def = def })
    return { id = id, pixel = true }
end)

Z.tool("texture_list", "Registered runtime textures: [{id, gen, chars|pixel, file}].", function()
    local out = {}
    for id, t in pairs(store().textures) do
        out[#out + 1] = { id = id, gen = t.gen, chars = t.chars, pixel = t.pixel ~= nil, file = t.file, uploaded = t.uploaded }
    end
    table.sort(out, function(x, y) return x.id < y.id end)
    return arr(out)
end)

Z.tool("texture_remove", "Forget a runtime texture (clients keep the file; sprites using it stop drawing). args: {id}.", function(a)
    local id = checkId(a.id, "id")
    if not store().textures[id] then error("unknown texture: " .. id) end
    store().textures[id] = nil
    V.enqueue("clear", { what = "textures", id = id })
    return { removed = id }
end)

---------------------------------------------------------------- tools: runtime 3D models (static)
Z.tool("model_upload", "Register a runtime 3D model on every client (static models, see ENGINE_NOTES 'Runtime 3D models'). args: {id, mesh?, texture?, scale?}. Drop the base64 of the PZ .x text mesh into the Lua dir as zmcp_model_<id>.x.b64 and of the PNG as zmcp_model_<id>.png.b64 (or name other files with args.mesh / args.texture). Clients write them under Lua/media/ and run ModelScript registration; the model name is 'zmcp_<id>_<gen>' (model_list shows it; scripts use ZMCPClient.models.name(id)). Clients report client_model events.", function(a)
    local id = checkId(a.id, "id")
    local meshSrc = a.mesh or ("zmcp_model_" .. id .. ".x.b64")
    local texSrc = a.texture or ("zmcp_model_" .. id .. ".png.b64")
    for _, f in ipairs({ meshSrc, texSrc }) do
        local t = Z.readFile(f)
        if not t or t == "" then error("file not found or empty in Lua dir: " .. f) end
        if #t > V.MAX_B64 then error("base64 too large: " .. f) end
    end
    local s = store()
    local gen = (s.models[id] and tonumber(s.models[id].gen) or 0) + 1
    s.models[id] = { meshSrc = meshSrc, texSrc = texSrc, gen = gen, scale = num(a.scale, 1),
        mesh = "media/zmcp_model_" .. id .. "_" .. gen .. ".x", texture = "media/zmcp_model_" .. id .. "_" .. gen .. ".png", uploaded = Z.now() }
    local chunks = V.sendModel(id, optPlayer(a.player))
    Z.event("model_upload", { id = id, gen = gen, chunks = chunks })
    return { id = id, gen = gen, name = "zmcp_" .. id .. "_" .. gen, chunks = chunks, note = "clients report client_model events" }
end)

Z.tool("model_list", "Registered runtime models: [{id, name, gen, scale, mesh, texture}].", function()
    local out = {}
    for id, m in pairs(store().models) do
        out[#out + 1] = { id = id, name = "zmcp_" .. id .. "_" .. m.gen, gen = m.gen, scale = m.scale, mesh = m.mesh, texture = m.texture, uploaded = m.uploaded }
    end
    table.sort(out, function(x, y) return x.id < y.id end)
    return arr(out)
end)

Z.tool("model_remove", "Forget a runtime model (clients keep the files and the registered ModelScript). args: {id}.", function(a)
    local id = checkId(a.id, "id")
    if not store().models[id] then error("unknown model: " .. id) end
    store().models[id] = nil
    return { removed = id }
end)

Z.tool("model_place", "Place a static 3D model in the world: spawns a carrier world item on the square and sets its world model (server side; sync of setWorldStaticModel to MP clients is unverified, single player verified). args: {id (model id), x, y, z?, item? (carrier, default Base.TirePiece), ox?, oy?, oz? (offsets, default 0.5,0.5,0), yrot? (degrees)}. Returns nothing to remove with yet: use run_lua_server / world tools.", function(a)
    local id = checkId(a.id, "id")
    local m = store().models[id]
    if not m then error("unknown model: " .. id .. " (model_upload first)") end
    local x, y = tonumber(a.x), tonumber(a.y)
    if not x or not y then error("args.x and args.y required") end
    local sq = Z.square(x, y, num(a.z, 0))
    local item = sq:AddWorldInventoryItem(tostring(a.item or "Base.TirePiece"), num(a.ox, 0.5), num(a.oy, 0.5), num(a.oz, 0))
    if not item then error("AddWorldInventoryItem returned nil") end
    local name = "zmcp_" .. id .. "_" .. m.gen
    item:setWorldStaticModel(name)
    if a.yrot then pcall(function() item:setWorldYRotation(tonumber(a.yrot)) end) end
    return { placed = name, x = math.floor(x), y = math.floor(y), z = math.floor(num(a.z, 0)), item = tostring(a.item or "Base.TirePiece") }
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

Z.tool("world_sprite_remove", "Remove a world sprite everywhere. args: {id} (omit id to remove all).", function(a)
    if a.id then
        local id = checkId(a.id, "id")
        store().sprites[id] = nil
        V.enqueue("spriteRemove", { id = id })
        return { removed = id }
    end
    store().sprites = {}
    V.enqueue("spriteRemove", {})
    return { removed = "all" }
end)

Z.tool("world_sprite_list", "Persistent world sprites: [{id, tex, x, y, z, ...}].", function()
    local out = {}
    for _, sp in pairs(store().sprites) do out[#out + 1] = sp end
    table.sort(out, function(p, q) return p.id < q.id end)
    return arr(out)
end)

---------------------------------------------------------------- tools: falling items
Z.tool("falling_items", "Items rain from the sky around a point (visual on every client) and the REAL items are spawned on the ground where each lands. args: {type ('Base.Banana'), count? (default 10, max 200), x?, y?, z? (default: args.player's position), radius? (tiles, default 3), duration? (s over which they start falling, default 3), fall? (s each drop takes, default 1.2), spawn? (default true), scale? (icon size)}.", function(a)
    local item = tostring(a.type or a.item or "")
    if item == "" then error("args.type required (e.g. Base.Banana)") end
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

Z.tool("overlay_draw", "Draw a primitive on every client's screen (or args.player). args: {kind = line|rect|text|texture, anchor = screen|world, x, y, z?, x2?, y2?, z2? (line end), w?, h?, r?, g?, b?, a?, ttl? (s, omit = until overlay_clear), id?, text?, font? (small|medium|large|title), centre?, fill? (rect), thick? (line), tex?, flip?}. World anchor: x,y,z in tiles, sizes in px at zoom 1. Screen anchor: px; negative x/y from the right/bottom.", function(a)
    local args = {}
    for _, k in ipairs(DRAW_KEYS) do if a[k] ~= nil then args[k] = a[k] end end
    args.id = args.id and checkId(tostring(args.id), "id") or nextId("d")
    V.enqueue("draw", args, optPlayer(a.player))
    return { id = args.id }
end)

Z.tool("overlay_clear", "Remove overlay primitives. args: {id?} (omit = all).", function(a)
    V.enqueue("clear", { what = "draw", id = a.id })
    return { cleared = a.id or "all" }
end)

Z.tool("clear_visuals", "Clear client visuals: args {what? = all|sprites|draw|fall|notices|textures}. 'all' removes sprites, overlays, falling items, notices and pushed render hooks (not textures or client modules).", function(a)
    local what = tostring(a.what or "all")
    if what == "all" or what == "sprites" then store().sprites = {} end
    if what == "textures" then store().textures = {} end
    V.enqueue("clear", { what = what })
    return { cleared = what }
end)

Z.tool("notify", "On-screen message at the top of every client's screen (or args.player). args: {text, ttl? (s, default 5), r?, g?, b?, font? (small|medium|large|title)}.", function(a)
    if not a.text then error("args.text required") end
    V.enqueue("notify", { text = tostring(a.text), ttl = tonumber(a.ttl), r = tonumber(a.r), g = tonumber(a.g), b = tonumber(a.b), font = a.font }, optPlayer(a.player))
    return { ok = true }
end)

Z.tool("halo", "Overhead halo text on a player (or everyone). args: {text, player?, r?, g?, b? (0-255), time?}.", function(a)
    if not a.text then error("args.text required") end
    V.enqueue("halo", { text = tostring(a.text), r = tonumber(a.r), g = tonumber(a.g), b = tonumber(a.b), time = tonumber(a.time) }, optPlayer(a.player))
    return { ok = true }
end)

Z.tool("visuals_status", "Visual subsystem state: queue length, known clients, registry counts, pending landings.", function()
    local s = store()
    local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
    return { version = V.version, queue = #V.queue, clients = V.clients, textures = count(s.textures), models = count(s.models),
        sprites = count(s.sprites), cmodules = count(s.cmodules), pendingSpawns = #V.pendingSpawns }
end)

Z.event("visuals_loaded", { version = V.version })
