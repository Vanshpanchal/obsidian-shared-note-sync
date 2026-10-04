# Shared.md Sync (Obsidian plugin)

Keeps one note, by default `Shared/shared.md`, in sync with your VaultBridge
backend, and syncs its attachments folder (`Shared/assets`). Works on desktop and
mobile (`isDesktopOnly: false`).

Install and setup steps are in the [main README](../README.md#2a-use-it-in-obsidian-desktop-and-mobile).

## Build

```sh
npm install
npm run build      # type-check, then bundle to main.js
npm test
```

Release files are `main.js` and `manifest.json`. Push a tag equal to the version in
`manifest.json` (for example `1.1.0`) and the *Release plugin* GitHub Action
publishes them.

## Commands

| Command | What it does |
|---|---|
| Pull shared.md | Fetch the server copy now |
| Push shared.md | Save the local note to the server now |
| Sync attachments now | Make the attachments folder and the server bucket equal |
| Resolve conflict: keep my shared.md (push it) | After merging by hand, push on top of the version you saw |
| Resolve conflict: use server copy | Replace the local note with the server's |

## Settings

Endpoint URL, API key (kept in Obsidian secret storage, not in `data.json`), target
path, auto-pull interval, attachments on/off, attachments folder, and
*Move embedded files into the attachments folder*.

## Behaviour notes

- Pulls on startup, when the note opens and on the interval. Pushes 3 s after an edit.
- A conflict never overwrites anything: the server copy goes to `shared.conflict.md`
  and auto-sync pauses until you resolve it.
- Attachments: the folder and the bucket are kept equal. Deleting on one side deletes
  on the other. Two different files with the same name are both kept (the local one
  becomes `name (conflict YYYY-MM-DD).ext`).
- Files the note embeds that live elsewhere in the vault (Obsidian saves pasted files
  where its own *Default location for new attachments* says) are moved into the
  attachments folder so they sync. Turn this off in settings if you prefer.
- If you sync your vault with git or iCloud, do not sync
  `.obsidian/plugins/shared-md-sync/data.json`. It holds this device's sync state.
