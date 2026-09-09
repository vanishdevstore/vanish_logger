# Changelog

All notable changes to this resource are documented here. This project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version in
`fxmanifest.lua` is the source of truth; merging a bump to `main` publishes a
release.

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
