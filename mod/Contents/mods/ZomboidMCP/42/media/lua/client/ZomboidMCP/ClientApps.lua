-- Zomboid MCP client: screen apps. A screen app is a Lua chunk pushed by app_start (server: Api/Scenes.lua) that
-- draws on the overlay and reads input, e.g. a flappy bird (examples/apps/flappy.lua). The chunk runs in its own
-- environment (setfenv; the engine is reachable through __index) and defines:
--   update(dt)                      every game tick, dt in seconds
--   draw(ui)                        every frame; ui is the overlay ISUIElement (drawRect, drawText, drawTextureScaled ...)
--   onKey(key, down)                LWJGL key code (app.keys.SPACE ...), down = true on press, false on release
--   onMouse(x, y, button, down)     0 = left, 1 = right
--   onExit()                        optional cleanup
--   focus = true                    optional: capture the mouse, sit above the UI and block player movement
-- Esc always exits (and releases everything). The `app` table gives helpers: app.score(n) reports a score event to the
-- server, app.exit(), app.send(data) (server event app_message, optional shared state), app.sound(name), app.text /
-- app.rect / app.border / app.line / app.texture drawing helpers, app.keys, app.keyDown(k), app.mouse(), app.w / app.h.
-- Built on the ZMCPClient.on hook registry (ClientInput.lua) under the hook name "zmcp_apps". An app that throws in
-- any callback is stopped and reported (app_result event with the error); it never breaks the frame.
ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.commands = C.commands or {}
C.apps = C.apps or {}
local A = C.apps
A.HOOK = "zmcp_apps"
A.list = A.list or {}          -- name -> app
A.order = A.order or {}        -- draw order
A.pending = A.pending or {}    -- name -> { total, parts, got, focus }
A.KEYS = {
    ESC = 1, ONE = 2, TWO = 3, THREE = 4, FOUR = 5, FIVE = 6, SIX = 7, SEVEN = 8, EIGHT = 9, NINE = 10, ZERO = 11,
    BACKSPACE = 14, TAB = 15, Q = 16, W = 17, E = 18, R = 19, T = 20, Y = 21, U = 22, I = 23, O = 24, P = 25, ENTER = 28,
    LCTRL = 29, A = 30, S = 31, D = 32, F = 33, G = 34, H = 35, J = 36, K = 37, L = 38, LSHIFT = 42, Z = 44, X = 45, C = 46,
    V = 47, B = 48, N = 49, M = 50, SPACE = 57, UP = 200, LEFT = 203, RIGHT = 205, DOWN = 208,
}

local function num(v, d) local n = tonumber(v); if n == nil then return d end; return n end
local function log(msg) if C.log then C.log(msg) else print("[ZomboidMCP] " .. tostring(msg)) end end
local function truthy(v) return v == true or v == 1 or v == "1" or v == "true" end
local FONTS = { small = UIFont.Small, medium = UIFont.Medium, large = UIFont.Large, title = UIFont.Title }

function A.wantsCapture()
    for _, app in pairs(A.list) do if app.focus then return true end end
    return false
end
C.syncCapture = C.syncCapture or function()
    local want = (C.scenes and C.scenes.wantsCapture and C.scenes.wantsCapture())
        or (C.apps and C.apps.wantsCapture and C.apps.wantsCapture()) or false
    C.capture(want)
end

local function blockMovement(on)
    local p = C.player()
    if not p then return end
    pcall(function() p:setBlockMovement(on and true or false) end)
end

local function syncFocus()
    C.syncCapture()
    blockMovement(A.wantsCapture())
end

