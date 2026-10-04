import { Client, Query, Storage, TablesDB } from 'node-appwrite';
// InputFile is not exported from the package root in node-appwrite 29.
import { InputFile } from 'node-appwrite/file';
import { createHandler } from './handler.js';

// Appwrite Functions entrypoint (Node.js runtime).
export default async (context) => {
  const { req } = context;
  const env = process.env;

  // Prefer an explicit key with databases read/write scopes. Fall back to the
  // per-execution dynamic key Appwrite injects (scopes set in function settings).
  const apiKey = env.APPWRITE_API_KEY || req.headers['x-appwrite-key'];

  const client = new Client()
    .setEndpoint(env.APPWRITE_ENDPOINT || env.APPWRITE_FUNCTION_API_ENDPOINT)
    .setProject(env.APPWRITE_PROJECT_ID || env.APPWRITE_FUNCTION_PROJECT_ID)
    .setKey(apiKey);

  const bucketId = env.BUCKET_ID || 'assets';
  const storageApi = new Storage(client);
  const storage = {
    async list() {
      const files = [];
      for (let offset = 0; ; offset += 100) {
        const page = await storageApi.listFiles({
          bucketId,
          queries: [Query.limit(100), Query.offset(offset)],
          total: false,
        });
        files.push(...page.files);
        if (page.files.length < 100) return files;
      }
    },
    get: (id) => storageApi.getFile({ bucketId, fileId: id }),
    create: (id, name, buffer) =>
      storageApi.createFile({ bucketId, fileId: id, file: InputFile.fromBuffer(buffer, name) }),
    download: async (id) => Buffer.from(await storageApi.getFileDownload({ bucketId, fileId: id })),
    remove: (id) => storageApi.deleteFile({ bucketId, fileId: id }),
  };

  const handle = createHandler({
    storage,
    maxAssetBytes: Number(env.ASSET_MAX_BYTES) || undefined,
    db: new TablesDB(client),
    databaseId: env.DATABASE_ID || 'brain',
    tableId: env.COLLECTION_ID || 'shared',
    sharedApiKey: env.SHARED_API_KEY,
  });

  return handle(context);
};
