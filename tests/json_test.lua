-- Unit tests for ZomboidMCP/Json.lua. Plain Lua 5.1 / LuaJIT:
--   lua5.1 tests/json_test.lua      (from the repo root)
-- or through tests/run_lua_tests.py (uses the lupa wheel, no system Lua needed).
local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
local path = root .. "/mod/Contents/mods/ZomboidMCP/42/media/lua/shared/ZomboidMCP/Json.lua"
local chunk = assert(loadfile(path))
local J = chunk()
assert(J == ZMCPJson, "module returns the global table")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end
end
local function keys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

test("scalars", function()
    eq(J.encode(nil), "null")
    eq(J.encode(true), "true")
    eq(J.encode(false), "false")
    eq(J.encode(0), "0")
    eq(J.encode(42), "42")
    eq(J.encode(-7), "-7")
    eq(J.encode(3.0), "3")
    eq(J.encode(1.5), "1.5")
    eq(J.encode(1e15), "1e+15")           -- beyond the integer path: tostring
    eq(J.encode(0/0), "null")
    eq(J.encode(math.huge), "null")
    eq(J.encode(-math.huge), "null")
    eq(J.encode(""), '""')
    eq(J.encode("abc"), '"abc"')
end)

test("number precision survives a round trip", function()
    for _, v in ipairs({ 1790720788.123, 0.1, 123456789012345, 1e-7, -2.5e10, 4294967296 }) do
        local back = J.decode(J.encode(v))
        eq(back, v, "value " .. tostring(v))
    end
end)

test("string escapes", function()
    eq(J.encode('a"b'), '"a\\"b"')
    eq(J.encode('a\\b'), '"a\\\\b"')
    eq(J.encode("line\nbreak\ttab\r"), '"line\\nbreak\\ttab\\r"')
    eq(J.encode("\b\f"), '"\\b\\f"')
    eq(J.encode("\1"), '"\\u0001"')
    eq(J.encode("\127"), '"\\u007f"')
    eq(J.encode("keep /slashes"), '"keep /slashes"')
    eq(J.encode("bootId"), '"bootId"')     -- Kahlua range bug regression: letters are never escaped
    eq(J.encode(" !#$%&'()*+,-./:;<=>?@[]^_`{|}~"), '" !#$%&\'()*+,-./:;<=>?@[]^_`{|}~"')
end)

test("utf-8 passes through (plain Lua) or is escaped (Kahlua)", function()
    local s = "caf\195\169"      -- café as UTF-8 bytes
    local out = J.encode(s)
    if J.wideChars then eq(out:find("\\u", 1, true) ~= nil, true) else eq(out, '"caf\195\169"') end
    eq(J.decode(out), s)
end)

test("arrays and objects", function()
    eq(J.encode({}), "{}")
    eq(J.encode(J.array()), "[]")
    eq(J.encode({ 1, 2, 3 }), "[1,2,3]")
    eq(J.encode({ "a", { b = 1 } }), '["a",{"b":1}]')
    eq(J.encode({ b = 1, a = 2 }), '{"a":2,"b":1}')           -- sorted keys
    eq(J.encode({ [1] = "x", [3] = "y" }), '{"1":"x","3":"y"}') -- hole: object with string keys
    eq(J.encode({ [1] = "x", n = 1 }), '{"1":"x","n":1}')
    eq(J.encode({ [1.5] = "x" }), '{"1.5":"x"}')
    eq(J.encode(J.array({ 1, nil, 3 })), "[1,null,3]")          -- forced array keeps holes as null
end)

test("nested and deep", function()
    local t = { a = { b = { c = { d = { 1, { e = "f" } } } } } }
    eq(J.encode(t), '{"a":{"b":{"c":{"d":[1,{"e":"f"}]}}}}')
    local deep = {}
    local cur = deep
    for _ = 1, 60 do cur.x = {}; cur = cur.x end
    local out = J.encode(deep)
    eq(out:find("too deep", 1, true) ~= nil, true, "depth guard")
end)

