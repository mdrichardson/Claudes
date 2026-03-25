# Scheduled Background Loops

Persistent, scheduled background agents that run Claude CLI on a recurring schedule for proactive monitoring and automation tasks, with actionable results surfaced through a hybrid UI.

## Requirements

- Scheduled recurring agents (cron-style) using custom prompts
- Use cases: proactive work, monitoring boards, code quality checks
- Run invisibly in the background; can peek into live output
- Execute via Claude CLI (`claude --print`) as headless child processes in `main.js` (not through pty-server)
- Actionable results with flagged attention items users can click to investigate
- Setup via in-app UI form OR conversational Claude session
- Persisted to disk, survives app restarts
- Cross-project visibility via flyout dashboard

## Data Model & Persistence

### Loop Configuration

Stored in `~/.claudes/loops.json` (global, cross-project):

```json
{
  "globalEnabled": true,
  "maxConcurrentRuns": 3,
  "loops": [
    {
      "id": "loop_abc123",
      "projectPath": "D:/Git Repos/MyApp",
      "name": "Check failing tests",
      "prompt": "Run the test suite and report any failures with suggested fixes",
      "schedule": { "type": "interval", "minutes": 60 },
      "budgetPerRun": 0.50,
      "maxTurns": 15,
      "enabled": true,
      "createdAt": "2026-03-24T10:00:00Z",
      "lastRunAt": "2026-03-24T11:00:00Z",
      "lastRunStatus": "completed",
      "lastError": null,
      "currentRunStartedAt": null,
      "createdBy": "ui"
    }
  ]
}
```

Time-of-day schedule variant:

```json
{ "type": "time_of_day", "hour": 9, "minute": 0, "days": ["mon","tue","wed","thu","fri"] }
```

### Run History

Stored in `~/.claudes/loop-runs/<loop-id>/<timestamp>.json`:

```json
{
  "loopId": "loop_abc123",
  "startedAt": "2026-03-24T11:00:00Z",
  "completedAt": "2026-03-24T11:02:34Z",
  "durationMs": 154000,
  "exitCode": 0,
  "status": "completed",
  "summary": "All 42 tests passing. No issues found.",
  "output": "Full Claude CLI output...",
  "attentionItems": [
    {
      "summary": "3 failing tests in auth.ts",
      "detail": "Tests testLogin, testLogout, testRefresh are failing due to..."
    }
  ],
  "costUsd": 0.12
}
```

### Run History Retention

- Maximum 50 run history files per loop
- After each run, prune oldest files beyond the limit
- Full output stored but truncated to 50KB max; summary field always preserved in full

## UI Components

### 1. Explorer Panel — LOOPS Tab

A new tab alongside FILES / GIT / RUN in the explorer panel. Per-project view. Shows "Select a project" placeholder when no project is active.

- **Loop cards** — Each loop shows: name, schedule (e.g. "Every 60m"), status dot (idle/running/attention), next run countdown, last result summary
- **Quick actions** — Play/pause toggle, "Run Now" button, edit, delete
- **"+ New Loop" button** — Opens a setup form modal with fields:
  - Name (text input)
  - Prompt (textarea)
  - Schedule picker (every X mins/hours/days, or specific time of day with day-of-week selector)
  - Budget limit per run (USD)
  - Max turns per run
- **Edit loop** — Same modal pre-filled with existing values
- **"Ask Claude to set it up" button** — Spawns a Claude column for conversational loop creation

Status indicators reuse existing activity dot/animation patterns:
- Green dot: idle (last run passed)
- Orange dot + attention-flash: has flagged items
- Blue dot: scheduled/waiting
- Spinning green: currently running
- Red dot: last run failed/errored

### 2. Flyout Dashboard

A toolbar button opens a ~400px slide-out panel from the right side, overlaying the terminal workspace:

- **Header** — "Loop Manager" title, aggregate counts (X active, Y need attention), global pause toggle, close button
- **Filter/group** — Group by project or flat list, filter by status
- **Loop rows** — Each row shows: project name tag, loop name, schedule, status, last run time, attention badge. Click to expand showing:
  - Last run's summary (truncated, not full output)
  - Flagged attention items as clickable cards
  - Run history (last 5 runs with status dots)
  - "Open Live" button (disabled in v1, labeled "Coming soon")
- **Actionable items** — Clicking a flagged attention item spawns a new Claude terminal column pre-loaded with context about what was flagged, so the user can act on it immediately

### 3. Sidebar Integration

- Projects with loops needing attention get a small loop icon badge next to their name in the project list
- Integrates with existing `projectsNeedingAttention` system

## Execution Engine

### Scheduler

- `setInterval`-based scheduler in `main.js`, checks `loops.json` every 30 seconds
- For interval schedules: triggers when `Date.now() >= lastRunAt + schedule.minutes * 60000`
- For time-of-day schedules: triggers when current time matches the configured hour/minute and it hasn't run today (based on `lastRunAt` date). If the app starts after the scheduled time and it hasn't run today, it triggers immediately (catch-up behavior)
- On app startup, loads all loops and resumes scheduling immediately
- Respects `globalEnabled` toggle — when false, no loops run
- Respects `maxConcurrentRuns` — queues excess loops until a slot opens

### Path Validation

Before each run, validate that `projectPath` exists:
- If path doesn't exist, set `lastRunStatus: "error"`, `lastError: "Project path not found: <path>"`, and `enabled: false`
- Show error state (red dot) on the loop card in the UI
- Emit IPC event so renderer can update immediately

