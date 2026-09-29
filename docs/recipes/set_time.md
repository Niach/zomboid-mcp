# set_time

Tool: `set_time` (server). Move the game clock; the server pushes the time to clients.

```lua
-- server
local gt = getGameTime()
gt:setTimeOfDay(22.5)      -- 0..24, fractional hours
-- gt:setDay(14)           -- 0-based day of month
-- gt:setMonth(9)          -- 0-based month
-- gt:setYear(1993)
return { hour = gt:getTimeOfDay(), day = gt:getDay() + 1, month = gt:getMonth() + 1, year = gt:getYear(),
         daysSurvived = gt:getDaysSurvived() }
```

Notes: jumping the clock does not advance world simulation (crops, decay); it only changes lighting and the date.
