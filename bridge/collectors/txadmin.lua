---Staff actions taken through txAdmin, from the web panel and the in-game menu.
---Every handler checks the event came from txAdmin's `monitor` resource,
---because any resource can trigger a server event with a forged payload.

if not Config.collectors.txadmin then return end

local IDENTIFIER_KINDS = { license = true, license2 = true, discord = true, steam = true, fivem = true }

---A party for a player txAdmin acted on, online or not.
---@param netId number|nil
---@param name string|nil
---@param ids table|nil txAdmin's identifier list
---@return table|number|nil
local function player(netId, name, ids)
    if tonumber(netId) and GetPlayerName(netId) then return tonumber(netId) end

    local party = { name = name }
    for _, id in ipairs(type(ids) == 'table' and ids or {}) do
        local kind = type(id) == 'string' and id:match('^(%w+):')
        if kind and IDENTIFIER_KINDS[kind] then party[kind] = id end
    end
    return party
end

---@param action string
---@param event table
local function logStaff(action, event)
    event.category = event.category or 'staff'
    event.action = action
    event.resource = 'txAdmin'
    LogEvent(event)
end

---@param name string
---@param handler fun(data: table)
local function onTxEvent(name, handler)
    AddEventHandler('txAdmin:events:' .. name, function(data)
        if GetInvokingResource() ~= 'monitor' or type(data) ~= 'table' then return end
        handler(data)
    end)
end

onTxEvent('playerBanned', function(data)
    logStaff('ban', {
        severity = 'notice',
        actor = data.author,
        target = player(data.targetNetId, data.targetName, data.targetIds),
        data = {
            reason = data.reason,
            duration = data.expiration == false and 'permanent' or data.durationTranslated,
            actionId = data.actionId,
        },
    })
end)

onTxEvent('playerKicked', function(data)
    local everyone = tonumber(data.target) == -1
    logStaff('kick', {
        actor = data.author,
        target = not everyone and player(data.target) or nil,
        data = { reason = data.reason, everyone = everyone or nil },
    })
end)

onTxEvent('playerWarned', function(data)
    logStaff('warn', {
        actor = data.author,
        target = player(data.targetNetId, data.targetName, data.targetIds),
        data = { reason = data.reason, actionId = data.actionId },
    })
end)

onTxEvent('actionRevoked', function(data)
    logStaff(data.actionType == 'ban' and 'unban' or 'warning_revoked', {
        actor = data.revokedBy,
        target = player(nil, data.playerName, data.playerIds),
        data = {
            reason = data.actionReason,
            actionId = data.actionId,
            originalAuthor = data.actionAuthor,
        },
    })
end)

onTxEvent('playerHealed', function(data)
    local everyone = tonumber(data.target) == -1
    logStaff('heal', {
        actor = data.author,
        target = not everyone and player(data.target) or nil,
        data = { everyone = everyone or nil },
    })
end)

onTxEvent('playerDirectMessage', function(data)
    logStaff('direct_message', {
        actor = data.author,
        target = player(data.target),
        data = { message = data.message },
    })
end)

onTxEvent('announcement', function(data)
    logStaff('announcement', { actor = data.author, data = { message = data.message } })
end)

onTxEvent('serverShuttingDown', function(data)
    logStaff('server_shutdown', {
        severity = 'notice',
        actor = data.author,
        data = { message = data.message, delay = data.delay },
    })
end)

onTxEvent('scheduledRestart', function(data)
    -- txAdmin counts down in several warnings; the last minute is the restart.
    if (tonumber(data.secondsRemaining) or 0) > 60 then return end
    logStaff('server_restart', { data = { secondsRemaining = data.secondsRemaining } })
end)

onTxEvent('scheduledRestartSkipped', function(data)
    logStaff('server_restart_skipped', {
        actor = data.author,
        data = { secondsRemaining = data.secondsRemaining, temporary = data.temporary },
    })
end)

for _, name in ipairs({ 'whitelistPlayer', 'whitelistPreApproval', 'whitelistRequest' }) do
    onTxEvent(name, function(data)
        logStaff('whitelist_changed', {
            actor = data.adminName,
            target = { name = data.playerName, license = data.license },
            data = { change = data.action, identifier = data.identifier, requestId = data.requestId },
        })
    end)
end

onTxEvent('consoleCommand', function(data)
    logStaff('console_command', {
        severity = 'notice',
        actor = data.author,
        data = { command = data.command },
    })
end)

onTxEvent('adminAuth', function(data)
    if not data.isAdmin then return end
    logStaff('admin_auth', { actor = data.netid, data = { account = data.username } })
end)

-- In-game menu actions that match a staff action the dashboard names.
local MENU_ACTIONS = {
    teleportWaypoint = 'teleport', teleportCoords = 'teleport', teleportPlayer = 'goto',
    summonPlayer = 'bring', healPlayer = 'heal', healSelf = 'heal', healAll = 'heal',
    spectatePlayer = 'spectate', freezePlayer = 'freeze',
    spawnVehicle = 'vehicle_spawn', deleteVehicle = 'vehicle_delete', clearArea = 'area_cleanup',
}

-- Menu actions whose data is the id of the player acted on.
local TARGETED = {
    summonPlayer = true, healPlayer = true, spectatePlayer = true, freezePlayer = true,
    drunkEffect = true, setOnFire = true, wildAttack = true,
}

local PRANKS = { drunkEffect = true, setOnFire = true, wildAttack = true }

AddEventHandler('txsv:logger:menuEvent', function(playerId, action, allowed, data)
    if GetInvokingResource() ~= 'monitor' or type(action) ~= 'string' then return end
    -- The announcement event above already carries the message.
    if action == 'announcement' then return end

    if not allowed then
        logStaff('unauthorized_event', {
            category = 'security',
            severity = 'warning',
            actor = playerId,
            data = { reason = ('txAdmin menu action "%s" without permission'):format(action) },
        })
        return
    end

    local staffAction = MENU_ACTIONS[action]
    local details = { menu = action }

    if action == 'playerModeChanged' then
        staffAction = data == 'noclip' and 'noclip' or 'player_mode'
        details.mode = data
    elseif action == 'spawnVehicle' then
        details.model = data
    elseif action == 'teleportCoords' and type(data) == 'table' then
        details.coords = { data.x, data.y, data.z }
    elseif action == 'clearArea' then
        details.radius = data
    end
    if not staffAction then details.command = ('txAdmin menu: %s'):format(action) end

    logStaff(staffAction or 'command_executed', {
        severity = PRANKS[action] and 'notice' or nil,
        actor = playerId,
        target = TARGETED[action] and tonumber(data) or nil,
        data = details,
    })
end)
