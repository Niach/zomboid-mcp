-- Merchant: a passive zombie who waits at a spot, greets players who come near, walks up to them and trades.
-- Start:  scene_start {name = "merchant", code = <this file>, args = {x, y, z, outfit, wares, price, radius}}
-- Stop:   scene_stop  {name = "merchant"}   (removes the puppet and everything else)
-- Args (all optional): x, y, z = where the merchant stands (default: 4 tiles east of the first player online);
--   outfit = zombie outfit name (docs/recipes/outfits.md; default "Bandit"); wares = item type he sells
--   (default "Base.Axe"); price = item type he wants (default "Base.Banana", nothing when price = false);
--   radius = greeting distance in tiles (default 6). Trades are counted in state.trades (survives restarts).
local cfg = args or {}
local wares = cfg.wares or "Base.Axe"
local price = cfg.price
if price == nil then price = "Base.Banana" end
local radius = cfg.radius or 6
-- what the merchant calls the items: the display name when the script manager knows the type, else the type
local function itemName(t)
    local ok, n = pcall(function() return getScriptManager():FindItem(t):getDisplayName() end)
    return ok and n or t
end
local waresName, priceName = itemName(wares), price and itemName(price) or nil

-- the spot: given, or next to the first player who is online (a persistent scene waits here after a restart)
local x, y, z = cfg.x, cfg.y, cfg.z or 0
if not x then
    waitUntil(function() return #players() > 0 end)
    local p = players()[1]
    x, y, z = math.floor(p:getX()) + 4, math.floor(p:getY()), math.floor(p:getZ())
end
-- the square must be loaded (someone near) before a zombie can be spawned there
waitUntil(function() return loaded(x, y, z) end)

state.trades = state.trades or 0
local merchant = spawnActor{ kind = "zombie", outfit = cfg.outfit or "Bandit", x = x, y = y, z = z, name = "Merchant", passive = true }
log("Merchant ready at", x, y, "selling", wares, "for", tostring(price))

-- take one `price` item from the player's inventory (server-side, synced); true when paid
local function takePayment(player)
    if not price then return true end
    local inv = player:getInventory()
    local item = inv:getFirstType(price)
    if not item then return false end
    inv:Remove(item)
    pcall(sendRemoveItemFromContainer, inv, item)
    return true
end

-- one visit: greet, walk over, offer, trade, walk back. Runs at most once per 20 s (cooldown), one player at a time.
merchant:onNear(radius, function(player)
    local who = name(player)
    merchant:face(player:getX(), player:getY())
    merchant:say("Psst... " .. who .. ". Over here.")
    if not merchant:walkTo(player:getX(), player:getY(), { dist = 1.5, timeout = 20 }) then
        merchant:say("Too far. Come closer next time.")
        return
    end
    local offer = price and ("I have an " .. waresName .. ". Yours for one " .. priceName .. ".") or ("Take this " .. waresName .. ", friend.")
    local choice = ask(player, offer, { "Deal", "No thanks" }, 30)
    if choice == "Deal" then
        if takePayment(player) then
            giveItem(player, wares, 1)
            state.trades = state.trades + 1
            merchant:say("Pleasure doing business. (#" .. state.trades .. ")")
            sound("UIActivateButton", nil, nil, nil, player)
            log("trade", state.trades, "with", who)
        else
            merchant:say("You do not even have a " .. priceName .. ". Come back when you do.")
        end
    else
        merchant:say("Suit yourself.")
    end
    wait(3)
    merchant:walkTo(x, y, { dist = 1, timeout = 20 })
    merchant:face(x + 1, y)
end, { cooldown = 20 })

-- idle chatter, only while somebody is close enough to see it
ambient(x, y, 15, 25, function()
    local lines = { "Fresh goods...", "No refunds.", "*groans politely*" }
    merchant:say(lines[random(#lines)])
end)

onStop(function(reason) log("merchant packing up:", reason) end)
