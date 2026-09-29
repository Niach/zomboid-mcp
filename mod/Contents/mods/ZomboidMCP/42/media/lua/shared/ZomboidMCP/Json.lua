-- Minimal JSON for Kahlua (Lua 5.1). Arrays are Lua tables with 1..n keys; empty tables encode as {}.
ZMCPJson = ZMCPJson or {}
local J = ZMCPJson

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return n > 0
end

local function encode(v, depth)
    depth = depth or 0
    if depth > 30 then return '"<depth>"' end
    local tv = type(v)
    if v == nil then return "null"
    elseif tv == "boolean" then return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.6g", v)
    elseif tv == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c) return escapes[c] or string.format("\\u%04x", string.byte(c)) end) .. '"'
    elseif tv == "table" then
        local out = {}
        if isArray(v) then
            for i = 1, #v do out[i] = encode(v[i], depth + 1) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        for k, val in pairs(v) do
            out[#out + 1] = encode(tostring(k)) .. ":" .. encode(val, depth + 1)
        end
        return "{" .. table.concat(out, ",") .. "}"
    else
        return encode(tostring(v))
    end
end
J.encode = encode

-- decoder
local function skip(s, i)
    local _, e = s:find("^[ \n\r\t]*", i)
    return e + 1
end

local decodeValue

local function decodeString(s, i)
    local out, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then error("unterminated string") end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local n = s:sub(j + 1, j + 1)
            local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
            if map[n] then out[#out + 1] = map[n]; j = j + 2
            elseif n == "u" then
                local code = tonumber(s:sub(j + 2, j + 5), 16) or 63
                if code < 128 then out[#out + 1] = string.char(code) else out[#out + 1] = "?" end
                j = j + 6
            else error("bad escape at " .. j) end
        else
            out[#out + 1] = c; j = j + 1
        end
    end
end

decodeValue = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            local k
            k, i = decodeString(s, skip(s, i))
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then error("expected : at " .. i) end
            obj[k], i = decodeValue(s, i + 1)
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            if d ~= "," then error("expected , or } at " .. i) end
            i = i + 1
        end
    elseif c == "[" then
        local arr = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            arr[#arr + 1], i = decodeValue(s, i)
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            if d ~= "," then error("expected , or ] at " .. i) end
            i = i + 1
        end
    elseif c == '"' then return decodeString(s, i)
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return nil, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" then error("unexpected '" .. c .. "' at " .. i) end
        return tonumber(num), i + #num
    end
end

function J.decode(s)
    local ok, v = pcall(decodeValue, s, 1)
    if not ok then return nil, v end
    return v
end

return J
