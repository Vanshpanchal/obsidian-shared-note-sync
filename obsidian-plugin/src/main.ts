import {
	App,
	debounce,
	getLinkpath,
	normalizePath,
	Notice,
	Plugin,
	PluginSettingTab,
	requestUrl,
	SecretComponent,
	Setting,
	TFile,
	TFolder,
	type RequestUrlResponse,
} from "obsidian";
import {
	conflictName,
	defaultAssetsFolder,
	invalidAssetName,
	MAX_ASSET_BYTES_FALLBACK,
	planAssetSync,
	sha256Bytes,
	uniqueAssetName,
	type AssetManifest,
	type LocalAsset,
	type ServerAsset,
} from "./assets";
import {
	byteLength,
	conflictPath,
	decidePull,
	MAX_CONTENT_BYTES,
	normalize,
	type ServerState,
	sha256,
} from "./sync";

interface SharedSyncData {
	endpoint: string;
	/** Name of the entry in Obsidian's secret storage that holds the API key. */
	apiKeySecret: string;
	targetPath: string;
	autoPullMinutes: number;
	deviceId: string;
	// Sync state
	lastVersion: number;
	lastSyncedHash: string;
	/** Server version written to the conflict file; set while a conflict is open. */
	conflictVersion: number | null;
	// Attachments (Shared/assets <-> Appwrite bucket)
	assetsEnabled: boolean;
	/** Move files the shared note embeds into the attachments folder so they sync. */
	adoptAttachments: boolean;
	assetsFolder: string;
	/** What both sides looked like after the last sync of each file. */
	assetManifest: AssetManifest;
	/** Local hash cache keyed by file name, valid while mtime and size match. */
	assetHashCache: Record<string, { mtime: number; size: number; hash: string }>;
}

const DEFAULTS: SharedSyncData = {
	endpoint: "",
	apiKeySecret: "",
	targetPath: "Shared/shared.md",
	autoPullMinutes: 5,
	deviceId: "",
	lastVersion: 0,
	lastSyncedHash: "",
	conflictVersion: null,
	assetsEnabled: true,
	adoptAttachments: true,
	assetsFolder: "Shared/assets",
	assetManifest: {},
	assetHashCache: {},
};

type Status = "idle" | "syncing" | "offline" | "conflict" | "error";

class HttpError extends Error {
	constructor(readonly status: number, message: string) {
		super(message);
	}
}

export default class SharedSyncPlugin extends Plugin {
	data: SharedSyncData = { ...DEFAULTS };
	private statusEl: HTMLElement | null = null;
	private queue: Promise<unknown> = Promise.resolve();
	/** True while the plugin itself writes the target file (loop prevention). */
	private writing = false;
	private pullTimer: number | null = null;
	/** >0 while the plugin itself writes attachment files (loop prevention). */
	private assetWrites = 0;
	/** Names already reported as skipped, so a bad file doesn't notify on every sync. */
	private assetSkipped = new Set<string>();
	/** One line for the settings tab: what the last attachment sync did. */
	assetStatus = "not synced yet";

	private readonly debouncedPush = debounce(() => void this.push(false), 3000, true);
	/** Pull shortly after the endpoint or key is changed in settings. */
	readonly debouncedPull = debounce(() => void this.pull(true), 1500, true);
	private readonly debouncedAssets = debounce(() => void this.syncAssets(false), 3000, true);

