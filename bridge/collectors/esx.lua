---Money, jobs, groups and characters, from the server events ESX already fires.
---These are server-local events; clients cannot trigger them.

if not Config.collectors.esx then return end

local ACCOUNT_ACTIONS = { money = 'cash', bank = 'bank', black_money = 'dirty' }
local SALARY_REASONS = { Paycheck = true, ['Welfare Check'] = true }

---@param account string
---@param direction 'added'|'removed'
---@return string
local function accountAction(account, direction)
    local base = ACCOUNT_ACTIONS[account] or NormaliseAction(account) or 'account'
    return ('%s_%s'):format(base, direction)
end

---@param action string
---@param playerId number
---@param account string
---@param amount number
---@param reason string|nil
---@param resource string|nil The resource that moved the money
local function logMoney(action, playerId, account, amount, reason, resource)
    LogEvent({
        category = 'money',
        action = action,
        actor = playerId,
        resource = resource or GetInvokingResource(),
        data = { account = account, amount = amount, reason = reason },
    })
end

AddEventHandler('esx:addAccountMoney', function(playerId, account, amount, reason, resource)
    local action = SALARY_REASONS[reason] and 'salary' or accountAction(account, 'added')
    logMoney(action, playerId, account, amount, reason, resource)
end)

AddEventHandler('esx:removeAccountMoney', function(playerId, account, amount, reason, resource)
    logMoney(accountAction(account, 'removed'), playerId, account, amount, reason, resource)
end)

AddEventHandler('esx:setAccountMoney', function(playerId, account, balance, reason, resource)
    -- Cash held as an ox_inventory item re-syncs after every item move, and the
    -- move itself is already logged; the echo would count it twice.
    if reason == 'Sync account with item' then return end
    logMoney('balance_set', playerId, account, balance, reason, resource)
end)

---@param job table|nil An ESX job table
---@return string|nil
local function jobLabel(job)
    if type(job) ~= 'table' then return nil end
    return ('%s - %s'):format(job.label or job.name, job.grade_label or job.grade)
end

AddEventHandler('esx:setJob', function(playerId, job, lastJob)
    if type(job) ~= 'table' then return end

    LogEvent({
        category = 'player',
        action = 'job_changed',
        actor = playerId,
        data = {
            job = jobLabel(job),
            jobName = job.name,
            grade = job.grade,
            previous = jobLabel(lastJob),
        },
    })
end)

AddEventHandler('esx:setGroup', function(playerId, group, lastGroup)
    LogEvent({
        category = 'player',
        action = 'group_changed',
        actor = playerId,
        data = { group = group, previous = lastGroup },
    })
end)

AddEventHandler('esx:playerLoaded', function(playerId, _, isNew)
    LogEvent({
        category = 'player',
        action = isNew and 'character_created' or 'character_loaded',
        actor = playerId,
    })
end)
