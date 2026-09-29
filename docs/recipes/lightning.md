# lightning

Not a tool: script it. Server-side, everyone nearby sees and hears it.

```lua
-- server
local x, y = 6400, 5498
-- (x, y, doStrike, doLight, doRumble): strike = the actual bolt/fx at the square, light = the screen flash
getClimateManager():transmitServerTriggerLightning(x, y, true, true, true)
return true
```

Notes: does not need the square to be loaded. A storm (`set_weather storm`) triggers its own lightning.
