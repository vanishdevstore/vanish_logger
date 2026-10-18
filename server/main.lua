---Initialize the transport after all dependencies have loaded.

local transport = Transport.new()
SetTransport(transport)

CreateThread(function()
    transport:Start()

    local endpoint = transport:Credentials()
    if endpoint then
        print(('[%s] ^2ready^7 - sending to %s (logger %s, schema v%d)')
            :format(GetCurrentResourceName(), endpoint, LoggerVersion, SchemaVersion))
    else
        Warn('started but not configured. Set "%s" and "%s" in server.cfg.',
            Config.endpointConvar, Config.keyConvar)
    end

    -- Report when automatic inventory collection is unavailable.
    if not InventoryAdapterActive() then
        if not Config.inventory.enabled then
            print(('[%s] inventory collection is disabled in config.lua'):format(GetCurrentResourceName()))
        else
            Warn('ox_inventory was not found, so no inventory events are collected. ' ..
                'The exports.%s:Log{} API still works.', GetCurrentResourceName())
        end
    end

    -- Emit startup status without waiting for a gameplay event.
    LogEvent({
        category = 'system',
        action = 'logger_started',
        severity = 'notice',
        resource = GetCurrentResourceName(),
        data = {
            loggerVersion = LoggerVersion,
            schemaVersion = SchemaVersion,
            inventoryAdapter = InventoryAdapterActive(),
            frameworkAdapter = FrameworkName(),
        },
    })
end)

local function shutdown()
    Shaper.FlushAll()
    transport:Stop()
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    shutdown()
end)

AddEventHandler('txAdmin:events:serverShuttingDown', shutdown)

---@param source number
---@param lines string[]
local function reply(source, lines)
    for index = 1, #lines do
        if source == 0 then
            print(lines[index])
        else
            TriggerClientEvent('chat:addMessage', source, { args = { 'vanishlogs', lines[index] } })
        end
    end
end

---The busiest event types, so a noisy script can be found and tuned.
---@param source number
---@param reset boolean
local function replyTop(source, reset)
    if reset then
        Shaper.ResetVolume()
        reply(source, { 'vanishlogs: volume counters reset' })
        return
    end

    local rows, seconds = Shaper.Top(15)
    local lines = { ('busiest events over the last %d min (per minute, total)'):format(math.ceil(seconds / 60)) }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = ('  %8.1f %8d  %s'):format(row.count * 60 / seconds, row.count, row.label)
    end
    reply(source, lines)
end

---Console status command. In-game callers need command.vanishlogs permission.
RegisterCommand('vanishlogs', function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'command.vanishlogs') then return end

    if args[1] == 'top' then
        replyTop(source, args[2] == 'reset')
        return
    end

    local status = transport:Status()
    local shaping = Shaper.Status()
    local collectors = {}
    for name, enabled in pairs(Config.collectors) do
        if enabled then collectors[#collectors + 1] = name end
    end
    table.sort(collectors)

    local lines = {
        ('vanish_logger %s (event schema v%d)'):format(status.loggerVersion, status.schemaVersion),
        ('  configured : %s'):format(status.configured and ('yes -> ' .. status.endpoint) or 'NO - set ' .. Config.endpointConvar .. ' and ' .. Config.keyConvar),
        ('  framework  : %s'):format(FrameworkName() or 'none'),
        ('  inventory  : %s'):format(InventoryAdapterActive() and 'ox_inventory' or 'not collecting'),
        ('  collectors : %s'):format(#collectors > 0 and table.concat(collectors, ', ') or 'none'),
        ('  queued     : %d events (%d bytes)'):format(status.queued, status.queuedBytes),
        ('  in flight  : %d'):format(status.inFlight),
        ('  sent       : %d'):format(status.totals.sent),
        ('  dropped    : %d'):format(status.totals.dropped),
        ('  folded     : %d repeats sent as totals'):format(shaping.folded),
        ('  limited    : %d over the per-player ceiling'):format(shaping.limited),
        ('  recovered  : %d events'):format(status.recovered or 0),
        ('  storage    : %s'):format(status.storageError or 'ready'),
        ('  failures   : %d consecutive'):format(status.failures),
        ('  last ok    : %s'):format(status.lastSuccessAt or 'never'),
        ('  last error : %s'):format(status.lastError or 'none'),
        'vanishlogs top shows the busiest events; vanishlogs top reset restarts the count',
    }

    reply(source, lines)
end, false)