	async onload() {
		this.data = Object.assign({}, DEFAULTS, await this.loadData());
		if (!this.data.deviceId) {
			this.data.deviceId = `obsidian-${crypto.randomUUID()}`;
			await this.saveData(this.data);
		}

		this.statusEl = this.addStatusBarItem();
		this.setStatus(this.data.conflictVersion !== null ? "conflict" : "idle");
		this.addSettingTab(new SharedSyncSettingTab(this.app, this));

		this.addCommand({ id: "pull", name: "Pull shared.md", callback: () => void this.pull(true) });
		this.addCommand({
			id: "sync-assets",
			name: "Sync attachments now",
			callback: () => void this.syncAssets(true),
		});
		this.addCommand({ id: "push", name: "Push shared.md", callback: () => void this.push(true) });
		this.addCommand({
			id: "resolve-keep-mine",
			name: "Resolve conflict: keep my shared.md (push it)",
			checkCallback: (checking) => {
				if (this.data.conflictVersion === null) return false;
				if (!checking) void this.resolveKeepMine();
				return true;
			},
		});
		this.addCommand({
			id: "resolve-use-server",
			name: "Resolve conflict: use server copy",
			checkCallback: (checking) => {
				if (this.data.conflictVersion === null) return false;
				if (!checking) void this.resolveUseServer();
				return true;
			},
		});

		this.registerEvent(
			this.app.vault.on("modify", (file) => {
				if (this.writing || file.path !== this.target) return;
				this.debouncedPush();
				// New embeds may point at files outside the attachments folder.
				this.debouncedAssets();
			}),
		);
		// Attachments: any change inside the attachments folder schedules a sync.
		const touched = (path: string) => this.inAssetsFolder(path);
		const onChange = (file: { path: string }) => {
			if (this.assetWrites === 0 && touched(file.path)) this.debouncedAssets();
		};
		this.registerEvent(this.app.vault.on("create", onChange));
		this.registerEvent(this.app.vault.on("modify", onChange));
		this.registerEvent(this.app.vault.on("delete", onChange));
		this.registerEvent(
			this.app.vault.on("rename", (file, oldPath) => {
				if (this.assetWrites === 0 && (touched(file.path) || touched(oldPath))) this.debouncedAssets();
			}),
		);
		this.registerEvent(
			this.app.workspace.on("file-open", (file) => {
				if (file?.path === this.target) void this.pull(false);
			}),
		);

		this.app.workspace.onLayoutReady(() => void this.pull(false));
		this.restartAutoPull();
	}

	onunload() {
		// Flush a pending debounced push.
		this.debouncedPush.run();
	}

	get target(): string {
		return normalizePath(this.data.targetPath || DEFAULTS.targetPath);
	}

	private get apiKey(): string {
		return this.data.apiKeySecret ? (this.app.secretStorage.getSecret(this.data.apiKeySecret) ?? "") : "";
	}

	private get configured(): boolean {
		return this.data.endpoint !== "" && this.apiKey !== "";
	}

	restartAutoPull() {
		if (this.pullTimer !== null) window.clearInterval(this.pullTimer);
		this.pullTimer = null;
		const minutes = this.data.autoPullMinutes;
		if (minutes > 0) {
			this.pullTimer = window.setInterval(() => void this.pull(false), minutes * 60_000);
			this.registerInterval(this.pullTimer);
		}
	}

	async saveState() {
		await this.saveData(this.data);
	}

	/** Called when the target path changes: the new file has no sync history. */
	async resetSyncState() {
		this.data.lastVersion = 0;
		this.data.lastSyncedHash = "";
		this.data.conflictVersion = null;
		await this.saveState();
		this.setStatus("idle");
	}

	// ---------------------------------------------------------------- sync

	/** Runs sync operations one at a time. */
	private serial<T>(task: () => Promise<T>): Promise<T> {
		const next = this.queue.then(task, task);
		this.queue = next.catch(() => undefined);
		return next;
	}

	/** Pulls the note, then the attachments. */
	async pull(interactive: boolean): Promise<void> {
		await this.pullNote(interactive);
		await this.syncAssets(interactive);
	}

	private pullNote(interactive: boolean): Promise<void> {
		return this.serial(async () => {
			if (!this.ensureConfigured(interactive)) return;
			if (this.data.conflictVersion !== null) {
				if (interactive) new Notice("shared.md has an open conflict. Resolve it first (see command palette).");
				return;
			}
			try {
				this.setStatus("syncing");
				const server = await this.request<ServerState>("GET");
				const local = await this.readLocal();
				const action = decidePull({
					serverVersion: server.version,
					serverHash: await sha256(server.content),
					lastVersion: this.data.lastVersion,
					lastSyncedHash: this.data.lastSyncedHash,
					localHash: local === null ? null : await sha256(local),
				});

				switch (action) {
					case "noop":
						break;
					case "adopt":
						await this.writeLocal(server.content);
						await this.markSynced(server.version, server.content);
						if (interactive) new Notice(`shared.md updated (v${server.version})`);
						break;
					case "markSynced":
						await this.markSynced(server.version, server.content);
						break;
					case "push":
						// Server hasn't moved past what we're replacing.
						this.data.lastVersion = server.version;
						await this.doPush(local ?? "", false, interactive);
						return;
					case "conflict":
						await this.openConflict(server);
						return;
				}
				this.setStatus("idle");
				if (interactive && action !== "adopt") new Notice("shared.md is up to date");
			} catch (e) {
				this.handleError(e, interactive);
			}
		});
	}

