# set_skills

Not a tool: script it. Raising a level through XP is the verified synced path; lowering only touches the server copy.

```lua
-- server
local p = ZMCP.player("niach")
local perk, target = Perks.Woodwork, 5           -- Perks.<Id>; PerkFactory.getPerkFromName("Woodwork") also works
local cur = p:getPerkLevel(perk)
if target > cur then
    local need = perk:getTotalXpForLevel(target) - p:getXp():getXP(perk)
    addXpNoMultiplier(p, perk, need)              -- global; sends the XP to the client (verified on our server)
elseif target < cur then
    p:setPerkLevelDebug(perk, target)             -- server copy only (what the debug menu does client-side)
    p:getXp():setXPToLevel(perk, target)
end
return { id = perk:getId(), before = cur, after = p:getPerkLevel(perk) }
```

Notes:
- Skill ids: see [player_info](player_info.md). Categories (`Perks.Agility`, `Perks.Combat`...) have `getParent() == Perks.None`.
- `p:getXp():AddXP(perk, xp)` applies the player's multipliers; `addXpNoMultiplier` does not.
- Lowering a level for a remote player is best done on that player's client (`run_lua_client`): the same two calls on `getPlayer()`.
