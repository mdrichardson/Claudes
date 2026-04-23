'use strict';

const { MongoClient } = require('mongodb');
const { normalizeConnectionString, redactHost } = require('./sharing-connection-string');

const DEFAULT_TIMEOUT_MS = 8000;

let currentClient = null;
let currentDb = null;
let currentConfig = null;
let connectInProgress = null;

/**
 * Open a transient client, ping, close. Returns { ok, dbName, hostRedacted, error? }.
 * Never throws for connection failures — returns { ok: false, error }.
 * Re-throws for programmer errors (invalid argument types).
 */
async function testConnection({ connectionString, dbName, timeoutMs = DEFAULT_TIMEOUT_MS }) {
  const cs = normalizeConnectionString(connectionString);
  if (typeof dbName !== 'string' || !dbName.trim()) {
    throw new Error('dbName must be a non-empty string');
  }
  const client = new MongoClient(cs, {
    serverSelectionTimeoutMS: timeoutMs,
    connectTimeoutMS: timeoutMs,
  });
  try {
    await client.connect();
    const db = client.db(dbName.trim());
    await db.command({ ping: 1 });
    return { ok: true, dbName: dbName.trim(), hostRedacted: redactHost(cs) };
  } catch (err) {
    return { ok: false, dbName: dbName.trim(), hostRedacted: redactHost(cs), error: String(err && err.message || err) };
  } finally {
    try { await client.close(); } catch { /* ignore */ }
  }
}

/**
 * Open a persistent client. Replaces any existing client.
 * Throws on failure — callers handle the error.
 * Serialised against concurrent calls via connectInProgress guard.
 */
async function connect({ connectionString, dbName }) {
  if (connectInProgress) {
    await connectInProgress.catch(() => { /* swallow previous in-flight failure so we can retry */ });
  }
  const p = _doConnect({ connectionString, dbName });
  connectInProgress = p;
  try {
    return await p;
  } finally {
    if (connectInProgress === p) connectInProgress = null;
  }
}

async function _doConnect({ connectionString, dbName }) {
  const cs = normalizeConnectionString(connectionString);
  if (typeof dbName !== 'string' || !dbName.trim()) {
    throw new Error('dbName must be a non-empty string');
  }
  await disconnect();
  const client = new MongoClient(cs, {
    serverSelectionTimeoutMS: DEFAULT_TIMEOUT_MS,
    connectTimeoutMS: DEFAULT_TIMEOUT_MS,
  });
  await client.connect();
  currentClient = client;
  currentDb = client.db(dbName.trim());
  currentConfig = { dbName: dbName.trim(), hostRedacted: redactHost(cs) };
  return { dbName: currentConfig.dbName, hostRedacted: currentConfig.hostRedacted };
}

async function disconnect() {
  if (!currentClient) return;
  const c = currentClient;
  currentClient = null;
  currentDb = null;
  currentConfig = null;
  try { await c.close(); } catch { /* ignore */ }
}

function getDb() {
  return currentDb;
}

// currentClient, currentDb, and currentConfig are always set and cleared together.
function getStatus() {
  if (!currentDb) return { connected: false };
  return { connected: true, dbName: currentConfig.dbName, hostRedacted: currentConfig.hostRedacted };
}

module.exports = { testConnection, connect, disconnect, getDb, getStatus };
