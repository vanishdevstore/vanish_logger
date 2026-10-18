---Joins and drops, from the base FiveM events, so it needs no framework.

if not Config.collectors.connections then return end

AddEventHandler('playerJoining', function()
    LogEvent({ category = 'player', action = 'connect', actor = source })
end)

AddEventHandler('playerDropped', function(reason)
    local playerId = source
    LogEvent({
        category = 'player',
        action = 'disconnect',
        actor = playerId,
        data = { reason = reason },
    })
    -- Resolving the leaving player re-cached them under an id that gets recycled.
    ClearIdentifierCache(playerId)
end)
