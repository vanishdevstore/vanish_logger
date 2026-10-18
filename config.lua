-- Set credentials in server.cfg:
--
--   set vanishlogs_endpoint "https://logs.example.com"
--   set vanishlogs_key      "plog_xxxxxxxx_yyyyyyyy"

Config = {
    -- Enable transport debug output for troubleshooting.
    debug = false,

    endpointConvar = 'vanishlogs_endpoint',
    keyConvar = 'vanishlogs_key',

    -- Test servers only: allow HTTP to literal 127.0.0.1 or [::1].
    allowLocalHttp = false,

    -- Batch events to reduce HTTP requests.
    batch = {
        maxEvents = 200,
        flushInterval = 2000,
        -- Drop and count the oldest events when either queue limit is reached.
        maxQueue = 5000,
        maxQueueBytes = 8388608, -- 8 MiB
        maxBodyBytes = 900000,   -- under the API's 1 MiB limit, with headroom
        -- ms between spool rewrites while a request is in flight or retrying.
        -- Each rewrite serialises the whole queue on the server thread, so an
        -- outage costs one every 10 s instead of one per event.
        idleCheckpointInterval = 10000,
    },

    -- Repeats of the same event (same player, action, item, reason, script and
    -- places; only amounts and counts differ) are folded together. The first
    -- is sent at once; the repeats that follow are sent as one event carrying
    -- their total and `data.repeats`. Turns payout loops, production loops and
    -- spam into two rows a minute instead of hundreds. window = 0 disables it.
    coalesce = {
        window = 10000,  -- ms of quiet after which a run of repeats is closed and sent
        maxHold = 60000, -- ms a busy run is held at most before it is sent anyway
    },

    -- Events kept per player per minute after folding repeats. Past it the
    -- rest are dropped and one security event says how many, so a single
    -- cheater cannot push everyone else's evidence out of the queue.
    -- 0 disables it.
    perPlayerPerMinute = 300,

    -- Checkpoint pending events to disk so a restart does not lose them.
    -- A crash can still lose events queued since the last checkpoint.
    persistence = true,

    retry = {
        baseDelay = 1000,
        maxDelay = 60000,
        httpTimeout = 15000,
    },

    -- Production ingest requires an HMAC on every batch. Leave this on.
    signRequests = true,

    -- Gameplay collected from events the server and common resources already
    -- fire, filed under the built-in categories. Each does nothing when its
    -- resource is missing. Set one to false to disable it.
    collectors = {
        connections = true, -- joins, and drops with their reason
        esx = true,         -- every cash, bank and dirty money change with its reason and script; job, group and character changes
        txadmin = true,     -- bans, kicks, warns, revokes, heals, announcements, restarts, live console and in-game menu actions
        doors = true,       -- ox_doorlock locks and unlocks by players
    },

    -- Controls automatic collection only. Exported events are filtered by the dashboard.
    inventory = {
        enabled = true,
        slotShuffles = false,   -- moves that start and end in the same inventory
        containerOpen = false,  -- stash/trunk/glovebox opens (high volume)
        -- Every item use: food, drink and opening a radio are most of it, and
        -- none of it is ever investigated. Items in usedWatchlist are logged
        -- either way, matched case-insensitively.
        itemUse = false,
        usedWatchlist = { 'lockpick', 'armour', 'bandage', 'medikit' },
        crafting = true,
        shopPurchases = true,
        includeMetadata = true, -- serials, durability; truncated if oversized
        maxMetadataKeys = 12,   -- 0 drops metadata entirely
        -- Creating scripts not worth logging, matched case-insensitively.
        -- Weapons are never ignored. `vanishlogs top` shows which scripts
        -- create the most items.
        ignoreCreatedBy = {},
        coords = false,         -- adds native calls to each event
    },
}
