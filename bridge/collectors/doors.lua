---Door locks and unlocks by players, from ox_doorlock's own state event.

if not Config.collectors.doors then return end

AddEventHandler('ox_doorlock:stateChanged', function(playerId, doorId, locked, usedItem)
    -- Autolock timers change state with no player behind them.
    if not playerId then return end

    local door = GetResourceState('ox_doorlock') == 'started' and exports.ox_doorlock:getDoor(doorId) or nil
    LogEvent({
        category = 'property',
        action = locked and 'door_locked' or 'door_unlocked',
        actor = playerId,
        resource = 'ox_doorlock',
        data = {
            door = door and door.name or nil,
            doorId = doorId,
            item = usedItem or nil,
        },
    })
end)
