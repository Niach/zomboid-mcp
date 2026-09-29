-- Zomboid MCP client: overlay primitives and on-screen notices.
-- "draw" items: line / rect / text / texture, anchored to the screen (pixels) or to the world (tile coords),
-- with an optional lifetime. "notify" shows a message at the top of the screen for a few seconds.
ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.draw = C.draw or {}
local D = C.draw
D.items = D.items or {}        -- id -> item
D.notices = D.notices or {}    -- list of { text, t0, ttl, r, g, b, font }
D.seq = D.seq or 0

local function num(v, d) local n = tonumber(v); if n == nil then return d end; return n end
local function bool(v) return v == true or v == 1 or v == "1" or v == "true" end
local FONTS = { small = UIFont.Small, medium = UIFont.Medium, large = UIFont.Large, title = UIFont.Title }
local function font(name) return FONTS[tostring(name or "medium"):lower()] or UIFont.Medium end

-- "draw" command:
--   { id?, kind = line|rect|text|texture, anchor = screen|world, x, y, z?, x2?, y2?, z2?, w?, h?,
--     r?, g?, b?, a?, ttl?, text?, font?, centre?, fill?, thick?, tex?, flip? }
-- world anchor: x,y,z are tile coords; w,h are pixels at zoom 1 (scaled with zoom); x2,y2,z2 for lines
-- screen anchor: everything in pixels; negative x/y count from the right/bottom edge
function D.add(a)
    D.seq = D.seq + 1
    local id = tostring(a.id or ("d" .. D.seq))
    local it = {
        id = id, kind = tostring(a.kind or "rect"), anchor = tostring(a.anchor or "screen"),
        x = num(a.x, 0), y = num(a.y, 0), z = num(a.z, 0), x2 = tonumber(a.x2), y2 = tonumber(a.y2), z2 = tonumber(a.z2),
        w = num(a.w, 32), h = num(a.h, 32),
        r = num(a.r, 1), g = num(a.g, 1), b = num(a.b, 1), a = num(a.a, 1),
        ttl = tonumber(a.ttl), t0 = C.now(),
        text = a.text and tostring(a.text) or nil, font = font(a.font), centre = bool(a.centre) or bool(a.center),
        fill = a.fill == nil or bool(a.fill), thick = math.max(1, num(a.thick, 1)),
        tex = a.tex and tostring(a.tex) or nil, flip = bool(a.flip),
    }
    if it.r > 1 or it.g > 1 or it.b > 1 then it.r, it.g, it.b = it.r / 255, it.g / 255, it.b / 255 end
    D.items[id] = it
    return id
end

function D.clear(id)
    if id then D.items[tostring(id)] = nil else D.items = {} end
end

-- "notify" command: { text, ttl?, r?, g?, b?, font? }
function D.notify(a)
    local n = { text = tostring(a.text or ""), t0 = C.now(), ttl = num(a.ttl, 5),
        r = num(a.r, 1), g = num(a.g, 1), b = num(a.b, 1), font = font(a.font or "large") }
    if n.r > 1 or n.g > 1 or n.b > 1 then n.r, n.g, n.b = n.r / 255, n.g / 255, n.b / 255 end
    D.notices[#D.notices + 1] = n
    if #D.notices > 6 then table.remove(D.notices, 1) end
end

local function screenPoint(it, x, y, z, sw, sh)
    if it.anchor == "world" then return isoToScreenX(0, x, y, z), isoToScreenY(0, x, y, z) end
    if x < 0 then x = sw + x end
    if y < 0 then y = sh + y end
    return x, y
end

local function drawLine(ui, x1, y1, x2, y2, a, r, g, b, thick)
    for o = 0, thick - 1 do ui:drawLine2(x1, y1 + o, x2, y2 + o, a, r, g, b) end
end

function D.render(ui)
    local t = C.now()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local zoom = getCore():getZoom(0)
    if not zoom or zoom <= 0 then zoom = 1 end
    for id, it in pairs(D.items) do
        local age = t - it.t0
        if it.ttl and age >= it.ttl then
            D.items[id] = nil
        else
            local alpha = it.a
            if it.ttl and it.ttl > 0.5 and it.ttl - age < 0.5 then alpha = alpha * (it.ttl - age) / 0.5 end
            local k = it.anchor == "world" and (1 / zoom) or 1
            local x, y = screenPoint(it, it.x, it.y, it.z, sw, sh)
            if it.kind == "line" then
                local x2, y2 = screenPoint(it, it.x2 or it.x, it.y2 or it.y, it.z2 or it.z, sw, sh)
                drawLine(ui, x, y, x2, y2, alpha, it.r, it.g, it.b, it.thick)
            elseif it.kind == "rect" then
                local w, h = it.w * k, it.h * k
                if it.anchor == "world" then x, y = x - w / 2, y - h end
                if it.fill then ui:drawRect(x, y, w, h, alpha, it.r, it.g, it.b)
                else ui:drawRectBorder(x, y, w, h, alpha, it.r, it.g, it.b) end
            elseif it.kind == "text" and it.text then
                if it.centre or it.anchor == "world" then ui:drawTextCentre(it.text, x, y, it.r, it.g, it.b, alpha, it.font)
                else ui:drawText(it.text, x, y, it.r, it.g, it.b, alpha, it.font) end
            elseif it.kind == "texture" and it.tex then
                local entry = C.tex.get(it.tex)
                if entry then
                    local w, h = it.w * k, it.h * k
                    if it.anchor == "world" then x, y = x - w / 2, y - h end
                    C.tex.draw(ui, entry, x, y, w, h, alpha, it.flip)
                end
            end
        end
    end
    if #D.notices > 0 then
        local keep, y = {}, 60
        local tm = getTextManager()
        for _, n in ipairs(D.notices) do
            local age = t - n.t0
            if age < n.ttl then
                keep[#keep + 1] = n
                local alpha = 1
                if age < 0.3 then alpha = age / 0.3 elseif n.ttl - age < 0.5 then alpha = (n.ttl - age) / 0.5 end
                local w = tm:MeasureStringX(n.font, n.text) + 24
                local h = tm:getFontHeight(n.font) + 10
                ui:drawRect(sw / 2 - w / 2, y, w, h, 0.6 * alpha, 0, 0, 0)
                ui:drawRectBorder(sw / 2 - w / 2, y, w, h, 0.8 * alpha, n.r, n.g, n.b)
                ui:drawTextCentre(n.text, sw / 2, y + 5, n.r, n.g, n.b, alpha, n.font)
                y = y + h + 6
            end
        end
        D.notices = keep
    end
end
