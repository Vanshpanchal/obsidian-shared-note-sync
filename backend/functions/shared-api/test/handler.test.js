import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHandler, isAuthorized } from '../src/handler.js';

class FakeError extends Error {
  constructor(code) {
    super(`fake ${code}`);
    this.code = code;
  }
}

/** In-memory TablesDB stand-in with the same bound semantics as Appwrite. */
function fakeDb() {
  let row = null;
  const db = {
    get row() {
      return row;
    },
    failNextUpdate: false,
    async getRow() {
      if (!row) throw new FakeError(404);
      return { ...row };
    },
    async createRow({ data }) {
      if (row) throw new FakeError(409);
      row = { ...data };
      return { ...row };
    },
    async updateRow({ data }) {
      if (db.failNextUpdate) {
        db.failNextUpdate = false;
        throw new FakeError(500);
      }
      row = { ...row, ...data };
      return { ...row };
    },
    async incrementRowColumn({ column, value, max }) {
      if (max !== undefined && row[column] + value > max) throw new FakeError(400);
      row[column] += value;
      return { ...row };
    },
    async decrementRowColumn({ column, value, min }) {
      if (min !== undefined && row[column] - value < min) throw new FakeError(400);
      row[column] -= value;
      return { ...row };
    },
  };
  return db;
}

function setup() {
  const db = fakeDb();
  const handle = createHandler({ db, databaseId: 'brain', tableId: 'shared', sharedApiKey: 'secret' });
  const call = async ({ method = 'GET', path = '/shared', key = 'secret', body, query = {} } = {}) => {
    let out;
    const res = { json: (data, status = 200) => (out = { status, data }) };
    const req = {
      method,
      path,
      query,
      headers: key === null ? {} : { 'x-api-key': key },
      bodyText: body === undefined ? '' : typeof body === 'string' ? body : JSON.stringify(body),
    };
    await handle({ req, res, log: () => {}, error: () => {} });
    return out;
  };
  return { db, call };
}

test('rejects missing or wrong key with 401', async () => {
  const { call } = setup();
  assert.equal((await call({ key: null })).status, 401);
  assert.equal((await call({ key: 'nope' })).status, 401);
});

test('GET creates an empty row at version 0', async () => {
  const { call } = setup();
  const r = await call();
  assert.equal(r.status, 200);
  assert.equal(r.data.content, '');
  assert.equal(r.data.version, 0);
  assert.ok(r.data.updatedAt);
});

test('POST with matching baseVersion saves and bumps version', async () => {
  const { call, db } = setup();
  const r = await call({ method: 'POST', body: { content: 'a\r\nb', baseVersion: 0, deviceId: 'd1' } });
  assert.equal(r.status, 200);
  assert.equal(r.data.version, 1);
  assert.equal(db.row.content, 'a\nb');
  assert.equal(db.row.deviceId, 'd1');
  const g = await call();
  assert.deepEqual([g.data.content, g.data.version], ['a\nb', 1]);
});

test('POST with stale baseVersion returns 409 with server state', async () => {
  const { call } = setup();
  await call({ method: 'POST', body: { content: 'v1', baseVersion: 0 } });
  const r = await call({ method: 'POST', body: { content: 'stale', baseVersion: 0 } });
  assert.equal(r.status, 409);
  assert.equal(r.data.content, 'v1');
  assert.equal(r.data.version, 1);
});

test('force=true overwrites on conflict', async () => {
  const { call, db } = setup();
  await call({ method: 'POST', body: { content: 'v1', baseVersion: 0 } });
  const r = await call({ method: 'POST', query: { force: 'true' }, body: { content: 'mine', baseVersion: 0 } });
  assert.equal(r.status, 200);
  assert.equal(r.data.version, 2);
  assert.equal(db.row.content, 'mine');
});

test('concurrent saves on the same base: exactly one wins', async () => {
  const { call, db } = setup();
  await call();
  const [a, b] = await Promise.all([
    call({ method: 'POST', body: { content: 'A', baseVersion: 0 } }),
    call({ method: 'POST', body: { content: 'B', baseVersion: 0 } }),
  ]);
  const statuses = [a.status, b.status].sort();
  assert.deepEqual(statuses, [200, 409]);
  assert.equal(db.row.version, 1);
  assert.equal(db.row.content, (a.status === 200 ? 'A' : 'B'));
});

test('failed content write rolls the version back', async () => {
  const { call, db } = setup();
  await call();
  db.failNextUpdate = true;
  const r = await call({ method: 'POST', body: { content: 'x', baseVersion: 0 } });
  assert.equal(r.status, 500);
  assert.equal(db.row.version, 0);
  assert.equal(db.row.content, '');
});

test('validation: types, size, json', async () => {
  const { call } = setup();
  assert.equal((await call({ method: 'POST', body: '{bad' })).status, 400);
  assert.equal((await call({ method: 'POST', body: { content: 1, baseVersion: 0 } })).status, 400);
  assert.equal((await call({ method: 'POST', body: { content: 'x', baseVersion: 1.5 } })).status, 400);
  const big = 'x'.repeat(2 * 1024 * 1024);
  assert.equal((await call({ method: 'POST', body: { content: big, baseVersion: 0 } })).status, 413);
  // Multibyte text near the limit is measured in bytes, not chars.
  const gu = 'ગ'.repeat(400_000); // 3 bytes each -> 1.2 MB
  assert.equal((await call({ method: 'POST', body: { content: gu, baseVersion: 0 } })).status, 413);
});

test('unicode round-trips unchanged', async () => {
  const { call } = setup();
  const text = '# નમસ્તે 🙏\n- हिंदी\n';
  await call({ method: 'POST', body: { content: text, baseVersion: 0 } });
  assert.equal((await call()).data.content, text);
});

test('routing: unknown path 404, bad method 405, trailing slash ok', async () => {
  const { call } = setup();
  assert.equal((await call({ path: '/other' })).status, 404);
  assert.equal((await call({ method: 'DELETE' })).status, 405);
  assert.equal((await call({ path: '/shared/' })).status, 200);
});

test('isAuthorized rejects empty configured key', () => {
  assert.equal(isAuthorized('', ''), false);
  assert.equal(isAuthorized('a', 'a'), true);
});
