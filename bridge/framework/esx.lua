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

-- Every GetPlayerFromId copies a whole xPlayer across the resource boundary,
-- and most events name a player, so each character is read once and kept
-- until something that changes it fires. The TTL bounds a missed event.
local CHARACTER_TTL <const> = 60000

---@type table<number, { info: table, at: number }>
local characters = {}
---@type table<string, number>
local sourceByIdentifier = {}

---@param playerId number
local function forget(playerId)
    local cached = characters[playerId]
    if cached and sourceByIdentifier[cached.info.identifier] == playerId then
        sourceByIdentifier[cached.info.identifier] = nil
    end
    characters[playerId] = nil
end

for _, event in ipairs({ 'esx:playerLoaded', 'esx:playerLogout', 'esx:playerDropped', 'esx:setJob', 'esx:setGroup' }) do
    AddEventHandler(event, function(playerId)
        local numeric = tonumber(playerId)
        if numeric then forget(numeric) end
    end)
end

AddEventHandler('playerDropped', function()
    forget(source)
end)

---Returns nil for unloaded players. ESX uses the same value for
---identifier and characterId. Callers must not modify the result.
---@param playerId number FiveM server id
---@return table|nil
function GetCharacterInfo(playerId)
    local esx = framework()
    if not esx then return nil end

    local numeric = tonumber(playerId)
    if not numeric or numeric <= 0 then return nil end

    local now = GetGameTimer()
    local cached = characters[numeric]
    if cached and now - cached.at < CHARACTER_TTL then return cached.info end

    local xPlayer = esx.GetPlayerFromId(numeric)
    if not xPlayer then
        forget(numeric)
        return nil
    end

    local info = {
        identifier = xPlayer.identifier,
        characterId = xPlayer.identifier,
        name = xPlayer.getName and xPlayer.getName() or GetPlayerName(numeric),
        job = xPlayer.job and xPlayer.job.name or nil,
        group = xPlayer.getGroup and xPlayer.getGroup() or nil,
    }
    characters[numeric] = { info = info, at = now }
    if info.identifier then sourceByIdentifier[info.identifier] = numeric end
    return info
end

---Wraps a framework owner identifier without a player lookup.
---Numeric inventory IDs must be resolved as server IDs by the caller.
---@param owner string|number|nil The `owner` field from an ox_inventory inventory
---@return table|nil
function GetCharacterByOwner(owner)
    if type(owner) ~= 'string' or owner == '' then return nil end
    return { identifier = owner, characterId = owner }
end

---The server id of the connected player playing a character.
---@param identifier string An ESX character identifier
---@return number|nil
function GetSourceByIdentifier(identifier)
    local esx = framework()
    if not esx or type(identifier) ~= 'string' then return nil end

    local known = sourceByIdentifier[identifier]
    if known then return known end

    local xPlayer = esx.GetPlayerFromIdentifier(identifier)
    if not xPlayer then return nil end

    GetCharacterInfo(xPlayer.source)
    return xPlayer.source
end
