---Asynchronous batch delivery with retries. Retain the exact request body
---across retries so the API can deduplicate events.

Transport = {}
Transport.__index = Transport

local MAX_INT = 9007199254740991

local function nonnegativeInteger(value)
    return type(value) == 'number' and value >= 0 and value <= MAX_INT and value % 1 == 0
end

---Validate the snapshot before replay. Invalid snapshots remain on disk.
local function validSnapshot(snapshot)
    if type(snapshot) ~= 'table' or snapshot.v ~= 1 or type(snapshot.queued) ~= 'table'
        or not nonnegativeInteger(snapshot.dropped or 0) then return false end
    local count = 0
    for index, item in pairs(snapshot.queued) do
        if not nonnegativeInteger(index) or index < 1 or index > #snapshot.queued
            or type(item) ~= 'table' or type(item.payload) ~= 'table'
            or not nonnegativeInteger(item.bytes) or item.bytes < 1 then return false end
        count = count + 1
    end
    if count ~= #snapshot.queued then return false end
    if snapshot.flight ~= nil then
        local flight = snapshot.flight
        if type(flight) ~= 'table' or type(flight.body) ~= 'string'
            or not nonnegativeInteger(flight.count) or flight.count < 1 then return false end
        local ok, body = pcall(json.decode, flight.body)
        if not ok or type(body) ~= 'table' or type(body.events) ~= 'table'
            or #body.events ~= flight.count then return false end
    end
    return true
end

---@return table
function Transport.new()
    math.randomseed(os.time() + GetGameTimer())

    return setmetatable({
        queue = Queue.new(),
        dirty = false,
        storageError = nil,
        storageBlocked = false,
        recovered = 0,
        queuedBytes = 0,
        running = false,
        sending = false,
        inFlight = nil,
        failures = 0,
        nextAttemptAt = 0,
        attemptSerial = 0,
        activeAttempt = nil,
        bootId = NewId(),
        sequence = 0,
        lastSuccessAt = nil,
        lastError = nil,
        credentialsWarned = false,
        unreportedDropped = 0,
        totals = { queued = 0, sent = 0, dropped = 0, failed = 0 },
    }, Transport)
end

local function allowedEndpoint(endpoint)
    -- Reject ambiguous URLs, embedded credentials, queries and fragments.
    if endpoint:find('[%c%s\\?#]') then return false end
    local scheme, authority = endpoint:match('^(https?)://([^/]+)')
    if not authority or authority:find('@', 1, true) then return false end
    if scheme == 'https' then return true end
    if Config.allowLocalHttp ~= true then return false end
    return authority == '127.0.0.1' or authority == '[::1]'
        or authority:match('^127%.0%.0%.1:%d+$') ~= nil
        or authority:match('^%[::1%]:%d+$') ~= nil
end

---Read credentials on each flush so convar updates apply without a restart.
---@return string|nil endpoint
---@return string|nil key
function Transport:Credentials()
    local endpoint = GetConvar(Config.endpointConvar, '')
    local key = GetConvar(Config.keyConvar, '')

    endpoint = endpoint:gsub('^%s+', ''):gsub('%s+$', ''):gsub('/+$', '')
    key = key:gsub('%s+', '')

    if not allowedEndpoint(endpoint) or key == '' then
        return nil, nil
    end
    return endpoint, key
end

