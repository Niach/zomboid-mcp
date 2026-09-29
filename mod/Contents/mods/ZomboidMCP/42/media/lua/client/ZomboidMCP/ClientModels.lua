-- Zomboid MCP client: generic file push + runtime 3D model registration (static models, see ENGINE_NOTES).
--   "file"  {id, gen, part, total, data, path}   base64 chunks -> ~/Zomboid/Lua/<path> (subdirs are created)
--   "model" {id, gen, mesh, texture, scale}      ModelScript registration once both files are present:
--       ms = ModelScript.new(); ms:setModule(getScriptManager():getModule("Base")); ms:InitLoadPP(name)
--       ms:Load(name, "{ mesh = <abs .x under media/>, texture = <abs .png>, scale = N, }"); addModelScript(ms)
--   The model name is "zmcp_<id>_<gen>" (a new upload = new files + new name; the loader caches by path).
--   ZMCPClient.models.name(id) gives the current model name for item:setWorldStaticModel(name).
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

function M.info()
    local out = {}
    for id, m in pairs(M.list) do out[#out + 1] = id .. "=" .. m.name .. (m.ok and "" or " (failed)") end
    table.sort(out)
    return out
end