	push(interactive: boolean): Promise<void> {
		return this.serial(async () => {
			if (!this.ensureConfigured(interactive)) return;
			if (this.data.conflictVersion !== null) {
				if (interactive) new Notice("shared.md has an open conflict. Resolve it first (see command palette).");
				return;
			}
			const local = await this.readLocal();
			if (local === null) {
				if (interactive) new Notice(`${this.target} does not exist`);
				return;
			}
			if ((await sha256(local)) === this.data.lastSyncedHash) {
				if (interactive) new Notice("shared.md: nothing to push");
				return;
			}
			try {
				await this.doPush(local, false, interactive);
			} catch (e) {
				this.handleError(e, interactive);
			}
		});
	}

	/** POSTs `local` with the current baseVersion. Caller holds the queue. */
	private async doPush(local: string, force: boolean, interactive: boolean) {
		const content = normalize(local);
		if (byteLength(content) > MAX_CONTENT_BYTES) {
			this.setStatus("error");
			new Notice("shared.md is larger than 1 MB and can't be synced.");
			return;
		}
		this.setStatus("syncing");
		try {
			const res = await this.request<{ version: number; updatedAt: string }>(
				"POST",
				{ content, baseVersion: this.data.lastVersion, deviceId: this.data.deviceId },
				force,
			);
			await this.markSynced(res.version, content);
			this.setStatus("idle");
			if (interactive) new Notice(`shared.md pushed (v${res.version})`);
		} catch (e) {
			if (e instanceof ConflictError) {
				await this.openConflict(e.server);
				return;
			}
			throw e;
		}
	}

	private async markSynced(version: number, content: string) {
		this.data.lastVersion = version;
		this.data.lastSyncedHash = await sha256(content);
		await this.saveState();
	}

	/** Writes the server copy next to the note so nothing is lost, and pauses auto-sync. */
	private async openConflict(server: ServerState) {
		const path = conflictPath(this.target);
		const header =
			`<!-- Server copy of ${this.target} (v${server.version}, ${server.updatedAt ?? "unknown time"}).\n` +
			`     Merge what you need into ${this.target}, then run\n` +
			`     "Resolve conflict: keep my shared.md" from the command palette. -->\n\n`;
		await this.writeFile(path, header + server.content);
		this.data.conflictVersion = server.version;
		await this.saveState();
		this.setStatus("conflict");
		new Notice(
			`shared.md conflict: it changed on another device. The server copy was saved to ${path}. ` +
				`Merge, then run "Resolve conflict" from the command palette.`,
			15000,
		);
	}

	private resolveKeepMine(): Promise<void> {
		return this.serial(async () => {
			const seen = this.data.conflictVersion;
			if (seen === null) return;
			const local = (await this.readLocal()) ?? "";
			// We've seen server version `seen` (it's in the conflict file). Push on top of
			// it without force: if the server moved again, we get a fresh conflict file.
			this.data.lastVersion = seen;
			this.data.conflictVersion = null;
			await this.saveState();
			try {
				await this.doPush(local, false, true);
			} catch (e) {
				this.data.conflictVersion = seen;
				await this.saveState();
				this.handleError(e, true);
				this.setStatus("conflict");
			}
		});
	}

	private async resolveUseServer(): Promise<void> {
		await this.serial(async () => {
			this.data.conflictVersion = null;
			// Forget local sync state so the pull adopts the server copy.
			this.data.lastSyncedHash = await sha256((await this.readLocal()) ?? "");
			this.data.lastVersion = -1;
			await this.saveState();
		});
		await this.pull(true);
	}

	// ---------------------------------------------------------------- I/O