### Running a Loop

1. Set `currentRunStartedAt` in `loops.json` before spawning
2. Spawn Claude CLI as a child process: `claude --print -p "<prompt>" --max-turns <maxTurns> --max-budget-usd <budget>`
3. Working directory set to the loop's `projectPath`
4. No terminal column allocated — output captured to an in-memory buffer
5. Process runs independently; does not use the pty-server WebSocket (no terminal UI needed for headless runs)

### Prompt Suffix

Every loop prompt is automatically appended with a structured output instruction:

```
End your response with a JSON block wrapped in :::loop-result markers like this:
:::loop-result
{"summary": "Brief one-line summary", "attentionItems": [{"summary": "Short description", "detail": "Full context"}]}
:::loop-result
If there are no issues, use an empty attentionItems array.
```

This makes result parsing deterministic rather than relying on heuristic pattern matching.

### Result Processing

When the CLI process exits:

1. Clear `currentRunStartedAt` in `loops.json`
2. Save raw output to `~/.claudes/loop-runs/<id>/<timestamp>.json`
3. Parse output for the `:::loop-result` JSON block; if not found, fall back to heuristic parsing (patterns like `ACTION NEEDED:`, `WARNING:`, `FAILING:`, `ERROR:`)
4. Extract cost from CLI output if available (Claude CLI outputs cost summary in `--print` mode)
5. Update `loops.json` with `lastRunAt`, `lastRunStatus`, `lastError` (null on success)
6. Emit IPC event `loops:run-completed` with loop ID and results to renderer
7. If attention items found, trigger notifications (taskbar flash + sidebar badge + explorer panel badge)
8. Prune run history files beyond retention limit

### Graceful Shutdown

On `app.on('before-quit')`:
- Kill all running loop child processes
- Update `loops.json`: clear `currentRunStartedAt`, set `lastRunStatus: "interrupted"` for any in-progress loops

On startup recovery:
- If any loop has a non-null `currentRunStartedAt`, mark it as `lastRunStatus: "interrupted"`, `lastError: "App closed during run"`, clear `currentRunStartedAt`

### Concurrency

- Only one instance of each loop runs at a time
- If a loop is still running when its next scheduled time arrives, that run is skipped
- Maximum `maxConcurrentRuns` (default: 3) loops running simultaneously across all projects
- Excess loops queue and run when a slot opens

### Budget Enforcement

- `--max-budget-usd <budget>` passed to CLI to cap cost per run
- Run history tracks actual cost per run for visibility

## IPC Channels

| Channel | Direction | Purpose |
|---------|-----------|---------|
| `loops:getAll` | renderer → main | Read all loop configs |
| `loops:getForProject` | renderer → main | Read loops for a specific project |
| `loops:create` | renderer → main | Create a new loop |
| `loops:update` | renderer → main | Update loop config (edit prompt, schedule, etc.) |
| `loops:delete` | renderer → main | Delete a loop and its run history |
| `loops:toggle` | renderer → main | Enable/disable a loop |
| `loops:toggleGlobal` | renderer → main | Enable/disable all loops globally |
| `loops:runNow` | renderer → main | Trigger an immediate run |
| `loops:getHistory` | renderer → main | Get run history for a loop (last N runs) |
| `loops:run-started` | main → renderer | Event: loop run has started |
| `loops:run-completed` | main → renderer | Event: loop run finished with results |

## Conversational Loop Setup

When the user clicks "Ask Claude to set it up":

1. Spawns a regular Claude terminal column **flagged as a loop-setup column** (`col.isLoopSetup = true`) with a system prompt prepended:
   > "The user wants to create a scheduled background loop. Ask them what they want to monitor/check, how often, and any budget constraints. When you have enough info, output a structured JSON block wrapped in `:::loop-config` markers."

2. The renderer watches for `:::loop-config{...}:::` pattern **only on columns where `col.isLoopSetup === true`** to prevent false positives in regular conversations

3. When detected:
   - Parse the JSON config
   - Show a confirmation toast: "Loop '[name]' created — runs every [X]" with Edit/Dismiss buttons
   - Save to `loops.json` via IPC
   - Update the LOOPS tab in the explorer panel

4. The Claude column stays open for refinement — user can ask "make it every 2 hours instead" and Claude outputs an updated config block

## Key Files to Modify

- **main.js** — Add loop scheduler, IPC handlers for loop CRUD, child process spawning for headless runs, graceful shutdown handling
- **renderer.js** — Add LOOPS tab to explorer panel, flyout dashboard, loop card components, config detection in loop-setup terminal output
- **preload.js** — Expose loop IPC methods to renderer (all channels listed above)
- **index.html** — Add LOOPS tab markup, flyout dashboard container, new/edit loop modal, toolbar button
- **styles.css** — Loop card styles, flyout dashboard styles, status indicators, attention badges

## New Files

- `~/.claudes/loops.json` — Loop configurations (created at runtime)
- `~/.claudes/loop-runs/` — Run history directory (created at runtime)

## Not In Scope (v1)

- Agent SDK integration (using CLI instead)
- Loop templates / presets (all custom prompts for now)
- Loop output streaming to terminal in real-time ("Open Live" button shown disabled, deferred to v2)
- Multi-machine sync of loop configs
- Loop dependencies (run loop B after loop A completes)
- Read-only / analysis-only mode restriction (v1 runs with full CLI permissions; document this in the setup UI)
- Per-loop notification preferences
- Aggregate cost dashboard / global daily budget cap