---Encodes and queues an event. Returns false and counts a drop if encoding
---fails or the event exceeds the size limit.
---@param event table
---@return boolean queued
function Transport:Enqueue(event)
    local ok, encoded = pcall(json.encode, event)
    if not ok or type(encoded) ~= 'string' then
        self.totals.dropped += 1
        self.unreportedDropped += 1
        Debug('dropped an event that could not be encoded')
        return false
    end

    if #encoded > Limits.maxEventBytes then
        self.totals.dropped += 1
        self.unreportedDropped += 1
        Warn('dropped an oversized %s.%s event (%d bytes, limit %d)',
            event.category or event.channel or '?', event.action or '?', #encoded, Limits.maxEventBytes)
        return false
    end

    local _, droppedItem = self.queue:Push(
        { payload = event, bytes = #encoded + 1 },
        Config.batch.maxQueue
    )
    if droppedItem then
        self.queuedBytes = math.max(0, self.queuedBytes - (droppedItem.bytes or 0))
        self.totals.dropped += 1
    end
    self.queuedBytes += #encoded + 1
    self.totals.queued += 1
    self.dirty = true
    while self.queuedBytes > (Config.batch.maxQueueBytes or 8388608) and self.queue:Size() > 0 do
        local discarded = self.queue:Pop()
        self.queuedBytes = math.max(0, self.queuedBytes - discarded.bytes)
        self.queue.dropped += 1
        self.totals.dropped += 1
    end

    -- Flush early on a burst rather than waiting out the interval.
    if self.queue:Size() >= Config.batch.maxEvents then
        self:Flush(false)
    end

    return true
end

---Builds the next request body from the queue.
---@return table|nil flight
function Transport:BuildFlight()
    local budget = math.min(Config.batch.maxBodyBytes, Limits.maxBodyBytes) - 2048
    local wrapped = self.queue:PopBatch(math.min(Config.batch.maxEvents, Limits.maxBatchSize), budget)
    if #wrapped == 0 then return nil end

    local events, bytes = {}, 0
    for index = 1, #wrapped do
        events[index] = wrapped[index].payload
        bytes += wrapped[index].bytes
    end
    self.queuedBytes = math.max(0, self.queuedBytes - bytes)

    self.sequence = math.min(self.sequence + 1, MAX_INT)

    local envelope = {
        v = SchemaVersion,
        loggerVersion = LoggerVersion,
        bootId = self.bootId,
        seq = self.sequence,
        sentAt = UtcNow(),
        droppedSinceLast = self.queue:TakeDropped() + self.unreportedDropped,
        events = events,
    }

    local ok, body = pcall(json.encode, envelope)
    if not ok or type(body) ~= 'string' then
        LogError('could not encode a batch of %d events; discarding it', #events)
        self.totals.dropped += #events
        self.unreportedDropped += #events
        return nil
    end

    self.unreportedDropped = 0
    return { body = body, count = #events, wrapped = wrapped }
end

---Signs the timestamp, nonce and body digest for replay protection.
---@param key string
---@param body string
---@return table
local function signatureHeaders(key, body)
    if not Config.signRequests then return {} end
    return exports[GetCurrentResourceName()]:SignLogBatch(key, body)
end

---Exponential backoff with jitter to spread retries across servers.
---@param status number|string
function Transport:ScheduleRetry(status)
    self.failures += 1
    local exponent = math.min(self.failures - 1, 20)
    local delay = math.min(Config.retry.maxDelay, Config.retry.baseDelay * (2 ^ exponent))

    -- An authentication failure will not fix itself by retrying sooner.
    if status == 401 or status == 403 then delay = Config.retry.maxDelay end

    local jitter = math.random(0, math.max(1, math.floor(delay * 0.25)))
    self.nextAttemptAt = GetGameTimer() + delay + jitter
    self.lastError = ('HTTP %s'):format(status)
    self.totals.failed += 1

    -- Limit warning output to the first failure and maximum-backoff attempts.
    if self.failures == 1 then
        if status == 401 or status == 403 then
            Warn('ingest rejected the credentials (HTTP %s); check %s', status, Config.keyConvar)
        else
            Warn('ingest returned %s; retrying with backoff', status)
        end
    elseif self.failures % 10 == 0 then
        Warn('ingest still failing after %d attempts (last: %s); %d events queued',
            self.failures, tostring(status), self.queue:Size())
    end
end

---@param flight table
---@param attemptId number
---@param status any
---@param responseBody any
function Transport:HandleResponse(flight, attemptId, status, responseBody)
    if self.inFlight ~= flight or self.activeAttempt ~= attemptId then return end

    self.sending = false
    self.activeAttempt = nil
    status = tonumber(status) or 0

    if status == 202 or status == 200 then
        -- Retry unless the receipt accounts for the entire batch.
        local valid, receipt = pcall(json.decode, responseBody or '')
        if not valid or type(receipt) ~= 'table' or not nonnegativeInteger(receipt.accepted)
            or not nonnegativeInteger(receipt.duplicates) or not nonnegativeInteger(receipt.rejected)
            or receipt.accepted + receipt.duplicates + receipt.rejected ~= flight.count then
            self:ScheduleRetry('invalid_receipt')
            return
        end
        self.totals.dropped += receipt.rejected
        self.unreportedDropped += receipt.rejected
        self.inFlight = nil
        self.failures = 0
        self.nextAttemptAt = 0
        self.lastError = nil
        self.lastSuccessAt = UtcNow()
        self.totals.sent += receipt.accepted + receipt.duplicates
        self.dirty = true
        self:Checkpoint()

        Debug('sent %d events (accepted %d, duplicates %d, rejected %d)',
            flight.count, receipt.accepted, receipt.duplicates, receipt.rejected)
        return
    end

    -- Discard permanent 4xx failures so they do not block the queue.
    -- Authentication and rate-limit failures remain retryable.
    if status == 400 or status == 413 or status == 415 or status == 422 then
        self.inFlight = nil
        self.totals.dropped += flight.count
        self.unreportedDropped += flight.count
        self.lastError = ('HTTP %s rejected the batch'):format(status)
        self.dirty = true
        self:Checkpoint()
        LogError('ingest rejected a batch with HTTP %s; %d events discarded. Response: %s',
            status, flight.count, tostring(responseBody):sub(1, 300))
        return
    end

    self:ScheduleRetry(status)
end

---@param endpoint string
---@param key string
function Transport:Send(endpoint, key)
    local flight = self.inFlight
    if not flight or self.sending then return end

    self.attemptSerial += 1
    local attemptId = self.attemptSerial
    self.activeAttempt = attemptId
    self.sending = true

    local headers = {
        ['Authorization'] = 'Bearer ' .. key,
        ['Content-Type'] = 'application/json',
        ['User-Agent'] = ('vanish_logger/%s'):format(LoggerVersion),
    }
    local signed, signature = pcall(signatureHeaders, key, flight.body)
    if not signed then
        self.sending = false
        self.activeAttempt = nil
        self:ScheduleRetry('signing_unavailable')
        return
    end
    for name, value in pairs(signature) do
        headers[name] = value
    end

    local ok, err = pcall(PerformHttpRequest, endpoint .. '/ingest/v1/events', function(status, body)
        self:HandleResponse(flight, attemptId, status, body)
    end, 'POST', flight.body, headers, { followLocation = false })

    if not ok then
        self.sending = false
        self.activeAttempt = nil
        Debug('PerformHttpRequest raised: %s', tostring(err))
        self:ScheduleRetry(0)
        return
    end

    -- Time out stalled requests whose callback never fires.
    SetTimeout(Config.retry.httpTimeout, function()
        if self.inFlight ~= flight or self.activeAttempt ~= attemptId then return end
        self.sending = false
        self.activeAttempt = nil
        self:ScheduleRetry('timeout')
    end)
end

---Sends the next batch if one is due.
---@param force? boolean Ignore backoff, used on shutdown
function Transport:Flush(force)
    if self.sending then self:Checkpoint() return end
    -- Checkpoint before sending so a crash can replay the batch.
    if not self:Checkpoint() then return end
    if not force and self.nextAttemptAt > GetGameTimer() then return end

    local endpoint, key = self:Credentials()
    if not endpoint or not key then
        if not self.credentialsWarned then
            Warn('missing credentials or refused endpoint. Use HTTPS and set "%s" and "%s" in server.cfg. Events remain queued.',
                Config.endpointConvar, Config.keyConvar)
            self.credentialsWarned = true
        end
        return
    end
    self.credentialsWarned = false

    if not self.inFlight then self.inFlight = self:BuildFlight() end
    if self.inFlight then
        self.dirty = true
        if self:Checkpoint() then self:Send(endpoint, key) end
    end
end

function Transport:Start()
    if self.running then return end
    self:Restore()
    self.running = true

    CreateThread(function()
        while self.running do
            Wait(Config.batch.flushInterval)
            self:Flush(false)
        end
    end)
end

---Checkpoint and attempt a final flush. onResourceStop does not guarantee
---that an asynchronous request will complete.
function Transport:Stop()
    if not self.running then return end
    self.running = false
    self:Flush(true)
end

---@return table
function Transport:Status()
    local endpoint, key = self:Credentials()
    return {
        configured = endpoint ~= nil and key ~= nil,
        endpoint = endpoint or GetConvar(Config.endpointConvar, ''),
        running = self.running,
        queued = self.queue:Size(),
        queuedBytes = self.queuedBytes,
        inFlight = self.inFlight and self.inFlight.count or 0,
        failures = self.failures,
        lastSuccessAt = self.lastSuccessAt,
        lastError = self.lastError,
        loggerVersion = LoggerVersion,
        schemaVersion = SchemaVersion,
        bootId = self.bootId,
        totals = self.totals,
        storageError = self.storageError,
        recovered = self.recovered,
    }
end

---Synchronously checkpoint the queue and in-flight body.
---A failed write blocks sending to preserve recoverability.
---@return boolean ok
function Transport:Checkpoint()
    if Config.persistence == false then return true end
    if self.storageBlocked then return false end
    if not self.dirty then return true end

    local queued = {}
    for index = self.queue.head, self.queue.tail do queued[#queued + 1] = self.queue.items[index] end

    local encoded, snapshot = pcall(json.encode, { v = 1, queued = queued, flight = self.inFlight,
        dropped = self.unreportedDropped + self.queue.dropped })

    local ok, result = false, nil
    if encoded then
        ok, result = pcall(function() return exports[GetCurrentResourceName()]:SavePendingLogs(snapshot) end)
    end
    if not ok or not result or not result.ok then
        self.storageError = 'Cannot checkpoint pending logs; check disk space and permissions'
        Warn('%s', self.storageError)
        return false
    end

    self.storageError = nil
    self.dirty = false
    return true
end

---Restore pending events. An unreadable or invalid spool blocks sending
---and remains on disk for recovery.
function Transport:Restore()
    if Config.persistence == false then return end

    local ok, result = pcall(function() return exports[GetCurrentResourceName()]:LoadPendingLogs() end)
    if not ok or not result or result.error then
        self.storageError = 'Pending-log storage cannot be read; preserve the spool and repair it'
        self.storageBlocked = true
        Warn('%s', self.storageError)
        return
    end
    if not result.data then return end

    local decoded, snapshot = pcall(json.decode, result.data)
    if not decoded or not validSnapshot(snapshot) then
        self.storageError = 'Invalid pending-log snapshot; preserve the spool and repair it'
        self.storageBlocked = true
        Warn('%s', self.storageError)
        return
    end

    local existing = {}
    while self.queue:Size() > 0 do existing[#existing + 1] = self.queue:Pop() end
    self.queue = Queue.new()
    self.queuedBytes = 0

    for _, item in ipairs(snapshot.queued) do
        self.queue:Push(item, math.huge)
        self.queuedBytes = self.queuedBytes + item.bytes
    end
    self.inFlight = snapshot.flight
    self.unreportedDropped = (snapshot.dropped or 0) + self.unreportedDropped
    self.recovered = self.queue:Size() + (self.inFlight and self.inFlight.count or 0)

    for _, item in ipairs(existing) do
        self.queue:Push(item, math.huge)
        self.queuedBytes = self.queuedBytes + item.bytes
    end

    -- Apply current queue limits to restored events.
    while self.queue:Size() > Config.batch.maxQueue
        or self.queuedBytes > (Config.batch.maxQueueBytes or 8388608) do
        local discarded = self.queue:Pop()
        if not discarded then break end
        self.queuedBytes = math.max(0, self.queuedBytes - discarded.bytes)
        self.queue.dropped = self.queue.dropped + 1
        self.totals.dropped = self.totals.dropped + 1
    end

    self.dirty = true
end
