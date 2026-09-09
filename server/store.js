// Node-side spool storage and HMAC-SHA256 signing.
// Write snapshots with temp file, fsync and rename; verify their checksum on load.

const fs = require('node:fs');
const path = require('node:path');
const { createHash, createHmac, randomBytes } = require('node:crypto');

const SPOOL_FILE = '.vanishlogs-spool.json';
const MAX_SPOOL_BYTES = 64 * 1024 * 1024;

function createStore(directory) {
  const filename = path.join(directory, SPOOL_FILE);

  return {
    // Preserve a damaged spool for recovery and report the checksum error.
    load() {
      if (!fs.existsSync(filename)) return { data: null };
      try {
        const entry = JSON.parse(fs.readFileSync(filename, 'utf8'));
        if (
          typeof entry.data !== 'string' ||
          createHash('sha256').update(entry.data).digest('hex') !== entry.sha256
        ) {
          throw Error('checksum');
        }
        return { data: entry.data };
      } catch {
        return { error: 'Pending-log storage is unreadable. Preserve the spool and repair it before restarting.' };
      }
    },

    save(data) {
      if (typeof data !== 'string' || Buffer.byteLength(data) > MAX_SPOOL_BYTES) {
        return { error: 'Pending logs exceed the 64 MiB storage limit.' };
      }

      const temporary = filename + '.tmp';
      let fd;
      try {
        // 0600: the spool holds customer event data.
        fd = fs.openSync(temporary, 'w', 0o600);
        fs.writeFileSync(fd, JSON.stringify({ data, sha256: createHash('sha256').update(data).digest('hex') }));
        fs.fsyncSync(fd);
        fs.closeSync(fd);
        fd = undefined;
        fs.renameSync(temporary, filename);

        // Persist the rename itself. Windows does not allow a directory fsync.
        if (process.platform !== 'win32') {
          const dir = fs.openSync(directory, 'r');
          try {
            fs.fsyncSync(dir);
          } finally {
            fs.closeSync(dir);
          }
        }
        return { ok: true };
      } catch {
        return { error: 'Could not persist pending logs. Check free disk space and resource write permissions.' };
      } finally {
        if (fd !== undefined) fs.closeSync(fd);
      }
    },
  };
}

// Keys use plog_<prefix>_<secret>. Sign with the secret portion only.
// The signature covers the timestamp, nonce and body hash.
function signBatch(key, body, now = Date.now()) {
  const match = /^plog_[^_]+_(.+)$/.exec(key);
  if (!match) throw Error('Invalid ingest key');

  const timestamp = String(now);
  const nonce = randomBytes(16).toString('hex');
  const hash = createHash('sha256').update(body).digest('hex');

  return {
    'X-Vanishlogs-Timestamp': timestamp,
    'X-Vanishlogs-Nonce': nonce,
    'X-Vanishlogs-Signature':
      'v1=' + createHmac('sha256', match[1]).update(`${timestamp}.${nonce}.${hash}`).digest('hex'),
  };
}

// Only inside FXServer. The tests require this file directly.
if (typeof GetCurrentResourceName === 'function') {
  const store = createStore(GetResourcePath(GetCurrentResourceName()));
  global.exports('LoadPendingLogs', () => store.load());
  global.exports('SavePendingLogs', (data) => store.save(data));
  global.exports('SignLogBatch', (key, body) => signBatch(key, body));
}

module.exports = { createStore, signBatch };
