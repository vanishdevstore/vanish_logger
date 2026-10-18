# Changelog

All notable changes to this resource are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version in
`fxmanifest.lua` is the source of truth; merging a bump to `main` publishes a
release.

## 1.3.0

Built for 500+ player servers. Measured end to end against a real ingest API and
Postgres, with the same 60-second peak (6,662 events offered, about 110 a
second), a one-player flood of 600 events, and a one-minute outage:

| | 1.2.0 | 1.3.0 |
| --- | --- | --- |
| Rows stored for the peak minute | 6,660 | 1,856 |
| Spool rewrites during the outage | 1,791 (790 MB serialised) | 15 (3 MB) |
| Spool rewrites during the flood | 207 (44 MB) | 5 (0.3 MB) |
| Item-use hook calls into the logger | 1,200 | 300 |

Money totals are unchanged: 2,400 payouts of $50 arrive as 80 rows that sum to
exactly $120,000.

### Fixed

- A busy server no longer rewrites the spool once per event. Once the queue
  reached `maxEvents` while a request was in flight or backing off, every new
  event flushed, and that flush rewrote the whole queue to disk on the server
  thread; during an outage that was a multi-megabyte synchronous write per
  event. An early flush now happens only when a request can actually go out,
  and while one is in flight or retrying the spool is rewritten at most every
  `batch.idleCheckpointInterval` (10 s). Shutdown still checkpoints at once.

### Added

- Repeats are folded (`Config.coalesce`). An event identical to one already
  sent, except for its amount, count or quantity, is held, and every repeat in
  the run is sent as one event with the totals and `data.repeats`. The first is
  always sent at once, so nothing new is delayed. A run closes after 10 s of
  quiet or 60 s of activity. Payout loops, production loops and spam become two
  rows a minute instead of hundreds, without losing any money or item totals.
- A per-player ceiling (`Config.perPlayerPerMinute`, 300). Past it, a player's
  events are dropped and one `security` / `rate_limit_triggered` event says how
  many, so one cheater cannot push everyone else's evidence out of the queue.
- `vanishlogs top` lists the busiest event types per minute, so a noisy script
  can be found and tuned; `vanishlogs top reset` restarts the count. `vanishlogs`
  also shows how many repeats were folded and how many events were limited.
- `Config.inventory.usedWatchlist`: items whose use is logged even with
  `itemUse` off. The filter is passed to ox_inventory's `itemFilter`, so an
  unwatched use never calls into the logger at all.

### Changed

- `Config.inventory.itemUse` now defaults to `false`. Food, drink and radios are
  most item uses and none is ever investigated. Set it to `true` to log every
  use, or list the items that matter in `usedWatchlist`.
- Character details are read once per player and kept until ESX says they
  changed (`esx:playerLoaded`, `esx:playerLogout`, `esx:setJob`, `esx:setGroup`,
  a drop), with a 60 s ceiling. Every lookup used to copy a whole xPlayer across
  the resource boundary for every event that named a player.
- Cash that ESX creates while paying a player (an ox_inventory account item
  created by `es_extended`) is no longer logged as an item; the ESX collector
  already records that payment with its reason. Account items created any
  other way still log.

## 1.2.0

### Added

- Collectors for gameplay other resources already announce, each a
  `Config.collectors` switch and each idle when its resource is missing:
  - `connections`: joins, and drops with the reason.
  - `esx`: every cash, bank and dirty money change, with its reason and the
    script that moved it (`esx:addAccountMoney`, `esx:removeAccountMoney`,
    `esx:setAccountMoney`); paychecks as `salary`; job, group and character
    load and create. Balance re-syncs from ox_inventory cash moves are skipped
    because the move itself is already logged.
  - `txadmin`: bans, kicks, warns, revokes, heals, direct messages,
    announcements, restarts, whitelist changes, live console commands, admin
    logins, and in-game menu actions. Menu actions refused for lack of
    permission are logged as `security` / `unauthorized_event`. Events not sent
    by txAdmin's own `monitor` resource are ignored.
  - `doors`: ox_doorlock locks and unlocks by players. Autolocks are skipped.
- `LogCommand(source, command, args, target, data)` logs an admin command under
  `staff`, mapped to the staff action the dashboard names (`/setgroup` is
  `permission_changed`, `/car` is `vehicle_spawn`) or `command_executed`.
- `fields` on any event: Discord-style `{ name|key, value }` rows are
  flattened into `data`, with money strings such as `"$1,250"` read as numbers
  and common titles mapped to indexed keys (`Amount Paid` also fills `amount`).
  Funnels built for webhooks can log without restating every field.
- `actor` and `target` accept an ESX character identifier (resolved to the
  connected player, or kept as the identifier when they are offline), a
  `license:` identifier, a name such as a txAdmin account, or `0` for the
  console.