	private async request<T>(method: "GET" | "POST", body?: unknown, force = false): Promise<T> {
		const base = this.data.endpoint.replace(/\/+$/, "").replace(/\/shared$/, "");
		let res;
		try {
			res = await requestUrl({
				url: `${base}/shared${force ? "?force=true" : ""}`,
				method,
				headers: { "x-api-key": this.apiKey },
				contentType: "application/json",
				body: body === undefined ? undefined : JSON.stringify(body),
				throw: false,
			});
		} catch (e) {
			throw new OfflineError(e);
		}
		if (res.status === 200) return res.json as T;
		if (res.status === 409) throw new ConflictError(res.json as ServerState);
		let message = `HTTP ${res.status}`;
		if (res.status === 401) message = "Invalid API key";
		else if (res.status === 413) message = "Document too large (max 1 MB)";
		else {
			try {
				message = (res.json as { error?: string }).error ?? message;
			} catch {
				// not JSON
			}
		}
		throw new HttpError(res.status, message);
	}

	private async readLocal(): Promise<string | null> {
		const file = this.app.vault.getFileByPath(this.target);
		return file ? this.app.vault.read(file) : null;
	}

	private writeLocal(content: string): Promise<void> {
		return this.writeFile(this.target, content);
	}

	private async writeFile(path: string, content: string) {
		this.writing = true;
		try {
			const existing = this.app.vault.getAbstractFileByPath(path);
			if (existing instanceof TFile) {
				await this.app.vault.process(existing, () => content);
			} else {
				const dir = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
				if (dir && !this.app.vault.getFolderByPath(dir)) {
					await this.app.vault.createFolder(dir).catch(() => undefined);
				}
				await this.app.vault.create(path, content);
			}
		} finally {
			// Modify events are dispatched asynchronously; keep the flag up briefly.
			// The hash check in push() is the real guard against echo pushes.
			window.setTimeout(() => (this.writing = false), 500);
		}
	}

	// ---------------------------------------------------------------- attachments

	get assetsPath(): string {
		return normalizePath(this.data.assetsFolder || defaultAssetsFolder(this.target));
	}

	private inAssetsFolder(path: string): boolean {
		const folder = this.assetsPath;
		const slash = path.lastIndexOf("/");
		return slash >= 0 && path.slice(0, slash) === folder;
	}

	private assetFile(name: string): TFile | null {
		return this.app.vault.getFileByPath(`${this.assetsPath}/${name}`);
	}

	/** Runs `fn` while our own writes to the attachments folder are in flight. */
	private async asOwnWrite<T>(fn: () => Promise<T>): Promise<T> {
		this.assetWrites++;
		try {
			return await fn();
		} finally {
			// Vault events arrive asynchronously; keep the guard up briefly.
			window.setTimeout(() => this.assetWrites--, 1000);
		}
	}

	/** Files directly inside the attachments folder, with hashes (cached by mtime+size). */
	private async listLocalAssets(): Promise<LocalAsset[]> {
		const folder = this.app.vault.getFolderByPath(this.assetsPath);
		if (!(folder instanceof TFolder)) return [];
		const out: LocalAsset[] = [];
		const seen = new Set<string>();
		for (const child of folder.children) {
			if (!(child instanceof TFile)) continue;
			if (invalidAssetName(child.name)) {
				this.skipOnce(child.name, `${child.name}: this name can't be synced (avoid # ^ [ ] | : / \\ ? * " < > and a leading or trailing dot).`);
				continue;
			}
			seen.add(child.name);
			const cached = this.data.assetHashCache[child.name];
			if (cached && cached.mtime === child.stat.mtime && cached.size === child.stat.size) {
				out.push({ name: child.name, hash: cached.hash });
				continue;
			}
			const hash = await sha256Bytes(await this.app.vault.readBinary(child));
			this.data.assetHashCache[child.name] = { mtime: child.stat.mtime, size: child.stat.size, hash };
			out.push({ name: child.name, hash });
		}
		for (const name of Object.keys(this.data.assetHashCache)) {
			if (!seen.has(name)) delete this.data.assetHashCache[name];
		}
		return out;
	}

	private skipOnce(key: string, message: string) {
		if (this.assetSkipped.has(key)) return;
		this.assetSkipped.add(key);
		new Notice(`Attachments: ${message}`, 10000);
	}

