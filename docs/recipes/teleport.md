# teleport

Tool: `teleport` (**client**). Player position is client-authoritative: setting `p:setX()` on the server copy is
overwritten by the next client update. The tool sends the `teleport` command (`docs/PROTOCOL.md` part 2) to the player's client
mod, which calls `player:teleportTo(x, y, z)`; by hand it is the equivalent of:

```lua
-- client (run_lua_client on that player): move the local player
local p = getPlayer()
local x, y, z = 6400.5, 5498.5, 0
if p:getVehicle() then p:getVehicle():exit(p) end
p:setX(x); p:setY(y); p:setZ(z)
p:setLx(x); p:setLy(y); p:setLz(z)      -- "last" position too, or the engine interpolates from the old spot
return { x = p:getX(), y = p:getY(), z = p:getZ() }
```

From the server without the client mod, the vanilla admin path is the console: `teleportto <user> <x>,<y>,<z>` or
`teleport <user> <toUser>` (the MCP `server_console` tool).

Notes:
- The target chunks load around the player after the move; expect a short black screen for far teleports.
- Verify with `player_info` a second later: the server copy updates once the client has sent its new position.
