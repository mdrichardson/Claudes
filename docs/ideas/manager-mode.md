# Manager Mode — Dev Agency Dashboard

## Status: Idea (not started)

## Concept
A meta-Claude that oversees all projects like a dev agency lead. Dashboard + advisor panel, not an autonomous agent. It recommends; the user approves.

## Phases

### Phase 1: Cross-Project Dashboard (no AI, zero cost)
Toolbar flyout panel aggregating state from ALL projects:
- Project name, branch, ahead/behind count
- Active Claude columns + activity states
- Uncommitted change count
- Loop status summary + attention items
- Click project card to switch to it
- ~350 LOC, uses only existing IPC channels

### Phase 2: On-Demand Briefing (claude --print)
"Get Briefing" button that gathers context from all projects and runs a single `claude --print` call:
- Reads CLAUDE.md (first 500 chars), git status, git log (3 commits), loop results per project
- Returns prioritized briefing: immediate attention items, suggested actions, cross-project risks
- Structured `:::manager-briefing` JSON output parsed into actionable cards
- Each card has "Spawn Claude in Project X" action button
- Briefing cached for 5 minutes

### Phase 3: Delegation Actions
One-click delegation from briefing cards:
- Switches to target project
- Spawns Claude column with pre-filled prompt
- Returns focus to Manager flyout for further delegation
- Tracks delegated task status

### Phase 4: Persistent Chat Interface
Replace one-shot briefing with chat sidebar:
- Free-form questions ("What's the status of the auth refactor?")
- Pre-built query buttons: Daily Standup, Security Check, Dependency Audit
- Chat history persisted to `~/.claudes/manager-history.json`

### Phase 5: Smart Coordination
- Watch for cross-project dependency impacts on git push events
- Auto-run cross-project checks when shared libraries change
- Notification badges when risks detected

## Key Design Decisions
- **Flyout panel** (not a column or separate window) — follows loops flyout pattern
- **claude --print** for all AI queries — proven pattern from loops engine
- **Aggressive context compression** — ~200-400 tokens per project, 10 projects = ~4K tokens
- **On-demand only** — no scheduler, no auto-cost. Dashboard is instant, AI only on user action
- **Main process gathers context** — renderer sends column state via IPC, main reads filesystem

## Recommendation
Build Phase 1 first (dashboard, no AI). Validate UX. Phase 2 only if users want "what should I do about this?"
