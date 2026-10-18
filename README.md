# vanish_logger

FiveM server resource that ships structured gameplay events to the
[Vanish Logs](https://github.com/vanishdevstore) ingestion API.

Events are queued in memory and posted in batches — one HTTP request per event
is unusable past a few hundred players — with exponential backoff when the API
is unreachable, a hard queue cap so a long outage drops the oldest events rather
than the server's memory, and a disk checkpoint so a restart does not lose what
was still pending.

## Requirements

- FiveM server build **6116** or newer

That is the only hard requirement. `es_extended` and `ox_inventory` are detected
at runtime: with them, gameplay is collected automatically; without them, the
resource still runs and the `Log` exports still work for your own scripts.

| Present                  | What you get                                        |
| ------------------------ | --------------------------------------------------- |
| Nothing                  | The exports API for your own resources              |
| `ox_inventory`           | Automatic inventory logging                         |
| `ox_inventory` + `ESX`   | The above, with character identity on every event   |

## Install

1. Download `vanish_logger.zip` from the
   [latest release](https://github.com/vanishdevstore/vanish_logger/releases/latest)
   and unzip it into your server's `resources/` directory.
2. Add `ensure vanish_logger` to `server.cfg`. If you run `ox_inventory`, start
   it before this resource.
3. Set the endpoint and key (below), then restart.

Run `vanishlogs` in the server console to confirm it is connected, and
`vanishlogs top` to see which events are busiest.

## Configuration

The endpoint and ingest key come from **convars, never from a file in this
resource** — deliberately, so the key cannot end up in a folder that gets
zipped, copied to another server, or committed.

```cfg
set vanishlogs_endpoint "https://your-vanish-logs-host"
set vanishlogs_key      "plog_xxxxxxxx_yyyyyyyy"
```

Use an HTTPS endpoint; the resource posts to `<endpoint>/ingest/v1/events`.
Trailing slashes are removed. URLs containing credentials, queries or fragments
are refused, and redirects are not followed. The key is issued from the dashboard.

For local testing only, set `Config.allowLocalHttp = true` to allow HTTP to
literal `127.0.0.1` or `[::1]`, with an optional port. Remote HTTP is always
refused. Keep the ingest key in a server-only `set` convar; never use `setr` or `sets`.

Everything else lives in [`config.lua`](config.lua), documented inline: batching
thresholds, retry timing, inventory detail, and whether to record coordinates.

Request signing (`signRequests`) is on by default because production ingest
requires an HMAC on every batch. Do not turn it off in production. The signature
binds the timestamp, a unique nonce, and the SHA-256 digest of the exact request
body to the secret half of the ingest key.

## Logging from your own resources

Everything is server-side. There is no client export on purpose: a client can
claim anything, and a log saying "player X gave themselves a weapon" is only
worth reading if the server decided it was true.

```lua
-- A channel you created in the dashboard.
exports.vanish_logger:LogTo('drugs.sales', 'sold', {
    actor = source,
    data = { substance = 'weed', grams = 12, price = 480 },
})

-- Or one of the eight built-in categories.
exports.vanish_logger:Log({
    category = 'money',
    action = 'bank_transfer',
    actor = source,
    target = targetSource,
    data = { amount = 25000, account = 'bank' },
})
```

`actor` and `target` take a server id and resolve identifiers and the current
character for you, an ESX character identifier, a name, or a table if you
already have them. `action` is normalised to snake_case, and `fields` takes
Discord-style `{ name, value }` rows and flattens them into `data`. Categories are
`inventory`, `money`, `player`, `vehicle`, `property`, `staff`, `security` and
`system`; an unknown one is refused locally rather than costing a round trip.
What a server actually stores is a dashboard setting — this resource does not
filter your events a second time.

| Export        | Purpose                                          |
| ------------- | ------------------------------------------------ |
| `Log`         | Submit an event. Returns `true` when queued.     |
| `LogTo`       | `LogTo(channel, action, event)`                  |
| `LogInventory`| `LogInventory(action, event)`                    |
| `LogCommand`  | `LogCommand(source, command, args, target, data)`, an admin command under `staff` |
| `GetStatus`   | Queue depth, totals, last error                  |
| `Flush`       | Send now, for a resource about to stop           |

Logging exports return `false` for invalid event arguments. Optional `context`
and `data` values must be tables. HTTP delivery is asynchronous; disk
checkpoints are synchronous.

## What is collected automatically

- `ox_inventory`, through its own `registerHook` API — item movements, drops,
  pickups, stash/trunk/glovebox transfers, item creation, container opens, item
  use, crafting, and shop purchases.
- The collectors in `Config.collectors`, from events those resources already
  fire, each idle when its resource is missing:

| Collector     | Category            | What                                                                   |
| ------------- | ------------------- | ---------------------------------------------------------------------- |
| `connections` | `player`            | Joins, and drops with their reason                                     |
| `esx`         | `money`, `player`   | Every account change with its reason and script; jobs, groups, characters |
| `txadmin`     | `staff`, `security` | Bans, kicks, warns, revokes, heals, announcements, restarts, console, menu actions |
| `doors`       | `property`          | ox_doorlock locks and unlocks by players                               |

Everything else is up to your own resources and the exports above.

## Durability

Pending events are checkpointed to a private `.vanishlogs-spool.json` in the
resource directory, before each send, on the flush interval, and at shutdown. A
restart restores pending events and the exact in-flight body; the API
deduplicates on event id, so a replayed batch is stored once. A sudden crash can
still lose events queued since the last checkpoint — normally up to two seconds,
and up to `batch.idleCheckpointInterval` (10 s) while the API is unreachable.

Keep the resource directory writable, and keep the spool when upgrading or
moving the resource. **Never distribute the spool**: it contains customer event
data. Checkpoint writes are synchronous, which is why they are bounded while a
request is in flight or retrying rather than taken per event.

## Volume on large servers

Events are sent in batches of up to 200, at most every two seconds, never one
request per event. What decides the volume is how many events there are:

- Repeats are folded (`Config.coalesce`): the first is sent at once, and the
  rest of a run arrive as one event with their totals and `data.repeats`.
- Each player is capped at `Config.perPlayerPerMinute` events; the excess is
  dropped and reported once as `security` / `rate_limit_triggered`.
- Item use is off by default; `usedWatchlist` names the items worth logging.
- `vanishlogs top` shows the busiest event types per minute. Tune with
  `ignoreCreatedBy`, `usedWatchlist`, the collector switches, or a channel
  pause in the dashboard.

If the spool cannot be read or fails its checksum, the resource stops sending
and says so rather than discarding it, so you can recover the file.

## Layout

```
fxmanifest.lua              Load order and dependencies
config.lua                  The one file you edit
server/limits.lua           Payload caps, mirrored from the API
server/util.lua             Logging, ids, identifiers, bounded copying
server/queue.lua            Bounded FIFO queue
server/transport.lua        Batching, HTTP, retry/backoff, checkpoints
server/shaping.lua          Folding repeats, the per-player ceiling, volume counters
server/store.js             Atomic spool writes and HMAC signing
server/api.lua              The exports above
server/main.lua             Wiring and the `vanishlogs` console command
bridge/framework/esx.lua    Character identity
bridge/inventory/ox_inventory.lua   The inventory collector
bridge/collectors/*.lua             Connection, ESX, txAdmin and door collectors
```

## Development

```sh
node --test tests/store.test.cjs        # spool + signing
cd tests && python transport_test.py   # queue/transport under real Lua
cd tests && python syntax_test.py      # every Lua file compiles
```

The Python harnesses need [`lupa`](https://pypi.org/project/lupa/)
(`pip install lupa`) and run the real Lua with FiveM natives stubbed. See
[`tests/fivem/README.md`](tests/fivem/README.md) for the manual FXServer probes
a release should still pass. `tests/` is not included in release zips.

## Releasing

Bump `version` in `fxmanifest.lua` and merge to `main`. CI tags the commit and
publishes a GitHub Release with `vanish_logger.zip` attached. See
[CHANGELOG.md](CHANGELOG.md).

## Licence

MIT — see [LICENSE](LICENSE).
