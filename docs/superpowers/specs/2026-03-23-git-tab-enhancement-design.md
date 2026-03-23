# Git Tab Enhancement Design

## Overview

Enhance the git tab in the Claudes explorer sidebar to provide a richer source control experience inspired by GitKraken. Four major improvements: visual commit graph, rich diff viewer in the main content area, enhanced commit list, and tree-structured file change view.

## 1. Architecture & Layout

### Layout Model

The sidebar keeps its current role (file changes, commit list, staging actions, branch/stash/push/pull) but gains:
- A **commit graph column** drawn alongside the commit list
- A **tree-structured file list** replacing the flat file list
- **Diff tabs in the main content area** — clicking a file or commit opens a diff viewer as a new column alongside terminals

Diff tabs use a **new `addDiffColumn` function** (not `addColumn`) that creates a non-terminal column. See Section 3 for details.

### New IPC Handlers (main.js)

| Handler | Git Command | Returns |
|---------|------------|---------|
| `git:graphLog` | `git log --format="%H\|%h\|%P\|%s\|%an\|%ar\|%D" -n <count>` | `{hash, abbrev, parents[], message, author, relativeDate, refs[]}[]` |
| `git:commitDetail` | `git show --stat --format="%H\|%s\|%an\|%aI" <hash>` | `{hash, message, author, date, files[{file, insertions, deletions, status}]}` |
| `git:diffCommit` | `git diff <hash>~1..<hash> -- <file>` (or `git show <hash> -- <file>` for initial commit) | Diff text string |
| `git:diffStat` | `git diff --numstat [--cached]` | `{file, insertions, deletions}[]` |

### Existing IPC Handlers Modified

| Handler | Change |
|---------|--------|
| `git:log` | **Replaced by `git:graphLog`**. Remove the old `git:log` handler entirely. All commit history now comes from `git:graphLog` which includes parent hashes, author, date, and refs. The `refreshGitStatus` function switches from `gitLog` to `gitGraphLog`. |

### No New Dependencies

- Commit graph: inline SVG
- Diff viewer: plain HTML + CSS
- No external libraries required

## 2. Visual Commit Graph

### Data Source

`git:graphLog` returns commits with parent hashes, enabling client-side lane computation:

```
git log --format="%H|%h|%P|%s|%an|%ar|%D" -n 50
```

Parsed into: `{ hash, abbrev, parents: string[], message, author, relativeDate, refs: string[] }`

### Lane Assignment Algorithm

Client-side algorithm assigns each active branch line to a lane (horizontal column position). The algorithm processes commits newest-first, maintaining a map of `commitHash → lane` as it goes.

**Pseudocode:**

```
lanes = []          // array of active commit hashes, one per lane (null = free)
commitLanes = {}    // maps commitHash → lane index

for each commit (newest first):
  // 1. Find or assign this commit's lane
  if commit.hash is in commitLanes:
    myLane = commitLanes[commit.hash]
  else:
    // This is a branch tip (no child assigned it a lane)
    myLane = first null slot in lanes[], or append new lane
    lanes[myLane] = commit.hash

  // 2. Record the lane for rendering
  commit.lane = myLane

  // 3. Handle parents
  if commit has 1 parent:
    // Continue the lane: parent will occupy this same lane
    lanes[myLane] = parent.hash
    commitLanes[parent.hash] = myLane

  else if commit has 2+ parents:
    // First parent continues the lane (main line)
    lanes[myLane] = parents[0]
    commitLanes[parents[0]] = myLane
    // Additional parents get their own lanes (merge sources)
    for each additional parent (parents[1], parents[2], ...):
      if parent already has a lane assigned:
        // Draw merge line from that lane into myLane
        commit.mergeFromLanes.push(commitLanes[parent])
      else:
        // Assign parent a new lane
        parentLane = first null slot in lanes[], or append
        lanes[parentLane] = parent
        commitLanes[parent] = parentLane
        commit.mergeFromLanes.push(parentLane)

  else:
    // Root commit (no parents) — free the lane
    lanes[myLane] = null

  // 4. Cap at 5 active lanes. If lanes.length > 5, collapse extras
  //    by merging the rightmost lanes into lane 4 (visual simplification).
```

After the loop, each commit has `.lane` (its column) and `.mergeFromLanes[]` (lanes that merge into it). This is sufficient to draw the SVG.

### Visual Rendering

- Graph column: 40-60px wide, sits left of commit entries
- Commit nodes: 6px circles, filled
- Branch lines: 2px SVG strokes
- Colors: use CSS variables `var(--accent)`, `var(--color-green)`, `var(--color-cyan)`. Each lane index maps to a color: `[accent, green, cyan, accent, green]` (cycling). Light theme automatically adapts via the existing CSS variable overrides.
- Each commit row is a fixed height (28px) for alignment between graph and text
- SVG is rendered as one `<svg>` per commit row (not one giant SVG), so each row aligns naturally with its commit entry in the DOM flow
- "Load more" appends new rows — no re-render of existing rows needed

