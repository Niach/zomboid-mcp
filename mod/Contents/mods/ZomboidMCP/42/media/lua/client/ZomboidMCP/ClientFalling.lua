-- Zomboid MCP client: items falling from the sky.
-- Purely visual: the item's inventory icon drops onto a target tile with a growing shadow and a small
-- bounce. The server spawns the real item on the square when the drop lands (Api/Visuals.lua falling_items).
ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.falling = C.falling or {}
local F = C.falling
F.list = F.list or {}          -- active drops
F.HEIGHT = 700                 -- drop height in screen px at zoom 1
F.ICON = 40                    -- icon size in px at zoom 1 (times scale)
F.LINGER = 0.6                 -- seconds the icon stays after landing (the real item appears meanwhile)

local function num(v, d) local n = tonumber(v); if n == nil then return d end; return n end

-- "fall" command: { id, item, items = "x,y,z,delay,dur;...", scale?, tex? }
--   x,y,z target square; delay seconds until this drop starts; dur seconds of fall
function F.add(a)
    local id = tostring(a.id or "fall")
    local item = tostring(a.item or "Base.Banana")
    local texRef = a.tex or ("item:" .. item)
    local scale = num(a.scale, 1)
    local t0 = C.now()
    local n = 0
    for seg in string.gmatch(tostring(a.items or ""), "[^;]+") do
        local x, y, z, delay, dur = string.match(seg, "^%s*([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%d%.]+),([%d%.]+)")
        if x then
            n = n + 1
            F.list[#F.list + 1] = {
                id = id, tex = texRef, scale = scale,
                x = tonumber(x) + 0.3 + (n % 5) * 0.1, y = tonumber(y) + 0.3 + (n % 3) * 0.15, z = tonumber(z),
                start = t0 + tonumber(delay), dur = math.max(0.2, tonumber(dur)),
            }
        end
    end
    return n
end

function F.clear(id)
    if not id then F.list = {}; return end
    local keep = {}
    for _, d in ipairs(F.list) do if d.id ~= tostring(id) then keep[#keep + 1] = d end end
    F.list = keep
end

function F.render(ui)
    if #F.list == 0 then return end
    local t = C.now()
    local zoom = getCore():getZoom(0)
    if not zoom or zoom <= 0 then zoom = 1 end
    local keep = {}
    for _, d in ipairs(F.list) do
        local p = (t - d.start) / d.dur
        if p < 0 then
            keep[#keep + 1] = d
        elseif p > 1 + F.LINGER / d.dur then
            -- done
        else
            keep[#keep + 1] = d
            local entry = C.tex.get(d.tex)
            local size = F.ICON * d.scale / zoom
            local gx = isoToScreenX(0, d.x, d.y, d.z)
            local gy = isoToScreenY(0, d.x, d.y, d.z)
            local fall = math.min(p, 1)
            -- shadow grows as the item comes down
            local sw, sh = size * (0.4 + 0.5 * fall), size * (0.15 + 0.2 * fall)
            ui:drawRect(gx - sw / 2, gy - sh / 2, sw, sh, 0.35 * fall, 0, 0, 0)
            local lift
            if p <= 1 then
                lift = F.HEIGHT / zoom * (1 - p * p)                 -- accelerating drop
            else
                local q = (p - 1) * d.dur / F.LINGER                -- one small bounce, then fade
                lift = math.sin(q * math.pi) * size * 0.35
            end
            local alpha = 1
            if p > 1 then alpha = 1 - (p - 1) * d.dur / F.LINGER end
            if entry then
                C.tex.draw(ui, entry, gx - size / 2, gy - lift - size, size, size, alpha, false)
            else
                ui:drawRect(gx - size / 4, gy - lift - size / 2, size / 2, size / 2, alpha, 1, 0.9, 0.2)
            end
        end
    end
    F.list = keep
end
