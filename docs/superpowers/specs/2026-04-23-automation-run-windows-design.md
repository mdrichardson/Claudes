# Automation Run Windows

A supervisor gate that restricts *when* scheduled automations are allowed to start, set at the global level and optionally overridden per automation. Intersection semantics — an automation runs only when both its own window (if any) and the global window (if any) are currently open.

## Problem

Automations schedule themselves via interval, time-of-day, or app-startup triggers. There is no way to say "only run these during working hours" or "don't run on weekends" short of disabling each automation manually. Users want a top-level time gate above the existing per-automation schedules.

## Requirements

- Global run window applied to all automations.
- Optional per-automation run window.
- Intersection semantics — both must be open for a run to start.
- Gate the *start* of new runs only. In-progress runs always finish.
- `Run Now` (manual) bypasses the gate.
- `run_after` dependent agents are not directly gated — they follow their upstream.
- Visible status strip so users know at a glance whether the gate is active now.
- No catch-up behavior when window opens (see "Not in scope").

## Data Model

Stored in `~/.claudes/automations.json`.

### Global (top-level)

```json
{
  "globalEnabled": true,
  "maxConcurrentRuns": 3,
  "agentReposBaseDir": "~/.claudes/agents/",
  "runWindow": {
    "enabled": false,
    "startHour": 9,
    "startMinute": 0,
    "endHour": 17,
    "endMinute": 0,
    "days": ["mon", "tue", "wed", "thu", "fri"]
  },
  "automations": [...]
}
```

### Per automation

Optional `runWindow` field on each automation, same shape as global.

```json
{
  "id": "auto_...",
  "name": "TaskBoard Pipeline",
  "projectPath": "...",
  "runWindow": {
    "enabled": true,
    "startHour": 22, "startMinute": 0,
    "endHour": 6, "endMinute": 0,
    "days": ["mon","tue","wed","thu","fri","sat","sun"]
  },
  "agents": [...]
}
```

### Field semantics

| Field | Type | Notes |
|---|---|---|
| `enabled` | boolean | `false` → this level imposes no restriction |
| `startHour` | 0–23 | Local time |
| `startMinute` | 0–59 | Local time |
| `endHour` | 0–23 | Local time |
| `endMinute` | 0–59 | Local time |
| `days` | string[] | Subset of `["mon","tue","wed","thu","fri","sat","sun"]`. Identifies the day(s) the window **opens** |

### Rules

- Both `runWindow` fields are optional. Absent or `enabled: false` → no restriction at that level.
- If `end <= start` (in HH:MM minutes), the window is treated as **overnight** — it opens at `start` on days listed in `days` and closes at `end` the following day.
- `days` must be non-empty when `enabled: true`. Enforced by the UI on save.
- `start != end` required when `enabled: true`. Enforced by the UI on save.
- When both global and per-automation windows are enabled, the agent may run only when **both** are currently open (intersection).

## Scheduler Gate

### `isWithinRunWindow(window, now)`

Pure function in `main.js`. Returns `true` when:

1. `window` is null/undefined, or
2. `window.enabled === false`, or
3. The following check passes:
   - Compute `nowMinutes = now.getHours() * 60 + now.getMinutes()`.
   - Compute `startMinutes`, `endMinutes` from the window.
   - Let `todayKey` = 3-letter day of `now` (e.g. `"mon"`), `yesterdayKey` = same for `now - 1 day`.
   - **Same-day window** (`endMinutes > startMinutes`):
     Return `true` iff `todayKey ∈ window.days` and `startMinutes <= nowMinutes < endMinutes`.
   - **Overnight window** (`endMinutes <= startMinutes`):
     Return `true` iff either
     - `todayKey ∈ window.days` and `nowMinutes >= startMinutes`, or
     - `yesterdayKey ∈ window.days` and `nowMinutes < endMinutes`.

### Wiring into `shouldRunAgent`

Current `shouldRunAgent(agent, now)` in `main.js:2535` gets two new early-return checks before its existing schedule-type logic:

```js
if (!isWithinRunWindow(data.runWindow, now)) return false;
if (!isWithinRunWindow(automation.runWindow, now)) return false;
```

The function signature is extended to receive the automation (for its optional `runWindow`) and the top-level data (for the global `runWindow`). Callers in `main.js` already have both in scope.

### Manual run bypass

`runAgentNow` / `runAutomationNow` IPC handlers do **not** check the window. Manual action is an explicit override.

### `run_after` agents

Dependent agents are triggered by upstream completion, not by the scheduler tick. They therefore ignore the window. Rationale: if the upstream was allowed to start, finishing the pipeline is safer than leaving it half-done.

### Time-of-day interaction

An agent with `schedule.type === "time_of_day"` whose target time falls outside the window is silently skipped for that day. The existing `lastRunAt` / "has it run today" check keeps it from double-firing when the window reopens.

### Interval interaction

An agent with `schedule.type === "interval"` whose next due time falls outside the window is skipped. The next scheduler tick inside the window that also satisfies the interval condition fires it. No backlog is built up — if the window was closed for 8 hours for a 60-minute interval agent, it fires once on reopen, not 8 times.

### No catch-up

When the window opens, the scheduler does not fire a batch of "owed" runs. Normal interval/time-of-day checks apply from that tick forward.

## UI

### 1. Flyout header clock button

The automations flyout header currently contains: title, counts, global pause button, close button. Insert a **clock button** between the pause button and the close button.

