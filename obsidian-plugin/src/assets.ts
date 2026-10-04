// Pure attachment-sync decisions (no Obsidian imports) so they can be unit-tested in Node.
//
// The vault folder (default Shared/assets) and the Appwrite bucket are kept equal.
// `manifest` remembers what both sides looked like at the last successful sync, which
// is how we tell "deleted on one side" from "never existed" and "changed" from "same".

export const MAX_ASSET_BYTES_FALLBACK = 10 * 1024 * 1024;

/** One file as listed by the server. */
export interface ServerAsset {
	name: string;
	size: number;
	/** Changes whenever the file is replaced. */
	updatedAt: string | null;
}

/** One file in the vault folder. */
export interface LocalAsset {
	name: string;
	hash: string;
}

/** What both sides agreed on after the last sync of this file. */
export interface AssetRecord {
	hash: string;
	size: number;
	updatedAt: string | null;
}

export type AssetManifest = Record<string, AssetRecord>;

export type AssetAction =
	/** New or changed on the server only. */
	| { type: "download"; name: string }
	/** New locally (create) or changed locally (overwrite). */
	| { type: "upload"; name: string; overwrite: boolean }
	/** Deleted on the server, untouched locally. */
	| { type: "deleteLocal"; name: string }
	/** Deleted locally, untouched on the server. */
	| { type: "deleteRemote"; name: string }
	/**
	 * Both sides have it and we can't tell from metadata whether the bytes match
	 * (first sync, or both changed). Download, compare, and keep both if they differ.
	 */
	| { type: "reconcile"; name: string }
	/** Gone on both sides: drop the manifest entry. */
	| { type: "forget"; name: string };

export interface PlanInput {
	manifest: AssetManifest;
	server: ServerAsset[];
	local: LocalAsset[];
}

export function planAssetSync({ manifest, server, local }: PlanInput): AssetAction[] {
	const srv = new Map(server.map((a) => [a.name, a]));
	const loc = new Map(local.map((a) => [a.name, a]));
	const names = new Set([...Object.keys(manifest), ...srv.keys(), ...loc.keys()]);
	const actions: AssetAction[] = [];

	for (const name of [...names].sort()) {
		const rec = manifest[name];
		const s = srv.get(name);
		const l = loc.get(name);

		const localChanged = l !== undefined && (rec === undefined || l.hash !== rec.hash);
		const serverChanged =
			s !== undefined && (rec === undefined || s.updatedAt !== rec.updatedAt || s.size !== rec.size);

		if (s && l) {
			if (rec === undefined || (serverChanged && localChanged)) {
				// Same name on both sides with no common history, or edited on both.
				// A server file with the same size and our recorded hash can't be told apart
				// without the bytes, so compare them.
				actions.push({ type: "reconcile", name });
			} else if (serverChanged) {
				actions.push({ type: "download", name });
			} else if (localChanged) {
				actions.push({ type: "upload", name, overwrite: true });
			}
		} else if (s && !l) {
			if (rec === undefined || serverChanged) {
				// New on the server, or changed there after we deleted it locally: keep it.
				actions.push({ type: "download", name });
			} else {
				actions.push({ type: "deleteRemote", name });
			}
		} else if (!s && l) {
			if (rec === undefined || localChanged) {
				// New locally, or edited locally after the server deleted it: keep it.
				actions.push({ type: "upload", name, overwrite: false });
			} else {
				actions.push({ type: "deleteLocal", name });
			}
		} else if (rec !== undefined) {
			actions.push({ type: "forget", name });
		}
	}
	return actions;
}

/**
 * `photo.png` -> `photo (conflict 2026-10-04).png`, then `... (2).png` if that exists.
 * `exists` reports whether a name is already taken in the vault folder.
 */
export function conflictName(name: string, date: string, exists: (n: string) => boolean): string {
	const dot = name.lastIndexOf(".");
	const stem = dot > 0 ? name.slice(0, dot) : name;
	const ext = dot > 0 ? name.slice(dot) : "";
	let candidate = `${stem} (conflict ${date})${ext}`;
	for (let i = 2; exists(candidate); i++) candidate = `${stem} (conflict ${date}) (${i})${ext}`;
	return candidate;
}

/** The characters the server (and wikilinks) don't allow in an attachment name. */
export function invalidAssetName(name: string): boolean {
	return (
		name.length === 0 ||
		name.length > 200 ||
		name !== name.trim() ||
		name.startsWith(".") ||
		name.endsWith(".") ||
		// eslint-disable-next-line no-control-regex
		/[\u0000-\u001f\u007f/\\:*?"<>|#^[\]]/.test(name)
	);
}

/** Default attachments folder: `assets` next to the note. `Shared/shared.md` -> `Shared/assets`. */
export function defaultAssetsFolder(target: string): string {
	const slash = target.lastIndexOf("/");
	return slash < 0 ? "assets" : `${target.slice(0, slash)}/assets`;
}

export async function sha256Bytes(bytes: ArrayBuffer): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", bytes);
	return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * `Pasted image.png` -> `Pasted image (2).png` until `exists` says the name is free.
 * Used when a file the note embeds is moved into the attachments folder.
 */
export function uniqueAssetName(name: string, exists: (n: string) => boolean): string {
	if (!exists(name)) return name;
	const dot = name.lastIndexOf(".");
	const stem = dot > 0 ? name.slice(0, dot) : name;
	const ext = dot > 0 ? name.slice(dot) : "";
	for (let i = 2; ; i++) {
		const candidate = `${stem} (${i})${ext}`;
		if (!exists(candidate)) return candidate;
	}
}
