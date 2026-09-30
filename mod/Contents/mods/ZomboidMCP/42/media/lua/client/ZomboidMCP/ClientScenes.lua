-- Zomboid MCP client: the client half of scenes (server: Api/Scenes.lua). Speech bubbles above sprites, zombies and
-- positions, sprite frame animation and opacity tweens on top of ClientSprites, choice dialogs that report back to the
-- scene, lights (IsoCell:addLamppost, render-only and never saved by the engine), UI sounds, and forwarding of sprite
-- clicks / key presses a scene asked for. Everything is keyed by scene name so "sceneClear" undoes one scene.
-- Built on the ZMCPClient.on hook registry (ClientInput.lua) under the hook name "zmcp_scenes"; hooks are re-added
-- lazily by every command, so a clear_visuals {what = 'hooks'} only pauses this module until the next command.
-- Protocol rows: docs/PROTOCOL.md part 2 ("Scenes and apps").
ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.commands = C.commands or {}
C.scenes = C.scenes or {}
local SC = C.scenes
SC.HOOK = "zmcp_scenes"
SC.bubbles = SC.bubbles or {}     -- id -> { scene, text, t0, ttl, sid?, zid?, x, y, z }
SC.dialogs = SC.dialogs or {}     -- id -> { scene, text, options = {}, t0, ttl, buttons = {} }
SC.dialogOrder = SC.dialogOrder or {}
SC.anims = SC.anims or {}         -- sprite id -> { scene, frames = {}, fps, t0 }
SC.fades = SC.fades or {}         -- sprite id -> { from, to, t0, dur }
SC.lights = SC.lights or {}       -- id -> { scene, light, x, y, z }
SC.watch = SC.watch or { clicks = {}, keys = {} }   -- clicks: sprite id -> scene; keys: "code" -> { scene -> true }
SC.zombies = SC.zombies or {}     -- "z<online id>" / "o<object id>" -> IsoZombie (cache for bubbles that follow a puppet)

local function num(v, d) local n = tonumber(v); if n == nil then return d end; return n end
local function log(msg) if C.log then C.log(msg) else print("[ZomboidMCP] " .. tostring(msg)) end end
local function isEmpty(t) for _ in pairs(t) do return false end return true end

-- desired input capture = a dialog is open, or a screen app has focus (ClientApps.lua)
function SC.wantsCapture() return not isEmpty(SC.dialogs) end
C.syncCapture = C.syncCapture or function()
    local want = (C.scenes and C.scenes.wantsCapture and C.scenes.wantsCapture())
        or (C.apps and C.apps.wantsCapture and C.apps.wantsCapture()) or false
    C.capture(want)
end

---------------------------------------------------------------- geometry helpers
-- screen rect (x, y, w, h) of a world sprite as ClientSprites draws it; nil when its texture is unknown
function SC.spriteRect(sp)
    local entry = C.tex.get(sp.tex)
    if not entry then return nil end
    local zoom = C.zoom()
    local w, h
    if sp.tiles then w = sp.tiles * C.sprites.TILE_PX / zoom; h = w * entry.h / entry.w
    else w = entry.w * (sp.scale or 1) / zoom; h = entry.h * (sp.scale or 1) / zoom end
    local x, y, z = sp._x or sp.x, sp._y or sp.y, sp._z or sp.z
    local sx, sy = isoToScreenX(0, x, y, z), isoToScreenY(0, x, y, z)
    local top = (sp.anchor == "center") and (sy - h / 2) or (sy - h)
    return sx - w / 2, top, w, h
end

-- the puppet a bubble follows: by online id (zid, multiplayer clients) or by object id (oid, single player)
local function findZombie(zid, oid)
    zid, oid = tonumber(zid), tonumber(oid)
    local key
    if zid and zid >= 0 then key = "z" .. zid elseif oid then key = "o" .. oid else return nil end
    local z = SC.zombies[key]
    if z then
        local ok, dead = pcall(function() return z:isDead() end)
        if ok and not dead then return z end
        SC.zombies[key] = nil
    end
    local ok, list = pcall(function() return getCell():getZombieList() end)
    if not ok or not list then return nil end
    for i = 0, list:size() - 1 do
        local zed = list:get(i)
        local ok2, id = pcall(function() if zid and zid >= 0 then return zed:getOnlineID() end return zed:getID() end)
        if ok2 and id == (zid and zid >= 0 and zid or oid) then SC.zombies[key] = zed; return zed end
    end
    return nil