- Icon: a small clock glyph.
- When `runWindow.enabled === true` globally, the icon has a small indicator dot.
- Click toggles a popover anchored below the button.

### 2. Run window popover

Shared between the flyout clock button and the status strip click handler.

**Contents:**
- Heading: `Run window`
- Checkbox: `Restrict when automations can run` (bound to `runWindow.enabled`)
- Time range: two `<input type="time">` controls labeled `From` and `To`
- Day checkboxes: `M T W T F S S`
- Footer: `[Cancel]` `[Save]`

**Validation on save:**
- Checkbox on → at least one day must be selected. Else inline error: `Pick at least one day`.
- Checkbox on → start must differ from end. Else inline error: `Start and end must differ`.
- Checkbox off → the entire `runWindow.enabled` becomes `false`; other fields retained so toggling back preserves the user's previous config.

Saving calls a new IPC handler `updateGlobalRunWindow(runWindow)` that writes `automations.json` and returns the full updated config. Renderer refreshes the status strip and any open flyout/panel.

### 3. Status strip (in AUTOMATIONS panel)

A compact strip directly under the AUTOMATIONS panel header (the toolbar row with `+ ↓ ↑ ▶ ⏸ 🗑`).

**Visibility:**
- Global `runWindow.enabled === false` → hidden.
- Else visible.

**Content when currently open:**
`⏰ Active · 09:00–17:00 · Mon–Fri` with a muted green dot.

**Content when currently closed:**
`⏰ Paused until Mon 09:00 · 09:00–17:00 · Mon–Fri` with a muted amber dot.

The "Paused until" time is computed from the next window-open moment given the configured days. The strip is clickable — opens the same popover as the clock button.

Refresh cadence: a renderer-side 60-second interval refreshes the strip text (matching the scheduler tick cadence in `main.js:3278`). The interval is cleared when the AUTOMATIONS tab is not active.

### 4. Per-automation clock badge

On each automation card in the AUTOMATIONS list and the flyout, if the automation has `runWindow.enabled === true`, render a small clock icon next to its existing status badge. Tooltip shows the per-automation window summary, e.g. `Runs 22:00–06:00 · Mon–Sun`.

### 5. Per-automation section in create/edit modal

In the existing automation create/edit modal, add a collapsible section **above the agents list**.

**Collapsed (default):** section header `▸ Run window (optional)`. No fields visible.

**Expanded:** reveals the same controls as the global popover:
- Checkbox: `Restrict when this automation can run`
- Time range (from/to)
- Day checkboxes
- Info text: `Intersects with the global run window.`

Validation mirrors the popover (at least one day, start ≠ end).

When the checkbox is unchecked on save, `runWindow` is omitted from the saved automation. When saving an existing automation with a window, the section is pre-expanded.

## IPC API

### New channel

| Channel | Direction | Purpose |
|---|---|---|
| `automations:updateGlobalRunWindow` | renderer → main | Persist the global `runWindow` and return the updated config |

### Existing channels updated

- `updateAutomation(automationId, updates)`: safe-fields list in `main.js:1598` extended to include `"runWindow"`.
- `createAutomation`, `exportAutomation`, `exportAutomations`, `importAutomations`: existing code already roundtrips the full automation shape, so `runWindow` passes through unchanged. Verify that import path preserves it.

## Error Handling

| Scenario | Behavior |
|---|---|
| Window saved with zero days | Save blocked by UI; inline error on the popover/modal |
| Window saved with start == end | Save blocked by UI; inline error |
| Scheduler tick lands exactly at window close | `isWithinRunWindow` is half-open `[start, end)`; a tick at `end:00` is outside the window → no new run |
| App sleeps across window open | No catch-up; normal schedule checks resume on next tick |
| DST transition inside the window | Wall-clock behavior — 2:00–3:00 may be skipped or repeated once a year. Acceptable and matches OS behavior |
| Window configured, global pause on | Global pause still wins. Window gates *additional* to the existing `globalEnabled` flag |
| Per-automation window present on a disabled automation | Ignored — `enabled: false` on the automation already blocks runs |
| `runAgentNow` pressed while window closed | Runs immediately (documented manual override) |
| `time_of_day` target outside window | Silently skipped that day; no double-fire later |
| Agent running when window closes | Finishes naturally; only new-start is gated |

## Files to modify

- `main.js` — add `isWithinRunWindow()`, extend `shouldRunAgent()` signature and two checks, add `updateGlobalRunWindow` IPC handler, extend `updateAutomation` safe-fields.
- `renderer.js` — flyout clock button handler, run-window popover, AUTOMATIONS panel status strip, per-automation modal section, per-automation clock badge, 60s refresh timer.
- `preload.js` — expose `updateGlobalRunWindow`.
- `index.html` — popover markup, status strip container, modal section markup, flyout clock button.
- `styles.css` — popover, status strip, clock button and badge.

## Not in scope

- Catch-up runs when the window opens after being closed.
- Per-agent (sub-automation) run windows. Window is per-automation only.
- Multiple ranges per day ("09:00–12:00 and 13:00–17:00").
- Per-day time overrides (Mon–Fri 9–5, Sat 10–14).
- Calendar-based exceptions (holidays, one-off blackouts).
- Killing in-progress runs when the window closes.
- Notifications on window open/close.
- Timezone selection — local wall-clock only.
