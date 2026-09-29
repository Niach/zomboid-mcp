# server_message

Tool: `server_message` (**client**) with `mode` = `notify` (box at the top of the screen), `halo` (text over the player), `chat`
(chat line) or `say` (speech bubble); it sends the command of the same name to the client mod (`docs/PROTOCOL.md` part 2).
The raw Lua behind it:

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

From a server script the client mod does it for you: `ZMCP.toClients("notify", { text = "Bananas incoming!", ttl = 5 })`,
`ZMCP.toClients("halo", { text = "..." }, ZMCP.player("niach"))`, `ZMCP.toClients("chat", { text = "..." })` or
`ZMCP.toClients("say", { text = "..." })` (see `docs/PROTOCOL.md` part 2).
