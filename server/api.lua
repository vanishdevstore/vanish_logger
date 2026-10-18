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
    Shaper.Init(function(payload) return transport:Enqueue(payload) end)
end

---Builds a party from what vendor scripts actually hand over: a server id, a
---character identifier, a staff name, or an explicit identity table.
---@param value number|string|table|nil
---@return table|nil
local function buildParty(value)
    if value == nil then return nil end

    local numeric = tonumber(value)
    if numeric then
        if numeric == 0 then return { name = 'Console' } end
        return PlayerParty(numeric)
    end

    if type(value) == 'string' then
        if value == '' then return nil end
        -- Identifiers carry a prefix ("char1:", "license:"); anything else is a
        -- name, such as a txAdmin account.
        if not value:find(':', 1, true) then return { name = ShortText(value) } end
        local playerId = GetSourceByIdentifier(value)
        if playerId then return PlayerParty(playerId) end
        local text = ShortText(value)
        if value:sub(1, 8) == 'license:' then return { license = text } end
        return { identifier = text, characterId = text }
    end

    if type(value) ~= 'table' then return nil end

    -- Explicit fields override values resolved from the player source.
    local party = {}
    local base = value.source and PlayerParty(value.source) or nil
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

    for _, field in ipairs({ 'context', 'data', 'fields' }) do
        if event[field] ~= nil and type(event[field]) ~= 'table' then return false end
    end

    local channel = event.channel
    local category = event.category
    local action = NormaliseAction(event.action)

    if not action then
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

    local data = event.data
    if event.fields then data = FieldsToData(event.fields, data) end

    local payload = {
        eventId = event.eventId or NewId(),
        occurredAt = event.occurredAt or UtcNow(),
        channel = type(channel) == 'string' and channel or nil,
        category = type(category) == 'string' and category or nil,
        action = action,
        severity = NormaliseSeverity(event.severity),
        actor = buildParty(event.actor),
        target = buildParty(event.target),
        context = next(context) and context or nil,
        data = data and BoundedCopy(data) or nil,
        correlationId = ShortText(event.correlationId),
        transactionId = ShortText(event.transactionId),
        sessionId = ShortText(event.sessionId),
        entityId = ShortText(event.entityId),
    }

    return Shaper.Submit(payload)
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

-- Admin commands that mean a staff action the dashboard already names; any
-- other command is logged as `command_executed`.
local COMMAND_ACTIONS = {
    tp = 'teleport', tpm = 'teleport', setcoords = 'teleport',
    ['goto'] = 'goto', bring = 'bring', noclip = 'noclip',
    heal = 'heal', revive = 'revive', freeze = 'freeze', unfreeze = 'freeze',
    car = 'vehicle_spawn', dv = 'vehicle_delete', cardel = 'vehicle_delete',
    giveaccountmoney = 'money_adjustment', removeaccountmoney = 'money_adjustment',
    setaccountmoney = 'money_adjustment',
    giveitem = 'item_give', additem = 'item_give', giveweapon = 'item_give',
    removeitem = 'item_remove', setitem = 'item_give',
    setjob = 'character_modified', setgroup = 'permission_changed',
}

---Logs an admin command under the staff category, mapped to a known staff
---action where there is one.
---@param source number The player who ran it, 0 for the console
---@param command string The command name without a slash
---@param args string|table|nil The arguments as typed
---@param target number|string|table|nil Whoever the command acted on
---@param data table|nil Anything else worth keeping
---@return boolean
exports('LogCommand', function(source, command, args, target, data)
    if type(command) ~= 'string' or command == '' then return false end
    if type(args) == 'table' then args = table.concat(args, ' ') end
    data = type(data) == 'table' and data or {}
    data.command = ('/%s%s'):format(command, type(args) == 'string' and args ~= '' and ' ' .. args or '')
    return LogEvent({
        category = 'staff',
        action = COMMAND_ACTIONS[command:lower()] or 'command_executed',
        actor = source,
        target = target,
        resource = GetInvokingResource(),
        data = data,
    })
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