### Changed

- Actions are normalised to snake_case before sending, so a title such as
  `"New Vehicle Purchase"` arrives as `new_vehicle_purchase` instead of being
  refused by the API.
- Vendor severities are mapped (`success` to `info`, `error` and `danger` to
  `warning`); an unknown severity is dropped instead of failing the event.
- A player resolved from a server id always carries their current character
  (name, identifier, job, group), for every export, not only inventory events.
  The name reads `Character Name (FiveM name)` so staff can search either.

### Fixed

- Character details no longer leak into the shared identifier cache. After a
  character switch, inventory events could carry the previous character's
  name, job and identifier.
- A player joining with a recycled server id no longer inherits the previous
  holder's cached identifiers.

## 1.1.0

### Added

- `Config.inventory.slotShuffles`, off by default. A move that begins and ends
  in the same inventory — tidying a bag, splitting a stack in place, giving to
  yourself — is no longer logged. Nothing changes hands and nothing enters or
  leaves the world, so no investigation reads one, but on a busy server they
  are routinely the largest single slice of inventory volume. Set it to `true`
  to restore the old behaviour.

### Changed

- `Config.inventory.containerOpen` now defaults to `false`. Opening a stash or
  a trunk is high volume and says only that somebody looked; what they took is
  already logged as a move. Existing installs that want container opens must
  set it back to `true` after updating.

## 1.0.5

### Fixed

- Created items are attributed to the player who received them and the script
  that made them. The actor was resolved with a helper that only accepts an
  owner string, while a player inventory id arrives as a number, so every
  created item logged without one; it now resolves through the same path as
  the other hooks and falls back to the inventory's persistent owner once the
  player has disconnected. The event's `resource` is now the script that asked
  for the item rather than a hardcoded `ox_inventory`, which every item passes
  through. `createdBy` stays in the payload.

### Added

- `Config.inventory.ignoreCreatedBy`, a list of scripts whose item creation is
  not logged, matched ignoring case and empty by default. A production or
  payout loop can be most of a server's log volume and none of it is something
  anyone investigates. Weapon creation is never ignored, whatever is listed.

## 1.0.4

### Fixed

- Player-to-player transfers no longer drop the target when the recipient's
  server ID cannot be resolved. ox_inventory defers hook post-events, so a
  recipient can already be unresolvable by the time an event is built; the
  target now falls back to the inventory's persistent owner. Inventories with
  no owner, and IDs ox_inventory does not hold, still emit no target.

## 1.0.3

### Security

- Require HTTPS for remote ingest endpoints and disable HTTP redirects.
- Allow loopback HTTP only when `Config.allowLocalHttp` is explicitly enabled
  for testing. Embedded URL credentials, queries and fragments are rejected.

### Fixed

- Reject malformed event containers and invalid export arguments with `false`
  instead of raising errors in calling resources.

## 1.0.2

### Changed

- Shortened source comments and corrected the notes on player inventory IDs
  and shutdown delivery. No runtime behavior changes.

## 1.0.1

### Fixed

- Player-to-player inventory transfers now resolve numeric recipient server IDs
  to the player's name and identifiers instead of emitting a missing target.
  Numeric strings are also supported; disconnected server IDs are not stored
  as persistent character identifiers.
- Added inventory identity regression tests to CI.

## 1.0.0

First public release.

### Added

- Optional dependency detection. `es_extended` and `ox_inventory` are resolved
  at runtime instead of being required in the manifest, so the resource runs on
  a server that has neither and still offers the exports API. Both adapters
  register correctly when their resource starts *after* this one.
- `vanishlogs` console output now reports which framework and inventory adapter
  are active, so "connected but collecting nothing" is visible.
- A Lua compile check and a manifest-completeness check over every shipped file.

### Fixed

- **Events sent to `money`, `player`, `vehicle`, `property` and `staff` were
  silently dropped.** Those categories shipped as `false` config switches for
  collectors that do not exist, and the switch gated every call to
  `exports.vanish_logger:Log` — including events from a server's own resources.
  Category filtering now belongs solely to the dashboard; this resource only
  refuses a category the platform does not define.

### Changed

- Everything is server-side. Config and helpers were previously `shared_scripts`
  and were downloaded and executed by every connecting client despite there
  being no client code.
- `ox_lib` is no longer a dependency. It was used for a single `lib.load` call.
- Config moved to `config.lua` at the repository root, and the per-category
  switch table was replaced by a `Config.inventory` block describing what is
  actually collected.
- Source layout flattened: `shared/` and the `server/core`, `server/api` and
  `bridge/*/server` levels are gone.

### Removed

- `escrow_ignore` from the manifest, which is meaningless in an open repository.
- Dead code: `FrameworkReady()`, `Queue:Prepend()` and `Queue:Clear()`, none of
  which had a caller.
