---Server-side logging exports. Validate client input before calling these.

local transport

---Built-in categories from the platform taxonomy.
local CATEGORIES = {
    inventory = true, money = true, player = true, vehicle = true,
    property = true, staff = true, security = true, system = true,
}

---@param instance table
function SetTransport(instance)
    transport = instance
end

---Builds a party from a server ID or explicit identity table.
---@param value number|string|table|nil
---@return table|nil
local function buildParty(value)
    if value == nil then return nil end

    if type(value) == 'number' or type(value) == 'string' then
        return GetIdentifiers(value)
    end

    if type(value) ~= 'table' then return nil end

    -- Explicit fields override values resolved from the player source.
    local party = {}
    local base = value.source and GetIdentifiers(value.source) or nil
    if base then
        for key, entry in pairs(base) do party[key] = entry end
    end
    for key, entry in pairs(value) do
        if entry ~= nil then party[key] = entry end
    end

    for _, field in ipairs({ 'name', 'characterId', 'identifier', 'license', 'license2', 'discord', 'steam', 'fivem', 'job', 'group' }) do
        if party[field] ~= nil then party[field] = ShortText(party[field]) end
    end

    return next(party) and party or nil
end

---Queues an event with an action and either a channel key or category.
---The dashboard applies category filtering.
---@param event table Needs `action`, plus `channel` or `category`.
---@return boolean accepted True when the event was queued
function LogEvent(event)
    if type(event) ~= 'table' then return false end
    if not transport then return false end

    for _, field in ipairs({ 'context', 'data' }) do
        if event[field] ~= nil and type(event[field]) ~= 'table' then return false end
    end

    local channel = event.channel
    local category = event.category
    local action = event.action

    if type(action) ~= 'string' or action == '' then
        Debug('rejected an event missing action')
        return false
    end
    if channel ~= nil and (type(channel) ~= 'string' or channel == '') then return false end
    if category ~= nil and type(category) ~= 'string' then return false end
    if type(channel) ~= 'string' and type(category) ~= 'string' then
        Debug('rejected an event with neither channel nor category')
        return false
    end
    if type(channel) ~= 'string' and not CATEGORIES[category] then
        Debug('rejected an event with unknown category "%s"', tostring(category))
        return false
    end

    local resource = event.resource or GetInvokingResource() or GetCurrentResourceName()

    local context = event.context and BoundedCopy(event.context) or {}
    context.resource = ShortText(resource, 64)

    local payload = {
        eventId = event.eventId or NewId(),
        occurredAt = event.occurredAt or UtcNow(),
        channel = type(channel) == 'string' and channel or nil,
        category = type(category) == 'string' and category or nil,
        action = action,
        severity = event.severity,
        actor = buildParty(event.actor),
        target = buildParty(event.target),
        context = next(context) and context or nil,
        data = event.data and BoundedCopy(event.data) or nil,
        correlationId = ShortText(event.correlationId),
        transactionId = ShortText(event.transactionId),
        sessionId = ShortText(event.sessionId),
        entityId = ShortText(event.entityId),
    }

    return transport:Enqueue(payload)
end

exports('Log', LogEvent)

---Submits an event to a dashboard-defined channel.
---@param channel string The channel key from the dashboard, e.g. 'drugs.sales'
---@param action string What happened, snake_case, e.g. 'sold'
---@param event table|nil The rest of the event
---@return boolean
exports('LogTo', function(channel, action, event)
    if type(channel) ~= 'string' or channel == '' then return false end
    if event ~= nil and type(event) ~= 'table' then return false end
    event = event or {}
    event.channel = channel
    event.action = action
    event.resource = event.resource or GetInvokingResource()
    return LogEvent(event)
end)

---@param action string e.g. 'item_transfer'
---@param event table|nil The rest of the event
---@return boolean
exports('LogInventory', function(action, event)
    if event ~= nil and type(event) ~= 'table' then return false end
    event = event or {}
    event.category = 'inventory'
    event.action = action
    event.resource = event.resource or GetInvokingResource()
    return LogEvent(event)
end)

---Current transport status, for a health command or another resource.
---@return table
exports('GetStatus', function()
    return transport and transport:Status() or { configured = false, running = false }
end)

---Schedules an immediate asynchronous flush.
exports('Flush', function()
    if transport then transport:Flush(true) end
end)
