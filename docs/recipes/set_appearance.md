# set_appearance

Not a tool: script it **on the client** (appearance is client-authoritative; the server copy gets overwritten).

```lua
-- client (run_lua_client on that player)
local p = getPlayer()
local vis = p:getHumanVisual()
vis:setHairModel("Mohawk")                       -- ids: getAllHairStyles(p:isFemale()) e.g. Bald, Picard, CrewCut, Baldspot...
vis:setBeardModel("Goatee")                      -- ids: getAllBeardStyles() (10 in 42.21); "" for none
vis:setHairColor(ImmutableColor.new(0.9, 0.2, 0.2))     -- floats 0..1 (an int overload 0..255 exists too)
vis:setBeardColor(ImmutableColor.new(0.9, 0.2, 0.2))
-- vis:setSkinColor(ImmutableColor.new(0.8, 0.7, 0.6))
p:resetModelNextFrame()                          -- rebuild the model
sendVisual(p)                                    -- client -> server -> other clients
return { hair = vis:getHairModel(), beard = vis:getBeardModel() }
```

Server-side attempt (works for what other players see; the owning client may revert it): same `HumanVisual` calls on the
server's player object, then `p:resetModelNextFrame()` and `sendHumanVisual(p)`.

Listing styles: `getAllHairStyles(female)` (42 male), `getAllBeardStyles()`; data in `media/hairStyles/*.xml`.
