import { createHash, timingSafeEqual } from 'node:crypto';

export const ROW_ID = 'shared';
export const MAX_CONTENT_BYTES = 1024 * 1024; // 1 MB of UTF-8
export const DEFAULT_MAX_ASSET_BYTES = 10 * 1024 * 1024; // 10 MB per attachment

/**
 * Pure request handler. `db` is a TablesDB-like object, injected so the
 * logic can be tested without a live Appwrite server.
 */
export function createHandler({
  db,
  databaseId,
  tableId,
  sharedApiKey,
  storage,
  maxAssetBytes = DEFAULT_MAX_ASSET_BYTES,
}) {
  const ids = { databaseId, tableId, rowId: ROW_ID };

  async function readRow() {
    try {
      return await db.getRow(ids);
    } catch (e) {
      if (e?.code !== 404) throw e;
    }
    try {
      return await db.createRow({
        ...ids,
        data: { content: '', version: 0, updatedAt: new Date().toISOString(), deviceId: '' },
      });
    } catch (e) {
      // Another request created it first.
      if (e?.code === 409) return db.getRow(ids);
      throw e;
    }
  }

  const state = (row) => ({
    content: row.content ?? '',
    version: row.version ?? 0,
    updatedAt: row.updatedAt ?? null,
  });

  /**
   * Atomically moves version from `expected` to `expected + 1`.
   * incrementRowColumn with `max` refuses to go past the bound, so of two
   * concurrent saves with the same base only one can claim the next version.
   * Returns false if someone else got there first.
   */
  async function claimVersion(expected) {
    let row;
    try {
      row = await db.incrementRowColumn({ ...ids, column: 'version', value: 1, max: expected + 1 });
    } catch (e) {
      if (e?.code === 400 || e?.code === 409) {
        const current = await db.getRow(ids);
        if (current.version !== expected) return false;
      }
      throw e;
    }
    if (row.version !== expected + 1) {
      // Defensive: the bound was not enforced as expected. Undo and treat as conflict.
      await db.decrementRowColumn({ ...ids, column: 'version', value: 1, min: expected }).catch(() => {});
      return false;
    }
    return true;
  }

  async function handleGet(res) {
    return res.json(state(await readRow()), 200);
  }

  async function handlePost(req, res) {
    const body = parseBody(req);
    if (body.error) return res.json({ error: body.error }, body.status);
    const { content, baseVersion, deviceId } = body;
    const force = String(req.query?.force ?? '').toLowerCase() === 'true';

    // A forced save still goes through claimVersion, retrying if the version moves.
    for (let attempt = 0; attempt < 3; attempt++) {
      const current = await readRow();
      if (!force && baseVersion !== current.version) {
        return res.json(state(current), 409);
      }
      const expected = current.version;
      if (!(await claimVersion(expected))) {
        if (force) continue;
        return res.json(state(await db.getRow(ids)), 409);
      }

      const updatedAt = new Date().toISOString();
      try {
        await db.updateRow({ ...ids, data: { content, updatedAt, deviceId } });
      } catch (e) {
        await db
          .decrementRowColumn({ ...ids, column: 'version', value: 1, min: expected })
          .catch(() => {});
        throw e;
      }
      return res.json({ version: expected + 1, updatedAt }, 200);
    }
    return res.json(state(await db.getRow(ids)), 409);
  }

  // ------------------------------------------------------------ attachments
  //
  // Files live in an Appwrite Storage bucket. `storage` is a small adapter
  // (see main.js) so this logic can be tested without a live server:
  //   list() -> File[]   get(id) -> File   create(id, name, buffer)
  //   download(id) -> Buffer   remove(id)
  // File ids are derived from the lower-cased name, so "A.png" and "a.png" are
  // the same attachment (vaults on macOS/Windows are case-insensitive).

  const assetJson = (f) => ({
    name: f.name,
    size: f.sizeOriginal ?? 0,
    mimeType: f.mimeType ?? 'application/octet-stream',
    createdAt: f.$createdAt ?? null,
    updatedAt: f.$updatedAt ?? null,
  });

  async function findAsset(name) {
    try {
      return await storage.get(assetId(name));
    } catch (e) {
      if (e?.code === 404) return null;
      throw e;
    }
  }

  async function handleAssets(req, res, route) {
    if (!storage) return res.json({ error: 'attachments_not_configured' }, 501);
    const method = req.method;

    if (route === 'list') {
      if (method !== 'GET') return res.json({ error: 'method_not_allowed' }, 405);
      const files = await storage.list();
      files.sort((a, b) => a.name.localeCompare(b.name));
      return res.json({ files: files.map(assetJson), maxBytes: maxAssetBytes }, 200);
    }

    // route === 'file': ?name=<file name>
    const name = String(req.query?.name ?? '');
    const bad = validateAssetName(name);
    if (bad) return res.json({ error: bad }, 400);

    if (method === 'GET') {
      const file = await findAsset(name);
      if (!file) return res.json({ error: 'not_found' }, 404);
      const bytes = await storage.download(file.$id);
      // The size header lets clients detect a truncated body instead of saving it.
      return res.binary(bytes, 200, {
        'content-type': file.mimeType || 'application/octet-stream',
        'x-asset-size': String(file.sizeOriginal ?? bytes.length),
        'x-asset-name': encodeURIComponent(file.name),
        'cache-control': 'private, max-age=0',
      });
    }

    if (method === 'DELETE') {
      const file = await findAsset(name);
      if (!file) return res.json({ error: 'not_found' }, 404);
      await storage.remove(file.$id);
      return res.json({ deleted: file.name }, 200);
    }

    if (method === 'POST') {
      const overwrite = String(req.query?.overwrite ?? '').toLowerCase() === 'true';
      const bytes = toBuffer(req);
      if (bytes.length === 0) return res.json({ error: 'empty_file' }, 400);
      if (bytes.length > maxAssetBytes) {
        return res.json({ error: 'payload_too_large', maxBytes: maxAssetBytes }, 413);
      }
      const existing = await findAsset(name);
      if (existing && !overwrite) {
        return res.json({ error: 'exists', file: assetJson(existing) }, 409);
      }
      // Replace = delete then create; a failure in between loses only the old copy,
      // and the caller (which still has the bytes) can simply retry.
      if (existing) await storage.remove(existing.$id);
      const created = await storage.create(assetId(name), name, bytes);
      return res.json(assetJson(created), existing ? 200 : 201);
    }

    return res.json({ error: 'method_not_allowed' }, 405);
  }

  return async function handle({ req, res, error }) {
    if (!isAuthorized(header(req, 'x-api-key'), sharedApiKey)) {
      return res.json({ error: 'unauthorized' }, 401);
    }

    const path = (req.path || '/').replace(/\/+$/, '') || '/';
    if (path === '/assets' || path === '/assets/file') {
      try {
        return await handleAssets(req, res, path === '/assets' ? 'list' : 'file');
      } catch (e) {
        error(`shared-api assets ${req.method} failed: code=${e?.code ?? '?'} type=${e?.type ?? e?.name ?? '?'}`);
        return res.json({ error: 'internal_error' }, 500);
      }
    }
    if (path !== '/shared') return res.json({ error: 'not_found' }, 404);

    try {
      if (req.method === 'GET') return await handleGet(res);
      if (req.method === 'POST') return await handlePost(req, res);
      return res.json({ error: 'method_not_allowed' }, 405);
    } catch (e) {
      // Never log content or keys: only the error code/type.
      error(`shared-api ${req.method} failed: code=${e?.code ?? '?'} type=${e?.type ?? e?.name ?? '?'}`);
      return res.json({ error: 'internal_error' }, 500);
    }
  };
}

