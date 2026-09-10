---ox_inventory 2.44.1 hook timing:
---- swapItems/createItem emit post-events through <close>; log on success.
---- openInventory/usingItem/buyItem/craftItem have no post-event; log
---  in the hook after validation, before the operation commits.
---Hooks return true to allow the inventory operation.

local hookIds = {}
local active = false

---Whether inventory events are actually being collected.
---@return boolean
function InventoryAdapterActive()
    return active
end

---@param itemName string|nil
---@return boolean
local function isWeapon(itemName)
    if type(itemName) ~= 'string' then return false end
    local lower = itemName:lower()
    return lower:sub(1, 7) == 'weapon_' or lower:sub(1, 5) == 'ammo-'
end

---Normalises the slot payload, which is a slot table or a bare slot number
---depending on the call site.
---@param slot any
---@return table
local function readSlot(slot)
    if type(slot) ~= 'table' then
        return { slot = tonumber(slot) or nil }
    end

    local metadata
    if Config.inventory.includeMetadata and Config.inventory.maxMetadataKeys > 0 and type(slot.metadata) == 'table' then
        metadata = BoundedCopy(slot.metadata, Config.inventory.maxMetadataKeys)
        if metadata and not next(metadata) then metadata = nil end
    end

    return {
        name = ShortText(slot.name, 64),
        label = ShortText(slot.label, 64),
        count = tonumber(slot.count),
        slot = tonumber(slot.slot),
        metadata = metadata,
    }
end

---Maps inventory types and move direction to an event action.
---@param payload table The swapItems hook payload
---@return string action
local function classifyMove(payload)
    local fromType = payload.fromType
    local toType = payload.toType

    if payload.action == 'give' then return 'player_to_player_transfer' end
    if toType == 'newdrop' or toType == 'drop' then return 'item_dropped' end
    if fromType == 'drop' then return 'item_picked_up' end

    if toType == 'stash' then return 'stash_deposit' end
    if fromType == 'stash' then return 'stash_withdrawal' end
    if toType == 'trunk' then return 'trunk_deposit' end
    if fromType == 'trunk' then return 'trunk_withdrawal' end
    if toType == 'glovebox' then return 'glovebox_deposit' end
    if fromType == 'glovebox' then return 'glovebox_withdrawal' end

    if fromType == 'player' and toType == 'player' and payload.fromInventory ~= payload.toInventory then
        return 'player_to_player_transfer'
    end

    return 'item_transfer'
end

---Reads the persistent owner off an inventory. ox_inventory returns false for
---ids it does not hold, so nothing is created or loaded by looking.
---@param inventoryId number|string
---@return string|nil
local function inventoryOwner(inventoryId)
    local ok, inventory = pcall(function()
        return exports.ox_inventory:GetInventory(inventoryId)
    end)
    if not ok or type(inventory) ~= 'table' then return nil end
    return ShortText(inventory.owner, 64)
end

---Player inventories can be server ids or framework owner identifiers. Server
---ids resolve to full character data while that player is connected, and to the
---inventory's owner once they are not.
---@param value number|string|nil
---@return table|nil
local function resolvePlayer(value)
    local numeric = tonumber(value)
    if numeric and numeric > 0 and GetPlayerName(numeric) then
        local party = GetIdentifiers(numeric) or { source = numeric }
        local character = GetCharacterInfo(numeric)
        if character then
            for key, value in pairs(character) do
                if value ~= nil then party[key] = value end
            end
        end
        return party
    end

    -- A server id only identifies someone while they are connected, and ids are
    -- recycled after a disconnect. ox_inventory defers hook post-events, so a
    -- player can already be gone by the time an event is built; fall back to the
    -- inventory's owner, which stays correct either way.
    if numeric then return GetCharacterByOwner(inventoryOwner(numeric)) end
    return GetCharacterByOwner(value)
end

