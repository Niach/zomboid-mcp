# Weather and time

Everything here is server-side and synced (✔ verified live on 42.21 unless marked ○).

## Weather

```lua
-- server: start rain, or a storm, or clear (what set_weather does), and report the climate
local cm = getClimateManager()
cm:transmitServerStartRain(0.7)          -- ✔ rain, intensity 0..1
-- cm:transmitServerTriggerStorm(0.8)    -- ✔ thunderstorm (rain + lightning + wind)
-- cm:transmitServerStopWeather()        -- ✔ end the current weather period
-- cm:transmitServerStopRain()           -- stop rain only
local wp = cm:getWeatherPeriod()
return { raining = cm:isRaining(), rain = cm:getRainIntensity(), temperature = cm:getTemperature(), fog = cm:getFogIntensity(),
         wind = cm:getWindIntensity(), clouds = cm:getCloudIntensity(), daylight = cm:getDayLightStrength(),
         storm = wp:isRunning() and wp:isThunderStorm(), snowing = cm:isSnowing() }
```

- Tool: `set_weather {kind = rain | storm | clear, intensity}`. The `transmit*` methods **without** `Server`
  (`transmitTriggerStorm`, `transmitTriggerTropical`, `transmitTriggerBlizzard`, `transmitGenerateWeather`) are the
  client → server admin requests; on the server call the `transmitServer*` ones.
- Tropical storms and blizzards have no `transmitServer*` form in 42.21. The simulation drifts back to its own
  schedule afterwards: a "clear" is not permanent.
- Fog, wind, temperature are read-only through the manager in practice (`api_search "ClimateManager:set"` lists the
  raw setters; they are overwritten by the simulation).

## Lightning

```lua
-- server: a bolt with light flash and rumble at a tile (does not need the square loaded)
local x, y = 6400, 5498
getClimateManager():transmitServerTriggerLightning(x, y, true, true, true)   -- ✔ (x, y, doStrike, doLight, doRumble)
return true
```

A storm (`set_weather storm`) triggers its own lightning.

## Time

```lua
-- server: 22:30 tonight (what set_time does)
local gt = getGameTime()
gt:setTimeOfDay(22.5)                    -- ✔ 0..24, fractional hours
-- gt:setDay(14) gt:setMonth(9) gt:setYear(1993)     -- 0-based day and month
return { hour = gt:getTimeOfDay(), day = gt:getDay() + 1, month = gt:getMonth() + 1, year = gt:getYear(),
         daysSurvived = gt:getDaysSurvived(), minutesPerDay = gt:getMinutesPerDay() }
```

- Tool: `set_time {hour, day, month, year}` (1-based in the tool). Jumping the clock changes lighting and the date, not
  crops or decay; sudden jumps affect darkness, zombie behaviour and player fatigue.
- Day length: `getGameTime():getMinutesPerDay()` (real minutes per game day, from the sandbox option `DayLength`:
  `getSandboxOptions():getOptionByName("DayLength")` ○). Pausing is not possible in multiplayer.
- Game-time events: `EveryOneMinute`, `EveryTenMinutes`, `EveryHours`, `EveryDays`, `OnDawn`, `OnDusk`.
- Seasons: `getClimateManager():getSeason()` ○, erosion (`ErosionMain`) drives vegetation growth over game days.

## Sounds

```lua
-- server: an FMOD event at a square for everyone in range
local sq = ZMCP.square(6400, 5498, 0)
playServerSound("ZombieThumpGeneric", sq)     -- ✔ names come from media/sound/*.bank (Thunder, AlarmClock, Dog...)
return true
```

Client-only (`run_lua_client`): `getSoundManager():PlaySound("name", false, 0)` ○ or `getPlayer():playSound("name")` ○
so one player hears it. `lua_examples "playServerSound"` shows vanilla event names.
