import { test } from "node:test";
import assert from "node:assert/strict";
import { conflictPath, decidePull, EMPTY_HASH, normalize, sha256 } from "../src/sync.ts";

const H = (s: string) => sha256(s);

test("EMPTY_HASH matches sha256('')", async () => {
	assert.equal(await H(""), EMPTY_HASH);
});

test("hash ignores CRLF vs LF", async () => {
	assert.equal(await H("a\r\nb"), await H("a\nb"));
	assert.equal(normalize("a\r\nb\rc"), "a\nb\nc");
});

test("decidePull table", async () => {
	const a = await H("a");
	const b = await H("b");
	const c = await H("c");
	const cases: [string, Parameters<typeof decidePull>[0], string][] = [
		["in sync", { serverVersion: 3, serverHash: a, lastVersion: 3, lastSyncedHash: a, localHash: a }, "noop"],
		["local edit, server same", { serverVersion: 3, serverHash: a, lastVersion: 3, lastSyncedHash: a, localHash: b }, "push"],
		["server newer, local clean", { serverVersion: 4, serverHash: b, lastVersion: 3, lastSyncedHash: a, localHash: a }, "adopt"],
		["server newer, local dirty", { serverVersion: 4, serverHash: b, lastVersion: 3, lastSyncedHash: a, localHash: c }, "conflict"],
		["server newer, same edit", { serverVersion: 4, serverHash: b, lastVersion: 3, lastSyncedHash: a, localHash: b }, "markSynced"],
		["file missing", { serverVersion: 4, serverHash: b, lastVersion: 3, lastSyncedHash: a, localHash: null }, "adopt"],
		["first sync, equal", { serverVersion: 2, serverHash: a, lastVersion: 0, lastSyncedHash: "", localHash: a }, "markSynced"],
		["first sync, local empty", { serverVersion: 2, serverHash: a, lastVersion: 0, lastSyncedHash: "", localHash: EMPTY_HASH }, "adopt"],
		["first sync, server empty", { serverVersion: 0, serverHash: EMPTY_HASH, lastVersion: 0, lastSyncedHash: "", localHash: a }, "push"],
		["first sync, both differ", { serverVersion: 2, serverHash: a, lastVersion: 0, lastSyncedHash: "", localHash: b }, "conflict"],
		["server reset to lower version, local clean", { serverVersion: 0, serverHash: EMPTY_HASH, lastVersion: 5, lastSyncedHash: a, localHash: a }, "adopt"],
	];
	for (const [name, input, expected] of cases) {
		assert.equal(decidePull(input), expected, name);
	}
});

test("conflictPath", () => {
	assert.equal(conflictPath("Shared/shared.md"), "Shared/shared.conflict.md");
	assert.equal(conflictPath("notes"), "notes.conflict.md");
});
