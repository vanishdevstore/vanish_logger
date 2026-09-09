---ESX character identity, job and group lookup.

local ESX

---Resolve lazily so es_extended can start after this resource.
---@return table|nil
local function framework()
    if ESX then return ESX end
    if GetResourceState('es_extended') ~= 'started' then return nil end
    local ok, object = pcall(function() return exports['es_extended']:getSharedObject() end)
    ESX = ok and object or nil
    return ESX
end

---The active framework's resource name, or nil when none was found.
---@return string|nil
function FrameworkName()
    return framework() and 'es_extended' or nil
end

---Returns nil for unloaded players. ESX uses the same value for
---identifier and characterId.
---@param playerId number FiveM server id
---@return table|nil
function GetCharacterInfo(playerId)
    local esx = framework()
    if not esx then return nil end

    local numeric = tonumber(playerId)
    if not numeric or numeric <= 0 then return nil end

    local xPlayer = esx.GetPlayerFromId(numeric)
    if not xPlayer then return nil end

    return {
        identifier = xPlayer.identifier,
        characterId = xPlayer.identifier,
        name = xPlayer.getName and xPlayer.getName() or GetPlayerName(numeric),
        job = xPlayer.job and xPlayer.job.name or nil,
        group = xPlayer.getGroup and xPlayer.getGroup() or nil,
    }
end

---Wraps a framework owner identifier without a player lookup.
---Numeric inventory IDs must be resolved as server IDs by the caller.
---@param owner string|number|nil The `owner` field from an ox_inventory inventory
---@return table|nil
function GetCharacterByOwner(owner)
    if type(owner) ~= 'string' or owner == '' then return nil end
    return { identifier = owner, characterId = owner }
end