---@param payload table
---@return table|nil
local function resolveActor(payload)
    return resolvePlayer(payload.source)
end

---@param payload table
---@param action string
---@return table|nil
local function resolveTarget(payload, action)
    if action ~= 'player_to_player_transfer' then return nil end
    if payload.toType ~= 'player' or not payload.toInventory then return nil end
    if tostring(payload.toInventory) == tostring(payload.fromInventory) then return nil end
    return resolvePlayer(payload.toInventory)
end

---@param source any
---@return table|nil
local function maybeCoords(source)
    if not Config.inventory.coords then return nil end
    local numeric = tonumber(source)
    if not numeric or numeric <= 0 then return nil end
    local ped = GetPlayerPed(numeric)
    if not ped or ped == 0 then return nil end
    local position = GetEntityCoords(ped)
    return { math.floor(position.x * 100) / 100, math.floor(position.y * 100) / 100, math.floor(position.z * 100) / 100 }
end

local function register()
    if active then return end
    local ox = exports.ox_inventory
    active = true

    -- Log completed item movements.
    local swapHookId = ox:registerHook('swapItems', function()
        -- Wait for the post-event to confirm success.
        return true
    end, { print = false })
    hookIds[#hookIds + 1] = swapHookId

    AddEventHandler(swapHookId, function(success, payload)
        if not success or type(payload) ~= 'table' then return end

        local action = classifyMove(payload)
        local fromSlot = readSlot(payload.fromSlot)
        local toSlot = readSlot(payload.toSlot)

        -- Record the source item as the subject and the other item as swappedWith.
        local item = fromSlot.name and fromSlot or toSlot
        local plate
        if payload.toType == 'trunk' or payload.toType == 'glovebox' then
            plate = tostring(payload.toInventory or ''):match('^%a+%-?(%w+)$')
        elseif payload.fromType == 'trunk' or payload.fromType == 'glovebox' then
            plate = tostring(payload.fromInventory or ''):match('^%a+%-?(%w+)$')
        end

        LogEvent({
            category = 'inventory',
            action = action,
            severity = isWeapon(item.name) and 'notice' or nil,
            resource = 'ox_inventory',
            actor = resolveActor(payload),
            target = resolveTarget(payload, action),
            transactionId = NewId(),
            context = {
                coords = maybeCoords(payload.source),
                fromInventory = { id = ShortText(payload.fromInventory, 64), type = payload.fromType },
                toInventory = { id = ShortText(payload.toInventory or payload.dropId, 64), type = payload.toType },
                vehicle = plate and { plate = plate } or nil,
            },
            data = {
                item = item.name,
                itemLabel = item.label,
                quantity = tonumber(payload.count) or item.count,
                slot = fromSlot.slot,
                toSlot = toSlot.slot,
                metadata = item.metadata,
                swappedWith = (payload.action == 'swap' and toSlot.name and toSlot.name ~= fromSlot.name)
                    and toSlot.name or nil,
                moveKind = payload.action,
            },
        })
    end)

    -- Log successful item creation.
    local createHookId = ox:registerHook('createItem', function()
        return true
    end, { print = false })
    hookIds[#hookIds + 1] = createHookId

    AddEventHandler(createHookId, function(success, payload)
        if not success or type(payload) ~= 'table' then return end

        local item = payload.item or {}
        local name = ShortText(item.name, 64)

        LogEvent({
            category = 'inventory',
            action = isWeapon(name) and 'weapon_added' or 'item_added',
            severity = isWeapon(name) and 'notice' or nil,
            resource = 'ox_inventory',
            actor = GetCharacterByOwner(payload.inventoryId),
            context = {
                inventory = { id = ShortText(payload.inventoryId, 64) },
            },
            data = {
                item = name,
                itemLabel = ShortText(item.label, 64),
                quantity = tonumber(payload.count),
                metadata = Config.inventory.includeMetadata
                    and BoundedCopy(payload.metadata, Config.inventory.maxMetadataKeys) or nil,
                -- Record which resource created the item.
                createdBy = ShortText(payload.resource, 64),
            },
        })
    end)

    if Config.inventory.containerOpen then
        hookIds[#hookIds + 1] = ox:registerHook('openInventory', function(payload)
            -- Skip opening the player's own inventory.
            local inventoryType = payload.inventoryType
            if inventoryType == 'player' and payload.inventoryId == nil then return true end

            LogEvent({
                category = 'inventory',
                action = 'container_open',
                resource = 'ox_inventory',
                actor = resolveActor(payload),
                context = {
                    coords = maybeCoords(payload.source),
                    inventory = { id = ShortText(payload.inventoryId, 64), type = inventoryType },
                },
                data = { slot = payload.slot, netId = payload.netId },
            })
            return true
        end, { print = false })
    end

    if Config.inventory.itemUse then
        hookIds[#hookIds + 1] = ox:registerHook('usingItem', function(payload)
            local item = readSlot(payload.item)
            LogEvent({
                category = 'inventory',
                action = 'item_used',
                resource = 'ox_inventory',
                actor = resolveActor(payload),
                context = {
                    coords = maybeCoords(payload.source),
                    inventory = { id = ShortText(payload.inventoryId, 64) },
                },
                data = {
                    item = item.name,
                    itemLabel = item.label,
                    slot = item.slot,
                    metadata = item.metadata,
                    consumed = payload.consume,
                },
            })
            return true
        end, { print = false })
    end

    if Config.inventory.shopPurchases then
        hookIds[#hookIds + 1] = ox:registerHook('buyItem', function(payload)
            local name = ShortText(payload.itemName, 64)
            LogEvent({
                category = 'inventory',
                action = 'item_purchased',
                severity = isWeapon(name) and 'notice' or nil,
                resource = 'ox_inventory',
                actor = resolveActor(payload),
                transactionId = NewId(),
                context = {
                    coords = maybeCoords(payload.source),
                    inventory = { id = ShortText(payload.shopId or payload.shopType, 64), type = 'shop' },
                    toInventory = { id = ShortText(payload.toInventory, 64), type = 'player' },
                },
                data = {
                    item = name,
                    quantity = tonumber(payload.count),
                    amount = tonumber(payload.totalPrice) or tonumber(payload.price),
                    account = ShortText(payload.payment or payload.currency, 32),
                    shop = ShortText(payload.shopType, 64),
                    metadata = Config.inventory.includeMetadata
                        and BoundedCopy(payload.metadata, Config.inventory.maxMetadataKeys) or nil,
                },
            })
            return true
        end, { print = false })
    end

    if Config.inventory.crafting then
        hookIds[#hookIds + 1] = ox:registerHook('craftItem', function(payload)
            LogEvent({
                category = 'inventory',
                action = 'item_crafted',
                resource = 'ox_inventory',
                actor = resolveActor(payload),
                context = {
                    coords = maybeCoords(payload.source),
                    inventory = { id = ShortText(payload.toInventory, 64) },
                },
                data = {
                    item = ShortText(payload.recipe and payload.recipe.name, 64),
                    quantity = tonumber(payload.count),
                    benchId = ShortText(payload.benchId, 64),
                },
            })
            return true
        end, { print = false })
    end

    Debug('ox_inventory adapter registered %d hooks', #hookIds)
end

if Config.inventory.enabled then
    CreateThread(function()
        if GetResourceState('ox_inventory') == 'started' then register() end
    end)

    -- Register hooks if ox_inventory starts after this resource.
    AddEventHandler('onResourceStart', function(resource)
        if resource == 'ox_inventory' then register() end
    end)
end

---Remove registered hooks when this resource stops.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for index = 1, #hookIds do
        pcall(function() exports.ox_inventory:removeHooks(hookIds[index]) end)
    end
end)
