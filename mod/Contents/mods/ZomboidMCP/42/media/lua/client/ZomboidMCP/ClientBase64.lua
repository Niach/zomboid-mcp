-- Zomboid MCP client: pure-Lua base64 (Kahlua has no bit operations, so this is arithmetic only).
-- Used to turn base64 PNG chunks pushed by the server into files in the Lua cache dir (getFileOutput).
ZMCPClient = ZMCPClient or {}
local C = ZMCPClient
C.b64 = C.b64 or {}
local B = C.b64

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local VALUE = {}
for i = 1, 64 do VALUE[string.byte(ALPHABET, i)] = i - 1 end
VALUE[string.byte("-")] = 62   -- url-safe variant
VALUE[string.byte("_")] = 63

-- Feed decoded bytes to sink(byte). Characters outside the alphabet (newlines, '=') are skipped.
-- Returns the number of bytes produced.
function B.decodeTo(text, sink)
    local buf, bits, n = 0, 0, 0
    for i = 1, #text do
        local v = VALUE[string.byte(text, i)]
        if v then
            buf = buf * 64 + v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local div = 2 ^ bits
                sink(math.floor(buf / div) % 256)
                n = n + 1
                buf = buf % div
            end
        end
    end
    return n
end

-- Decode to a Lua string (fine for small payloads: JSON, short text).
function B.decode(text)
    local out, chunk = {}, {}
    B.decodeTo(text, function(b)
        chunk[#chunk + 1] = string.char(b)
        if #chunk >= 512 then out[#out + 1] = table.concat(chunk); chunk = {} end
    end)
    out[#out + 1] = table.concat(chunk)
    return table.concat(out)
end

-- Decode straight into a binary file in the Lua cache dir (~/Zomboid/Lua/<name>). Returns bytes written.
function B.decodeToFile(text, name)
    local out = getFileOutput(name)
    if not out then error("getFileOutput failed for " .. tostring(name)) end
    local ok, n = pcall(B.decodeTo, text, function(b) out:writeByte(b) end)
    endFileOutput()
    if not ok then error(n) end
    return n
end

-- Encode a Lua string (used by tests and by exec'd code that wants to send small binaries back).
function B.encode(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = string.byte(s, i), string.byte(s, i + 1), string.byte(s, i + 2)   -- single-arg byte() for Kahlua
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = ALPHABET:sub(c1 + 1, c1 + 1) .. ALPHABET:sub(c2 + 1, c2 + 1)
            .. (b and ALPHABET:sub(c3 + 1, c3 + 1) or "=") .. (c and ALPHABET:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end
