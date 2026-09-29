-- >>> ZomboidMCP dev bootstrap
-- Appended by `tools/pz bootstrap` to a server Lua file that is already loaded at startup (currently
-- vapps/VappsGuardian.lua in the dev bind mount), so that `reloadlua <that file>` from the console:
--   * runs Zomboid/Lua/zmcp_boot.lua (written by `tools/pz load`) when it is new (first line stamp differs
--     from ZMCP.bootStamp): this is how the bridge gets into the running server before the ZomboidMCP
--     bind mount exists, and how it comes back after a server start;
--   * otherwise just polls the bridge (ZMCP.poll), which is how requests get answered while the server is
--     paused with nobody online (no Lua event fires then). Same job as ZomboidMCP/ZMCPPoll.lua.
-- Everything is pcall'ed: it can never break the host file.
pcall(function()
    local ok, r = pcall(getFileReader, "zmcp_boot.lua", false)
    if not ok or not r then return end
    local t, l = {}, r:readLine()
    while l do t[#t + 1] = l; l = r:readLine() end
    r:close()
    local text = table.concat(t, "\n")
    local stamp = text:match("^%-%- zmcp_boot (%S+)")
    if ZMCP and ZMCP.poll and stamp and ZMCP.bootStamp == stamp then
        ZMCP.poll()
        return
    end
    local fn, err = loadstring(text, "=zmcp_boot.lua")
    if not fn then print("[ZomboidMCP] boot compile error: " .. tostring(err)) return end
    local ok2, res = pcall(fn)
    if ok2 then print("[ZomboidMCP] boot: " .. tostring(res))
    else print("[ZomboidMCP] boot error: " .. tostring(res)) end
end)
-- <<< ZomboidMCP dev bootstrap