end

-- screen anchor (bottom-centre x, top y) of a bubble
local function bubbleAnchor(b)
    if b.sid then
        local sp = C.sprites.list[b.sid]
        if sp then
            local x, y, w, h = SC.spriteRect(sp)
            if x then return x + w / 2, y end
            return isoToScreenX(0, sp.x, sp.y, sp.z), isoToScreenY(0, sp.x, sp.y, sp.z) - 64 / C.zoom()
        end
        return nil
    end
    if b.zid or b.oid then
        local zed = findZombie(b.zid, b.oid)
        if zed then
            local ok, x, y, z = pcall(function() return zed:getX(), zed:getY(), zed:getZ() end)
            if ok then b.x, b.y, b.z = x, y, z end
        end
    end
    if b.x == nil then return nil end
    return isoToScreenX(0, b.x, b.y, b.z or 0), isoToScreenY(0, b.x, b.y, b.z or 0) - 120 / C.zoom()
end

---------------------------------------------------------------- hooks
local function drawBubble(ui, b, t)
    local ax, ay = bubbleAnchor(b)
    if not ax then return end
    local age = t - b.t0
    local alpha = 1
    if age < 0.2 then alpha = age / 0.2 elseif b.ttl - age < 0.4 then alpha = math.max(0, (b.ttl - age) / 0.4) end
    local tm = getTextManager()
    local font = UIFont.Small
    local w = tm:MeasureStringX(font, b.text) + 16
    local h = tm:getFontHeight(font) + 10
    local x, y = ax - w / 2, ay - h - 8
    ui:drawRect(x, y, w, h, 0.85 * alpha, 1, 1, 1)
    ui:drawRectBorder(x, y, w, h, alpha, 0.2, 0.2, 0.2)
    ui:drawRect(ax - 3, y + h, 6, 5, 0.85 * alpha, 1, 1, 1)      -- the little tail
    ui:drawTextCentre(b.text, ax, y + 5, 0.1, 0.1, 0.1, alpha, font)
end

local function drawDialog(ui, d, t)
    local sw, sh = C.screen()
    local tm = getTextManager()
    local font, small = UIFont.Medium, UIFont.Small
    local w = math.max(320, tm:MeasureStringX(font, d.text) + 40)
    local bh = tm:getFontHeight(small) + 12
    local h = tm:getFontHeight(font) + 30 + #d.options * (bh + 6)
    local x, y = sw / 2 - w / 2, sh / 2 - h / 2
    ui:drawRect(x, y, w, h, 0.9, 0.08, 0.08, 0.1)
    ui:drawRectBorder(x, y, w, h, 1, 0.9, 0.8, 0.5)
    ui:drawTextCentre(d.text, sw / 2, y + 12, 1, 1, 1, 1, font)
    local by = y + tm:getFontHeight(font) + 26
    d.buttons = {}
    local mx, my = getMouseX(), getMouseY()
    for i, opt in ipairs(d.options) do
        local bx, bw = x + 20, w - 40
        local hover = mx >= bx and mx <= bx + bw and my >= by and my <= by + bh
        ui:drawRect(bx, by, bw, bh, hover and 0.9 or 0.6, hover and 0.35 or 0.2, hover and 0.3 or 0.2, 0.25)
        ui:drawRectBorder(bx, by, bw, bh, 1, 0.9, 0.8, 0.5)
        ui:drawText(i .. ". " .. opt, bx + 10, by + 6, 1, 1, 1, 1, small)
        d.buttons[i] = { x = bx, y = by, w = bw, h = bh }
        by = by + bh + 6
    end
    if d.ttl then
        local left = math.max(0, d.ttl - (t - d.t0))
        ui:drawText(string.format("%ds", math.floor(left)), x + w - 34, y + 6, 0.7, 0.7, 0.7, 1, small)
    end
end

function SC.render(ui)
    local t = C.now()
    for id, b in pairs(SC.bubbles) do
        if t - b.t0 >= b.ttl then SC.bubbles[id] = nil else drawBubble(ui, b, t) end
    end
    for _, id in ipairs(SC.dialogOrder) do
        local d = SC.dialogs[id]
        if d then
            if d.ttl and t - d.t0 >= d.ttl then SC.closeDialog(id, nil, true) else drawDialog(ui, d, t) end
        end
    end
end