test("cycles do not hang", function()
    local t = {}
    t.self = t
    local out = J.encode(t)
    eq(type(out), "string")
end)

test("unencodable values become strings", function()
    local out = J.encode({ f = print })
    eq(out:sub(1, 6), '{"f":"')
end)

test("decode scalars", function()
    eq(J.decode("null"), nil)
    eq(J.decode("true"), true)
    eq(J.decode("false"), false)
    eq(J.decode("42"), 42)
    eq(J.decode("-0.5"), -0.5)
    eq(J.decode("1e3"), 1000)
    eq(J.decode("1E-2"), 0.01)
    eq(J.decode('"x"'), "x")
    eq(J.decode('  "x"  '), "x")
end)

test("decode structures", function()
    local v = J.decode('{"a": [1, 2, {"b": null, "c": "d"}], "e": {}, "f": [], "g": -1.25}')
    eq(#v.a, 3)
    eq(v.a[3].b, nil)
    eq(v.a[3].c, "d")
    eq(keys(v.e), 0)
    eq(#v.f, 0)
    eq(v.g, -1.25)
    local arr = J.decode("[null, 1, null, 2]")
    eq(#arr, 2, "nulls dropped from arrays")
    eq(arr[1], 1)
    eq(arr[2], 2)
end)

test("decode string escapes", function()
    eq(J.decode('"a\\"b\\\\c\\/d\\n\\t\\r\\b\\f"'), 'a"b\\c/d\n\t\r\b\f')
    eq(J.decode('"\\u0041\\u0042"'), "AB")
    eq(J.decode('"x\\u0000y"'), "x\0y")
    if J.wideChars then
        eq(J.decode('"\\u00e9"'), string.char(0xE9))
    else
        eq(J.decode('"\\u00e9"'), "\195\169")
        eq(J.decode('"\\u20ac"'), "\226\130\172")
        eq(J.decode('"\\ud83d\\ude00"'), "\240\159\152\128")   -- surrogate pair -> 4-byte UTF-8
    end
end)

test("decode errors return nil, message", function()
    for _, bad in ipairs({ "", "{", "[1,", '{"a":}', '{"a" 1}', '"unterminated', "tru", "[1 2]", '{"a":1} x', "1-2", "{a:1}", "[1,]", '"\\q"', '"\\u12"' }) do
        local v, err = J.decode(bad)
        eq(v, nil, "input " .. bad)
        eq(type(err), "string", "error for " .. bad)
    end
    local v, err = J.decode(42)
    eq(v, nil); eq(type(err), "string")
end)

test("round trip of a request/response shaped document", function()
    local req = { n = 57, t = 1790720788.5, tool = "lua_eval", args = { code = "return 'x'", list = { 1, 2 }, flag = false } }
    local back = J.decode(J.encode(req))
    eq(back.n, 57); eq(back.t, 1790720788.5); eq(back.tool, "lua_eval")
    eq(back.args.code, "return 'x'"); eq(back.args.list[2], 2); eq(back.args.flag, false)
    local res = { n = 57, ok = true, result = { pong = true, players = "", nested = { J.array({}), {} } }, ms = 0 }
    local text = J.encode(res)
    eq(text, '{"ms":0,"n":57,"ok":true,"result":{"nested":[[],{}],"players":"","pong":true}}')
end)

test("large string decode is linear-ish", function()
    local big = string.rep("0123456789abcdef", 8192)   -- 128 KB
    local t0 = os.clock()
    local v = J.decode('{"s":"' .. big .. '"}')
    eq(v.s, big)
    eq(J.decode(J.encode({ s = big })).s, big)
    assert(os.clock() - t0 < 2, "took too long: " .. (os.clock() - t0))
end)

print(string.format("json_test.lua: %d passed, %d failed (%s)", passed, failed, _VERSION))
if failed > 0 then os.exit(1) end
