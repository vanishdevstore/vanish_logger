---Keep these caps in sync with packages/events/src/limits.ts in the platform.
Limits = {
    maxBodyBytes    = 1048576, -- 1 MiB, the API's request body cap
    maxBatchSize    = 500,     -- events per request
    maxEventBytes   = 32768,   -- 32 KiB, one serialised event
    maxDataKeys     = 64,      -- top-level keys in `data`
    maxStringLength = 2048,    -- any single string value inside `data`
    maxFieldLength  = 128,     -- identity and short-text fields
    maxArrayLength  = 64,      -- elements kept from an array
    maxDepth        = 6,       -- nesting depth
}

---The API rejects unsupported schema versions.
SchemaVersion = 1

---Sent with every batch so the dashboard can flag outdated servers.
LoggerVersion = GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '0.0.0'