### Commit Row Layout

```
[graph(40px) | hash(50px) | message(flex) | refs | author(60px) | time(60px)]
```

- **Hash:** 5 chars, monospace, dimmed color
- **Message:** single line, truncated with ellipsis, primary text color
- **Refs:** branch/tag badges — small colored pills (branch: `var(--accent)`, tag: `var(--color-cyan)`)
- **Author:** short name, dimmed
- **Time:** relative format ("2h ago", "3 days ago"), dimmed
- **Click:** opens commit diff in main area (Section 3)

### Pagination

- Initial load: 50 commits
- "Load more" button at bottom loads next 50
- Lane state is preserved — the algorithm continues from the current `lanes[]` and `commitLanes{}` state

### Section Placement

The commit graph + list replaces the current "Recent Commits" collapsed section. It is always visible (not collapsed by default) and sits below the staged/unstaged file sections.

## 3. Rich Diff Viewer

### New `addDiffColumn` Function

A **separate function** `addDiffColumn(diffData, opts)` creates a non-terminal column. This avoids forking the existing `addColumn` function which is tightly coupled to xterm/PTY.

`addDiffColumn` does the following:
1. Creates the column `div` and appends it to the active row (same as `addColumn`)
2. Creates a column header via `createColumnHeader(id, title, { isDiff: true })` — the third `opts` parameter is new (see below)
3. Creates a scrollable `div` (not an xterm terminal) for the diff content
4. Stores `colData` in `state.columns` with `{ element, terminal: null, isDiff: true, diffData, ... }`
5. Does NOT: create a Terminal, load FitAddon/WebglAddon, send WebSocket `create` message, register `terminal.onData`, or call `refitAll`

**`createColumnHeader` modification:** Add an optional third parameter `opts`. When `opts.isDiff` is true, skip creating the compact, teleport, effort, and restart buttons. Only create: title, maximize, and close.

**`removeColumn` modification:** Guard the `col.terminal.dispose()` call with `if (col.terminal)`. Guard the WebSocket `kill` message with `if (!col.isDiff)`. This is a 2-line change.

**`restartColumn` modification:** Early-return if `col.isDiff` (diff columns cannot be restarted).

**`refitAll` modification:** Skip columns where `col.isDiff` is true (no terminal to refit).

### Diff Deduplication

Before opening a diff column, check if one is already open for the same file/commit. If so, focus it (scroll into view) instead of opening a duplicate. Match by `colData.diffData.filePath` for working-tree diffs or `colData.diffData.commitHash + filePath` for commit diffs.

### Diff Tab Structure

```
+-----------------------------------------------+
| renderer.js (M)           [Unified|Split] [x]  |  ← column header
+-----------------------------------------------+
| file1.js | file2.css | file3.html |             |  ← file tabs (commit diffs only)
+-----------------------------------------------+
|  42  42  |   function foo() {                   |  ← unified diff body
|  43      | - var old = true;                    |
|      43  | + var controls = {};                 |
|      44  | + var playBtn = {};                  |
|  44  45  |   return result;                     |
+-----------------------------------------------+
```

**File tabs for multi-file commits:** If a commit changes more than 15 files, the tab bar scrolls horizontally (CSS `overflow-x: auto`). Each tab shows the filename (not full path) and a colored status letter (M/A/D/R).

### Unified Mode (Default)

- Two line-number columns: old (left) and new (right)
- Context lines: both numbers shown, normal text color
- Added lines: green background tint (`rgba(var(--color-green-rgb, 78,201,78), 0.08)`), `+` prefix, only new line number
- Removed lines: red background tint (`rgba(var(--accent-rgb, 229,57,70), 0.08)`), `+` prefix, only old line number
- Hunk headers (`@@`): styled as section dividers with dimmed text, showing line range
- Monospace font, consistent with terminal theme
- Colors adapt to light theme via CSS variables

### Side-by-Side Mode

- Left panel: old file content with line numbers
- Right panel: new file content with line numbers
- Deleted lines highlighted red on left, added lines highlighted green on right
- Synchronized scrolling (both panels scroll together via JS scroll event listener)
- Toggle button in the column header switches between modes

### Entry Points

1. **Staged/unstaged file click:** Opens working tree diff for that file (uses existing `git:diff` handler)
2. **Commit row click:** Fetches full commit diff via `git:commitDetail` + `git:diffCommit`, shows file tabs for multi-file commits, first file selected by default
3. **Existing inline diff is removed:** Clicking a filename in the sidebar no longer expands an inline `<pre>` — it always opens in the main area. Remove the `gitExpandedDiff` state variable and related inline diff code.

### Diff Parsing

The diff text from git is parsed into structured hunks:

```javascript
{ hunks: [{ oldStart, oldCount, newStart, newCount, lines: [{type: 'add'|'del'|'context', content, oldLine, newLine}] }] }
```

