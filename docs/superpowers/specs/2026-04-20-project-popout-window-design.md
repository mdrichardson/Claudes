# Break Out Project into Separate Window — Design

**Date:** 2026-04-20
**Status:** Approved for implementation planning

## Problem

In Claudes, switching between projects means clicking tabs in the left sidebar of a single window. When working across projects — especially on multi-monitor setups — users want to give a project its own dedicated OS window so they can place it on another display, alt-tab to it directly, and stop hunting through sidebar tabs.

## Goals

- Let the user detach any project into its own `BrowserWindow`.
- Keep PTY sessions alive across the move (no terminal restart).
- Persist popped-out state across app restarts, including window bounds.
- Leave the existing main-window experience unchanged for projects that are not popped out.

## Non-goals

- Drag-to-tear tabs (like browser tab detaching).
- Showing the same project simultaneously in two windows.
- Adding new projects to a popout window or moving other projects into it.
- Cross-window terminal sharing (each PTY is attached to exactly one xterm at a time).

## User flow

1. User right-clicks a project in the main sidebar and selects **"Open in new window"**.
2. A new OS window opens containing the toolbar, columns, and terminals for that project. No sidebar.
3. The project disappears from the main sidebar. If it was the active project in the main window, main switches to the next available project (or its empty state).
4. The popout behaves as an independent OS window: separate close/minimize, taskbar entry, focus.
5. When the user closes the popout window, the project rejoins the main sidebar via the normal sort/pin/group ordering. The main window's active project is not changed.
6. If the user quits the app with a project popped out, the popout reopens at its last bounds on the next launch.

## Architecture

### Window model

- One `BrowserWindow` per popout, loading the existing `index.html` with `?mode=popout&projectKey=<encoded-path>`.
- Main window continues to load `index.html` with no query string (implicitly `mode=main`).
- `renderer.js` reads `location.search` at boot:
  - `mode=popout`: hide sidebar, skip the project-list load path, load only the single project referenced by `projectKey`. Disable UI that does not apply in popout (add-project button, sidebar reorder/pin/group controls).
  - default / `mode=main`: current behaviour, filtered to exclude projects with `poppedOut: true`.
- Window title for popouts is the project name.

### Config model

Two new per-project fields in `~/.claudes/projects.json`:

```js
{
  path: "D:/Git Repos/Example",
  name: "Example",
  columnCount: 2,
  // existing fields...
  poppedOut: false,          // currently in its own window?
  popoutBounds: null          // { x, y, width, height } last used, or null
}
```

No changes to session state files (`<project>/.claudes/sessions.json`).

### Single-writer discipline

All `projects.json` writes go through `main.js` via existing `config:saveProjects` IPC. Both the main window and each popout send proposed config changes; `main.js` is the single writer and rebroadcasts changes via a new `config:updated` channel to every renderer.

Paul's `81163bf` debounce (400ms coalesced, sync flush on quit) is unchanged by this feature; it already sits in the write path.

### IPC additions

| Channel | Direction | Payload | Purpose |
|---|---|---|---|
| `project:popOut` | renderer → main | `{ projectKey }` | Set `poppedOut: true`, save config, create popout window, broadcast `config:updated`. |
| `project:popIn` | popout renderer → main (internal, on window close) | `{ projectKey, bounds }` | Set `poppedOut: false`, save `popoutBounds`, broadcast `config:updated`. |
| `config:updated` | main → all renderers | `{ config }` | Push on every config rewrite so renderers reconcile without re-reading disk. |

### Popout window lifecycle (main.js)

- `createProjectWindow(projectKey)`:
  - Uses `popoutBounds` if present, else offsets by `+40,+40` from main window.
  - Same `webPreferences`, title bar styling, and theme detection as `createWindow()`.
  - On `move` / `resize` (debounced ~300ms): updates `popoutBounds` in config via the single writer.
  - On `close`: marks project `poppedOut: false`, persists final bounds, broadcasts update. No active-project change in main.
- Main process keeps `Map<projectKey, BrowserWindow>` of open popouts to prevent duplicates and to address IPC.
- On startup after reading config: for each project with `poppedOut: true`, call `createProjectWindow`.
- `app.on('before-quit')`: close each popout window (which persists bounds) while leaving `poppedOut: true` intact so next launch restores them.
- If a popped-out project is deleted (from main, via existing delete flow): close the popout window first, then remove from config.

### Sidebar integration (renderer.js, main mode)

- Filter `poppedOut: true` projects out at the top of the sidebar render pipeline, before pin/alpha-sort/worktree-group logic added in `a3bc688` and `0b41fa5`.
- If a worktree group becomes empty because all its members are popped out, the group header does not render.
- Right-click menu on any project item gets a new entry: **"Open in new window"**. Only shown for projects that are not already popped out (which, given the filter above, is always true for visible items — so always shown).
- The re-entry position after pop-in is whatever the current pin/sort/group state dictates. No "remember original index" tracking.

### Popout renderer (renderer.js, popout mode)

- Boot detects `mode=popout`, reads `projectKey` from query string.
- Skips sidebar rendering and project-list setup entirely.
- Loads and activates only the referenced project. All per-project UI (columns, spawn options, pause/resume all, CLAUDE.md modal, explorer panel, git tab) functions identically to main.
- Listens for `config:updated` so shared settings (theme, automations, etc.) stay consistent with main.

## Verification checklist

Manual verification (no automated UI tests in this repo):

**Golden path**
- Right-click project → "Open in new window" opens a popout with terminals intact.
- Project is hidden from main sidebar; active project in main switches if needed.
- Typing/output works in popout terminals; PTYs never restart.
- Closing popout returns project to main sidebar under current sort/pin/group rules; main's active project unchanged.

**Persistence**
- Pop out, move/resize, quit fully, relaunch → popout reopens at saved bounds.
- Pop out, close popout, relaunch → project is back in main sidebar, no popout.

**Edge cases**
- Popping out the active project switches main to next available (or empty state).
- Main hides to tray while popout open → popout stays visible.
- Tray quit closes all popouts cleanly, bounds persisted.
- Multiple popouts open concurrently, each independent.
- Deleting a popped-out project closes the popout first.
- CLAUDE.md editor, spawn options, explorer panel, git tab, pause/resume all work in popout.

**Regression surface**
- Non-popped-out projects in main still honour pin, alpha sort, worktree groups, drag reorder, collapsible groups (from `a3bc688` / `0b41fa5`).
- `projects.json` debounced writes still flush on quit (`81163bf`).

## Files touched

- `main.js` — `createProjectWindow()`, popout registry, new IPC handlers (`project:popOut`, `project:popIn`), `config:updated` broadcast, startup restore, before-quit cleanup, delete-project coordination.
- `renderer.js` — mode detection at boot, sidebar filter for `poppedOut`, popout-mode boot path, right-click menu entry, `config:updated` listener.
- `preload.js` — expose `project:popOut` and `config:updated` on the context bridge.
- `index.html` — no structural changes required; existing elements are hidden via JS in popout mode.
- `styles.css` — optional: a body-level class (e.g. `.mode-popout`) for any CSS-driven UI hiding if cleaner than JS.

## Risks

- **Race on bounds write during rapid move:** mitigated by the existing 400ms debounce.
- **Popout launched before `pty-server.js` ready on startup restore:** restore popouts after the pty-server is confirmed up, same gate the main window uses.
- **Theme / titleBarOverlay colour drift between windows:** both windows recompute from the same config on `config:updated`.
