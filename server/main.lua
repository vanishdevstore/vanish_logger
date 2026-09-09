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

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    transport:Stop()
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function()
    transport:Stop()
end)

---Console status command. In-game callers need command.vanishlogs permission.
RegisterCommand('vanishlogs', function(source)
    if source ~= 0 and not IsPlayerAceAllowed(source, 'command.vanishlogs') then return end

    local status = transport:Status()
    local lines = {
        ('vanish_logger %s (event schema v%d)'):format(status.loggerVersion, status.schemaVersion),
        ('  configured : %s'):format(status.configured and ('yes -> ' .. status.endpoint) or 'NO - set ' .. Config.endpointConvar .. ' and ' .. Config.keyConvar),
        ('  framework  : %s'):format(FrameworkName() or 'none'),
        ('  inventory  : %s'):format(InventoryAdapterActive() and 'ox_inventory' or 'not collecting'),
        ('  queued     : %d events (%d bytes)'):format(status.queued, status.queuedBytes),
        ('  in flight  : %d'):format(status.inFlight),
        ('  sent       : %d'):format(status.totals.sent),
        ('  dropped    : %d'):format(status.totals.dropped),
        ('  recovered  : %d events'):format(status.recovered or 0),
        ('  storage    : %s'):format(status.storageError or 'ready'),
        ('  failures   : %d consecutive'):format(status.failures),
        ('  last ok    : %s'):format(status.lastSuccessAt or 'never'),
        ('  last error : %s'):format(status.lastError or 'none'),
    }

    for index = 1, #lines do
        if source == 0 then
            print(lines[index])
        else
            TriggerClientEvent('chat:addMessage', source, { args = { 'vanishlogs', lines[index] } })
        end
    end
end, false)
