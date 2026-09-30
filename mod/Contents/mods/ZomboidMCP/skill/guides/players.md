# Players

Legend: ✔ verified live on 42.21, ○ from the API index / vanilla Lua. **Authority matters most here:** the server owns
XP, traits, god mode, inventory; the **client** owns position, body damage and infection, appearance, stats and moodles
(the server only holds a copy that the client overwrites every second).

## Find and describe

```lua
-- server: every online player with position and health (what players_list does)
local out = {}
for _, p in ipairs(ZMCP.players()) do
    local d = p:getDescriptor()
    out[#out + 1] = { user = p:getUsername(), name = d:getForename() .. " " .. d:getSurname(),
        x = p:getX(), y = p:getY(), z = p:getZ(), health = p:getBodyDamage():getOverallBodyHealth(),
        dead = p:isDead(), access = p:getAccessLevel(), vehicle = p:getVehicle() and p:getVehicle():getScriptName() or nil }
end
return out
```

- ✔ `getOnlinePlayers()` works on the server; `getPlayerFromUsername` returned nil: `ZMCP.player(name)` matches the
  account or "Forename Surname" case-insensitively and errors with the online list. In single player the host is
  `getSpecificPlayer(0)`.
- `player_info {player}` gives health, infection, traits, skills, inventory summary, equipment, moodles and stats.

## Heal and cure (client-authoritative)

✔ A server-side cure was overwritten by the client every second. Send it to that player's client:

```lua
-- server: heal and cure one player through the client mod's built-in commands
local p = ZMCP.player("niach")
ZMCP.toClients("heal", {}, p)     -- every body part restored, stiffness/pain/panic/stress/fatigue/hunger/thirst reset
ZMCP.toClients("cure", {}, p)     -- zombie infection and wound infection cleared
return "sent"
```

```lua
-- client (run_lua_client {player}): the same by hand, on the local player
local p = getPlayer()
local bd = p:getBodyDamage()
local parts = bd:getBodyParts()
for i = 0, parts:size() - 1 do
    local bp = parts:get(i)
    bp:RestoreToFullHealth()
    bp:SetInfected(false)
    bp:setInfectedWound(false)
end
bd:setInfected(false)
bd:setInfectionTime(-1)
bd:setInfectionMortalityDuration(-1)
p:getStats():set(CharacterStat.PANIC, 0)      -- B42 stats registry: stats:set(CharacterStat.X, value)
sendPlayerStatsChange(p)
return { health = bd:getOverallBodyHealth(), infected = bd:IsInfected() }
```

Vanilla admin path from the server (`bodyPart:RestoreToFullHealth()` + `syncBodyPart(bp, 0xFFFFFFFFFFF)`) heals but
was not proven for infection. `CharacterStat` names: HUNGER, THIRST, FATIGUE, ENDURANCE, PANIC, STRESS, BOREDOM,
UNHAPPINESS, PAIN, SICKNESS, WETNESS, TEMPERATURE, INTOXICATION, ZOMBIE_INFECTION.

## Teleport (client-authoritative)

Tool: `teleport {player, x, y, z}` sends the `teleport` command; the client calls `p:teleportTo(x, y, z)`, chunks load
around them (short black screen for far jumps), and the server copy updates a second later (`player_info`). By hand
on the client: `getPlayer():teleportTo(x, y, z)`. Vanilla fallback without the client mod: `server_console
"teleportto <user> <x>,<y>,<z>"`.

## XP, skills, traits, god mode (server-authoritative)

```lua
-- server: Woodwork to level 5 through XP (synced), a trait, god mode
local p = ZMCP.player()
local perk = Perks.Woodwork                                   -- Perks.<Id>; PerkFactory.getPerkFromName("Woodwork")
local cur = p:getPerkLevel(perk)
if cur < 5 then
    addXpNoMultiplier(p, perk, perk:getTotalXpForLevel(5) - p:getXp():getXP(perk))   -- ✔ sends the XP to the client
end
p:getCharacterTraits():add(CharacterTrait.BRAVE)              -- ✔ constants are UPPER_SNAKE (FAST_LEARNER, ...)
p:setGodMod(true, true)                                       -- ✔ what the godmodeplayer console command does
sendPlayerExtraInfo(p)                                        -- ✔ pushes traits / god mode / access to clients
return { level = p:getPerkLevel(perk), god = p:isGodMod() }
```

- Skill ids (42.21): Axe, Blunt, SmallBlunt, LongBlade, SmallBlade, Spear, Maintenance, Aiming, Reloading, Woodwork,
  Carving, Cooking, Electricity, Doctor, Glassmaking, FlintKnapping, Masonry, Blacksmith, Mechanics, Pottery, Tailoring,
  MetalWelding, Fishing, PlantScavenging, Tracking, Trapping, Fitness, Strength, Lightfoot, Nimble, Sprinting, Sneak,
  Farming, Husbandry, Butchering. Categories have `getParent() == Perks.None`.
- Lowering a level: `p:setPerkLevelDebug(perk, n)` + `p:getXp():setXPToLevel(perk, n)` on the **client** of that player.
- Traits: `CharacterTraitDefinition.getTraits()` lists 97 definitions (`d:getType():getName()`, `d:getLabel()`);
  `traits:remove(CharacterTrait.X)`. The client UI may refresh only after relog.
- Invisible: ○ `p:setInvisible(true)` + `sendPlayerExtraInfo(p)` (the `invisible` console command).
- Kills, hours: `p:getZombieKills()`, `p:getHoursSurvived()`.

## Appearance (client-authoritative)

```lua
-- client (run_lua_client {player}): hair, beard and colours on the local player, then sync
local p = getPlayer()
local vis = p:getHumanVisual()
vis:setHairModel("Mohawk")                            -- ids: getAllHairStyles(p:isFemale())
vis:setBeardModel("Goatee")                           -- ids: getAllBeardStyles(); "" for none
vis:setHairColor(ImmutableColor.new(0.9, 0.2, 0.2))   -- floats 0..1
p:resetModelNextFrame()
sendVisual(p)                                         -- client -> server -> other clients
return { hair = vis:getHairModel(), beard = vis:getBeardModel() }
```

Clothing is inventory: give the item and equip it on the client (`items.md`). Styles are listed in
`media/hairStyles/*.xml`; `getAllHairStyles(female)` / `getAllBeardStyles()` at runtime.

## Messages to a player

`server_message {text, mode = notify | halo | chat | say, player?}` or from a script `ZMCP.toClients("notify",
{text, ttl}, p)`, `("halo", {text, r, g, b})`, `("chat", {text})`, `("say", {text})`. Vanilla fallback for players
without the mod: `server_console "servermsg <text>"`. Client-side halo by hand: `HaloTextHelper.addText(getPlayer(),
"Bananas incoming!", "", 255, 220, 40)`.

## Death and respawn

`Events.OnPlayerDeath.Add(function(p) end)` (server) fires on death; `p:isDead()`. Respawn is the player's own choice
through the UI. Access level: `p:getAccessLevel()` (`admin`, `moderator`, ...), changed with the console
(`setaccesslevel <user> admin`).
