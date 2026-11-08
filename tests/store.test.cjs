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
const { createStore, signBatch, signBatchV2 } = require('../server/store.js');

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
test('v2 names the key by its prefix and signs with the signing secret only', () => {
  const body='{"events":[]}', key='plog_prefix_secret_with_underscores', signingSecret='vlsig_abc-DEF_123';
  const headers=signBatchV2(key,signingSecret,body,123456789);
  assert.deepEqual(Object.keys(headers).sort(),
    ['X-Vanishlogs-Key-Id','X-Vanishlogs-Nonce','X-Vanishlogs-Signature','X-Vanishlogs-Timestamp']);
  assert.equal(headers['X-Vanishlogs-Key-Id'],'prefix');
  assert.equal(headers['X-Vanishlogs-Timestamp'],'123456789');
  assert.match(headers['X-Vanishlogs-Nonce'],/^[0-9a-f]{32}$/);
  assert.ok(!JSON.stringify(headers).includes('secret_with_underscores'));
  const message=`123456789.${headers['X-Vanishlogs-Nonce']}.${createHash('sha256').update(body).digest('hex')}`;
  assert.equal(headers['X-Vanishlogs-Signature'],'v2='+createHmac('sha256',signingSecret).update(message).digest('hex'));
  assert.notEqual(signBatchV2(key,signingSecret,body,123456789)['X-Vanishlogs-Nonce'],headers['X-Vanishlogs-Nonce']);
});
test('v2 refuses a malformed key or a missing signing secret', () => {
  for (const key of ['', 'plog_', 'plog_prefix', 'plog__secret', 'pk_prefix_secret'])
    assert.throws(() => signBatchV2(key,'vlsig_abc','{}'),/Invalid ingest key/);
  for (const secret of ['', undefined, null])
    assert.throws(() => signBatchV2('plog_prefix_secret',secret,'{}'),/Missing signing secret/);
});
