// Pure sync decisions (no Obsidian imports) so they can be unit-tested in Node.

export const MAX_CONTENT_BYTES = 1024 * 1024;

export interface ServerState {
	content: string;
	version: number;
	updatedAt: string | null;
}

export function normalize(text: string): string {
	return text.replace(/\r\n?/g, "\n");
}

export async function sha256(text: string): Promise<string> {
	const bytes = new TextEncoder().encode(normalize(text));
	const digest = await crypto.subtle.digest("SHA-256", bytes);
	return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

export function byteLength(text: string): number {
	return new TextEncoder().encode(text).length;
}

export type PullAction =
	/** Nothing to do. */
	| "noop"
	/** Server unchanged, local has edits: push them. */
	| "push"
	/** Server newer, no local edits: overwrite the local file. */
	| "adopt"
	/** Server newer but identical to local: just record the new version. */
	| "markSynced"
	/** Server newer and local has different unsynced edits. */
	| "conflict";

export interface PullInput {
	serverVersion: number;
	serverHash: string;
	lastVersion: number;
	/** Hash of the content at the last successful sync; "" if never synced. */
	lastSyncedHash: string;
	/** Hash of the local file, or null if it doesn't exist. */
	localHash: string | null;
}

export function decidePull(i: PullInput): PullAction {
	// A missing file has no edits worth protecting; recreate it from the server.
	if (i.localHash === null) return "adopt";

	const localDirty = i.localHash !== i.lastSyncedHash;

	if (i.localHash === i.serverHash) {
		return i.serverVersion === i.lastVersion && !localDirty ? "noop" : "markSynced";
	}
	if (i.serverVersion === i.lastVersion && i.lastSyncedHash !== "") {
		return localDirty ? "push" : "noop";
	}
	// Server moved (or we have never synced and contents differ).
	if (!localDirty) return "adopt";
	// Never synced and the local file is empty: nothing to lose.
	if (i.lastSyncedHash === "" && i.localHash === EMPTY_HASH) return "adopt";
	// Never synced and the server is empty: seed the server from the vault.
	if (i.lastSyncedHash === "" && i.serverHash === EMPTY_HASH) return "push";
	return "conflict";
}

/** sha256("") */
export const EMPTY_HASH = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/** `Shared/shared.md` -> `Shared/shared.conflict.md` */
export function conflictPath(target: string): string {
	return target.toLowerCase().endsWith(".md")
		? `${target.slice(0, -3)}.conflict.md`
		: `${target}.conflict.md`;
}
