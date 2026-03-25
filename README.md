<p align="center">
  <img src="banner.png" alt="Claudes" width="800">
</p>

<p align="center">
  <strong>A desktop IDE for Claude Code — run multiple AI coding agents side-by-side.</strong>
</p>

---

## How to install

Download the latest installer from [**GitHub Releases**](https://github.com/paulallington/Claudes/releases/latest) — grab the `.exe` file and run it. That's it.

Claudes will **automatically update itself** when new versions are published. You'll get a notification when an update is available, and it'll install in the background ready for next launch. No need to re-download manually.

> **Prerequisite:** You need [Claude Code CLI](https://claude.ai/claude-code) installed and available on your PATH.

---

## What is Claudes?

Claudes is a **Claude Code GUI** — a desktop client that gives you a visual, multi-pane interface for running [Claude Code](https://claude.ai/claude-code) sessions. If you've been looking for a **Claude Code IDE**, a **Claude Code desktop app**, or just a better way to manage multiple AI coding agents at once, this is it.

I built it because I like running lots of Claude Code sessions at once and got tired of juggling terminal windows. It gives you a proper multi-column workspace where you can spawn, resize, and organise Claude Code instances by project — like a terminal multiplexer purpose-built for Claude.

It's not a commercial project — just a tool I made for myself that I thought others might find useful too. If you find a bug or have an idea, feel free to [raise an issue](https://github.com/paulallington/Claudes/issues) or send me a pull request.

## Screenshot

<p align="center">
  <img src="screenshot.png" alt="Claudes in action" width="900">
</p>

## Features

### Multi-Column Terminal Layout

- **Resizable columns and rows** — run multiple Claude Code agents side-by-side in a flexible grid layout
- **Drag-and-drop reordering** — grab a column header and drag it to rearrange your workspace
- **Maximize/minimize columns** — focus on one Claude at a time or see them all
- **Custom column titles** — double-click a header to rename it
- **Activity indicators** — see at a glance which Claudes are working, waiting, or idle

### Project Workspaces

- **Organise by project** — group your Claude Code sessions by project, switch between them instantly
- **Persistent sessions** — switching projects preserves running Claudes in the background
- **Session resume** — remembers which Claude sessions were open per project and resumes them on restart
- **Branch display** — see the current git branch for each project in the sidebar

### Spawn Options

- **Model selection** — choose between Default, Sonnet, Opus, or Haiku per session
- **Skip Permissions** — bypass permission prompts for trusted workflows
- **Remote Control** — enable remote access from claude.ai or mobile app
- **Bare Mode** — lightweight mode skipping hooks, LSP, and plugins
- **Worktree support** — spawn sessions in isolated git worktrees
- **Custom arguments** — pass arbitrary CLI flags to Claude Code

### File Explorer

- **Built-in file browser** — browse your project files without leaving the app
- **Search** — live filtering to quickly find files
- **Inline editor** — click any file to view and edit it directly
- **Context menu** — reveal files in your system file manager

### Git Integration

Full git workflow without leaving Claudes:

- **Branch management** — view, switch, and create branches
- **Staging** — stage/unstage individual files or all at once
- **Diff viewer** — see staged and unstaged changes with full diff output
- **Commit** — write commit messages and commit directly, with amend support
- **Push & Pull** — sync with your remote in one click
- **Stash management** — create, list, and pop stashes
- **Git log** — browse commit history with details and diffs
- **Ahead/behind tracking** — see how your branch compares to the remote

### Loops (Automated Background Agents)

Set up recurring Claude Code agents that run on a schedule:

- **Interval or daily scheduling** — run every N minutes/hours, or at a specific time on chosen days
- **Dashboard** — monitor all loops across projects with status indicators
- **Attention tracking** — loops flag items that need your attention (warnings, errors, failing tests)
- **Run history** — view past runs with output, duration, cost, and status
- **Open in Claude** — send loop findings to a new interactive Claude session for investigation
- **Global controls** — pause/resume all loops, set concurrency limits

### Run Configurations

Launch and manage your application processes alongside Claude:

- **Auto-detect** — picks up configurations from VS Code `launch.json` and .NET `launchSettings.json`
- **Supported runtimes** — .NET/C#, Node.js, Python, and generic shell commands
- **Environment profiles** — create reusable sets of environment variables
- **Launch controls** — start, stop, and restart with visual status indicators

### CLAUDE.md Editor

- **Built-in editor** — read and write your project's CLAUDE.md instructions without switching tools

### Usage Analytics

- **Token tracking** — monitor input/output tokens and cache savings across sessions
- **Daily breakdown** — chart your usage over time
- **Session browser** — explore individual sessions with model, duration, and token details
- **Environmental impact** — see estimated CO2, water, and energy consumption

### Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+T` | Spawn a new Claude |
| `Ctrl+Shift+R` | Add a new row |
| `Ctrl+Shift+W` | Kill focused Claude |
| `Ctrl+Shift+M` | Maximize/restore focused column |
| `Ctrl+Shift+E` | Toggle Explorer panel |
| `Ctrl+1-9` | Jump to column by number |
| `Ctrl+Arrow Keys` | Navigate between columns |
| `Ctrl+B` | Toggle sidebar |
| `Ctrl+Enter` | Commit staged changes (Git tab) |
| `Ctrl+=`/`Ctrl+-`/`Ctrl+0` | Zoom in / out / reset |

### Theme Support

- **Dark**, **Light**, and **Auto** (syncs with your OS preference)

---

## Building from source

If you prefer to run from source instead of the installer:

```bash
git clone https://github.com/paulallington/Claudes.git
cd Claudes
npm install
npm start
```

Requires [Node.js](https://nodejs.org/) (v18+) and [Claude Code CLI](https://claude.ai/claude-code) on your PATH.

## How it works

Claudes is an Electron-based desktop application that acts as a **graphical frontend for Claude Code**. Under the hood, it spawns a separate Node.js process (`pty-server.js`) that manages pseudo-terminal instances via [node-pty](https://github.com/microsoft/node-pty). The Electron renderer communicates with the pty server over WebSocket, rendering each Claude Code terminal with [xterm.js](https://xtermjs.org/).

This architecture avoids the need to compile native modules against Electron's Node.js headers — `node-pty` runs under the system Node.js using its prebuilt binaries.

Session state is saved per project (in `.claudes/sessions.json` within the project directory), so when you restart the app your Claude Code sessions are automatically resumed.

## Contributing

This is a personal project, but contributions are welcome! If you run into a problem, [open an issue](https://github.com/paulallington/Claudes/issues). If you want to add something, send a pull request and I'll take a look.

## License

See [LICENSE](LICENSE) for details. Free to use, but the source code may not be modified or redistributed without permission.

---

<p align="center">
  A <a href="https://www.thecodeguy.co.uk">The Code Guy</a> project
</p>