function SC.tick(t)
    for id, a in pairs(SC.anims) do
        local sp = C.sprites.list[id]
        if not sp or #a.frames == 0 then SC.anims[id] = nil
        else
            local frame = math.floor((t - a.t0) * a.fps) % #a.frames + 1
            sp.tex = a.frames[frame]
        end
    end
    for id, f in pairs(SC.fades) do
        local sp = C.sprites.list[id]
        if not sp then SC.fades[id] = nil
        else
            local p = math.min(1, (t - f.t0) / f.dur)
            sp.opacity = f.from + (f.to - f.from) * p
            if p >= 1 then SC.fades[id] = nil end
        end
    end
end

function SC.mouseDown(x, y, button)
    if button ~= 0 then return end
    -- dialogs first (newest on top)
    for i = #SC.dialogOrder, 1, -1 do
        local d = SC.dialogs[SC.dialogOrder[i]]
        if d and d.buttons then
            for k, r in ipairs(d.buttons) do
                if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
                    SC.closeDialog(SC.dialogOrder[i], d.options[k])
                    return
                end
            end
            return              -- a click outside the buttons of a modal dialog does nothing
        end
    end
    for id, scene in pairs(SC.watch.clicks) do
        local sp = C.sprites.list[id]
        if sp then
            local rx, ry, rw, rh = SC.spriteRect(sp)
            if rx and x >= rx and x <= rx + rw and y >= ry and y <= ry + rh then
                C.send("sceneClick", { scene = scene, id = id, x = x, y = y })
            end
        end
    end
end

function SC.keyDown(key)
    -- number keys 1..9 (LWJGL codes 2..10) answer the top dialog
    if #SC.dialogOrder > 0 and key >= 2 and key <= 10 then
        local id = SC.dialogOrder[#SC.dialogOrder]
        local d = SC.dialogs[id]
        if d and d.options[key - 1] then SC.closeDialog(id, d.options[key - 1]); return end
    end
    local scenes = SC.watch.keys[tostring(key)]
    if scenes then for scene in pairs(scenes) do C.send("sceneKey", { scene = scene, key = key }) end end
end

function SC.ensure()
    if C.renderHooks[SC.HOOK] then return end
    C.on(SC.HOOK, "render", SC.render)
    C.on(SC.HOOK, "tick", SC.tick)
    C.on(SC.HOOK, "mouseDown", SC.mouseDown)
    C.on(SC.HOOK, "keyDown", SC.keyDown)
end

function SC.closeDialog(id, choice, timedOut)
    local d = SC.dialogs[id]
    if not d then return end
    SC.dialogs[id] = nil
    for i, k in ipairs(SC.dialogOrder) do if k == id then table.remove(SC.dialogOrder, i); break end end
    if not timedOut then C.send("sceneChoice", { scene = d.scene, id = id, choice = choice or "" }) end
    C.syncCapture()
end

---------------------------------------------------------------- commands
-- bubble {scene, id, text, ttl?, sid? (follow a sprite), zid? (follow a zombie by online id), x?, y?, z?}
C.commands.bubble = function(a)
    SC.ensure()
    -- always drawn: a zombie puppet's own Say line is not rendered in single player (only the player's is)
    SC.bubbles[tostring(a.id or "b")] = { scene = a.scene, text = tostring(a.text or ""), t0 = C.now(), ttl = num(a.ttl, 4),
        sid = a.sid and tostring(a.sid) or nil, zid = tonumber(a.zid), oid = tonumber(a.oid),
        x = tonumber(a.x), y = tonumber(a.y), z = tonumber(a.z) }
end
C.commands.bubbleRemove = function(a) SC.bubbles[tostring(a.id or "")] = nil end

