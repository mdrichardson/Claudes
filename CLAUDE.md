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
/release           # patch bump (e.g. 2.0.0 -> 2.0.1)
/release minor     # minor bump (e.g. 2.0.0 -> 2.1.0)
/release major     # major bump (e.g. 2.0.0 -> 3.0.0)
/release 2.1.0     # explicit version
```

This commits all outstanding changes, then runs `release.sh` which bumps `package.json` version, tags, pushes, builds the NSIS installer, and creates a GitHub Release with the artifacts. Requires `gh` CLI to be authenticated. Installed apps auto-update from GitHub Releases via `electron-updater`.

Can also be run manually: `./release.sh [major|minor|patch|x.y.z]`

## UI Conventions

- Product name: "Claudes"
- Terminology: Spawn (not Add), Kill (not Close), Respawn (not Restart)
- Use the real Claude starburst icon (claude-icon.png / claude-small.png), not unicode approximations
- Background colours must be consistent: terminal theme background is `#1a1a2e`

## Project Config

- App config stored in `~/.claudes/projects.json` (dev: `projects-dev.json` — auto-selected when unpackaged). Each project entry carries:
  - `name`, `path`, `columnCount`, `poppedOut`, `popoutBounds` (existing)
  - `workspaces: []` — array of `{ id, name, createdAt }` sub-workspaces (peers to Primary, rendered as indented sub-rows under the project card)
  - `activeWorkspaceId: null | "<ws id>"` — which workspace the project last routed to; `null` means Primary
- Per-project session state stored in `<project>/.claudes/sessions.json`, shape:
  ```json
  { "sessions": [ ... ], "workspaces": { "<ws id>": { "sessions": [ ... ] } } }
  ```
  Primary's columns live in the top-level `sessions` array; each sub-workspace's columns live under `workspaces.<id>.sessions`. Legacy files with just `{ "sessions": [...] }` are read as Primary with an implicit empty `workspaces: {}`; the first save upgrades the shape. Writes are atomic (tmp + rename).
- Claude sessions detected by scanning `~/.claude/projects/<path-key>/` for `.jsonl` files

<!-- aidp-orchestrator-start -->
## AI-Driven Project Orchestrator

**Session agent active** — read `_aidp-orchestrator.md` from project memory for project-specific config (shadow dir, verify commands, docs).

### Assigned Agents
| Agent | Scope | Model |
|-------|-------|-------|
| implementer-electron | main.js, renderer.js, preload.js, pty-server.js, index.html, styles.css, scripts/, release.sh, package.json | sonnet |
| tester-node | test/ | sonnet |
| ux-reviewer | index.html, styles.css, renderer.js | sonnet |
| reviewer | (read-only) | opus |

### Workflow (mandatory for ALL implementation)
1. **Classify** — trivial (skip to 4) | standard | vague/complex (`EnterPlanMode`)
2. **Research** — Explore agent(s) to understand affected areas
3. **Plan** — decompose into agent-scoped subtasks
4. **Sync main and branch** — `git checkout main && git pull --ff-only` (skip pull if no remote; on divergence, escalate — do NOT auto-merge/rebase) then `git checkout -b work/<task-description>`
5. **Create and enter worktree** — `git worktree add -b worktree-<task-slug> .claude/worktrees/<task-slug>` then `EnterWorktree(path: ".claude/worktrees/<task-slug>")` (use `worktree add` so the branch is based on local HEAD, not origin/<default>)
6. **Delegate** — Agent() calls WITHOUT `isolation` (agents inherit worktree CWD). Prompts MUST include `## Constitution Rules` and `## Structure Snippet` sections (paste from session-cached docs) so agents can skip their own file reads. Add `## Design Snippet` when delegating to ui-compose/ux-reviewer.
implementer-electron + tester-node + ux-reviewer can run in parallel. Merge ALL before delegating tester.
7. **Commit** — after ALL agents return: `git add` + `git commit`
8. **Quality gate** — `npm test`. ALL must pass (zero errors, including pre-existing). 3 failures → escalate
9. **Review** — reviewer agent on `git diff main...HEAD`. Review-fix loop: Critical → fix → re-commit → re-gate → re-review (max 2 cycles)
10. **Exit worktree** — `ExitWorktree(action: "keep")`
11. **Merge and ship** — merge worktree → integration branch → main. Conflict check at each merge, verify after each, revert main on failure. Worktree cleanup (unlock + remove + branch -d) then integration branch cleanup. See Merge Protocol in `_aidp-orchestrator.md`
12. **Escalate** — user only for architectural decisions or merge conflicts

### Enforcement (hooks auto-enforce — these WILL block you)
- Agent() calls blocked without active worktree (except Explore, Plan, reviewer, plan-reviewer)
- Write/Edit blocked on subdirectory files without active worktree
- Bash file writes blocked without active worktree
- Branch must be main/master/work/* before worktree creation
- Plan review offered via AskUserQuestion before ExitPlanMode (user chooses: finalize or review first)
- ExitWorktree blocked until reviewer has run (commit-hash verified — new commits require re-review)
- ExitWorktree blocked until ALL verify commands pass (zero errors — pre-existing included)

### Direct-Edit Scope (orchestrator only, no worktree needed)
Root config: CLAUDE.md, README.md, .gitignore, package.json | .claude/ | memory/ | git ops

**All other files: Branch → EnterWorktree → Delegate → Commit → Gate → Review → ExitWorktree**
Every source file change — including one-line fixes — goes through an agent in a worktree.

### Agent Lifecycle
Agents are one-shot. Always spawn fresh Agent() for remaining work. No `isolation` param — agents inherit worktree CWD.

### Task Tracking
Emit `TaskCreate` at step 3 (Plan), one per phase: Implement (one per parallel agent), Quality gate, Review, Merge. Use `addBlockedBy` for ordering. Update to `in_progress` when entering each step, `completed` on pass. Never `completed` while tests fail or reviewer flagged Critical. Orchestrator owns tasks — agents don't touch them. Skip for orchestrator-direct edits.

**Before your first task each session**, read `_aidp-orchestrator.md` from project memory — it is the authoritative workflow source and may be more current than these inline rules.
<!-- aidp-orchestrator-end -->
