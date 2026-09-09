const { test } = require('node:test');
const assert = require('node:assert/strict');
const { mkdtempSync, readFileSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve, dirname, basename } = require('node:path');
function cleanup(dir) {
  if(dirname(resolve(dir))!==resolve(tmpdir())||!basename(dir).startsWith('vanishlogs-spool-')) throw Error('Unexpected test cleanup path');
  rmSync(dir,{recursive:true});
}
const { createHmac, createHash } = require('node:crypto');
const { createStore, signBatch } = require('../server/store.js');

test('a new store instance restores the exact pending bytes after restart', () => {
  const dir = mkdtempSync(join(tmpdir(), 'vanishlogs-spool-'));
  try {
    const body = '{"events":[{"id":"stable","occurredAt":"2026-09-05T00:00:00Z"}]}';
    assert.equal(createStore(dir).save(body).ok, true);
    assert.equal(createStore(dir).load().data, body);
    assert.ok(readFileSync(join(dir, '.vanishlogs-spool.json'), 'utf8').includes('sha256'));
  } finally { cleanup(dir); }
});
test('corrupt snapshots fail visibly instead of silently discarding pending logs', () => {
  const dir = mkdtempSync(join(tmpdir(), 'vanishlogs-spool-'));
  try {
    writeFileSync(join(dir, '.vanishlogs-spool.json'), '{broken');
    assert.match(createStore(dir).load().error, /unreadable/);
  } finally { cleanup(dir); }
});
test('signature uses exact API HMAC contract and fresh nonces on replay', () => {
  const body='{"events":[]}', key='plog_prefix_secret_with_underscores';
  const first=signBatch(key,body,123456789), second=signBatch(key,body,123456789);
  assert.notEqual(first['X-Vanishlogs-Nonce'],second['X-Vanishlogs-Nonce']);
  const expected=createHmac('sha256','secret_with_underscores').update(`123456789.${first['X-Vanishlogs-Nonce']}.${createHash('sha256').update(body).digest('hex')}`).digest('hex');
  assert.equal(first['X-Vanishlogs-Signature'],'v1='+expected);
});