-- dialog {scene, id, text, options = "a|b|c", ttl?}
C.commands.dialog = function(a)
    SC.ensure()
    local id = tostring(a.id or "q")
    local options = {}
    for opt in string.gmatch(tostring(a.options or ""), "[^|]+") do options[#options + 1] = opt end
    if #options == 0 then options[1] = "OK" end
    SC.dialogs[id] = { scene = a.scene, text = tostring(a.text or ""), options = options, t0 = C.now(), ttl = tonumber(a.ttl) }
    SC.dialogOrder[#SC.dialogOrder + 1] = id
    C.syncCapture()
end
C.commands.dialogClose = function(a) SC.closeDialog(tostring(a.id or ""), nil, true) end

-- spriteAnim {id, frames = "tex1,tex2,...", fps}: cycles the sprite's texture; frames = "" stops
C.commands.spriteAnim = function(a)
    SC.ensure()
    local id = tostring(a.id or "")
    local frames = {}
    for f in string.gmatch(tostring(a.frames or ""), "[^,]+") do frames[#frames + 1] = f end
    if #frames == 0 then SC.anims[id] = nil; return end
    SC.anims[id] = { scene = a.scene, frames = frames, fps = math.max(0.1, num(a.fps, 6)), t0 = C.now() }
end

-- spriteFade {id, to, dur}
C.commands.spriteFade = function(a)
    SC.ensure()
    local id = tostring(a.id or "")
    local sp = C.sprites.list[id]
    if not sp then return end
    SC.fades[id] = { from = sp.opacity or 1, to = num(a.to, 0), t0 = C.now(), dur = math.max(0.01, num(a.dur, 1)) }
end

-- light {scene, id, x, y, z, r, g, b, radius}: IsoCell:addLamppost (render state only; the scene re-sends on hello)
C.commands.light = function(a)
    local id = tostring(a.id or "l")
    if SC.lights[id] then C.commands.lightRemove({ id = id }) end
    local ok, light = pcall(function()
        return getCell():addLamppost(math.floor(num(a.x, 0)), math.floor(num(a.y, 0)), math.floor(num(a.z, 0)),
            num(a.r, 1), num(a.g, 0.9), num(a.b, 0.7), math.floor(num(a.radius, 6)))
    end)
    if not ok then log("light " .. id .. " failed: " .. tostring(light)); return end
    SC.lights[id] = { scene = a.scene, light = light, x = num(a.x, 0), y = num(a.y, 0), z = num(a.z, 0) }
end

-- lightRemove {id} | {scene}
C.commands.lightRemove = function(a)
    for id, l in pairs(SC.lights) do
        if (a.id and tostring(a.id) == id) or (a.scene and l.scene == a.scene) or (not a.id and not a.scene) then
            pcall(function()
                if l.light then getCell():removeLamppost(l.light) else getCell():removeLamppost(math.floor(l.x), math.floor(l.y), math.floor(l.z)) end
            end)
            SC.lights[id] = nil
        end
    end
end

-- sceneWatch {scene, clicks = "id1,id2", keys = "57,28"}: forward clicks on those sprites / those keys to the scene
C.commands.sceneWatch = function(a)
    SC.ensure()
    local scene = tostring(a.scene or "")
    for id in string.gmatch(tostring(a.clicks or ""), "[^,]+") do SC.watch.clicks[id] = scene end
    for k in string.gmatch(tostring(a.keys or ""), "[^,]+") do
        SC.watch.keys[k] = SC.watch.keys[k] or {}
        SC.watch.keys[k][scene] = true
    end
end

-- sceneClear {scene}: drop everything this module holds for a scene (lights go through lightRemove)
C.commands.sceneClear = function(a)
    local scene = a.scene and tostring(a.scene) or nil
    local function match(v) return scene == nil or v.scene == scene end
    for id, b in pairs(SC.bubbles) do if match(b) then SC.bubbles[id] = nil end end
    for id, d in pairs(SC.dialogs) do if match(d) then SC.closeDialog(id, nil, true) end end
    for id, an in pairs(SC.anims) do if match(an) then SC.anims[id] = nil end end
    for id, s in pairs(SC.watch.clicks) do if scene == nil or s == scene then SC.watch.clicks[id] = nil end end
    for k, set in pairs(SC.watch.keys) do
        if scene == nil then SC.watch.keys[k] = nil else set[scene] = nil; if isEmpty(set) then SC.watch.keys[k] = nil end end
    end
    if scene == nil then SC.fades = {} end
    C.syncCapture()
end

-- sound {name}: a UI sound on this client (vanilla sound names)
C.commands.sound = function(a)
    local name = tostring(a.name or "")
    local ok = pcall(function() getSoundManager():playUISound(name) end)
    if not ok then pcall(function() getSoundManager():PlaySound(name, false, 1) end) end
end

function SC.info()
    local bubbles, lights, anims, dialogs = 0, 0, 0, 0
    for _ in pairs(SC.bubbles) do bubbles = bubbles + 1 end
    for _ in pairs(SC.lights) do lights = lights + 1 end
    for _ in pairs(SC.anims) do anims = anims + 1 end
    for _ in pairs(SC.dialogs) do dialogs = dialogs + 1 end
    return { bubbles = bubbles, lights = lights, anims = anims, dialogs = dialogs }
end
