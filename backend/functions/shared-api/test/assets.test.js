import { test } from 'node:test';
import assert from 'node:assert/strict';
import { assetId, createHandler, validateAssetName } from '../src/handler.js';

class FakeError extends Error {
  constructor(code) {
    super(`fake ${code}`);
    this.code = code;
  }
}

/** In-memory stand-in for the Appwrite Storage adapter in main.js. */
function fakeStorage() {
  const files = new Map();
  let tick = 0;
  return {
    files,
    async list() {
      return [...files.values()].map((f) => f.meta);
    },
    async get(id) {
      const f = files.get(id);
      if (!f) throw new FakeError(404);
      return f.meta;
    },
    async create(id, name, buffer) {
      if (files.has(id)) throw new FakeError(409);
      const meta = {
        $id: id,
        name,
        sizeOriginal: buffer.length,
        mimeType: name.endsWith('.png') ? 'image/png' : 'application/octet-stream',
        $createdAt: `2026-10-04T10:00:0${tick}Z`,
        $updatedAt: `2026-10-04T10:00:0${tick++}Z`,
      };
      files.set(id, { meta, buffer: Buffer.from(buffer) });
      return meta;
    },
    async download(id) {
      return files.get(id).buffer;
    },
    async remove(id) {
      if (!files.delete(id)) throw new FakeError(404);
    },
  };
}

function setup(opts = {}) {
  const storage = opts.noStorage ? undefined : fakeStorage();
  const handle = createHandler({
    db: {},
    databaseId: 'brain',
    tableId: 'shared',
    sharedApiKey: 'secret',
    storage,
    maxAssetBytes: opts.max ?? 1024,
  });
  const call = async ({ method = 'GET', path = '/assets/file', key = 'secret', query = {}, bytes } = {}) => {
    let out;
    const res = {
      json: (data, status = 200) => (out = { status, data }),
      binary: (data, status = 200, headers = {}) => (out = { status, data, headers, binary: true }),
    };
    const req = {
      method,
      path,
      query,
      headers: key === null ? {} : { 'x-api-key': key },
      bodyBinary: bytes,
      bodyText: '',
    };
    await handle({ req, res, log: () => {}, error: () => {} });
    return out;
  };
  return { storage, call };
}

const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4]);

test('assets require the api key', async () => {
  const { call } = setup();
  assert.equal((await call({ path: '/assets', key: null })).status, 401);
  assert.equal((await call({ path: '/assets', key: 'bad' })).status, 401);
});

test('assets are 501 when no storage is configured', async () => {
  const { call } = setup({ noStorage: true });
  assert.equal((await call({ path: '/assets' })).status, 501);
});

test('upload, list, download, delete round trip', async () => {
  const { call } = setup();
  const up = await call({ method: 'POST', query: { name: 'photo one.png' }, bytes: png });
  assert.equal(up.status, 201);
  assert.equal(up.data.name, 'photo one.png');
  assert.equal(up.data.size, png.length);

  const list = await call({ path: '/assets' });
  assert.equal(list.status, 200);
  assert.deepEqual(list.data.files.map((f) => f.name), ['photo one.png']);
  assert.equal(list.data.maxBytes, 1024);

  const dl = await call({ query: { name: 'photo one.png' } });
  assert.equal(dl.status, 200);
  assert.ok(dl.binary);
  assert.deepEqual([...dl.data], [...png]);
  assert.equal(dl.headers['content-type'], 'image/png');
  assert.equal(dl.headers['x-asset-size'], String(png.length));

  const del = await call({ method: 'DELETE', query: { name: 'photo one.png' } });
  assert.equal(del.status, 200);
  assert.equal((await call({ query: { name: 'photo one.png' } })).status, 404);
  assert.equal((await call({ method: 'DELETE', query: { name: 'photo one.png' } })).status, 404);
});

test('uploading an existing name is 409 unless overwrite=true', async () => {
  const { call } = setup();
  await call({ method: 'POST', query: { name: 'a.png' }, bytes: png });
  const dup = await call({ method: 'POST', query: { name: 'a.png' }, bytes: Buffer.from('new') });
  assert.equal(dup.status, 409);
  assert.equal(dup.data.error, 'exists');
  // Names differing only by case are the same attachment.
  assert.equal((await call({ method: 'POST', query: { name: 'A.PNG' }, bytes: png })).status, 409);

  const over = await call({ method: 'POST', query: { name: 'a.png', overwrite: 'true' }, bytes: Buffer.from('new') });
  assert.equal(over.status, 200);
  const dl = await call({ query: { name: 'a.png' } });
  assert.equal(Buffer.from(dl.data).toString(), 'new');
});

test('size limit and empty files are rejected', async () => {
  const { call } = setup({ max: 16 });
  const big = await call({ method: 'POST', query: { name: 'big.bin' }, bytes: Buffer.alloc(17) });
  assert.equal(big.status, 413);
  assert.equal(big.data.maxBytes, 16);
  assert.equal((await call({ method: 'POST', query: { name: 'e.bin' }, bytes: Buffer.alloc(0) })).status, 400);
  assert.equal((await call({ method: 'POST', query: { name: 'ok.bin' }, bytes: Buffer.alloc(16) })).status, 201);
});

test('invalid names are rejected before touching storage', async () => {
  const { call, storage } = setup();
  for (const name of ['', '../x.png', 'a/b.png', 'a\\b.png', '.hidden', 'x.', 'a#b.png', 'a|b.png', 'a^b.png', 'a[b].png', 'a:b.png', ' sp.png']) {
    const r = await call({ method: 'POST', query: { name }, bytes: png });
    assert.equal(r.status, 400, `name ${JSON.stringify(name)}`);
  }
  assert.equal(storage.files.size, 0);
});

test('names with spaces and unicode are fine and ids are stable', async () => {
  assert.equal(validateAssetName('Pasted image 20261004.png'), null);
  assert.equal(validateAssetName('નમસ્તે 🙏.png'), null);
  assert.equal(assetId('A.png'), assetId('a.PNG'));
  assert.notEqual(assetId('a.png'), assetId('b.png'));
  assert.match(assetId('x'), /^[a-z0-9]{1,36}$/);
  assert.ok(assetId('x').length <= 36);
});

test('listing is sorted and wrong methods are 405', async () => {
  const { call } = setup();
  await call({ method: 'POST', query: { name: 'b.png' }, bytes: png });
  await call({ method: 'POST', query: { name: 'a.png' }, bytes: png });
  assert.deepEqual((await call({ path: '/assets' })).data.files.map((f) => f.name), ['a.png', 'b.png']);
  assert.equal((await call({ path: '/assets', method: 'POST' })).status, 405);
  assert.equal((await call({ method: 'PUT', query: { name: 'a.png' } })).status, 405);
});

test('main.js loads (SDK imports resolve)', async () => {
  const mod = await import('../src/main.js');
  assert.equal(typeof mod.default, 'function');
  const { InputFile } = await import('node-appwrite/file');
  assert.equal(typeof InputFile.fromBuffer, 'function');
});