	/**
	 * Obsidian saves a pasted or attached file wherever "Default location for new
	 * attachments" says (often the vault root or the note's folder), not in our synced
	 * folder, so the app would never see it. Move every file the shared note embeds or
	 * links into the attachments folder; Obsidian rewrites the links itself.
	 */
	private async adoptAttachments(): Promise<void> {
		if (!this.data.adoptAttachments) return;
		const note = this.app.vault.getFileByPath(this.target);
		const cache = note ? this.app.metadataCache.getFileCache(note) : null;
		if (!note || !cache) return;
		const seen = new Set<string>();
		for (const ref of [...(cache.embeds ?? []), ...(cache.links ?? [])]) {
			const dest = this.app.metadataCache.getFirstLinkpathDest(getLinkpath(ref.link), note.path);
			if (!dest || dest.extension === "md" || seen.has(dest.path)) continue;
			seen.add(dest.path);
			if (this.inAssetsFolder(dest.path)) continue;
			// Names with # ^ [ ] | etc. can't be synced (they would break wikilinks).
			if (invalidAssetName(dest.name)) continue;
			try {
				if (!this.app.vault.getFolderByPath(this.assetsPath)) await this.ensureFolder(this.assetsPath);
				const name = uniqueAssetName(dest.name, (n) => this.assetFile(n) !== null);
				await this.asOwnWrite(() => this.app.fileManager.renameFile(dest, `${this.assetsPath}/${name}`));
			} catch (e) {
				const message = e instanceof Error ? e.message : String(e);
				this.skipOnce(`adopt:${dest.path}:${message}`, `Couldn't move ${dest.name} into ${this.assetsPath}: ${message}`);
			}
		}
	}

	/** Brings the attachments folder and the server bucket in line. */
	syncAssets(interactive: boolean): Promise<void> {
		return this.serial(async () => {
			if (!this.data.assetsEnabled || !this.configured) return;
			const counts = { down: 0, up: 0, removed: 0, conflicts: 0, failed: 0 };
			try {
				await this.adoptAttachments();
				const listing = await this.assetRequest<{ files: ServerAsset[]; maxBytes?: number }>("GET", "");
				const maxBytes = listing.maxBytes ?? MAX_ASSET_BYTES_FALLBACK;
				const server = listing.files;
				const serverByName = new Map(server.map((f) => [f.name, f]));
				const actions = planAssetSync({
					manifest: this.data.assetManifest,
					server,
					local: await this.listLocalAssets(),
				});

				for (const action of actions) {
					try {
						switch (action.type) {
							case "download":
								await this.assetDownload(serverByName.get(action.name)!);
								counts.down++;
								break;
							case "upload":
								if (await this.assetUpload(action.name, action.overwrite, maxBytes)) counts.up++;
								break;
							case "deleteLocal": {
								const file = this.assetFile(action.name);
								if (file) await this.asOwnWrite(() => this.app.fileManager.trashFile(file));
								delete this.data.assetManifest[action.name];
								counts.removed++;
								break;
							}
							case "deleteRemote":
								await this.assetRequest("DELETE", `/file?name=${encodeURIComponent(action.name)}`);
								delete this.data.assetManifest[action.name];
								counts.removed++;
								break;
							case "reconcile":
								if (await this.assetReconcile(serverByName.get(action.name)!, maxBytes)) counts.conflicts++;
								break;
							case "forget":
								delete this.data.assetManifest[action.name];
								break;
						}
					} catch (e) {
						if (e instanceof OfflineError) throw e;
						counts.failed++;
						const message = e instanceof Error ? e.message : String(e);
						this.skipOnce(`${action.type}:${action.name}:${message}`, `${action.name}: ${message}`);
					}
				}
				await this.saveState();

				const total = Object.keys(this.data.assetManifest).length;
				const time = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
				this.assetStatus = `${total} file${total === 1 ? "" : "s"} · synced ${time}` + (counts.failed ? ` · ${counts.failed} failed` : "");
				const changed = counts.down + counts.up + counts.removed + counts.conflicts;
				if (interactive || counts.conflicts > 0) {
					new Notice(
						changed === 0 && counts.failed === 0
							? "Attachments are up to date"
							: `Attachments: ${counts.down} downloaded, ${counts.up} uploaded, ${counts.removed} removed` +
									(counts.conflicts ? `, ${counts.conflicts} conflict(s) kept as copies` : ""),
					);
				}
			} catch (e) {
				if (e instanceof OfflineError) {
					this.assetStatus = "offline";
					if (interactive) new Notice("Attachments: offline, will retry on the next change or auto-pull.");
				} else {
					const message = e instanceof Error ? e.message : String(e);
					this.assetStatus = `error: ${message}`;
					if (interactive) new Notice(`Attachments sync failed: ${message}`);
				}
			}
		});
	}

