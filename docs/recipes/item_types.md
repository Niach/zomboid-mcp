# item_types (search item scripts)

Not a tool: script it. `getScriptManager():getAllItems()` is every item script (vanilla + mods).

```lua
-- server (or client)
local q, limit, out = "banana", 50, {}
q = string.lower(q)
local list = getScriptManager():getAllItems()
for i = 0, list:size() - 1 do
    local s = list:get(i)
    local full, disp = s:getFullName(), s:getDisplayName() or ""
    if string.find(string.lower(full), q, 1, true) or string.find(string.lower(disp), q, 1, true) then
        if not s:isHidden() and not s:getObsolete() and #out < limit then
            out[#out + 1] = { type = full, name = disp, category = s:getDisplayCategory(), weight = s:getActualWeight() }
        end
    end
end
return out
```

Notes: `getScriptManager():FindItem("Base.Banana")` checks one type (nil when unknown). Verified live: "banana" → `Base.Banana`.
