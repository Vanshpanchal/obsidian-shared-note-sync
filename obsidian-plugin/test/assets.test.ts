import { test } from "node:test";
import assert from "node:assert/strict";
import {
	conflictName,
	defaultAssetsFolder,
	invalidAssetName,
	planAssetSync,
	uniqueAssetName,
	type AssetManifest,
	type LocalAsset,
	type ServerAsset,
} from "../src/assets.ts";

const srv = (name: string, updatedAt = "t1", size = 10): ServerAsset => ({ name, size, updatedAt });
const loc = (name: string, hash = "h1"): LocalAsset => ({ name, hash });
const rec = (hash = "h1", updatedAt = "t1", size = 10) => ({ hash, updatedAt, size });
const plan = (manifest: AssetManifest, server: ServerAsset[], local: LocalAsset[]) =>
	planAssetSync({ manifest, server, local });

test("nothing to do when all three agree", () => {
	assert.deepEqual(plan({ "a.png": rec() }, [srv("a.png")], [loc("a.png")]), []);
});

test("new on the server is downloaded; new locally is uploaded without overwrite", () => {
	assert.deepEqual(plan({}, [srv("a.png")], []), [{ type: "download", name: "a.png" }]);
	assert.deepEqual(plan({}, [], [loc("b.png")]), [{ type: "upload", name: "b.png", overwrite: false }]);
});

test("changed on the server only is downloaded; changed locally only is uploaded (overwrite)", () => {
	assert.deepEqual(plan({ "a.png": rec() }, [srv("a.png", "t2")], [loc("a.png")]), [
		{ type: "download", name: "a.png" },
	]);
	assert.deepEqual(plan({ "a.png": rec() }, [srv("a.png")], [loc("a.png", "h2")]), [
		{ type: "upload", name: "a.png", overwrite: true },
	]);
});

test("size change alone counts as a server change", () => {
	assert.deepEqual(plan({ "a.png": rec() }, [srv("a.png", "t1", 99)], [loc("a.png")]), [
		{ type: "download", name: "a.png" },
	]);
});

test("changed on both sides, or same name with no history: reconcile (compare bytes)", () => {
	assert.deepEqual(plan({ "a.png": rec() }, [srv("a.png", "t2")], [loc("a.png", "h2")]), [
		{ type: "reconcile", name: "a.png" },
	]);
	assert.deepEqual(plan({}, [srv("a.png")], [loc("a.png")]), [{ type: "reconcile", name: "a.png" }]);
});

test("deleted locally and untouched on the server: delete remotely", () => {
	assert.deepEqual(plan({ "a.png": rec() }, [srv("a.png")], []), [{ type: "deleteRemote", name: "a.png" }]);
});

test("deleted on the server and untouched locally: delete locally", () => {
	assert.deepEqual(plan({ "a.png": rec() }, [], [loc("a.png")]), [{ type: "deleteLocal", name: "a.png" }]);
});

test("a delete never wins over an edit made on the other side", () => {
	// Deleted locally, but replaced on the server since: bring it back.
	assert.deepEqual(plan({ "a.png": rec() }, [srv("a.png", "t2")], []), [{ type: "download", name: "a.png" }]);
	// Deleted on the server, but edited locally since: upload the edit.
	assert.deepEqual(plan({ "a.png": rec() }, [], [loc("a.png", "h2")]), [
		{ type: "upload", name: "a.png", overwrite: false },
	]);
});

test("gone everywhere: forget the manifest entry", () => {
	assert.deepEqual(plan({ "a.png": rec() }, [], []), [{ type: "forget", name: "a.png" }]);
});

test("actions come out sorted by name and cover independent files", () => {
	const actions = plan(
		{ "b.png": rec() },
		[srv("c.png"), srv("b.png")],
		[loc("a.png"), loc("b.png")],
	);
	assert.deepEqual(actions, [
		{ type: "upload", name: "a.png", overwrite: false },
		{ type: "download", name: "c.png" },
	]);
});

test("conflictName avoids existing names", () => {
	const taken = new Set(["photo (conflict 2026-10-04).png"]);
	assert.equal(conflictName("photo.png", "2026-10-04", (n) => taken.has(n)), "photo (conflict 2026-10-04) (2).png");
	assert.equal(conflictName("noext", "2026-10-04", () => false), "noext (conflict 2026-10-04)");
});

test("invalidAssetName mirrors the server rules", () => {
	for (const n of ["", "a/b.png", ".x", "x.", "a#b", "a^b", "a[b]", "a|b", " a.png", "a:b"]) {
		assert.equal(invalidAssetName(n), true, n);
	}
	for (const n of ["photo.png", "Pasted image 2026.png", "નમસ્તે 🙏.pdf", "a (1).png"]) {
		assert.equal(invalidAssetName(n), false, n);
	}
});

test("defaultAssetsFolder sits next to the note", () => {
	assert.equal(defaultAssetsFolder("Shared/shared.md"), "Shared/assets");
	assert.equal(defaultAssetsFolder("shared.md"), "assets");
	assert.equal(defaultAssetsFolder("a/b/c.md"), "a/b/assets");
});

test("uniqueAssetName keeps a free name and numbers a taken one", () => {
	assert.equal(uniqueAssetName("a.png", () => false), "a.png");
	const taken = new Set(["a.png", "a (2).png"]);
	assert.equal(uniqueAssetName("a.png", (n) => taken.has(n)), "a (3).png");
	assert.equal(uniqueAssetName("noext", (n) => n === "noext"), "noext (2)");
});