	private async assetDownload(info: ServerAsset): Promise<void> {
		const bytes = await this.assetFetch(info);
		const hash = await this.writeAsset(info.name, bytes);
		this.data.assetManifest[info.name] = { hash, size: info.size, updatedAt: info.updatedAt };
	}

	/** GETs the bytes and refuses a body whose length differs from what the server says it has. */
	private async assetFetch(info: ServerAsset): Promise<ArrayBuffer> {
		let res: RequestUrlResponse;
		try {
			res = await this.assetRaw("GET", `/file?name=${encodeURIComponent(info.name)}`);
		} catch (e) {
			// Files the app uploaded before it encoded spaces as %20 are only reachable
			// with a raw "+" in the name.
			if (!(e instanceof HttpError) || e.status !== 404 || !info.name.includes("+")) throw e;
			res = await this.assetRaw("GET", `/file?name=${encodeURIComponent(info.name).replace(/%2B/g, "+")}`);
		}
		const bytes = res.arrayBuffer;
		const declared = Number(headerOf(res, "x-asset-size") ?? info.size);
		if (bytes.byteLength !== declared || bytes.byteLength !== info.size) {
			throw new Error(`download was cut short (${bytes.byteLength} of ${info.size} bytes)`);
		}
		return bytes;
	}

	/** Writes `bytes` as `name` in the attachments folder; returns its hash. */
	private async writeAsset(name: string, bytes: ArrayBuffer): Promise<string> {
		const path = `${this.assetsPath}/${name}`;
		await this.asOwnWrite(async () => {
			const existing = this.assetFile(name);
			if (existing) {
				await this.app.vault.modifyBinary(existing, bytes);
				return;
			}
			if (!this.app.vault.getFolderByPath(this.assetsPath)) {
				await this.ensureFolder(this.assetsPath);
			}
			await this.app.vault.createBinary(path, bytes);
		});
		const hash = await sha256Bytes(bytes);
		const file = this.assetFile(name);
		if (file) this.data.assetHashCache[name] = { mtime: file.stat.mtime, size: file.stat.size, hash };
		return hash;
	}

	private async ensureFolder(path: string) {
		let current = "";
		for (const part of path.split("/")) {
			current = current ? `${current}/${part}` : part;
			if (!this.app.vault.getFolderByPath(current)) {
				await this.app.vault.createFolder(current).catch(() => undefined);
			}
		}
	}

	/** Returns true if the file was uploaded. */
	private async assetUpload(name: string, overwrite: boolean, maxBytes: number): Promise<boolean> {
		const file = this.assetFile(name);
		if (!file) return false;
		if (file.stat.size === 0) {
			this.skipOnce(`empty:${name}`, `${name} is empty and can't be synced.`);
			return false;
		}
		if (file.stat.size > maxBytes) {
			this.skipOnce(
				`big:${name}`,
				`${name} is ${(file.stat.size / 1048576).toFixed(1)} MB, over the ${Math.round(maxBytes / 1048576)} MB limit, so it stays local.`,
			);
			return false;
		}
		const bytes = await this.app.vault.readBinary(file);
		const res = await this.assetRaw(
			"POST",
			`/file?name=${encodeURIComponent(name)}${overwrite ? "&overwrite=true" : ""}`,
			bytes,
			true,
		);
		if (res.status === 409) {
			// Someone created the same name since we listed. Reconcile on the next sync.
			this.debouncedAssets();
			return false;
		}
		const saved = res.json as ServerAsset;
		this.data.assetManifest[name] = {
			hash: await sha256Bytes(bytes),
			size: saved.size,
			updatedAt: saved.updatedAt,
		};
		return true;
	}

