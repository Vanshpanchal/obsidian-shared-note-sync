// Creates database `brain`, table `shared` (with columns) and the single row `shared`.
// Safe to re-run: anything that already exists is skipped.
//
// Usage (needs a key with databases.read/write, tables.read/write, columns.read/write,
// rows.read/write, buckets.read/write and files.read/write scopes):
//   APPWRITE_ENDPOINT=https://<region>.cloud.appwrite.io/v1 \
//   APPWRITE_PROJECT_ID=... APPWRITE_API_KEY=... \
//   node backend/scripts/setup-db.mjs
//
// Uses the TablesDB API (Appwrite 1.8+). Collections/documents/attributes in the
// older Databases API are now tables/rows/columns.

import { createRequire } from 'node:module';

const require = createRequire(new URL('../functions/shared-api/package.json', import.meta.url));
const { Client, Storage, TablesDB } = require('node-appwrite');

// Load backend/.env if present (vars already set in the shell win).
try {
  process.loadEnvFile(new URL('../.env', import.meta.url));
} catch (e) {
  if (e?.code !== 'ENOENT') throw e;
}

const env = process.env;
for (const k of ['APPWRITE_ENDPOINT', 'APPWRITE_PROJECT_ID', 'APPWRITE_API_KEY']) {
  if (!env[k]) {
    console.error(`Missing env var ${k}`);
    process.exit(1);
  }
}
const databaseId = env.DATABASE_ID || 'brain';
const tableId = env.COLLECTION_ID || 'shared';
const bucketId = env.BUCKET_ID || 'assets';
const maxAssetBytes = Number(env.ASSET_MAX_BYTES) || 10 * 1024 * 1024;

const client = new Client()
  .setEndpoint(env.APPWRITE_ENDPOINT)
  .setProject(env.APPWRITE_PROJECT_ID)
  .setKey(env.APPWRITE_API_KEY);
const db = new TablesDB(client);
const storage = new Storage(client);

async function ensure(label, fn) {
  try {
    await fn();
    console.log(`created  ${label}`);
  } catch (e) {
    if (e?.code === 409) console.log(`exists   ${label}`);
    else throw e;
  }
}

await ensure(`database ${databaseId}`, () => db.create({ databaseId, name: 'brain' }));

// No permissions and no row security: clients can't touch it; only server keys can.
await ensure(`table ${tableId}`, () =>
  db.createTable({ databaseId, tableId, name: 'shared', permissions: [], rowSecurity: false }),
);

const base = { databaseId, tableId };
await ensure('column content (mediumtext)', () =>
  db.createMediumtextColumn({ ...base, key: 'content', required: false, xdefault: '' }),
);
await ensure('column version (integer)', () =>
  db.createIntegerColumn({ ...base, key: 'version', required: false, min: 0, xdefault: 0 }),
);
await ensure('column updatedAt (datetime)', () =>
  db.createDatetimeColumn({ ...base, key: 'updatedAt', required: false }),
);
await ensure('column deviceId (varchar 128)', () =>
  db.createVarcharColumn({ ...base, key: 'deviceId', size: 128, required: false, xdefault: '' }),
);

// Columns are created asynchronously; wait until all are available.
for (let i = 0; i < 30; i++) {
  const { columns } = await db.listColumns(base);
  const pending = columns.filter((c) => c.status !== 'available');
  const failed = columns.filter((c) => c.status === 'failed');
  if (failed.length) throw new Error(`column(s) failed: ${failed.map((c) => c.key).join(', ')}`);
  if (!pending.length && columns.length >= 4) break;
  await new Promise((r) => setTimeout(r, 1000));
}

await ensure('row shared', () =>
  db.createRow({
    ...base,
    rowId: 'shared',
    data: { content: '', version: 0, updatedAt: new Date().toISOString(), deviceId: '' },
  }),
);

// Attachments bucket (Shared/assets in the vault). No permissions and no file
// security: clients can't touch it; only the function (server key) can.
await ensure(`bucket ${bucketId}`, () =>
  storage.createBucket({
    bucketId,
    name: 'assets',
    permissions: [],
    fileSecurity: false,
    enabled: true,
    maximumFileSize: maxAssetBytes,
    compression: 'none',
    encryption: false,
    antivirus: false,
  }),
);

console.log('done');
