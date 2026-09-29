-- Zomboid MCP client: runtime textures.
-- The server streams a PNG as base64 chunks ("tex" commands). Once all parts are here the client decodes
-- them into ~/Zomboid/Lua/zmcp_tex_<id>_<gen>.png and loads it with getTexture(absolutePath)
-- (verified on 42.21, see docs/ENGINE_NOTES.md "Textures at runtime"). Textures are cached by path, so
-- every upload of an id gets a new generation number and therefore a new file name.
-- Fallback when loading fails: pixel sprites ("pixel" command), drawn with drawRect from a palette + rows.
ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.tex = C.tex or {}
local T = C.tex
T.loaded = T.loaded or {}      -- id -> { tex = Texture, w, h, gen, file } | { pixel = def, w, h }
T.pending = T.pending or {}    -- id -> { gen, total, parts = {} }
T.vanilla = T.vanilla or {}    -- name -> Texture|false (getTexture / item icon cache)

local function log(msg) if C.log then C.log(msg) else print("[ZomboidMCP] " .. tostring(msg)) end end

function T.filePath(name)
    local sep = getFileSeparator()
    return getMyDocumentFolder() .. sep .. "Lua" .. sep .. name
end

-- load a PNG that already exists in the Lua cache dir
function T.loadFile(id, name, gen)
    local tex = getTexture(T.filePath(name))
    if not tex then
        local ok, t = pcall(function() return Texture.getSharedTexture(T.filePath(name)) end)
        if ok and t then tex = t end
    end
    if not tex then return nil, "getTexture returned nil for " .. name end
    local entry = { tex = tex, w = tex:getWidth(), h = tex:getHeight(), gen = gen, file = name }
    if not entry.w or entry.w <= 0 then return nil, "texture has no size: " .. name end
    T.loaded[id] = entry
    return entry
end

-- "tex" command: { id, gen, part, total, data }   (data = base64 slice, ~3000 chars)
function T.onChunk(a)
    local id = tostring(a.id)
    local gen, part, total = tonumber(a.gen) or 1, tonumber(a.part) or 1, tonumber(a.total) or 1
    local p = T.pending[id]
    if not p or p.gen ~= gen or p.total ~= total then
        p = { gen = gen, total = total, parts = {}, got = 0 }
        T.pending[id] = p
    end
    if not p.parts[part] then p.got = p.got + 1 end
    p.parts[part] = a.data or ""
    if p.got < total then return end
    T.pending[id] = nil
    local b64 = table.concat(p.parts)
    local name = "zmcp_tex_" .. id .. "_" .. gen .. ".png"
    local ok, bytes = pcall(C.b64.decodeToFile, b64, name)
    if not ok then
        log("texture " .. id .. " write failed: " .. tostring(bytes))
        C.send("texResult", { id = id, gen = gen, ok = false, err = tostring(bytes) })
        return
    end
    local entry, err = T.loadFile(id, name, gen)
    if entry then
        log("texture " .. id .. " gen " .. gen .. " loaded " .. entry.w .. "x" .. entry.h .. " (" .. bytes .. " bytes)")
        C.send("texResult", { id = id, gen = gen, ok = true, w = entry.w, h = entry.h, bytes = bytes })
    else
        log("texture " .. id .. " load failed: " .. tostring(err))
        C.send("texResult", { id = id, gen = gen, ok = false, err = tostring(err), bytes = bytes })
    end
end

-- "pixel" command: { id, def }  def = JSON {"w":8,"h":8,"palette":{"a":[r,g,b,a]},"rows":["aab.",...]}
-- '.' (or any char missing from the palette) is transparent. Colours are 0..1 or 0..255.
function T.onPixel(a)
    local id = tostring(a.id)
    local def = a.def
    if type(def) == "string" then
        local ok, d = pcall(ZMCPJson.decode, def)
        if not ok or type(d) ~= "table" then log("pixel " .. id .. ": bad def json"); return end
        def = d
    end
    if type(def) ~= "table" or not def.rows then log("pixel " .. id .. ": def needs rows"); return end
    def.h = def.h or #def.rows
    def.w = def.w or #(def.rows[1] or "")
    for _, c in pairs(def.palette or {}) do
        for i = 1, 4 do
            if c[i] and c[i] > 1 then c[i] = c[i] / 255 end
        end
        c[4] = c[4] or 1
    end
    T.loaded[id] = { pixel = def, w = def.w, h = def.h }
    log("pixel sprite " .. id .. " " .. def.w .. "x" .. def.h)
end

-- resolve a texture reference:
--   an uploaded id, "item:Base.Banana" (inventory icon), or any vanilla texture name/path for getTexture
function T.get(ref)
    if ref == nil then return nil end
    ref = tostring(ref)
    local e = T.loaded[ref]
    if e then return e end
    local v = T.vanilla[ref]
    if v == nil then
        local tex
        if ref:sub(1, 5) == "item:" then
            tex = T.itemTexture(ref:sub(6))
        else
            local ok, t = pcall(getTexture, ref)
            if ok then tex = t end
        end
        if tex then v = { tex = tex, w = tex:getWidth(), h = tex:getHeight() } else v = false end
        T.vanilla[ref] = v
    end
    return v or nil
end

-- inventory icon of an item type ("Base.Banana"); nil when the type is unknown
function T.itemTexture(fullType)
    local ok, item = pcall(instanceItem, fullType)
    if ok and item then
        local t = item:getTex()
        if t then return t end
    end
    local ok2, t2 = pcall(getItemTex, fullType)
    if ok2 and t2 then return t2 end
    local ok3, script = pcall(function() return getScriptManager():getItem(fullType) end)
    if ok3 and script then
        local icon = script:getIcon()
        if icon then
            local t = getTexture("Item_" .. icon)
            if t then return t end
        end
    end
    return nil
end

-- draw entry (texture or pixel def) into the rect x,y,w,h; flip mirrors horizontally
function T.draw(ui, entry, x, y, w, h, alpha, flip)
    alpha = alpha or 1
    if entry.tex then
        if flip then ui:drawTextureScaled(entry.tex, x + w, y, -w, h, alpha)
        else ui:drawTextureScaled(entry.tex, x, y, w, h, alpha) end
        return
    end
    local def = entry.pixel
    if not def then return end
    local cw, ch = w / def.w, h / def.h
    for row = 1, def.h do
        local line = def.rows[row] or ""
        for col = 1, def.w do
            local c = def.palette[line:sub(col, col)]
            if c then
                local cx = flip and (x + w - col * cw) or (x + (col - 1) * cw)
                ui:drawRect(cx, y + (row - 1) * ch, cw + 0.5, ch + 0.5, c[4] * alpha, c[1], c[2], c[3])
            end
        end
    end
end

function T.list()
    local out = {}
    for id, e in pairs(T.loaded) do out[#out + 1] = id .. (e.pixel and "(pixel)" or ("(" .. e.w .. "x" .. e.h .. ")")) end
    table.sort(out)
    return out
end

function T.clear(id)
    if id then T.loaded[tostring(id)] = nil; T.pending[tostring(id)] = nil
    else T.loaded = {}; T.pending = {} end
end
