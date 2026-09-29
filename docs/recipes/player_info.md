# player_info

Tool: `player_info` (server). Position, health, traits, skills, inventory, equipment, moodles and stats of one player.
Moodles and stats are the server's copy of client state; they can lag behind what the player sees.

```lua
-- server
local p = ZMCP.player("niach")          -- or loop getOnlinePlayers()
local bd, info = p:getBodyDamage(), {}
info.pos = { x = p:getX(), y = p:getY(), z = p:getZ(), dir = tostring(p:getDir()) }
info.health = { overall = bd:getOverallBodyHealth(), infected = bd:IsInfected(),
                bleeding = bd:getNumPartsBleeding(), asleep = p:isAsleep(), god = p:isGodMod() }

-- traits: List<CharacterTrait>; ids are short like "brave"; labels through the definition
info.traits = {}
local kt = p:getCharacterTraits():getKnownTraits()
for i = 0, kt:size() - 1 do
    local t = kt:get(i)
    info.traits[#info.traits + 1] = { id = t:getName(),
        label = CharacterTraitDefinition.getCharacterTraitDefinition(t):getLabel() }
end

-- skills: PerkFactory.PerkList holds categories (parent == Perks.None) and skills
info.skills = {}
for i = 0, PerkFactory.PerkList:size() - 1 do
    local perk = PerkFactory.PerkList:get(i)
    if perk:getParent() ~= Perks.None then
        info.skills[perk:getId()] = { level = p:getPerkLevel(perk), xp = p:getXp():getXP(perk) }
    end
end

-- inventory summary by type
info.inventory = {}
local items = p:getInventory():getItems()
for i = 0, items:size() - 1 do
    local t = items:get(i):getFullType()
    info.inventory[t] = (info.inventory[t] or 0) + 1
end
info.weight = p:getInventory():getContentsWeight()

-- equipped / worn
local prim, sec = p:getPrimaryHandItem(), p:getSecondaryHandItem()
info.primary = prim and prim:getFullType() or nil
info.secondary = sec and sec:getFullType() or nil
info.worn = {}
local worn = p:getWornItems():getItems()
for i = 0, worn:size() - 1 do
    local w = worn:get(i)
    info.worn[#info.worn + 1] = { location = tostring(w:getLocation():getId()), type = w:getItem():getFullType() }
end

-- moodles (MoodleType.X constants) and stats (CharacterStat.X)
info.moodles = {}
for _, n in ipairs({ "HUNGRY", "THIRST", "TIRED", "PANIC", "STRESS", "PAIN", "INJURED", "BLEEDING", "SICK", "WET", "DRUNK" }) do
    local lvl = p:getMoodles():getMoodleLevel(MoodleType[n])
    if lvl > 0 then info.moodles[n] = lvl end
end
info.stats = { hunger = p:getStats():get(CharacterStat.HUNGER), thirst = p:getStats():get(CharacterStat.THIRST),
               fatigue = p:getStats():get(CharacterStat.FATIGUE), panic = p:getStats():get(CharacterStat.PANIC) }
return info
```

Notes:
- Skill ids (42.21): Axe, Blunt, SmallBlunt, LongBlade, SmallBlade, Spear, Maintenance, Aiming, Reloading, Woodwork, Carving,
  Cooking, Electricity, Doctor, Glassmaking, FlintKnapping, Masonry, Blacksmith, Mechanics, Pottery, Tailoring, MetalWelding,
  Fishing, PlantScavenging, Tracking, Trapping, Fitness, Strength, Lightfoot, Nimble, Sprinting, Sneak, Farming, Husbandry, Butchering.
- `CharacterStat.X` names: HUNGER, THIRST, FATIGUE, ENDURANCE, PANIC, STRESS, BOREDOM, UNHAPPINESS, PAIN, SICKNESS, WETNESS,
  TEMPERATURE, INTOXICATION, ZOMBIE_INFECTION (and more, see `javap zombie.characters.CharacterStat`).
