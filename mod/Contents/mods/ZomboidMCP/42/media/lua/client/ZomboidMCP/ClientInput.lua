-- Zomboid MCP client: hook registry for pushed scripts (render / tick / keyboard / mouse) and input capture
-- for screen apps (a game drawn on the overlay that wants the mouse and keys).
--
--   ZMCPClient.on(name, event, fn)   register; ZMCPClient.off(name) removes every hook of that name
--     events: "render" fn(ui)            every frame, on the overlay (draw with ui:drawRect/drawText/...)
--             "tick" fn(now)             every game tick (seconds, float)
--             "keyDown" fn(key)          OnKeyStartPressed;  "keyUp" fn(key) OnKeyPressed (release);
--             "keyHeld" fn(key)          OnKeyKeepPressed
--             "mouseDown" fn(x, y, button)   "mouseUp" fn(x, y, button)   "mouseMove" fn(x, y, dx, dy)
--             "mouseWheel" fn(delta)
--   ZMCPClient.capture(true|false)   make the overlay swallow mouse events and sit on top of the UI
--   ZMCPClient.input.keyDown(k) / mouse()    polling helpers (isKeyDown, getMouseX/Y, isMouseButtonDown)
--   Legacy: ZMCPClient.renderHooks[name] = fn(ui), ZMCPClient.tickHooks[name] = fn(now) still work.
-- A hook that throws is removed and the error is logged (never every frame).
ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.renderHooks = C.renderHooks or {}
C.tickHooks = C.tickHooks or {}
C.input = C.input or {}
local I = C.input
I.hooks = I.hooks or {}         -- event -> { name -> fn }
I.captured = I.captured or false
I.EVENTS = { keyDown = true, keyUp = true, keyHeld = true, mouseDown = true, mouseUp = true, mouseMove = true, mouseWheel = true }

local function log(msg) if C.log then C.log(msg) else print("[ZomboidMCP] " .. tostring(msg)) end end

function C.on(name, event, fn)
    name = tostring(name)
    if type(fn) ~= "function" then error("ZMCPClient.on(name, event, fn): fn must be a function") end
    if event == "render" then C.renderHooks[name] = fn
    elseif event == "tick" then C.tickHooks[name] = fn
    elseif I.EVENTS[event] then
        I.hooks[event] = I.hooks[event] or {}
        I.hooks[event][name] = fn
    else error("unknown hook event '" .. tostring(event) .. "'") end
    if C.ensureOverlay and C.player() then C.ensureOverlay() end
end

function C.off(name)
    name = tostring(name)
    C.renderHooks[name] = nil
    C.tickHooks[name] = nil
    for _, t in pairs(I.hooks) do t[name] = nil end
end

function C.offAll()
    C.renderHooks = {}
    C.tickHooks = {}
    I.hooks = {}
    C.capture(false)
end

-- run every hook of an event; a failing hook is dropped
function I.fire(event, ...)
    local t = I.hooks[event]
    if not t then return end
    for name, fn in pairs(t) do
        local ok, err = pcall(fn, ...)
        if not ok then t[name] = nil; log("hook '" .. name .. "' (" .. event .. ") removed: " .. tostring(err)) end
    end
end

function I.hasHooks(event)
    local t = I.hooks[event]
    if not t then return false end
    for _ in pairs(t) do return true end
    return false
end

-- overlay on top, swallowing mouse events (for screen apps); off = click-through again, behind the UI
function C.capture(on)
    on = on and true or false
    I.captured = on
    local o = C.overlay
    if not o then return on end
    pcall(function()
        o.javaObject:setConsumeMouseEvents(on)
        if on then o:bringToTop() else o:backMost() end
    end)
    return on
end

function I.keyDown(key) local ok, v = pcall(isKeyDown, key); return ok and v or false end
function I.mouse() return getMouseX(), getMouseY(), isMouseButtonDown(0), isMouseButtonDown(1) end

-- overlay mouse callbacks (ISUIElement calls these only while the overlay consumes mouse events)
function I.overlayMouseDown(x, y) I.fire("mouseDown", x, y, 0); return I.captured end
function I.overlayMouseUp(x, y) I.fire("mouseUp", x, y, 0); return I.captured end
function I.overlayRightDown(x, y) I.fire("mouseDown", x, y, 1); return I.captured end
function I.overlayRightUp(x, y) I.fire("mouseUp", x, y, 1); return I.captured end
function I.overlayMouseMove(dx, dy) I.fire("mouseMove", getMouseX(), getMouseY(), dx, dy); return false end
function I.overlayMouseWheel(del) I.fire("mouseWheel", del); return I.captured end

-- global events (fire whether or not the overlay is capturing)
I.globalHandlers = {
    OnKeyStartPressed = function(key) I.fire("keyDown", key) end,
    OnKeyPressed = function(key) I.fire("keyUp", key) end,
    OnKeyKeepPressed = function(key) I.fire("keyHeld", key) end,
    OnMouseDown = function(x, y) if not I.captured then I.fire("mouseDown", x, y, 0) end end,
    OnMouseUp = function(x, y) if not I.captured then I.fire("mouseUp", x, y, 0) end end,
    OnRightMouseDown = function(x, y) if not I.captured then I.fire("mouseDown", x, y, 1) end end,
    OnRightMouseUp = function(x, y) if not I.captured then I.fire("mouseUp", x, y, 1) end end,
    OnMouseMove = function(dx, dy) if not I.captured then I.fire("mouseMove", getMouseX(), getMouseY(), dx, dy) end end,
    OnMouseWheel = function(del) if not I.captured then I.fire("mouseWheel", del) end end,
}
