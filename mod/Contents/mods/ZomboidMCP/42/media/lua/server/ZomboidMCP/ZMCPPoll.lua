-- Poll hook for a paused dedicated server (docs/PROTOCOL.md, "Paused server").
-- With PauseEmpty=true and no players online no Lua event fires, but the console still runs
-- `reloadlua ZomboidMCP/ZMCPPoll.lua`, which re-runs this file: it makes the bridge process pending
-- requests once. Harmless when the game loop is running (ZMCP.poll returns immediately then).
if ZMCP and ZMCP.poll then ZMCP.poll() end