function header(req, name) {
  const headers = req.headers ?? {};
  if (name in headers) return headers[name];
  const key = Object.keys(headers).find((k) => k.toLowerCase() === name);
  return key ? headers[key] : undefined;
}

export function isAuthorized(provided, expected) {
  if (typeof provided !== 'string' || typeof expected !== 'string' || expected.length === 0) {
    return false;
  }
  // Hash both sides so lengths match and timingSafeEqual can be used.
  const a = createHash('sha256').update(provided).digest();
  const b = createHash('sha256').update(expected).digest();
  return timingSafeEqual(a, b);
}

function parseBody(req) {
  const raw = req.bodyText ?? '';
  if (Buffer.byteLength(raw, 'utf8') > MAX_CONTENT_BYTES + 64 * 1024) {
    return { error: 'payload_too_large', status: 413 };
  }
  let json;
  try {
    json = raw ? JSON.parse(raw) : null;
  } catch {
    return { error: 'invalid_json', status: 400 };
  }
  if (!json || typeof json !== 'object') return { error: 'invalid_body', status: 400 };

  const { content, baseVersion, deviceId } = json;
  if (typeof content !== 'string') return { error: 'content_must_be_string', status: 400 };
  if (!Number.isInteger(baseVersion) || baseVersion < 0) {
    return { error: 'baseVersion_must_be_integer', status: 400 };
  }
  if (deviceId !== undefined && (typeof deviceId !== 'string' || deviceId.length > 128)) {
    return { error: 'invalid_deviceId', status: 400 };
  }

  const normalized = content.replace(/\r\n?/g, '\n');
  if (Buffer.byteLength(normalized, 'utf8') > MAX_CONTENT_BYTES) {
    return { error: 'payload_too_large', status: 413 };
  }
  return { content: normalized, baseVersion, deviceId: deviceId ?? '' };
}

/** Stable Appwrite file id for an attachment name (<= 36 chars, starts alphanumeric). */
export function assetId(name) {
  const digest = createHash('sha256').update(name.normalize('NFC').toLowerCase()).digest('hex');
  return `a${digest.slice(0, 35)}`;
}

/**
 * Attachment names are plain file names: no folders, no characters Obsidian or
 * the OS reject, no characters that break `[[wikilinks]]` (`# ^ [ ] |`).
 * Returns an error code, or null if the name is fine.
 */
export function validateAssetName(name) {
  if (typeof name !== 'string' || name.length === 0) return 'name_required';
  if (name.length > 200) return 'name_too_long';
  if (name !== name.trim() || name.startsWith('.') || name.endsWith('.')) return 'invalid_name';
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f/\\:*?"<>|#^[\]]/.test(name)) return 'invalid_name';
  return null;
}

function toBuffer(req) {
  if (Buffer.isBuffer(req.bodyBinary)) return req.bodyBinary;
  if (req.bodyBinary instanceof Uint8Array) return Buffer.from(req.bodyBinary);
  return Buffer.from(req.bodyText ?? '', 'utf8');
}
