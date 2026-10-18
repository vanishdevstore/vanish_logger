---Traffic shaping between the logging exports and the transport: repeats are
---folded into one event, each player has a per-minute ceiling, and volume is
---counted for `vanishlogs top`.

Shaper = {}

---@type fun(payload: table): boolean
local deliver

-- Fields that differ between repeats of the same thing. Amounts and counts are
-- summed; slots and the per-move transaction id are noise to an investigator.
local SUMMED = { amount = true, count = true, quantity = true }
local IGNORED_DATA = { slot = true, toSlot = true }

---@type table<string, table>
local runs = {}
---@type table<number, number>
local usedThisMinute = {}
---@type table<number, { dropped: number, actor: table }>
local overLimit = {}
local minuteStartedAt

---@type table<string, number>
local volume = {}
local volumeSince = os.time()
local folded, limited = 0, 0

---@param send fun(payload: table): boolean
function Shaper.Init(send)
    deliver = send
end

---Serialises a value with sorted keys and length-prefixed strings, so two
---events with the same content always produce the same key.
---@param value any
---@param out string[]
local function canonical(value, out)
    local kind = type(value)
    if kind == 'string' then
        out[#out + 1] = ('s%d:%s'):format(#value, value)
        return
    end
    if kind ~= 'table' then
        out[#out + 1] = kind:sub(1, 1) .. tostring(value)
        return
    end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    out[#out + 1] = '{'
    for _, key in ipairs(keys) do
        canonical(key, out)
        canonical(value[key], out)
    end
    out[#out + 1] = '}'
end

---@param payload table
---@return string
local function repeatKey(payload)
    local data
    if payload.data then
        data = {}
        for key, value in pairs(payload.data) do
            if not SUMMED[key] and not IGNORED_DATA[key] then data[key] = value end
        end
    end

    local context
    if payload.context then
        context = {}
        for key, value in pairs(payload.context) do
            if key ~= 'coords' then context[key] = value end
        end
    end

    local out = {}
    canonical({
        channel = payload.channel,
        category = payload.category,
        action = payload.action,
        severity = payload.severity,
        actor = payload.actor,
        target = payload.target,
        context = context,
        data = data,
        correlationId = payload.correlationId,
        sessionId = payload.sessionId,
        entityId = payload.entityId,
    }, out)
    return table.concat(out)
end

---@param payload table
---@return string
local function volumeLabel(payload)
    return ('%s %s'):format(payload.channel or payload.category or '?', payload.action)
end

---Applies the per-player ceiling, then hands the event to the transport.
---@param payload table
---@return boolean
local function admit(payload)
    local limit = Config.perPlayerPerMinute or 0
    local playerId = payload.actor and tonumber(payload.actor.source)

    if limit > 0 and playerId then
        minuteStartedAt = minuteStartedAt or GetGameTimer()
        local used = (usedThisMinute[playerId] or 0) + 1
        usedThisMinute[playerId] = used

        if used > limit then
            local entry = overLimit[playerId] or { dropped = 0, actor = payload.actor }
            entry.dropped += 1
            overLimit[playerId] = entry
            limited += 1
            return false
        end
    end

    local label = volumeLabel(payload)
    volume[label] = (volume[label] or 0) + 1
    return deliver(payload)
end

---@param payload table
---@return boolean accepted
function Shaper.Submit(payload)
    local window = Config.coalesce and Config.coalesce.window or 0
    if window <= 0 then return admit(payload) end

    local key = repeatKey(payload)
    local run = runs[key]

    if run then
        run.repeats += 1
        run.lastAt = GetGameTimer()
        run.lastOccurredAt = payload.occurredAt
        run.firstRepeatAt = run.firstRepeatAt or payload.occurredAt
        for field in pairs(SUMMED) do
            local value = payload.data and tonumber(payload.data[field])
            if value then run.sums[field] = (run.sums[field] or 0) + value end
        end
        folded += 1
        return true
    end

    local now = GetGameTimer()
    runs[key] = { template = payload, repeats = 0, sums = {}, openedAt = now, lastAt = now }
    return admit(payload)
end

---One event carrying every repeat a run absorbed after its first.
---@param run table
local function sendRepeats(run)
    if run.repeats == 0 then return end

    local rollup = {}
    for key, value in pairs(run.template) do rollup[key] = value end

    local data = {}
    for key, value in pairs(run.template.data or {}) do
        if not SUMMED[key] then data[key] = value end
    end
    for field, total in pairs(run.sums) do data[field] = total end
    data.repeats = run.repeats
    data.repeatedUntil = run.lastOccurredAt

    rollup.eventId = NewId()
    rollup.occurredAt = run.firstRepeatAt or run.template.occurredAt
    rollup.transactionId = nil
    rollup.data = data
    admit(rollup)
end

---Reports each player who went over the ceiling, once per minute.
local function reportOverLimit()
    for playerId, entry in pairs(overLimit) do
        deliver({
            eventId = NewId(),
            occurredAt = UtcNow(),
            category = 'security',
            action = 'rate_limit_triggered',
            severity = 'warning',
            actor = entry.actor,
            context = { resource = GetCurrentResourceName() },
            data = {
                reason = ('%d events in a minute; logging kept %d and dropped the rest'):format(
                    Config.perPlayerPerMinute + entry.dropped, Config.perPlayerPerMinute),
                dropped = entry.dropped,
            },
        })
        overLimit[playerId] = nil
    end
    usedThisMinute = {}
end

---Closes quiet or long-held runs and rolls the per-player minute over.
---@param now number GetGameTimer()
function Shaper.Sweep(now)
    local window = Config.coalesce and Config.coalesce.window or 0
    local maxHold = Config.coalesce and Config.coalesce.maxHold or window

    for key, run in pairs(runs) do
        if now - run.lastAt >= window or now - run.openedAt >= maxHold then
            runs[key] = nil
            sendRepeats(run)
        end
    end

    if not minuteStartedAt then minuteStartedAt = now end
    if now - minuteStartedAt >= 60000 then
        minuteStartedAt = now
        reportOverLimit()
    end
end

---Sends every open run's repeats, for a resource about to stop.
function Shaper.FlushAll()
    for key, run in pairs(runs) do
        runs[key] = nil
        sendRepeats(run)
    end
    reportOverLimit()
end

---@return { folded: number, limited: number }
function Shaper.Status()
    return { folded = folded, limited = limited }
end

---The busiest event types since the counters were last reset.
---@param limit number
---@return { label: string, count: number }[] rows
---@return number seconds Covered by the counters
function Shaper.Top(limit)
    local rows = {}
    for label, count in pairs(volume) do rows[#rows + 1] = { label = label, count = count } end
    table.sort(rows, function(a, b) return a.count > b.count end)
    for index = #rows, limit + 1, -1 do rows[index] = nil end
    return rows, math.max(1, os.time() - volumeSince)
end

function Shaper.ResetVolume()
    volume = {}
    volumeSince = os.time()
end

CreateThread(function()
    while true do
        Wait(1000)
        Shaper.Sweep(GetGameTimer())
    end
end)
