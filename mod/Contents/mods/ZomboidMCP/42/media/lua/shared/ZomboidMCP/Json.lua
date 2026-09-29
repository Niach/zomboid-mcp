-- Minimal JSON for Kahlua (Project Zomboid) and plain Lua 5.1 / LuaJIT.
--   ZMCPJson.encode(value) -> string            never raises; unencodable values become strings
--   ZMCPJson.decode(text)  -> value | nil, err   returns nil, "message" on malformed input
-- Conventions:
--   * A table whose keys are exactly 1..n (n >= 1) is an array; every other table is an object.
--     An empty table encodes as {}. Use ZMCPJson.array(t) to force [] for empty tables.
--   * JSON null decodes to nil: object keys disappear, array nulls are dropped (indices shift).
--   * Output is pure ASCII on Kahlua (non-ASCII chars become \uXXXX), so it is safe whatever the
--     JVM's default file charset is. On plain Lua, strings are treated as UTF-8 bytes.
--   * Numbers: integers print without a decimal point, other numbers via tostring (full precision).
--     NaN and +/-inf become null.
ZMCPJson = ZMCPJson or {}
local J = ZMCPJson

-- Kahlua strings are Java strings (UTF-16 units, string.char accepts up to 0xFFFF);
-- plain Lua strings are bytes (string.char(256) raises). Detect which one we are on.
local WIDE = pcall(string.char, 256)
J.wideChars = WIDE

local ARRAY = {}   -- metatable marker: force array encoding
function J.array(t) return setmetatable(t or {}, ARRAY) end

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function escapeChar(c)
    local e = escapes[c]
    if e then return e end
    return string.format("\\u%04x", string.byte(c))
end

-- Kahlua: escape everything outside printable ASCII (including chars > 255) in two passes; its pattern
-- matcher does not treat an escaped char (%]) as the start of a range, so a single negated set cannot
-- exclude both quote and backslash. Plain Lua: one pass for control chars, quotes and backslashes; bytes
-- >= 0x80 pass through as UTF-8.
local encodeString
if WIDE then
    encodeString = function(s)
        local escaped = s:gsub('["\\]', escapeChar)
        escaped = escaped:gsub('[^ -~]', escapeChar)
        return '"' .. escaped .. '"'
    end
else
    encodeString = function(s)
        local escaped = s:gsub('[%c"\\]', escapeChar)
        return '"' .. escaped .. '"'
    end
end

local function isArray(t)
    if getmetatable(t) == ARRAY then return true end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
        n = n + 1
    end
    if n == 0 then return false end
    for i = 1, n do if t[i] == nil then return false end end
    return true
end

local function encodeNumber(v)
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.floor(v) == v and math.abs(v) < 1e15 then
        local ok, s = pcall(string.format, "%d", v)
        if ok then return s end
    end
    local s = tostring(v)
    if s:sub(-2) == ".0" then s = s:sub(1, -3) end   -- Kahlua prints 3.0 for some integral doubles
    return s
end

local function encode(v, depth)
    depth = depth or 0
    if depth > 40 then return '"<too deep>"' end
    local tv = type(v)
    if v == nil then return "null"
    elseif tv == "boolean" then return v and "true" or "false"
    elseif tv == "number" then return encodeNumber(v)
    elseif tv == "string" then return encodeString(v)
    elseif tv == "table" then
        local out = {}
        if isArray(v) then
            local n = #v
            if getmetatable(v) == ARRAY then n = 0; for k in pairs(v) do if type(k) == "number" and k > n then n = k end end end
            for i = 1, n do out[i] = encode(v[i], depth + 1) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        for k, val in pairs(v) do
            out[#out + 1] = encodeString(tostring(k)) .. ":" .. encode(val, depth + 1)
        end
        table.sort(out)     -- deterministic output (helps tests and diffs)
        return "{" .. table.concat(out, ",") .. "}"
    else
        local ok, s = pcall(tostring, v)   -- userdata / function: best effort
        return encodeString(ok and s or ("<" .. tv .. ">"))
    end
end
J.encode = function(v) return encode(v, 0) end

---------------------------------------------------------------- decoder
local function skip(s, i)
    local _, e = s:find("^[ \n\r\t]*", i)
    return e + 1
end

local function utf8Char(code)
    if WIDE then return string.char(code) end
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40) end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local unescape = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local function decodeString(s, i)
    -- s:sub(i, i) == '"'
    local out, j = {}, i + 1
    while true do
        local k = s:find('["\\]', j)
        if not k then error("unterminated string starting at " .. i) end
        if k > j then out[#out + 1] = s:sub(j, k - 1) end
        if s:sub(k, k) == '"' then return table.concat(out), k + 1 end
        local n = s:sub(k + 1, k + 1)
        if unescape[n] then
            out[#out + 1] = unescape[n]; j = k + 2
        elseif n == "u" then
            local hex = s:sub(k + 2, k + 5)
            local code = #hex == 4 and tonumber(hex, 16)
            if not code then error("bad \\u escape at " .. k) end
            j = k + 6
            if not WIDE and code >= 0xD800 and code <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
                local lo = tonumber(s:sub(j + 2, j + 5), 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
                    j = j + 6
                end
            end
            out[#out + 1] = utf8Char(code)
        else
            error("bad escape \\" .. n .. " at " .. k)
        end
    end
end

local decodeValue

local function decodeObject(s, i)
    local obj = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        i = skip(s, i)
        if s:sub(i, i) ~= '"' then error("expected string key at " .. i) end
        local k
        k, i = decodeString(s, i)
        i = skip(s, i)
        if s:sub(i, i) ~= ":" then error("expected ':' at " .. i) end
        obj[k], i = decodeValue(s, i + 1)
        i = skip(s, i)
        local d = s:sub(i, i)
        if d == "}" then return obj, i + 1 end
        if d ~= "," then error("expected ',' or '}' at " .. i) end
        i = i + 1
    end
end

local function decodeArray(s, i)
    local arr, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local v
        v, i = decodeValue(s, i)
        if v ~= nil then n = n + 1; arr[n] = v end
        i = skip(s, i)
        local d = s:sub(i, i)
        if d == "]" then return arr, i + 1 end
        if d ~= "," then error("expected ',' or ']' at " .. i) end
        i = i + 1
    end
end

decodeValue = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then return decodeObject(s, i)
    elseif c == "[" then return decodeArray(s, i)
    elseif c == '"' then return decodeString(s, i)
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return nil, i + 4
    elseif c == "" then error("unexpected end of input")
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        local v = num and tonumber(num)
        if not v then error("unexpected '" .. c .. "' at " .. i) end
        return v, i + #num
    end
end

function J.decode(s)
    if type(s) ~= "string" then return nil, "expected string, got " .. type(s) end
    local ok, v, i = pcall(decodeValue, s, 1)
    if not ok then return nil, tostring(v) end
    i = skip(s, i)
    if i <= #s then return nil, "trailing garbage at " .. i end
    return v
end

return J
