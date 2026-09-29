local B64 = "<base64 of art/claude.png>"
local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local map = {}
for i = 1, 64 do map[chars:sub(i, i)] = i - 1 end
local name = "zmcp_claude_1.png"
local out = getFileOutput(name)
local n, buf, bits = 0, 0, 0
for i = 1, #B64 do
    local v = map[B64:sub(i, i)]
    if v then
        buf = buf * 64 + v; bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            out:writeByte(math.floor(buf / 2 ^ bits) % 256); n = n + 1
            buf = buf % (2 ^ bits)
        end
    end
end
endFileOutput()
local sep = getFileSeparator()
local tex = getTexture(getMyDocumentFolder() .. sep .. "Lua" .. sep .. name)
ZMCPDev.claudeTex = tex
local p = getSpecificPlayer(0)
local bx, by, bz = p:getX() + 3, p:getY() + 3, p:getZ()
local t0 = getTimestampMs() / 1000
ZMCPDev.hooks["spike"] = function(ui)
    local t = getTimestampMs() / 1000 - t0
    local zoom = getCore():getZoom(0)
    local s = (3.2 + 0.15 * math.sin(t * 2)) / zoom
    local w, h = 256 * s * 0.55, 256 * s * 0.55
    local sx = isoToScreenX(0, bx, by, bz)
    local sy = isoToScreenY(0, bx, by, bz)
    ui:drawTextureScaled(tex, sx - w / 2, sy - h * 0.95, w, h, 1, 1, 1, 1)
end
return "claude logo bytes=" .. n .. " tex=" .. tostring(tex) .. string.format(" at %.0f,%.0f", bx, by)
