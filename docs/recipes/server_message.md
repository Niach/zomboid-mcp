# server_message

Not a tool: three ways.

```lua
-- client (run_lua_client on all players or one): floating halo text above the local player
HaloTextHelper.addText(getPlayer(), "Bananas incoming!", "", 255, 220, 40)   -- (player, text, suffix, r, g, b)
-- HaloTextHelper.addGoodText(getPlayer(), "Healed")  / addBadText(...)
```

```lua
-- client: a line in the chat panel (no sender)
ISChat.addLineInChat({ getText = function() return "Bananas incoming!" end, getTextWithPrefix = function() return "[MCP] Bananas incoming!" end,
                       isServerAlert = function() return true end, isShowAuthor = function() return false end,
                       getAuthor = function() return "" end, setShouldAttractZombies = function() end,
                       setOverHeadSpeech = function() end, isOverHeadSpeech = function() return false end,
                       getChatID = function() return -1 end, isFromDiscord = function() return false end,
                       getDatetimeStr = function() return "" end, getTextWithReplacedParentheses = function() return "Bananas incoming!" end }, -1)
```
(The chat object shape depends on the ISChat version; the halo path is the robust one.)

Server console (the MCP `server_console` tool): `servermsg "Bananas incoming!"` shows the vanilla server-message box on every client.

The server can also ask the client mod to do it: `sendServerCommand(player, "zmcp", "message", { text = "...", mode = "halo" })`
if ZOM-6 implements the `message` command (see `docs/PROTOCOL.md`).
