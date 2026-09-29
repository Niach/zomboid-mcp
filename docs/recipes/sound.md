# sound

Not a tool: script it. `playServerSound` plays an FMOD event at a square for all clients in range.

```lua
-- server
local sq = getCell():getGridSquare(6400, 5498, 0)
if not sq then error("square not loaded") end
playServerSound("ZombieThumpGeneric", sq)          -- event names from media/sound/*.bank (e.g. Thunder, AlarmClock, Dog...)
return true
```

Client-only (the local player hears it): `getSoundManager():PlaySound("name", false, 0)` or
`getPlayer():playSound("name")`. World sounds that attract zombies: `addSound(source, x, y, z, radius, volume)`.
