# set_traits

Not a tool: script it. Traits live server-side in `CharacterTraits`; the change syncs, the client UI may only refresh after relog.

```lua
-- server
local p = ZMCP.player("niach")
local traits = p:getCharacterTraits()
traits:add(CharacterTrait.BRAVE)                -- constants: upper snake case, see javap zombie.scripting.objects.CharacterTrait
traits:remove(CharacterTrait.COWARDLY)
sendPlayerExtraInfo(p)                           -- pushes extra info (traits, god mode, ...) to clients
local out = {}
local known = traits:getKnownTraits()            -- List<CharacterTrait>
for i = 0, known:size() - 1 do out[#out + 1] = known:get(i):getName() end   -- ids like "brave"
return out
```

Look a trait up by name or label:

```lua
local function findTrait(name)
    local direct = CharacterTrait[string.upper(string.gsub(name, "[^%w]", "_"))]   -- "Fast Learner" -> FAST_LEARNER
    if direct then return direct end
    local defs = CharacterTraitDefinition.getTraits()                              -- 97 definitions
    for i = 0, defs:size() - 1 do
        local d = defs:get(i)
        if string.lower(d:getLabel()) == string.lower(name) or d:getType():getName() == string.lower(name) then return d:getType() end
    end
end
```

Listing: `CharacterTraitDefinition.getTraits()` → `d:getType():getName()` (id), `d:getLabel()`, `d:getCost()`, `d:isFree()`.
Verified live: `CharacterTrait.BRAVE:getName() == "brave"`.