This parsed structure drives both unified and side-by-side rendering.

## 4. File Change Tree View

### Tree Structure

Changed files are grouped by directory path into a collapsible tree:

```
▾ src/
  ▾ components/
      Button.tsx        M  +12 −3
      Modal.tsx         A  +45
  ▾ utils/
      helpers.ts        M  +8 −2
▾ styles/
    theme.css           M  +22 −15
  package.json          M  +1 −1
```

### Node Types

**Folder nodes:**
- Collapse arrow (▸/▾)
- Folder name
- Count badge showing number of changed files inside (recursive)
- Click to collapse/expand
- All folders start expanded

**File nodes:**
- Status indicator: colored single letter (M=yellow, A=green, D=red, R=cyan) — same colors as current, using CSS variables
- Filename (not full path, since the path is shown by the tree structure)
- Insertion/deletion counts: `+N` in green, `−N` in red — from `git:diffStat`
- Click to open diff in main area
- Hover shows stage/unstage/discard action buttons (same as current behavior)

### Root-Level Files

Files at the repository root appear at the top level, not under a folder node.

### Section Structure

The tree is rendered separately within each existing section:
- "Staged Changes" section → tree of staged files
- "Changes" section → tree of unstaged/untracked files

Each section retains its existing header with collapse arrow and bulk stage/unstage button.

### Stat Counts Data

New `git:diffStat` handler returns per-file insertion/deletion counts:

```
git diff --numstat        → unstaged changes
git diff --numstat --cached → staged changes
```

Returns: `[{ file: "src/foo.js", insertions: 12, deletions: 3 }]`

### `refreshGitStatus` Changes

The existing `refreshGitStatus` parallel fetch array expands from 5 to 7 items:

```javascript
var fetchAll = [
  window.electronAPI.gitStatus(activeProjectKey),          // [0] status
  window.electronAPI.gitBranch(activeProjectKey),          // [1] branch
  window.electronAPI.gitAheadBehind(activeProjectKey),     // [2] ahead/behind
  window.electronAPI.gitStashList(activeProjectKey),       // [3] stashes
  window.electronAPI.gitGraphLog(activeProjectKey, 50),    // [4] graph log (replaces gitLog)
  window.electronAPI.gitDiffStat(activeProjectKey, false), // [5] unstaged stats
  window.electronAPI.gitDiffStat(activeProjectKey, true),  // [6] staged stats
];
```

`renderGitStatus` signature changes to: `renderGitStatus(files, branch, aheadBehind, stashes, graphLog, unstagedStats, stagedStats)`

The `lastGitRaw` cache key includes the new data to maintain the change-detection optimization.

## 5. Implementation Scope

### Files Modified

| File | Changes |
|------|---------|
| `main.js` | Add `git:graphLog`, `git:commitDetail`, `git:diffCommit`, `git:diffStat` handlers. Remove `git:log` (replaced by `git:graphLog`). |
| `preload.js` | Expose new IPC channels: `gitGraphLog`, `gitCommitDetail`, `gitDiffCommit`, `gitDiffStat`. Remove `gitLog`. |
| `renderer.js` | New: `addDiffColumn`, `renderDiffView`, `parseDiff`, commit graph SVG generator, lane algorithm, tree builder. Modified: `createColumnHeader` (add opts param), `removeColumn` (guard terminal), `restartColumn` (guard diff), `refitAll` (skip diff cols), `refreshGitStatus` (7 fetches), `renderGitStatus` (new signature), `createGitSection` (tree view), `createGitFileRow` (tree nodes, stat counts, click-to-diff). Removed: inline diff expansion, `gitExpandedDiff` variable, `createGitLogSection` (replaced by graph). |
| `styles.css` | New: diff viewer styles (unified + side-by-side), commit graph styles, tree node styles, file tab bar styles, ref badge styles. Modified: existing git section styles as needed. |
| `index.html` | Minimal changes — most UI is dynamically generated |

### What Is NOT In Scope

- Interactive rebase
- Merge conflict resolution UI
- Blame/annotation view
- File history (log for a single file)
- Stash diff viewing
- Search/filter commits
- Keyboard navigation for diff viewer (future enhancement)

## 6. Error Handling

- `git:graphLog` with no git repo → return empty array, show "Not a git repository" message
- `git:diffCommit` for initial commit (no parent) → use `git show <hash> -- <file>` instead of `git diff`
- `git:diffStat` failure → show file tree without stat counts (graceful degradation — omit the `+N −N` badges)
- Diff column for a deleted file → show all lines as removed
- Diff column for a new/untracked file → read file content directly (existing pattern from `git:diff` handler in main.js which already does this for untracked files)
- Large diffs (>5000 lines) → truncate with "Diff too large, showing first 5000 lines" message
- Diff deduplication → if diff column already open for same file/commit, focus it instead of opening another