---------------------------------------------------------------- the `app` helper table given to a chunk
local function makeApi(app)
    local api = { name = app.name, keys = A.KEYS, state = {} }
    function api.now() return C.now() end
    function api.size() return C.screen() end
    function api.exit() A.stop(app.name, "exit") end
    function api.score(n)
        app.score = tonumber(n) or 0
        C.send("appScore", { name = app.name, score = app.score })
    end
    function api.send(data)
        if type(data) == "table" then local ok, s = pcall(ZMCPJson.encode, data); data = ok and s or tostring(data) end
        C.send("appMsg", { name = app.name, data = tostring(data) })
    end
    function api.log(msg) log("app " .. app.name .. ": " .. tostring(msg)) end
    function api.sound(name)
        local ok = pcall(function() getSoundManager():playUISound(tostring(name)) end)
        if not ok then pcall(function() getSoundManager():PlaySound(tostring(name), false, 1) end) end
    end
    function api.keyDown(k) return C.input.keyDown(k) end
    function api.mouse() return C.input.mouse() end
    function api.rect(ui, x, y, w, h, r, g, b, a) ui:drawRect(x, y, w, h, a or 1, r or 1, g or 1, b or 1) end
    function api.border(ui, x, y, w, h, r, g, b, a) ui:drawRectBorder(x, y, w, h, a or 1, r or 1, g or 1, b or 1) end
    function api.line(ui, x1, y1, x2, y2, r, g, b, a) ui:drawLine2(x1, y1, x2, y2, a or 1, r or 1, g or 1, b or 1) end
    function api.text(ui, text, x, y, r, g, b, a, font, centre)
        local f = FONTS[tostring(font or "medium"):lower()] or UIFont.Medium
        if centre then ui:drawTextCentre(tostring(text), x, y, r or 1, g or 1, b or 1, a or 1, f)
        else ui:drawText(tostring(text), x, y, r or 1, g or 1, b or 1, a or 1, f) end
    end
    function api.textWidth(text, font)
        return getTextManager():MeasureStringX(FONTS[tostring(font or "medium"):lower()] or UIFont.Medium, tostring(text))
    end
    -- texture(ui, ref, x, y, w, h, alpha?, flip?): ref = uploaded texture id, pixel sprite id, "item:Base.X" or a vanilla name
    function api.texture(ui, ref, x, y, w, h, alpha, flip)
        local entry = C.tex.get(ref)
        if not entry then return false end
        C.tex.draw(ui, entry, x, y, w, h, alpha or 1, flip)
        return true
    end
    return api
end

---------------------------------------------------------------- lifecycle
local function report(app, ok, err, state)
    C.send("appResult", { name = app.name, ok = ok, err = err, state = state })
end

local function fail(app, where, err)
    log("app " .. app.name .. " " .. where .. " error: " .. tostring(err))
    A.stop(app.name, "error")
    report(app, false, where .. ": " .. tostring(err), "stopped")
end