	/**
	 * Same name on both sides and we can't tell which is newer. Compare the bytes; if they
	 * differ, the server's copy takes the name and the local one is kept (and uploaded)
	 * under a "(conflict …)" name, so nothing is lost. Returns true if they differed.
	 */
	private async assetReconcile(info: ServerAsset, maxBytes: number): Promise<boolean> {
		const local = this.assetFile(info.name);
		if (!local) return false;
		const localBytes = await this.app.vault.readBinary(local);
		const serverBytes = await this.assetFetch(info);
		const localHash = await sha256Bytes(localBytes);
		const serverHash = await sha256Bytes(serverBytes);
		if (localHash === serverHash) {
			this.data.assetManifest[info.name] = { hash: serverHash, size: info.size, updatedAt: info.updatedAt };
			return false;
		}
		const date = new Date().toISOString().slice(0, 10);
		const copyName = conflictName(info.name, date, (n) => this.assetFile(n) !== null);
		await this.writeAsset(copyName, localBytes);
		await this.writeAsset(info.name, serverBytes);
		this.data.assetManifest[info.name] = { hash: serverHash, size: info.size, updatedAt: info.updatedAt };
		await this.assetUpload(copyName, false, maxBytes).catch(() => undefined);
		return true;
	}

	// ---- attachment HTTP

	private assetRequest<T>(method: "GET" | "DELETE", suffix: string): Promise<T> {
		return this.assetRaw(method, suffix).then((res) => res.json as T);
	}

	private async assetRaw(
		method: "GET" | "POST" | "DELETE",
		suffix: string,
		body?: ArrayBuffer,
		allowConflict = false,
	): Promise<RequestUrlResponse> {
		const base = this.data.endpoint.replace(/\/+$/, "").replace(/\/shared$/, "");
		let res: RequestUrlResponse;
		try {
			res = await requestUrl({
				url: `${base}/assets${suffix}`,
				method,
				headers: { "x-api-key": this.apiKey },
				contentType: body ? "application/octet-stream" : undefined,
				body,
				throw: false,
			});
		} catch (e) {
			throw new OfflineError(e);
		}
		if (res.status >= 200 && res.status < 300) return res;
		if (res.status === 409 && allowConflict) return res;
		let message = `HTTP ${res.status}`;
		if (res.status === 401) message = "Invalid API key";
		else if (res.status === 501) message = "the server has no attachments bucket yet (run setup-db and redeploy the function)";
		else if (res.status === 413) message = "file too large for the server";
		else {
			try {
				message = (res.json as { error?: string }).error ?? message;
			} catch {
				// not JSON
			}
		}
		throw new HttpError(res.status, message);
	}

	// ---------------------------------------------------------------- status

	private ensureConfigured(interactive: boolean): boolean {
		if (this.configured) return true;
		this.setStatus("error", "not set up");
		if (interactive) new Notice("shared.md sync: set the endpoint and API key in settings.");
		return false;
	}

	private handleError(e: unknown, interactive: boolean) {
		if (e instanceof OfflineError) {
			this.setStatus("offline");
			if (interactive) new Notice("shared.md: offline, will retry on the next change or auto-pull.");
			return;
		}
		const message = e instanceof Error ? e.message : String(e);
		this.setStatus("error", message);
		if (interactive) new Notice(`shared.md sync failed: ${message}`);
	}

	private setStatus(status: Status, detail?: string) {
		if (!this.statusEl) return;
		const labels: Record<Status, string> = {
			idle: "shared.md ✓",
			syncing: "shared.md ↻",
			offline: "shared.md offline",
			conflict: "shared.md ⚠ conflict",
			error: "shared.md ✗",
		};
		this.statusEl.setText(labels[status]);
		this.statusEl.setAttr("aria-label", detail ?? `shared.md sync: ${status} (v${this.data.lastVersion})`);
	}
}

function headerOf(res: RequestUrlResponse, name: string): string | undefined {
	const key = Object.keys(res.headers).find((k) => k.toLowerCase() === name);
	return key ? res.headers[key] : undefined;
}

class OfflineError extends Error {
	constructor(readonly cause: unknown) {
		super("offline");
	}
}

