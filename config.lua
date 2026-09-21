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
    },

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

    -- Controls automatic collection only. Exported events are filtered by the dashboard.
    inventory = {
        enabled = true,
        containerOpen = true,  -- stash/trunk/glovebox opens (high volume)
        itemUse = true,
        crafting = true,
        shopPurchases = true,
        includeMetadata = true, -- serials, durability; truncated if oversized
        maxMetadataKeys = 12,   -- 0 drops metadata entirely
        -- Scripts whose item creation is not worth logging, matched against
        -- the resource ox_inventory reports as the creator, ignoring case.
        --
        -- Production and payout loops are the reason this exists: a drug
        -- script granting an item every few seconds can be most of a server's
        -- entire log volume, and not one of those rows is something anyone
        -- investigates. Dropping them here costs no bandwidth and no storage.
        -- Weapon creation is never ignored, whatever is listed.
        --
        -- Find the names to put here by grouping logged items by source; the
        -- dashboard shows it as the Source column once attribution is on.
        ignoreCreatedBy = {},
        -- Coordinate collection adds native calls to each event.
        coords = false,
    },
}