-- start(name, src, focusArg): compile + run the chunk, collect its callbacks
function A.start(name, src, focusArg)
    name = tostring(name)
    if A.list[name] then A.stop(name, "restart") end
    local app = { name = name, t0 = C.now(), last = C.now(), score = nil }
    local env = setmetatable({}, { __index = _G })
    app.env = env
    env.app = makeApi(app)
    local fn, err = loadstring(src, "=app:" .. name)
    if not fn then
        log("app " .. name .. " compile error: " .. tostring(err))
        report(app, false, "compile: " .. tostring(err))
        return nil
    end
    setfenv(fn, env)
    local ok, ret = pcall(fn)
    if not ok then
        log("app " .. name .. " error: " .. tostring(ret))
        report(app, false, tostring(ret))
        return nil
    end
    local def = type(ret) == "table" and ret or {}
    for _, k in ipairs({ "update", "draw", "onKey", "onMouse", "onExit" }) do
        local f = def[k] or rawget(env, k)
        if f ~= nil and type(f) ~= "function" then log("app " .. name .. ": " .. k .. " is not a function"); f = nil end
        app[k] = f
    end
    local focus = def.focus
    if focus == nil then focus = rawget(env, "focus") end
    if focus == nil then focus = focusArg end
    app.focus = truthy(focus)
    A.list[name] = app
    A.order[#A.order + 1] = name
    A.ensure()
    syncFocus()
    log("app " .. name .. " started" .. (app.focus and " (focused)" or ""))
    report(app, true, nil, "running")
    return app
end

function A.stop(name, reason)
    name = tostring(name)
    local app = A.list[name]
    if not app then return false end
    A.list[name] = nil
    for i, n in ipairs(A.order) do if n == name then table.remove(A.order, i); break end end
    if app.onExit then
        local ok, err = pcall(app.onExit, reason)
        if not ok then log("app " .. name .. " onExit error: " .. tostring(err)) end
    end
    syncFocus()
    log("app " .. name .. " stopped (" .. tostring(reason) .. ")")
    if reason ~= "error" then report(app, true, nil, "stopped") end
    return true
end

function A.stopAll(reason)
    for _, name in ipairs({ unpack(A.order) }) do A.stop(name, reason or "stopAll") end
end

---------------------------------------------------------------- hooks
local function each(fn)
    -- iterate over a copy: callbacks may stop apps
    local names = {}
    for _, n in ipairs(A.order) do names[#names + 1] = n end
    for _, n in ipairs(names) do
        local app = A.list[n]
        if app then fn(app) end
    end
end

function A.render(ui)
    each(function(app)
        if app.draw then
            local ok, err = pcall(app.draw, ui)
            if not ok then fail(app, "draw", err) end
        end
    end)
end

function A.tick(t)
    each(function(app)
        local dt = t - app.last
        app.last = t
        if app.update then
            local ok, err = pcall(app.update, math.min(dt, 0.25))
            if not ok then fail(app, "update", err) end
        end
    end)
end

local function key(k, down)
    if down and k == A.KEYS.ESC then
        -- Esc always exits: focused apps first, otherwise every app
        local focused = {}
        for _, n in ipairs(A.order) do if A.list[n].focus then focused[#focused + 1] = n end end
        if #focused > 0 then for _, n in ipairs(focused) do A.stop(n, "esc") end
        else A.stopAll("esc") end
        return
    end
    each(function(app)
        if app.onKey then
            local ok, err = pcall(app.onKey, k, down)
            if not ok then fail(app, "onKey", err) end
        end
    end)
end
function A.keyDown(k) key(k, true) end
function A.keyUp(k) key(k, false) end

local function mouse(x, y, button, down)
    each(function(app)
        if app.onMouse then
            local ok, err = pcall(app.onMouse, x, y, button, down)
            if not ok then fail(app, "onMouse", err) end
        end
    end)
end
function A.mouseDown(x, y, b) mouse(x, y, b, true) end
function A.mouseUp(x, y, b) mouse(x, y, b, false) end

function A.ensure()
    if C.renderHooks[A.HOOK] then return end
    C.on(A.HOOK, "render", A.render)
    C.on(A.HOOK, "tick", A.tick)
    C.on(A.HOOK, "keyDown", A.keyDown)
    C.on(A.HOOK, "keyUp", A.keyUp)
    C.on(A.HOOK, "mouseDown", A.mouseDown)
    C.on(A.HOOK, "mouseUp", A.mouseUp)
end

---------------------------------------------------------------- commands
-- appStart {name, part, total, code, focus?}: chunked source, started when every part is in
C.commands.appStart = function(a)
    local name = tostring(a.name or "app")
    local part, total = tonumber(a.part) or 1, tonumber(a.total) or 1
    local p = A.pending[name]
    if not p or p.total ~= total then p = { total = total, parts = {}, got = 0 }; A.pending[name] = p end
    if not p.parts[part] then p.got = p.got + 1 end
    p.parts[part] = a.code or ""
    if a.focus ~= nil then p.focus = a.focus end
    if p.got < total then return end
    A.pending[name] = nil
    if C.ensureOverlay then C.ensureOverlay() end
    A.start(name, table.concat(p.parts), p.focus)
end

C.commands.appStop = function(a)
    if a.name and a.name ~= "" then A.stop(tostring(a.name), "appStop") else A.stopAll("appStop") end
end

function A.info()
    local out = {}
    for _, n in ipairs(A.order) do
        local app = A.list[n]
        out[#out + 1] = n .. (app.focus and "(focused)" or "") .. (app.score and (" score=" .. app.score) or "")
    end
    return out
end