class ConflictError extends Error {
	constructor(readonly server: ServerState) {
		super("conflict");
	}
}

class SharedSyncSettingTab extends PluginSettingTab {
	constructor(app: App, private readonly plugin: SharedSyncPlugin) {
		super(app, plugin);
	}

	display(): void {
		const { containerEl } = this;
		const data = this.plugin.data;
		containerEl.empty();

		new Setting(containerEl)
			.setName("Endpoint URL")
			.setDesc('Appwrite function domain, e.g. https://xxxx.appwrite.run ("/shared" is added).')
			.addText((t) =>
				t
					.setPlaceholder("https://…")
					.setValue(data.endpoint)
					.onChange(async (v) => {
						data.endpoint = v.trim();
						await this.plugin.saveState();
						this.plugin.debouncedPull();
					}),
			);

		new Setting(containerEl)
			.setName("API key")
			.setDesc("Stored in Obsidian's secret storage, not in the vault, so it isn't synced or committed.")
			.addComponent((el) =>
				new SecretComponent(this.app, el).setValue(data.apiKeySecret).onChange(async (v) => {
					data.apiKeySecret = v;
					await this.plugin.saveState();
					this.plugin.debouncedPull();
				}),
			);

		new Setting(containerEl)
			.setName("Target path")
			.setDesc("The note to keep in sync. Changing it resets sync state for the new file.")
			.addText((t) =>
				t.setValue(data.targetPath).onChange(async (v) => {
					const next = v.trim() || DEFAULTS.targetPath;
					if (next === data.targetPath) return;
					data.targetPath = next;
					await this.plugin.resetSyncState();
					this.plugin.debouncedPull();
				}),
			);

		new Setting(containerEl)
			.setName("Auto-pull interval (minutes)")
			.setDesc("0 disables. Pulls also happen on startup and when the note is opened.")
			.addText((t) =>
				t.setValue(String(data.autoPullMinutes)).onChange(async (v) => {
					const n = Number.parseInt(v, 10);
					data.autoPullMinutes = Number.isFinite(n) && n >= 0 ? n : DEFAULTS.autoPullMinutes;
					await this.plugin.saveState();
					this.plugin.restartAutoPull();
				}),
			);

		containerEl.createEl("h3", { text: "Attachments" });

		new Setting(containerEl)
			.setName("Sync attachments")
			.setDesc("Keep the attachments folder equal to the server's attachments bucket, so files added in the app can be linked as [[wikilinks]] here.")
			.addToggle((t) =>
				t.setValue(data.assetsEnabled).onChange(async (v) => {
					data.assetsEnabled = v;
					await this.plugin.saveState();
					if (v) this.plugin.debouncedPull();
				}),
			);

		new Setting(containerEl)
			.setName("Move embedded files into the attachments folder")
			.setDesc("Obsidian saves pasted or attached files wherever its own attachment setting says. When the shared note embeds a file stored elsewhere, move it into the attachments folder so the app can show it. Links are updated automatically.")
			.addToggle((t) =>
				t.setValue(data.adoptAttachments).onChange(async (v) => {
					data.adoptAttachments = v;
					await this.plugin.saveState();
					if (v) this.plugin.debouncedPull();
				}),
			);

		new Setting(containerEl)
			.setName("Attachments folder")
			.setDesc("Files directly inside this folder are synced. Changing it starts a fresh sync of the new folder.")
			.addText((t) =>
				t.setValue(data.assetsFolder).onChange(async (v) => {
					const next = v.trim().replace(/\/+$/, "") || DEFAULTS.assetsFolder;
					if (next === data.assetsFolder) return;
					data.assetsFolder = next;
					data.assetManifest = {};
					data.assetHashCache = {};
					await this.plugin.saveState();
					this.plugin.debouncedPull();
				}),
			);

		new Setting(containerEl)
			.setName("Attachments status")
			.setDesc(this.plugin.assetStatus)
			.addButton((b) => b.setButtonText("Sync now").onClick(() => void this.plugin.syncAssets(true)));

		new Setting(containerEl)
			.setName("Sync state")
			.setDesc(`Device ${data.deviceId} · last synced version ${data.lastVersion}`);
	}
}
