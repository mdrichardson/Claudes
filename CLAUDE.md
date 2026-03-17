# Claudes

Multi-column Claude Code terminal desktop app built with Electron.

## Architecture

Electron main process spawns `pty-server.js` as a **child process under system Node.js** (not Electron's bundled Node). This is critical — node-pty's prebuilt binaries only work with system Node, and electron-rebuild fails on this system. Never try to load node-pty directly in Electron's process.

Communication: Electron renderer <-> WebSocket <-> pty-server.js <-> node-pty <-> Claude CLI

## Key Files

- `main.js` — Electron main process, window management, IPC handlers (config, sessions, file explorer, git, CLAUDE.md editor)
- `pty-server.js` — Standalone WebSocket server + node-pty. Runs under system Node.js. Accepts `cmd` param to spawn arbitrary processes (not just Claude)
- `preload.js` — Context bridge exposing IPC to renderer
- `renderer.js` — All frontend logic: project management, row/column layout, xterm terminals, spawn options, explorer panel, CLAUDE.md modal
- `index.html` — App shell with sidebar, explorer panel, toolbar, modals
- `styles.css` — Dark theme

## Build & Run

```bash
npm install    # No postinstall/electron-rebuild needed
npm start      # Launches Electron app
```

## Releasing

Use the `/release` slash command:
```
/release 2.1.0
```

This commits all outstanding changes, then runs `release.sh` which bumps `package.json` version, tags, pushes, builds the NSIS installer, and creates a GitHub Release with the artifacts. Requires `gh` CLI to be authenticated. Installed apps auto-update from GitHub Releases via `electron-updater`.

Can also be run manually: `./release.sh 2.1.0`

## UI Conventions

- Product name: "Claudes"
- Terminology: Spawn (not Add), Kill (not Close), Respawn (not Restart)
- Use the real Claude starburst icon (claude-icon.png / claude-small.png), not unicode approximations
- Background colours must be consistent: terminal theme background is `#1a1a2e`

## Project Config

- App config stored in `~/.claudes/projects.json`
- Per-project session state stored in `<project>/.claudes/sessions.json`
- Claude sessions detected by scanning `~/.claude/projects/<path-key>/` for `.jsonl` files
