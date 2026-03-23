# Git Tab Enhancement Design

## Overview

Enhance the git tab in the Claudes explorer sidebar to provide a richer source control experience inspired by GitKraken. Four major improvements: visual commit graph, rich diff viewer in the main content area, enhanced commit list, and tree-structured file change view.

## 1. Architecture & Layout

### Layout Model

The sidebar keeps its current role (file changes, commit list, staging actions, branch/stash/push/pull) but gains:
- A **commit graph column** drawn alongside the commit list
- A **tree-structured file list** replacing the flat file list
- **Diff tabs in the main content area** — clicking a file or commit opens a diff viewer as a new column alongside terminals

Diff tabs reuse the existing column/row system (`addColumn`) but render HTML content instead of an xterm terminal. This is a new column content type.

### New IPC Handlers (main.js)

| Handler | Git Command | Returns |
|---------|------------|---------|
| `git:graphLog` | `git log --format=<format> -n <count>` | `{hash, abbrev, parents[], message, author, date, refs[]}[]` |
| `git:commitDetail` | `git show --stat <hash>` | `{hash, message, author, date, files[{file, insertions, deletions, status}]}` |
| `git:diffCommit` | `git diff <hash>^..<hash> -- <file>` | Diff text string |
| `git:diffStat` | `git diff --numstat [--cached]` | `{file, insertions, deletions}[]` |

### Existing IPC Handlers Modified

| Handler | Change |
|---------|--------|
| `git:log` | Extend format to include author, date, parents (backwards compatible — add fields to returned objects) |

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

Client-side algorithm assigns each active branch line to a lane (horizontal column position):

1. Process commits top-to-bottom (newest first)
2. Each commit occupies a lane. If it's the first commit of a branch, assign the next available lane.
3. If a commit has 2 parents (merge), draw a curved line from the secondary parent's lane into the current lane
4. If a commit is the last in its lane (no children reference it), free that lane
5. Maximum 5-6 lanes — beyond that, collapse into a single "other" track

### Visual Rendering

- Graph column: 40-60px wide, sits left of commit entries
- Commit nodes: 6px circles, filled
- Branch lines: 2px SVG strokes
- Colors: rotate through 3 theme-consistent colors — accent red (`#e63946`), green (`#4ec94e`), cyan (existing `--color-cyan`)
- Each commit row is a fixed height (~28px) for alignment between graph and text

### Commit Row Layout

```
[graph(40px) | hash(50px) | message(flex) | refs | author(60px) | time(60px)]
```

- **Hash:** 5 chars, monospace, dimmed color
- **Message:** single line, truncated with ellipsis, primary text color
- **Refs:** branch/tag badges — small colored pills (branch: accent, tag: cyan)
- **Author:** short name, dimmed
- **Time:** relative format ("2h ago", "3 days ago"), dimmed
- **Click:** opens commit diff in main area (Section 3)

### Pagination

- Initial load: 50 commits
- "Load more" button at bottom loads next 50
- Graph state (lane assignments) carries over across pages

### Section Placement

The commit graph + list replaces the current "Recent Commits" collapsed section. It is always visible (not collapsed by default) and sits below the staged/unstaged file sections.

## 3. Rich Diff Viewer

### Column Type

A new column content type `diff` is added to the existing column system:

```javascript
addColumn([], null, {
  type: 'diff',
  title: 'renderer.js',
  diffData: { ... }
});
```

When `opts.type === 'diff'`, the column creates a `div` with the diff viewer instead of an xterm terminal. The existing column header (close button, maximize) works as-is. The compact/teleport/effort buttons are hidden for diff columns.

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

### Unified Mode (Default)

- Two line-number columns: old (left) and new (right)
- Context lines: both numbers shown, normal text color
- Added lines: green background tint (`rgba(78,201,78,0.08)`), `+` prefix, only new line number
- Removed lines: red background tint (`rgba(229,57,70,0.08)`), `-` prefix, only old line number
- Hunk headers (`@@`): styled as section dividers with dimmed text, showing line range
- Monospace font, consistent with terminal theme

### Side-by-Side Mode

- Left panel: old file content with line numbers
- Right panel: new file content with line numbers
- Deleted lines highlighted red on left, added lines highlighted green on right
- Synchronized scrolling (both panels scroll together)
- Toggle button in the column header switches between modes

### Entry Points

1. **Staged/unstaged file click:** Opens working tree diff for that file (uses existing `git:diff` handler)
2. **Commit row click:** Fetches full commit diff via `git:commitDetail` + `git:diffCommit`, shows file tabs for multi-file commits, first file selected by default
3. **Existing inline diff is removed:** Clicking a filename in the sidebar no longer expands an inline `<pre>` — it always opens in the main area

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
- Status indicator: colored single letter (M=yellow, A=green, D=red, R=cyan) — same colors as current
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

This is fetched alongside `git:status` in the existing parallel data fetch.

## 5. Implementation Scope

### Files Modified

| File | Changes |
|------|---------|
| `main.js` | Add `git:graphLog`, `git:commitDetail`, `git:diffCommit`, `git:diffStat` IPC handlers. Extend `git:log` format. |
| `preload.js` | Expose new IPC channels |
| `renderer.js` | New: diff column renderer, commit graph SVG generator, lane algorithm, diff parser, tree builder. Modified: `refreshGitStatus`, `renderGitStatus`, `createGitSection`, `createGitFileRow`, commit log section. Remove inline diff. |
| `styles.css` | New: diff viewer styles, commit graph styles, tree node styles, file tab styles. Modified: existing git section styles as needed. |
| `index.html` | Minimal changes — most UI is dynamically generated |

### What Is NOT In Scope

- Interactive rebase
- Merge conflict resolution UI
- Blame/annotation view
- File history (log for a single file)
- Stash diff viewing
- Search/filter commits

## 6. Error Handling

- `git:graphLog` with no git repo → return empty array, show "Not a git repository" message
- `git:diffCommit` for a commit with no parent (initial commit) → use `git diff --root <hash>`
- `git:diffStat` failure → show file tree without stat counts (graceful degradation)
- Diff column for a deleted file → show all lines as removed
- Diff column for a new/untracked file → show all lines as added (use `git diff /dev/null <file>` or read file content directly)
- Large diffs (>5000 lines) → truncate with "Diff too large, showing first 5000 lines" message
