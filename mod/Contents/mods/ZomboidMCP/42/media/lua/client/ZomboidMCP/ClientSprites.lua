-- Zomboid MCP client: world sprites.
-- A texture (uploaded id, "item:Base.X" or a vanilla texture name) anchored bottom-centre at a world
-- position, scaled with the camera zoom, always drawn on top of the world (owner preference: no occlusion).
-- Optional: waypoint path + speed (crawl), loop mode, bobbing, facing flip, opacity, lifetime.
ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.sprites = C.sprites or {}
local S = C.sprites
S.list = S.list or {}          -- id -> sprite
S.TILE_PX = 64                 -- screen width of one world tile at zoom 1 (for the "tiles" size option)

local function num(v, d) local n = tonumber(v); if n == nil then return d end; return n end
local function isEmpty(t) for _ in pairs(t) do return false end return true end   -- Kahlua has no next()
local function log(msg) if C.log then C.log(msg) else print("[ZomboidMCP] " .. tostring(msg)) end end

-- "x,y,z;x,y,z;..." -> { {x,y,z}, ... }   (z optional per point)
function S.parsePath(str, z)
    local pts = {}
    for seg in string.gmatch(tostring(str or ""), "[^;]+") do
        local x, y, pz = string.match(seg, "^%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,?%s*([%-%d%.]*)")
        if x and y then pts[#pts + 1] = { tonumber(x), tonumber(y), tonumber(pz) or z } end
    end
    return pts
end

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

-- "sprite" command: { id, tex, x, y, z, scale?, tiles?, path?, speed?, loop?, bob?, bobHz?, flip?, opacity?,
--                     ttl?, fade?, anchor? }
function S.set(a)
    local id = tostring(a.id or "sprite")
    local old = S.list[id]
    local sp = {
        id = id, tex = tostring(a.tex or a.texture or ""),
        x = num(a.x, 0), y = num(a.y, 0), z = num(a.z, 0),
        scale = num(a.scale, 1), tiles = tonumber(a.tiles),
        speed = num(a.speed, 0), loop = tostring(a.loop or "loop"),
        bob = num(a.bob, 0), bobHz = num(a.bobHz, 1),
        flip = a.flip, opacity = num(a.opacity, 1),
        ttl = tonumber(a.ttl), fade = num(a.fade, 0), anchor = tostring(a.anchor or "bottom"),
        t0 = C.now(),
    }
    if sp.flip == nil or sp.flip == "auto" then sp.flip = "auto"
    else sp.flip = (sp.flip == true or sp.flip == 1 or sp.flip == "1" or sp.flip == "true") end
    local pts = { { sp.x, sp.y, sp.z } }
    for _, p in ipairs(S.parsePath(a.path, sp.z)) do pts[#pts + 1] = p end
    sp.path = pts
    sp.length, sp.segs = pathLength(pts)
    if old and old.tex == sp.tex and a.keepTime then sp.t0 = old.t0 end
    S.list[id] = sp
    return sp
end

function S.remove(id)
    if id then S.list[tostring(id)] = nil else S.list = {} end
end

-- position along the path at time t (world coords) + direction of travel (dx, dy)
function S.positionAt(sp, t)
    local pts = sp.path
    if #pts < 2 or sp.speed <= 0 or sp.length <= 0 then return pts[1][1], pts[1][2], pts[1][3], 0, 0 end
    local dist = sp.speed * (t - sp.t0)
    local dir = 1
    if sp.loop == "once" then
        if dist >= sp.length then local p = pts[#pts]; return p[1], p[2], p[3], 0, 0 end
    elseif sp.loop == "pingpong" then
        local cycle = dist % (2 * sp.length)
        if cycle > sp.length then dist = 2 * sp.length - cycle; dir = -1 else dist = cycle end
    else
        dist = dist % sp.length
    end
    for i = 1, #pts - 1 do
        local d = sp.segs[i]
        if dist <= d or i == #pts - 1 then
            local a, b = pts[i], pts[i + 1]
            local f = d > 0 and math.min(dist / d, 1) or 0
            return a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f,
                (b[1] - a[1]) * dir, (b[2] - a[2]) * dir
        end
        dist = dist - d
    end
    local p = pts[#pts]
    return p[1], p[2], p[3], 0, 0
end

-- ordered snapshot for rendering: south/east sprites drawn last (on top)
local function sorted(t)
    local out = {}
    for _, sp in pairs(S.list) do
        local x, y, z, dx, dy = S.positionAt(sp, t)
        sp._x, sp._y, sp._z, sp._dx, sp._dy = x, y, z, dx, dy
        out[#out + 1] = sp
    end
    table.sort(out, function(a, b)
        if a._z ~= b._z then return a._z < b._z end
        return (a._x + a._y) < (b._x + b._y)
    end)
    return out
end

function S.render(ui)
    if isEmpty(S.list) then return end
    local t = C.now()
    local zoom = getCore():getZoom(0)
    if not zoom or zoom <= 0 then zoom = 1 end
    for _, sp in ipairs(sorted(t)) do
        local age = t - sp.t0
        local alpha = sp.opacity
        if sp.ttl and age >= sp.ttl then
            S.list[sp.id] = nil
        else
            if sp.fade > 0 then
                alpha = alpha * math.min(1, age / sp.fade)
                if sp.ttl then alpha = alpha * math.min(1, (sp.ttl - age) / sp.fade) end
            end
            local entry = C.tex.get(sp.tex)
            if entry and alpha > 0 then
                local w, h
                if sp.tiles then
                    w = sp.tiles * S.TILE_PX / zoom
                    h = w * entry.h / entry.w
                else
                    w = entry.w * sp.scale / zoom
                    h = entry.h * sp.scale / zoom
                end
                local sx = isoToScreenX(0, sp._x, sp._y, sp._z)
                local sy = isoToScreenY(0, sp._x, sp._y, sp._z)
                if sp.bob > 0 then sy = sy - math.abs(math.sin(age * math.pi * sp.bobHz)) * sp.bob / zoom end
                local flip = sp.flip
                if flip == "auto" then
                    -- screen x grows with world x and shrinks with world y; mirror when travelling left
                    flip = (sp._dx - sp._dy) < 0
                end
                local top = (sp.anchor == "center") and (sy - h / 2) or (sy - h)
                C.tex.draw(ui, entry, sx - w / 2, top, w, h, alpha, flip)
            end
        end
    end
end

function S.info()
    local out = {}
    for id, sp in pairs(S.list) do
        out[#out + 1] = string.format("%s tex=%s at %.1f,%.1f,%d speed=%.2f", id, sp.tex, sp._x or sp.x, sp._y or sp.y, sp.z, sp.speed)
    end
    table.sort(out)
    return out
end
