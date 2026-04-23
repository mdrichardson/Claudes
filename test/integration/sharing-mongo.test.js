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
