# VaultBridge backend

An [Appwrite](https://appwrite.io) Function (Node.js 22) in front of one database row
(the note) and one storage bucket (the attachments).

```
functions/shared-api/   the function: src/handler.js (logic), src/main.js (Appwrite wiring)
scripts/setup-db.mjs    creates database, table, columns, row and bucket (safe to re-run)
scripts/acceptance.sh   live curl tests against a deployed function
scripts/package-function.sh   builds shared-api.tar.gz for "upload code" in the Console
.env.example            every variable, with comments
```

Full deployment steps are in the [main README](../README.md#1-deploy-the-backend).

## Tests

```sh
cd functions/shared-api && npm ci && npm test      # unit tests against in-memory fakes
cp .env.example .env                               # fill in SHARED_URL and SHARED_API_KEY
./scripts/acceptance.sh                            # live tests (needs jq)
```

The acceptance script saves the current note first and restores it at the end. It
uploads and deletes throw-away `acceptance-*.bin` files.
