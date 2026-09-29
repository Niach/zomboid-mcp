# set_weather

Tool: `set_weather` (server). Rain, thunderstorm or clear through the climate manager's server transmit methods.

```lua
-- server
local cm = getClimateManager()
cm:transmitServerStartRain(0.7)        -- rain, intensity 0..1
-- cm:transmitServerTriggerStorm(0.8)  -- thunderstorm (rain + lightning + wind)
-- cm:transmitServerStopWeather()      -- end the current weather period
-- cm:transmitServerStopRain()         -- stop rain only
return { raining = cm:isRaining(), rain = cm:getRainIntensity(), temperature = cm:getTemperature() }
```

Notes:
- The `transmit*` methods without `Server` in the name (`transmitTriggerStorm`, `transmitTriggerTropical`,
  `transmitTriggerBlizzard`, `transmitGenerateWeather`) are the client → server admin requests; on the server call the
  `transmitServer*` ones.
- Tropical storms and blizzards have no `transmitServer*` form in 42.21; `cm:getWeatherPeriod()` exposes what is running
  (`isRunning`, `isThunderStorm`, `isTropicalStorm`, `isBlizzard`, `getCurrentStrength`).
- The weather simulation resumes its own schedule afterwards; a "clear" is not permanent.
