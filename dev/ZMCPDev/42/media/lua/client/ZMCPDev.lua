-- Dev exec watcher: re-runs Lua/zmcp_dev_exec.lua when its content changes (checked every ~0.5 s).
ZMCPDev = ZMCPDev or { last = nil, hooks = {} }
local D = ZMCPDev
local function read(name)
    local ok, r = pcall(getFileReader, name, false)
    if not ok or not r then return nil end
    local t, l = {}, r:readLine()
    while l do t[#t + 1] = l; l = r:readLine() end
    r:close()
    return table.concat(t, "\n")
end
local function write(name, s)
    local w = getFileWriter(name, true, false)
    if w then w:write(s); w:close() end
end
local lastCheck = 0
local function check()
    local t = getTimestampMs()
    if t - lastCheck < 500 then return end
    lastCheck = t
    local src = read("zmcp_dev_exec.lua")
    if not src or src == "" or src == D.last then return end
    D.last = src
    local fn, err = loadstring(src)
    local res
    if not fn then res = "COMPILE ERROR: " .. tostring(err)
    else
        local ok, r = pcall(fn)
        res = (ok and "OK: " or "ERROR: ") .. tostring(r)
    end
    write("zmcp_dev_result.txt", os.date("%H:%M:%S") .. " " .. res .. "\n")
    print("[ZMCPDev] " .. res)
end
-- overlay for drawing hooks
require "ISUI/ISUIElement"
local O = ISUIElement:derive("ZMCPDevOverlay")
function O:new() return ISUIElement.new(self, 0, 0, getCore():getScreenWidth(), getCore():getScreenHeight()) end
function O:createChildren() self.javaObject:setConsumeMouseEvents(false) end
function O:render()
    for k, fn in pairs(D.hooks) do
        local ok, err = pcall(fn, self)
        if not ok then D.hooks[k] = nil; print("[ZMCPDev] hook " .. k .. " removed: " .. tostring(err)) end
    end
end
Events.OnGameStart.Add(function()
    if not D.overlay then D.overlay = O:new(); D.overlay:initialise(); D.overlay:instantiate(); D.overlay:addToUIManager(); D.overlay:backMost() end
    write("zmcp_dev_result.txt", os.date("%H:%M:%S") .. " READY\n")
end)
Events.OnTick.Add(check)
