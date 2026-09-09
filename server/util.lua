---Shared helpers: logging, timestamps, ids, and bounded copying.

local resourceName = GetCurrentResourceName()

---Print debug output only when Config.debug is enabled.
---@param message string
---@param ... any
function Debug(message, ...)
    if not Config.debug then return end
    print(('[%s] %s'):format(resourceName, message:format(...)))
end

---@param message string
---@param ... any
function Warn(message, ...)
    print(('[%s] ^3WARN^7 %s'):format(resourceName, message:format(...)))
end

---@param message string
---@param ... any
function LogError(message, ...)
    print(('[%s] ^1ERROR^7 %s'):format(resourceName, message:format(...)))
end

---ISO-8601 UTC timestamp.
---@return string
function UtcNow()
    return os.date('!%Y-%m-%dT%H:%M:%SZ') --[[@as string]]
end

local uuidChars = '0123456789abcdef'

---Random event ID; the API deduplicates on (server, eventId).
---@return string
function NewId()
    local parts = {}
    for index = 1, 32 do
        local position = math.random(1, 16)
        parts[index] = uuidChars:sub(position, position)
    end
    return table.concat(parts)
end

---Truncates a string to the ingest field limit.
---@param value any
---@param maxLength? number
---@return string|nil
function ShortText(value, maxLength)
    if type(value) == 'number' then value = tostring(value) end
    if type(value) ~= 'string' then return nil end
    if value == '' then return nil end
    maxLength = maxLength or Limits.maxFieldLength
    if #value > maxLength then return value:sub(1, maxLength) end
    return value
end

---Bound metadata by depth, key count and string length.
---@param source any
---@param maxKeys? number
---@param depth? number
---@return any
function BoundedCopy(source, maxKeys, depth)
    depth = depth or 0
    if depth >= Limits.maxDepth then return nil end

    local kind = type(source)
    if kind == 'string' then
        return #source > Limits.maxStringLength and source:sub(1, Limits.maxStringLength) or source
    end
    if kind == 'number' or kind == 'boolean' then return source end
    if kind ~= 'table' then return nil end

    local out, kept = {}, 0
    local limit = maxKeys or Limits.maxDataKeys

    for key, value in pairs(source) do
        if kept >= limit then break end
        local keyType = type(key)
        if keyType == 'string' or keyType == 'number' then
            local copied = BoundedCopy(value, limit, depth + 1)
            if copied ~= nil then
                out[key] = copied
                kept += 1
            end
        end
    end

    return out
end

---Cache identifiers to avoid repeating native calls for each event.
---@type table<number, table>
local identifierCache = {}

AddEventHandler('playerDropped', function()
    identifierCache[source] = nil
end)

---Collect persistent identifiers and the current server ID.
---Server IDs are reused after disconnect. IP addresses are excluded.
---@param playerId number|string The FiveM server id
---@return table|nil
function GetIdentifiers(playerId)
    local numeric = tonumber(playerId)
    if not numeric or numeric <= 0 then return nil end

    local cached = identifierCache[numeric]
    if cached then return cached end

    if not GetPlayerName(numeric) then return nil end

    local identifiers = { source = numeric, name = GetPlayerName(numeric) }

    for index = 0, GetNumPlayerIdentifiers(numeric) - 1 do
        local identifier = GetPlayerIdentifier(numeric, index)
        if identifier then
            local kind = identifier:match('^(%w+):')
            if kind == 'license' or kind == 'license2' or kind == 'discord'
                or kind == 'steam' or kind == 'fivem' then
                identifiers[kind] = identifier
            end
        end
    end

    identifierCache[numeric] = identifiers
    return identifiers
end

---Clears a player's cached identifiers, for when a character switches.
---@param playerId number
function ClearIdentifierCache(playerId)
    identifierCache[tonumber(playerId) or 0] = nil
end
