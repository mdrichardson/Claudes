'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { MongoMemoryReplSet } = require('mongodb-memory-server');
const {
  testConnection,
  connect,
  disconnect,
  getDb,
} = require('../../lib/sharing-mongo');

let replset;
let uri;

before(async () => {
  replset = await MongoMemoryReplSet.create({ replSet: { count: 1 } });
  uri = replset.getUri();
}, { timeout: 60_000 });

after(async () => {
  await disconnect();
  if (replset) await replset.stop();
});

test('testConnection: ok against a live Mongo', async () => {
  const result = await testConnection({ connectionString: uri, dbName: 'Claudes' });
  assert.equal(result.ok, true);
  assert.equal(result.dbName, 'Claudes');
  assert.equal(typeof result.hostRedacted, 'string');
  assert.equal(result.hostRedacted.length > 0, true);
});

test('testConnection: fails with invalid host (short timeout)', async () => {
  const result = await testConnection({
    connectionString: 'mongodb://127.0.0.1:1/',
    dbName: 'Claudes',
    timeoutMs: 1500,
  });
  assert.equal(result.ok, false);
  assert.equal(typeof result.error, 'string');
  assert.equal(result.error.length > 0, true);
});

test('connect + getDb: returns a usable Db handle', async () => {
  await connect({ connectionString: uri, dbName: 'Claudes' });
  const db = getDb();
  assert.equal(db !== null, true);
  const pong = await db.command({ ping: 1 });
  assert.equal(pong.ok, 1);
  await disconnect();
});

test('getDb before connect returns null', () => {
  assert.equal(getDb(), null);
});

test('disconnect when not connected is a no-op', async () => {
  await disconnect();
  assert.equal(getDb(), null);
});

test('connect twice without disconnect closes the previous client', async () => {
  await connect({ connectionString: uri, dbName: 'Claudes' });
  const db1 = getDb();
  assert.equal(db1 !== null, true);
  // Reconnect without an explicit disconnect — _doConnect should close the prior client.
  await connect({ connectionString: uri, dbName: 'Claudes' });
  const db2 = getDb();
  assert.equal(db2 !== null, true);
  // The second connect replaced state wholesale, so db2 is a fresh Db handle.
  assert.equal(db1 !== db2, true);
  // New connection still works.
  const pong = await db2.command({ ping: 1 });
  assert.equal(pong.ok, 1);
  await disconnect();
});

test('testConnection: throws TypeError for non-string dbName', async () => {
  await assert.rejects(
    () => testConnection({ connectionString: 'mongodb://127.0.0.1:1/', dbName: 42 }),
    /dbName must be a non-empty string/
  );
});

test('testConnection: throws for non-string connectionString', async () => {
  await assert.rejects(
    () => testConnection({ connectionString: null, dbName: 'Claudes' }),
    /must be a string/
  );
});
