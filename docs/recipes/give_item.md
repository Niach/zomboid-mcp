# give_item

Tool: `give_item` (server). Put items in a player's inventory; `sendAddItemToContainer` syncs it to the client.

```lua
-- server
local p = ZMCP.player("niach")
local script = getScriptManager():FindItem("Base.Axe")
if not script then error("unknown item") end
local inv, added = p:getInventory(), {}
for i = 1, 2 do
    local item = inv:AddItem(script:getFullName())
    sendAddItemToContainer(inv, item)                     -- required in MP, harmless in SP
    added[#added + 1] = item:getFullType()
end
return added
```

Notes:
- Search types with the [item_types](item_types.md) recipe. `FindItem` also accepts short names in some cases; use the
  full `Module.Type`.
- Removing: `inv:Remove(item)` + `sendRemoveItemFromContainer(inv, item)`.
- Equipping is client-side (`ISInventoryPaneContextMenu.equipWeapon(item, true, false, playerNum)` in a client script).
