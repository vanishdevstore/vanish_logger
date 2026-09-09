# Manual FXServer probes

The automated tests run the transport under stubbed natives. These probes run it
against a real server, which is still required before a release.

`vanishlogs_testbench` is a **separate resource**. Copy it into your test
server's `resources/` directory — do not leave it inside `vanish_logger`, and
never add it to a production startup config.

Start a configured `vanish_logger` first, then from the server console:

1. `refresh` and `ensure vanishlogs_testbench`
2. `vanishlogs_test run` — sends a custom inventory event twice with the same
   id, rejects a malformed event locally, and creates three water items in a
   temporary ox_inventory stash. Check the printed correlation and inventory ids
   in the dashboard: the duplicate must appear exactly once.
3. `vanishlogs_test status` — empty queue, nothing in flight, no failures or
   drops once delivery has settled.
4. `vanishlogs_test outage` — points only the logger's endpoint at a closed
   loopback port and queues a recovery probe. Confirm a checkpoint exists, then
   `restart vanish_logger` and check that status reports a recovered event.
5. `vanishlogs_test restore` — puts the endpoint back. After backoff, the
   recovery event must appear once and the queue must drain.
6. `vanishlogs_test cleanup`, then `stop vanishlogs_testbench`.

`vanishlogs_test demo` sends eight clearly marked synthetic inventory events 1.5
seconds apart, for checking the live feed. It changes no player inventories.

The harness refuses player sources, never reads the ingest key, and restores the
endpoint and removes its stash when stopped. If the FXServer process exits
during the outage probe, the endpoint is restored from your normal server config
on the next start.

Last verified on FXServer build 31623 with ESX and ox_inventory 2.44.1.
