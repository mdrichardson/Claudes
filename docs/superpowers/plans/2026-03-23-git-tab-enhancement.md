# Git Tab Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance the git tab with a visual commit graph, rich diff viewer in the main content area, tree-structured file changes, and enhanced commit entries.

**Architecture:** Four new IPC handlers in main.js provide graph log, commit detail, commit diff, and diff stat data. The renderer gains a new `addDiffColumn` function for non-terminal columns, a lane assignment algorithm for the commit graph SVG, a diff parser, and a tree builder for file changes. The existing `refreshGitStatus` pipeline expands from 5 to 7 parallel fetches.

**Tech Stack:** Vanilla JS (ES5 style with `var`), Electron IPC, inline SVG, plain HTML/CSS. No external dependencies.

**Spec:** `docs/superpowers/specs/2026-03-23-git-tab-enhancement-design.md`

---

### Task 1: New IPC Handlers (main.js + preload.js)

**Files:**
- Modify: `main.js:464-474` (replace `git:log` handler)
- Modify: `main.js:505` (add new handlers after `git:stashPop`)
- Modify: `preload.js:31` (replace `gitLog`, add new methods)

- [ ] **Step 1: Replace `git:log` with `git:graphLog` in main.js**

Find the `git:log` handler at `main.js:464-474` and replace it with:

```javascript
ipcMain.handle('git:graphLog', (event, projectPath, count) => {
  try {
    const output = execFileSync('git', ['log', '--format=%H|%h|%P|%s|%an|%ar|%D', '-' + (count || 50), '--no-color'], { cwd: projectPath, encoding: 'utf8', timeout: 10000 });
    return output.trim().split('\n').filter(Boolean).map(line => {
      const parts = line.split('|');
      return {
        hash: parts[0],
        abbrev: parts[1],
        parents: parts[2] ? parts[2].split(' ').filter(Boolean) : [],
        message: parts[3],
        author: parts[4],
        relativeDate: parts[5],
        refs: parts[6] ? parts[6].split(',').map(r => r.trim()).filter(Boolean) : []
      };
    });
  } catch {
    return [];
  }
});
```

- [ ] **Step 2: Add `git:commitDetail`, `git:diffCommit`, `git:diffStat` handlers after `git:stashPop` in main.js**

Insert after line 505 (after the `git:stashPop` closing `});`):

```javascript
ipcMain.handle('git:commitDetail', (event, projectPath, hash) => {
  try {
    const output = execFileSync('git', ['show', '--stat', '--format=%H|%s|%an|%aI', hash, '--no-color'], { cwd: projectPath, encoding: 'utf8', timeout: 10000 });
    const lines = output.trim().split('\n');
    const meta = lines[0].split('|');
    const files = [];
    // Parse stat lines (skip first line=format, last line=summary)
    for (let i = 1; i < lines.length; i++) {
      const statMatch = lines[i].match(/^\s*(.+?)\s+\|\s+(\d+)\s+(\+*)(-*)/);
      if (statMatch) {
        files.push({
          file: statMatch[1].trim(),
          insertions: (statMatch[3] || '').length,
          deletions: (statMatch[4] || '').length,
          total: parseInt(statMatch[2])
        });
      }
    }
    return {
      hash: meta[0],
      message: meta[1],
      author: meta[2],
      date: meta[3],
      files: files
    };
  } catch (err) {
    return { hash: hash, message: '', author: '', date: '', files: [], error: (err.stderr || err.message).toString().trim() };
  }
});

ipcMain.handle('git:diffCommit', (event, projectPath, hash, filePath) => {
  try {
    // Try normal diff first (hash~1..hash)
    const args = filePath
      ? ['diff', hash + '~1..' + hash, '--', filePath]
      : ['diff', hash + '~1..' + hash];
    return execFileSync('git', args, { cwd: projectPath, encoding: 'utf8', timeout: 10000 });
  } catch {
    // Fallback for initial commit (no parent)
    try {
      const args2 = filePath
        ? ['show', hash, '--', filePath]
        : ['show', '--format=', hash];
      return execFileSync('git', args2, { cwd: projectPath, encoding: 'utf8', timeout: 10000 });
    } catch {
      return '';
    }
  }
});

ipcMain.handle('git:diffStat', (event, projectPath, staged) => {
  try {
    const args = staged ? ['diff', '--numstat', '--cached'] : ['diff', '--numstat'];
    const output = execFileSync('git', args, { cwd: projectPath, encoding: 'utf8', timeout: 5000 });
    return output.trim().split('\n').filter(Boolean).map(line => {
      const parts = line.split('\t');
      return {
        insertions: parts[0] === '-' ? 0 : parseInt(parts[0]) || 0,
        deletions: parts[1] === '-' ? 0 : parseInt(parts[1]) || 0,
        file: parts[2]
      };
    });
  } catch {
    return [];
  }
});
```

- [ ] **Step 3: Update preload.js**

In `preload.js`, replace line 31 (`gitLog`) and add new methods. Replace:

```javascript
  gitLog: (projectPath, count) => ipcRenderer.invoke('git:log', projectPath, count),
```

With:

```javascript
  gitGraphLog: (projectPath, count) => ipcRenderer.invoke('git:graphLog', projectPath, count),
  gitCommitDetail: (projectPath, hash) => ipcRenderer.invoke('git:commitDetail', projectPath, hash),
  gitDiffCommit: (projectPath, hash, filePath) => ipcRenderer.invoke('git:diffCommit', projectPath, hash, filePath),
  gitDiffStat: (projectPath, staged) => ipcRenderer.invoke('git:diffStat', projectPath, staged),
```

- [ ] **Step 4: Commit**

```
git add main.js preload.js
git commit -m "feat: add git graphLog, commitDetail, diffCommit, diffStat IPC handlers"
```

---

### Task 2: Column System Guards for Diff Columns (renderer.js)

**Files:**
- Modify: `renderer.js:733` (`createColumnHeader`)
- Modify: `renderer.js:1227` (`removeColumn`)
- Modify: `renderer.js:1298` (`restartColumn`)
- Modify: `renderer.js:1562` (`refitAll`)

- [ ] **Step 1: Modify `createColumnHeader` to accept opts parameter**

At `renderer.js:733`, change the function signature and add conditional button creation:

```javascript
function createColumnHeader(id, customTitle, opts) {
  opts = opts || {};
  var header = document.createElement('div');
  header.className = 'column-header';
  var title = document.createElement('span');
  title.className = 'col-title';
  title.textContent = customTitle || ('Claude #' + id);
  title.addEventListener('dblclick', function () {
    startTitleEdit(id, title);
  });
  // Action buttons container (right side of header)
  var actions = document.createElement('span');
  actions.className = 'col-actions';

  if (!opts.isDiff) {
    var compactBtn = document.createElement('span');
    compactBtn.className = 'col-action';
    compactBtn.title = 'Compact context (/compact)';
    compactBtn.textContent = '\u229C';
    compactBtn.addEventListener('click', function () {
      wsSend({ type: 'write', id: id, data: '/compact\n' });
    });

    var teleportBtn = document.createElement('span');
    teleportBtn.className = 'col-action';
    teleportBtn.title = 'Teleport to claude.ai (/teleport)';
    teleportBtn.textContent = '\u21F1';
    teleportBtn.addEventListener('click', function () {
      wsSend({ type: 'write', id: id, data: '/teleport\n' });
    });

    var effortSelect = document.createElement('select');
    effortSelect.className = 'col-effort';
    effortSelect.title = 'Effort level';
    effortSelect.innerHTML = '<option value="">Effort</option><option value="low">Low</option><option value="medium">Med</option><option value="high">High</option>';
    effortSelect.addEventListener('change', function () {
      if (effortSelect.value) {
        wsSend({ type: 'write', id: id, data: '/config set effort ' + effortSelect.value + '\n' });
      }
    });
    effortSelect.addEventListener('mousedown', function (e) { e.stopPropagation(); });

    actions.appendChild(compactBtn);
    actions.appendChild(teleportBtn);
    actions.appendChild(effortSelect);
  }

  var maximizeBtn = document.createElement('span');
  maximizeBtn.className = 'col-maximize';
  maximizeBtn.title = 'Maximize';
  maximizeBtn.textContent = '\u25A1';
  maximizeBtn.addEventListener('click', function () {
    toggleMaximizeColumn(id);
  });

  if (!opts.isDiff) {
    var restartBtn = document.createElement('span');
    restartBtn.className = 'col-restart';
    restartBtn.dataset.id = String(id);
    restartBtn.title = 'Restart';
    restartBtn.textContent = '\u21bb';
    actions.appendChild(restartBtn);
  }

  var closeBtn = document.createElement('span');
  closeBtn.className = 'col-close';
  closeBtn.dataset.id = String(id);
  closeBtn.title = opts.isDiff ? 'Close' : 'Kill';
  closeBtn.textContent = '\u00d7';

  actions.appendChild(maximizeBtn);
  actions.appendChild(closeBtn);

  header.appendChild(title);
  header.appendChild(actions);

  // Double-click header (not title) to toggle maximize
  header.addEventListener('dblclick', function (e) {
    if (e.target === title || title.contains(e.target)) return;
    toggleMaximizeColumn(id);
  });

  return header;
}
```

- [ ] **Step 2: Guard `removeColumn` at line 1242 and 1256**

At `renderer.js:1242`, change:
```javascript
  wsSend({ type: 'kill', id: id });
```
To:
```javascript
  if (!col.isDiff) wsSend({ type: 'kill', id: id });
```

At `renderer.js:1256`, change:
```javascript
  col.terminal.dispose();
```
To:
```javascript
  if (col.terminal) col.terminal.dispose();
```

- [ ] **Step 3: Guard `restartColumn` at line 1298**

At `renderer.js:1298`, add early return after the null check:

```javascript
function restartColumn(id) {
  var col = allColumns.get(id);
  if (!col) return;
  if (col.isDiff) return; // diff columns cannot be restarted
```

- [ ] **Step 4: Guard `refitAll` at line 1565**

At `renderer.js:1565`, change:
```javascript
  state.columns.forEach(function (col, id) {
    try {
      col.fitAddon.fit();
```
To:
```javascript
  state.columns.forEach(function (col, id) {
    if (col.isDiff) return;
    try {
      col.fitAddon.fit();
```

- [ ] **Step 5: Commit**

```
git add renderer.js
git commit -m "feat: guard column system functions for non-terminal diff columns"
```

---

### Task 3: `addDiffColumn` Function and Diff Parser (renderer.js)

**Files:**
- Modify: `renderer.js` (add after `addColumn` function, around line 1110)

- [ ] **Step 1: Add `parseDiff` function**

Insert after the `addColumn` closing brace (around line 1110):

```javascript
// ============================================================
// Diff Column
// ============================================================

function parseDiff(diffText) {
  var hunks = [];
  if (!diffText || !diffText.trim()) return { hunks: hunks };
  var lines = diffText.split('\n');
  var currentHunk = null;
  var oldLine = 0;
  var newLine = 0;

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var hunkMatch = line.match(/^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@(.*)/);
    if (hunkMatch) {
      currentHunk = {
        oldStart: parseInt(hunkMatch[1]),
        oldCount: parseInt(hunkMatch[2]) || 1,
        newStart: parseInt(hunkMatch[3]),
        newCount: parseInt(hunkMatch[4]) || 1,
        header: line,
        lines: []
      };
      oldLine = currentHunk.oldStart;
      newLine = currentHunk.newStart;
      hunks.push(currentHunk);
      continue;
    }
    if (!currentHunk) continue;
    if (line.startsWith('+')) {
      currentHunk.lines.push({ type: 'add', content: line.substring(1), oldLine: null, newLine: newLine++ });
    } else if (line.startsWith('-')) {
      currentHunk.lines.push({ type: 'del', content: line.substring(1), oldLine: oldLine++, newLine: null });
    } else if (line.startsWith('\\')) {
      // "\ No newline at end of file" — skip
    } else {
      currentHunk.lines.push({ type: 'context', content: line.length > 0 ? line.substring(1) : '', oldLine: oldLine++, newLine: newLine++ });
    }
  }
  return { hunks: hunks };
}
```

- [ ] **Step 2: Add `addDiffColumn` function**

```javascript
function addDiffColumn(diffData, opts) {
  opts = opts || {};
  if (!activeProjectKey) return;

  var state = getActiveState();
  if (!state) return;

  // Deduplication check
  var existingId = null;
  state.columns.forEach(function (col, id) {
    if (!col.isDiff) return;
    if (diffData.commitHash && col.diffData.commitHash === diffData.commitHash && col.diffData.filePath === diffData.filePath) existingId = id;
    if (!diffData.commitHash && !col.diffData.commitHash && col.diffData.filePath === diffData.filePath && col.diffData.staged === diffData.staged) existingId = id;
  });
  if (existingId !== null) {
    var existingCol = allColumns.get(existingId);
    if (existingCol) existingCol.element.scrollIntoView({ behavior: 'smooth' });
    return;
  }

  var row = getActiveRow(state);
  if (!row) row = addRowToProject(state);

  var id = ++globalColumnId;
  var col = document.createElement('div');
  col.className = 'column diff-column';
  col.id = 'col-' + id;
  col.style.flex = '1';

  var title = opts.title || diffData.filePath || 'Diff';
  var header = createColumnHeader(id, title, { isDiff: true });

  // Diff mode toggle button
  var toggleBtn = document.createElement('span');
  toggleBtn.className = 'col-action diff-toggle';
  toggleBtn.title = 'Toggle unified/split view';
  toggleBtn.textContent = '\u2194'; // ↔
  var headerActions = header.querySelector('.col-actions');
  headerActions.insertBefore(toggleBtn, headerActions.firstChild);

  var diffBody = document.createElement('div');
  diffBody.className = 'diff-body';

  col.appendChild(header);
  col.appendChild(diffBody);

  // Add resize handle if not the first column
  if (row.columnIds.length > 0) {
    var handle = document.createElement('div');
    handle.className = 'resize-handle';
    row.rowEl.appendChild(handle);
    setupResizeHandle(handle);
  }

  row.rowEl.appendChild(col);

  var colData = {
    element: col,
    terminal: null,
    isDiff: true,
    diffData: diffData,
    diffMode: 'unified',
    headerEl: header,
    cwd: activeProjectKey,
    projectKey: activeProjectKey,
    customTitle: title,
    createdAt: Date.now()
  };

  row.columnIds.push(id);
  state.columns.set(id, colData);
  allColumns.set(id, colData);

  // Toggle button handler
  toggleBtn.addEventListener('click', function () {
    colData.diffMode = colData.diffMode === 'unified' ? 'split' : 'unified';
    toggleBtn.textContent = colData.diffMode === 'unified' ? '\u2194' : '\u2016';
    renderDiffContent(diffBody, colData);
  });

  // Close button handler
  header.querySelector('.col-close').addEventListener('click', function () {
    removeColumn(id);
  });

  // Render diff content
  if (diffData.diffText) {
    renderDiffContent(diffBody, colData);
  } else if (diffData.commitHash) {
    loadCommitDiff(diffBody, colData);
  } else {
    loadWorkingDiff(diffBody, colData);
  }

  setFocusedColumn(id);
  saveColumnCounts();
  renderProjectList();
}
```

- [ ] **Step 3: Add diff loading and rendering functions**

```javascript
function loadWorkingDiff(diffBody, colData) {
  diffBody.textContent = 'Loading...';
  window.electronAPI.gitDiff(activeProjectKey, colData.diffData.filePath, colData.diffData.staged || false).then(function (text) {
    colData.diffData.diffText = text;
    colData.diffData.parsed = parseDiff(text);
    renderDiffContent(diffBody, colData);
  });
}

function loadCommitDiff(diffBody, colData) {
  diffBody.textContent = 'Loading...';
  var hash = colData.diffData.commitHash;

  if (colData.diffData.filePath) {
    // Single file diff
    window.electronAPI.gitDiffCommit(activeProjectKey, hash, colData.diffData.filePath).then(function (text) {
      colData.diffData.diffText = text;
      colData.diffData.parsed = parseDiff(text);
      renderDiffContent(diffBody, colData);
    });
  } else {
    // Full commit — load detail then show file tabs
    window.electronAPI.gitCommitDetail(activeProjectKey, hash).then(function (detail) {
      colData.diffData.commitDetail = detail;
      colData.diffData.files = detail.files || [];
      if (detail.files.length > 0) {
        colData.diffData.activeFile = detail.files[0].file;
        return window.electronAPI.gitDiffCommit(activeProjectKey, hash, detail.files[0].file);
      }
      return '';
    }).then(function (text) {
      colData.diffData.diffText = text;
      colData.diffData.parsed = parseDiff(text);
      renderDiffContent(diffBody, colData);
    });
  }
}

function renderDiffContent(diffBody, colData) {
  while (diffBody.firstChild) diffBody.removeChild(diffBody.firstChild);
  var parsed = colData.diffData.parsed;
  if (!parsed || parsed.hunks.length === 0) {
    var empty = document.createElement('div');
    empty.className = 'diff-empty';
    empty.textContent = '(no changes)';
    diffBody.appendChild(empty);
    return;
  }

  // File tabs for multi-file commit diffs
  if (colData.diffData.commitDetail && colData.diffData.files && colData.diffData.files.length > 1) {
    var tabBar = document.createElement('div');
    tabBar.className = 'diff-file-tabs';
    for (var t = 0; t < colData.diffData.files.length; t++) {
      (function (fileInfo) {
        var tab = document.createElement('button');
        tab.className = 'diff-file-tab' + (fileInfo.file === colData.diffData.activeFile ? ' active' : '');
        tab.textContent = fileInfo.file.split('/').pop();
        tab.title = fileInfo.file;
        tab.addEventListener('click', function () {
          colData.diffData.activeFile = fileInfo.file;
          diffBody.textContent = 'Loading...';
          window.electronAPI.gitDiffCommit(activeProjectKey, colData.diffData.commitHash, fileInfo.file).then(function (text) {
            colData.diffData.diffText = text;
            colData.diffData.parsed = parseDiff(text);
            renderDiffContent(diffBody, colData);
          });
        });
        tabBar.appendChild(tab);
      })(colData.diffData.files[t]);
    }
    diffBody.appendChild(tabBar);
  }

  // Render diff based on mode
  var container = document.createElement('div');
  container.className = 'diff-content';
  if (colData.diffMode === 'split') {
    renderSplitDiff(container, parsed);
  } else {
    renderUnifiedDiff(container, parsed);
  }
  diffBody.appendChild(container);

  // Truncation warning
  var totalLines = 0;
  for (var h = 0; h < parsed.hunks.length; h++) totalLines += parsed.hunks[h].lines.length;
  if (totalLines > 5000) {
    var warn = document.createElement('div');
    warn.className = 'diff-truncated';
    warn.textContent = 'Diff too large — showing first 5000 lines';
    diffBody.appendChild(warn);
  }
}

function renderUnifiedDiff(container, parsed) {
  for (var h = 0; h < parsed.hunks.length; h++) {
    var hunk = parsed.hunks[h];
    // Hunk header
    var hunkHeader = document.createElement('div');
    hunkHeader.className = 'diff-hunk-header';
    hunkHeader.textContent = hunk.header;
    container.appendChild(hunkHeader);

    for (var i = 0; i < hunk.lines.length && i < 5000; i++) {
      var lineData = hunk.lines[i];
      var row = document.createElement('div');
      row.className = 'diff-line diff-line-' + lineData.type;

      var oldNum = document.createElement('span');
      oldNum.className = 'diff-line-num';
      oldNum.textContent = lineData.oldLine !== null ? lineData.oldLine : '';

      var newNum = document.createElement('span');
      newNum.className = 'diff-line-num';
      newNum.textContent = lineData.newLine !== null ? lineData.newLine : '';

      var prefix = document.createElement('span');
      prefix.className = 'diff-line-prefix';
      prefix.textContent = lineData.type === 'add' ? '+' : lineData.type === 'del' ? '-' : ' ';

      var content = document.createElement('span');
      content.className = 'diff-line-content';
      content.textContent = lineData.content;

      row.appendChild(oldNum);
      row.appendChild(newNum);
      row.appendChild(prefix);
      row.appendChild(content);
      container.appendChild(row);
    }
  }
}

function renderSplitDiff(container, parsed) {
  var leftPanel = document.createElement('div');
  leftPanel.className = 'diff-split-panel diff-split-left';
  var rightPanel = document.createElement('div');
  rightPanel.className = 'diff-split-panel diff-split-right';

  for (var h = 0; h < parsed.hunks.length; h++) {
    var hunk = parsed.hunks[h];
    // Hunk headers
    var lhdr = document.createElement('div');
    lhdr.className = 'diff-hunk-header';
    lhdr.textContent = hunk.header;
    leftPanel.appendChild(lhdr);
    var rhdr = document.createElement('div');
    rhdr.className = 'diff-hunk-header';
    rhdr.textContent = hunk.header;
    rightPanel.appendChild(rhdr);

    // Pair up lines: deletions on left, additions on right, context on both
    var delQueue = [];
    var addQueue = [];
    function flushQueues() {
      var maxLen = Math.max(delQueue.length, addQueue.length);
      for (var q = 0; q < maxLen; q++) {
        var ld = delQueue[q];
        var la = addQueue[q];
        var leftRow = document.createElement('div');
        leftRow.className = 'diff-line ' + (ld ? 'diff-line-del' : 'diff-line-empty');
        var leftNum = document.createElement('span');
        leftNum.className = 'diff-line-num';
        leftNum.textContent = ld ? ld.oldLine : '';
        var leftContent = document.createElement('span');
        leftContent.className = 'diff-line-content';
        leftContent.textContent = ld ? ld.content : '';
        leftRow.appendChild(leftNum);
        leftRow.appendChild(leftContent);
        leftPanel.appendChild(leftRow);

        var rightRow = document.createElement('div');
        rightRow.className = 'diff-line ' + (la ? 'diff-line-add' : 'diff-line-empty');
        var rightNum = document.createElement('span');
        rightNum.className = 'diff-line-num';
        rightNum.textContent = la ? la.newLine : '';
        var rightContent = document.createElement('span');
        rightContent.className = 'diff-line-content';
        rightContent.textContent = la ? la.content : '';
        rightRow.appendChild(rightNum);
        rightRow.appendChild(rightContent);
        rightPanel.appendChild(rightRow);
      }
      delQueue = [];
      addQueue = [];
    }

    for (var i = 0; i < hunk.lines.length; i++) {
      var line = hunk.lines[i];
      if (line.type === 'del') {
        delQueue.push(line);
      } else if (line.type === 'add') {
        addQueue.push(line);
      } else {
        flushQueues();
        var cl = document.createElement('div');
        cl.className = 'diff-line diff-line-context';
        var cln = document.createElement('span');
        cln.className = 'diff-line-num';
        cln.textContent = line.oldLine;
        var clc = document.createElement('span');
        clc.className = 'diff-line-content';
        clc.textContent = line.content;
        cl.appendChild(cln);
        cl.appendChild(clc);
        leftPanel.appendChild(cl);

        var cr = document.createElement('div');
        cr.className = 'diff-line diff-line-context';
        var crn = document.createElement('span');
        crn.className = 'diff-line-num';
        crn.textContent = line.newLine;
        var crc = document.createElement('span');
        crc.className = 'diff-line-content';
        crc.textContent = line.content;
        cr.appendChild(crn);
        cr.appendChild(crc);
        rightPanel.appendChild(cr);
      }
    }
    flushQueues();
  }

  container.classList.add('diff-split-container');
  container.appendChild(leftPanel);
  container.appendChild(rightPanel);

  // Synchronized scrolling
  leftPanel.addEventListener('scroll', function () { rightPanel.scrollTop = leftPanel.scrollTop; });
  rightPanel.addEventListener('scroll', function () { leftPanel.scrollTop = rightPanel.scrollTop; });
}
```

- [ ] **Step 4: Commit**

```
git add renderer.js
git commit -m "feat: add addDiffColumn, diff parser, unified and split diff renderers"
```

---

### Task 4: Diff Viewer CSS (styles.css)

**Files:**
- Modify: `styles.css` (add after existing git styles, around line 1823)

- [ ] **Step 1: Add diff viewer styles**

Append after the existing git CSS section:

```css
/* Diff Column */

.diff-column {
  display: flex;
  flex-direction: column;
  background: var(--bg-primary);
}

.diff-body {
  flex: 1;
  overflow: auto;
  font-family: 'Cascadia Code', 'Consolas', 'Courier New', monospace;
  font-size: 12px;
  line-height: 1.5;
}

.diff-empty {
  padding: 20px;
  color: var(--text-dimmer);
  text-align: center;
}

.diff-truncated {
  padding: 8px 12px;
  color: var(--color-yellow);
  font-size: 11px;
  text-align: center;
  border-top: 1px solid var(--border-subtle);
}

/* Diff file tabs */

.diff-file-tabs {
  display: flex;
  overflow-x: auto;
  border-bottom: 1px solid var(--border-subtle);
  background: var(--bg-secondary);
  flex-shrink: 0;
}

.diff-file-tab {
  padding: 4px 12px;
  border: none;
  background: none;
  color: var(--text-dim);
  font-size: 11px;
  font-family: inherit;
  cursor: pointer;
  white-space: nowrap;
  border-bottom: 2px solid transparent;
}

.diff-file-tab:hover {
  color: var(--text-primary);
  background: var(--hover-subtle);
}

.diff-file-tab.active {
  color: var(--text-primary);
  border-bottom-color: var(--accent);
}

/* Diff lines */

.diff-content {
  min-width: fit-content;
}

.diff-hunk-header {
  padding: 4px 12px;
  background: var(--bg-deep);
  color: var(--color-cyan);
  font-size: 11px;
  border-top: 1px solid var(--border-subtle);
  border-bottom: 1px solid var(--border-subtle);
  user-select: none;
}

.diff-line {
  display: flex;
  min-height: 20px;
  white-space: pre;
}

.diff-line-num {
  width: 40px;
  min-width: 40px;
  padding: 0 6px;
  text-align: right;
  color: var(--text-dimmer);
  user-select: none;
  flex-shrink: 0;
}

.diff-line-prefix {
  width: 14px;
  min-width: 14px;
  text-align: center;
  flex-shrink: 0;
  user-select: none;
}

.diff-line-content {
  flex: 1;
  padding-right: 12px;
}

.diff-line-add {
  background: rgba(78, 201, 78, 0.08);
}

.diff-line-add .diff-line-prefix,
.diff-line-add .diff-line-content {
  color: var(--color-green);
}

.diff-line-del {
  background: rgba(229, 57, 70, 0.08);
}

.diff-line-del .diff-line-prefix,
.diff-line-del .diff-line-content {
  color: var(--accent);
}

.diff-line-empty {
  background: var(--bg-deep);
}

/* Split view */

.diff-split-container {
  display: flex;
  flex: 1;
}

.diff-split-panel {
  flex: 1;
  overflow-y: auto;
  overflow-x: auto;
  min-width: 0;
}

.diff-split-left {
  border-right: 1px solid var(--border-subtle);
}

/* Diff toggle button */

.diff-toggle {
  font-size: 14px;
}

/* Light theme overrides */

[data-theme="light"] .diff-line-add {
  background: rgba(40, 167, 69, 0.1);
}

[data-theme="light"] .diff-line-del {
  background: rgba(220, 53, 69, 0.1);
}
```

- [ ] **Step 2: Commit**

```
git add styles.css
git commit -m "feat: add diff viewer CSS for unified, split, file tabs, and light theme"
```

---

### Task 5: File Change Tree View (renderer.js)

**Files:**
- Modify: `renderer.js:1869-1895` (`refreshGitStatus`)
- Modify: `renderer.js:1897` (`renderGitStatus`)
- Modify: `renderer.js:2151-2302` (replace `createGitSection` and `createGitFileRow`)
- Remove: `renderer.js:1867` (`gitExpandedDiff` variable)

- [ ] **Step 1: Update `refreshGitStatus` to fetch 7 data sources**

Replace `refreshGitStatus` (lines 1869-1895) with:

```javascript
function refreshGitStatus(force) {
  if (!activeProjectKey || !window.electronAPI) return;

  var fetchAll = [
    window.electronAPI.gitStatus(activeProjectKey),
    window.electronAPI.gitBranch(activeProjectKey),
    window.electronAPI.gitAheadBehind(activeProjectKey),
    window.electronAPI.gitStashList(activeProjectKey),
    window.electronAPI.gitGraphLog(activeProjectKey, 50),
    window.electronAPI.gitDiffStat(activeProjectKey, false),
    window.electronAPI.gitDiffStat(activeProjectKey, true)
  ];

  if (!force) {
    Promise.all(fetchAll).then(function (results) {
      var rawKey = JSON.stringify(results[0]) + '|' + results[1] + '|' + JSON.stringify(results[2]) + '|' + results[3].length + '|' + JSON.stringify(results[4]);
      if (rawKey === lastGitRaw) return;
      lastGitRaw = rawKey;
      renderGitStatus(results[0], results[1], results[2], results[3], results[4], results[5], results[6]);
    });
    return;
  }

  lastGitRaw = null;
  Promise.all(fetchAll).then(function (results) {
    lastGitRaw = JSON.stringify(results[0]) + '|' + results[1] + '|' + JSON.stringify(results[2]) + '|' + results[3].length + '|' + JSON.stringify(results[4]);
    renderGitStatus(results[0], results[1], results[2], results[3], results[4], results[5], results[6]);
  });
}
```

- [ ] **Step 2: Update `renderGitStatus` signature**

Change the function signature at line 1897 from:

```javascript
function renderGitStatus(files, branch, aheadBehind, stashes, commits) {
```

To:

```javascript
function renderGitStatus(files, branch, aheadBehind, stashes, graphLog, unstagedStats, stagedStats) {
```

And update the two `createGitSection` calls to pass stats, and replace `createGitLogSection(commits)` with the graph section (Task 6). For now, pass stats to `createGitSection`:

Change:
```javascript
  if (staged.length > 0) {
    gitChangesEl.appendChild(createGitSection('Staged Changes', staged, true));
  }
  if (changes.length > 0) {
    gitChangesEl.appendChild(createGitSection('Changes', changes, false));
  }
```
To:
```javascript
  if (staged.length > 0) {
    gitChangesEl.appendChild(createGitSection('Staged Changes', staged, true, stagedStats));
  }
  if (changes.length > 0) {
    gitChangesEl.appendChild(createGitSection('Changes', changes, false, unstagedStats));
  }
```

And replace the commit log section:
```javascript
  if (commits.length > 0) {
    gitChangesEl.appendChild(createGitLogSection(commits));
  }
```
With:
```javascript
  if (graphLog.length > 0) {
    gitChangesEl.appendChild(createGitGraphSection(graphLog));
  }
```

- [ ] **Step 3: Remove `gitExpandedDiff` variable**

Delete line 1867:
```javascript
var gitExpandedDiff = null; // track which file has diff open
```

- [ ] **Step 4: Add `buildFileTree` helper and replace `createGitSection`**

Replace `createGitSection` (lines 2151-2205) with:

```javascript
function buildFileTree(files) {
  var root = { folders: {}, files: [] };
  for (var i = 0; i < files.length; i++) {
    var parts = files[i].file.replace(/\\/g, '/').split('/');
    var node = root;
    for (var p = 0; p < parts.length - 1; p++) {
      if (!node.folders[parts[p]]) node.folders[parts[p]] = { folders: {}, files: [] };
      node = node.folders[parts[p]];
    }
    node.files.push(files[i]);
  }
  return root;
}

function countTreeFiles(node) {
  var count = node.files.length;
  for (var k in node.folders) count += countTreeFiles(node.folders[k]);
  return count;
}

function createGitSection(title, files, isStaged, stats) {
  var section = document.createElement('div');
  section.className = 'git-section';

  var header = document.createElement('div');
  header.className = 'git-section-header';

  var arrow = document.createElement('span');
  arrow.className = 'git-section-arrow';
  arrow.textContent = '\u25BE';

  var label = document.createElement('span');
  label.className = 'git-section-label';
  label.textContent = title + ' (' + files.length + ')';

  var actions = document.createElement('span');
  actions.className = 'git-section-actions';

  if (isStaged) {
    var unstageAllBtn = document.createElement('button');
    unstageAllBtn.className = 'git-file-action';
    unstageAllBtn.textContent = '\u2212';
    unstageAllBtn.title = 'Unstage All';
    unstageAllBtn.addEventListener('click', function (e) { e.stopPropagation(); gitUnstageAll(); });
    actions.appendChild(unstageAllBtn);
  } else {
    var stageAllBtn = document.createElement('button');
    stageAllBtn.className = 'git-file-action';
    stageAllBtn.textContent = '+';
    stageAllBtn.title = 'Stage All';
    stageAllBtn.addEventListener('click', function (e) { e.stopPropagation(); gitStageAll(); });
    actions.appendChild(stageAllBtn);
  }

  header.appendChild(arrow);
  header.appendChild(label);
  header.appendChild(actions);
  section.appendChild(header);

  var list = document.createElement('div');
  list.className = 'git-section-list';

  // Build and render tree
  var statsMap = {};
  if (stats) {
    for (var s = 0; s < stats.length; s++) {
      statsMap[stats[s].file] = stats[s];
    }
  }
  var tree = buildFileTree(files);
  renderFileTreeNode(list, tree, isStaged, statsMap, 0);

  section.appendChild(list);

  header.addEventListener('click', function () {
    var collapsed = list.style.display === 'none';
    list.style.display = collapsed ? 'block' : 'none';
    arrow.textContent = collapsed ? '\u25BE' : '\u25B8';
  });

  return section;
}

function renderFileTreeNode(container, node, isStaged, statsMap, depth) {
  // Sort folders first, then files
  var folderNames = Object.keys(node.folders).sort();
  for (var f = 0; f < folderNames.length; f++) {
    (function (folderName) {
      var folder = node.folders[folderName];
      var folderEl = document.createElement('div');
      folderEl.className = 'git-tree-folder';

      var folderHeader = document.createElement('div');
      folderHeader.className = 'git-tree-folder-header';
      folderHeader.style.paddingLeft = (8 + depth * 12) + 'px';

      var folderArrow = document.createElement('span');
      folderArrow.className = 'git-tree-arrow';
      folderArrow.textContent = '\u25BE';

      var folderLabel = document.createElement('span');
      folderLabel.className = 'git-tree-folder-name';
      folderLabel.textContent = folderName + '/';

      var folderCount = document.createElement('span');
      folderCount.className = 'git-tree-count';
      folderCount.textContent = countTreeFiles(folder);

      folderHeader.appendChild(folderArrow);
      folderHeader.appendChild(folderLabel);
      folderHeader.appendChild(folderCount);
      folderEl.appendChild(folderHeader);

      var folderContent = document.createElement('div');
      folderContent.className = 'git-tree-folder-content';
      renderFileTreeNode(folderContent, folder, isStaged, statsMap, depth + 1);
      folderEl.appendChild(folderContent);

      folderHeader.addEventListener('click', function () {
        var collapsed = folderContent.style.display === 'none';
        folderContent.style.display = collapsed ? '' : 'none';
        folderArrow.textContent = collapsed ? '\u25BE' : '\u25B8';
      });

      container.appendChild(folderEl);
    })(folderNames[f]);
  }

  // Files
  for (var i = 0; i < node.files.length; i++) {
    container.appendChild(createGitFileRow(node.files[i], isStaged, statsMap, depth));
  }
}
```

- [ ] **Step 5: Replace `createGitFileRow` to use tree layout + diff column + stats**

Replace `createGitFileRow` (lines 2207-2302) with:

```javascript
function createGitFileRow(file, isStaged, statsMap, depth) {
  var container = document.createElement('div');
  container.className = 'git-file-container';

  var row = document.createElement('div');
  row.className = 'git-file';
  row.style.paddingLeft = (8 + (depth || 0) * 12) + 'px';

  var statusEl = document.createElement('span');
  statusEl.className = 'git-status git-status-' + gitStatusClass(file.status);
  statusEl.textContent = file.status;

  var nameEl = document.createElement('span');
  nameEl.className = 'git-filename';
  // Show only the filename (not path) since tree shows the path
  var parts = file.file.replace(/\\/g, '/').split('/');
  nameEl.textContent = parts[parts.length - 1];
  nameEl.title = file.file + ' — Click to view diff';

  // Click filename to open diff in main area
  nameEl.addEventListener('click', function (e) {
    e.stopPropagation();
    addDiffColumn({
      filePath: file.file,
      staged: isStaged,
      status: file.status
    }, { title: parts[parts.length - 1] + ' (' + file.status + ')' });
  });

  // Stat counts
  var statEl = document.createElement('span');
  statEl.className = 'git-file-stat';
  var fileStat = statsMap ? statsMap[file.file] : null;
  if (fileStat) {
    if (fileStat.insertions > 0) {
      var addStat = document.createElement('span');
      addStat.className = 'git-stat-add';
      addStat.textContent = '+' + fileStat.insertions;
      statEl.appendChild(addStat);
    }
    if (fileStat.deletions > 0) {
      var delStat = document.createElement('span');
      delStat.className = 'git-stat-del';
      delStat.textContent = '\u2212' + fileStat.deletions;
      statEl.appendChild(delStat);
    }
  }

  var actions = document.createElement('span');
  actions.className = 'git-file-actions';

  if (isStaged) {
    var unstageBtn = document.createElement('button');
    unstageBtn.className = 'git-file-action';
    unstageBtn.textContent = '\u2212';
    unstageBtn.title = 'Unstage';
    unstageBtn.addEventListener('click', function (e) { e.stopPropagation(); gitUnstageFile(file.file); });
    actions.appendChild(unstageBtn);
  } else {
    var stageBtn = document.createElement('button');
    stageBtn.className = 'git-file-action';
    stageBtn.textContent = '+';
    stageBtn.title = 'Stage';
    stageBtn.addEventListener('click', function (e) { e.stopPropagation(); gitStageFile(file.file); });
    actions.appendChild(stageBtn);

    if (!file.untracked) {
      var discardBtn = document.createElement('button');
      discardBtn.className = 'git-file-action git-discard';
      discardBtn.textContent = '\u21A9';
      discardBtn.title = 'Discard Changes';
      discardBtn.addEventListener('click', function (e) { e.stopPropagation(); gitDiscardFile(file.file); });
      actions.appendChild(discardBtn);
    }
  }

  row.appendChild(statusEl);
  row.appendChild(nameEl);
  row.appendChild(statEl);
  row.appendChild(actions);
  container.appendChild(row);
  return container;
}
```

- [ ] **Step 6: Remove old `createGitLogSection` function**

Delete the entire `createGitLogSection` function (lines 2088-2134). It is replaced by `createGitGraphSection` in Task 6.

- [ ] **Step 7: Add tree view CSS to styles.css**

Append to git styles section in `styles.css`:

```css
/* File tree */

.git-tree-folder-header {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 2px 8px;
  cursor: pointer;
  font-size: 12px;
  color: var(--text-secondary);
  user-select: none;
}

.git-tree-folder-header:hover {
  background: var(--hover-subtle);
}

.git-tree-arrow {
  width: 10px;
  font-size: 10px;
  flex-shrink: 0;
  color: var(--text-dimmer);
}

.git-tree-folder-name {
  color: var(--text-secondary);
}

.git-tree-count {
  font-size: 10px;
  color: var(--text-dimmer);
  margin-left: auto;
  padding: 0 4px;
}

.git-file-stat {
  display: flex;
  gap: 4px;
  font-size: 10px;
  margin-left: auto;
  flex-shrink: 0;
  padding-right: 4px;
}

.git-stat-add {
  color: var(--color-green);
}

.git-stat-del {
  color: var(--accent);
}
```

- [ ] **Step 8: Commit**

```
git add renderer.js styles.css
git commit -m "feat: file change tree view with folder grouping, stats, and click-to-diff"
```

---

### Task 6: Visual Commit Graph (renderer.js + styles.css)

**Files:**
- Modify: `renderer.js` (add after the git section functions)
- Modify: `styles.css` (add commit graph styles)

- [ ] **Step 1: Add lane assignment algorithm**

Add in `renderer.js` after the `createGitSection`/`renderFileTreeNode` functions:

```javascript
// ============================================================
// Commit Graph
// ============================================================

var graphLaneState = null; // persisted across "load more"

function computeGraphLanes(commits, existingState) {
  var lanes = existingState ? existingState.lanes.slice() : [];
  var commitLanes = existingState ? JSON.parse(JSON.stringify(existingState.commitLanes)) : {};

  function findFreeLane() {
    for (var i = 0; i < lanes.length; i++) {
      if (lanes[i] === null) return i;
    }
    lanes.push(null);
    return lanes.length - 1;
  }

  for (var c = 0; c < commits.length; c++) {
    var commit = commits[c];
    var myLane;
    commit.mergeFromLanes = [];

    if (commitLanes[commit.hash] !== undefined) {
      myLane = commitLanes[commit.hash];
    } else {
      myLane = findFreeLane();
      lanes[myLane] = commit.hash;
    }
    commit.lane = myLane;
    commit.activeLanes = lanes.slice(); // snapshot for rendering vertical lines

    if (commit.parents.length === 0) {
      lanes[myLane] = null;
    } else if (commit.parents.length === 1) {
      lanes[myLane] = commit.parents[0];
      commitLanes[commit.parents[0]] = myLane;
    } else {
      // First parent continues the lane
      lanes[myLane] = commit.parents[0];
      commitLanes[commit.parents[0]] = myLane;
      // Additional parents
      for (var p = 1; p < commit.parents.length; p++) {
        var parent = commit.parents[p];
        if (commitLanes[parent] !== undefined) {
          commit.mergeFromLanes.push(commitLanes[parent]);
        } else {
          var parentLane = findFreeLane();
          lanes[parentLane] = parent;
          commitLanes[parent] = parentLane;
          commit.mergeFromLanes.push(parentLane);
        }
      }
    }

    // Cap at 5 lanes
    while (lanes.length > 5) {
      var last = lanes.length - 1;
      if (lanes[last] !== null) {
        // Merge into lane 4
        if (commit.lane === last) commit.lane = 4;
        commitLanes[lanes[last]] = 4;
        lanes[4] = lanes[last];
      }
      lanes.pop();
    }
  }

  return { commits: commits, lanes: lanes, commitLanes: commitLanes };
}
```

- [ ] **Step 2: Add graph SVG renderer**

```javascript
var GRAPH_LANE_COLORS = ['var(--accent)', 'var(--color-green)', 'var(--color-cyan)', 'var(--accent)', 'var(--color-green)'];
var GRAPH_ROW_HEIGHT = 28;
var GRAPH_LANE_WIDTH = 10;
var GRAPH_PADDING = 8;

function renderGraphSvg(commit) {
  var maxLanes = 0;
  for (var a = 0; a < commit.activeLanes.length; a++) {
    if (commit.activeLanes[a] !== null) maxLanes = a + 1;
  }
  maxLanes = Math.max(maxLanes, commit.lane + 1);
  var svgWidth = GRAPH_PADDING + maxLanes * GRAPH_LANE_WIDTH + GRAPH_PADDING;

  var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('width', svgWidth);
  svg.setAttribute('height', GRAPH_ROW_HEIGHT);
  svg.style.flexShrink = '0';

  var cy = GRAPH_ROW_HEIGHT / 2;

  // Draw vertical lines for active lanes
  for (var i = 0; i < commit.activeLanes.length; i++) {
    if (commit.activeLanes[i] === null) continue;
    var lx = GRAPH_PADDING + i * GRAPH_LANE_WIDTH + GRAPH_LANE_WIDTH / 2;
    var line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
    line.setAttribute('x1', lx);
    line.setAttribute('y1', 0);
    line.setAttribute('x2', lx);
    line.setAttribute('y2', GRAPH_ROW_HEIGHT);
    line.setAttribute('stroke', GRAPH_LANE_COLORS[i % GRAPH_LANE_COLORS.length]);
    line.setAttribute('stroke-width', '2');
    svg.appendChild(line);
  }

  // Draw merge lines
  for (var m = 0; m < commit.mergeFromLanes.length; m++) {
    var fromLane = commit.mergeFromLanes[m];
    var fromX = GRAPH_PADDING + fromLane * GRAPH_LANE_WIDTH + GRAPH_LANE_WIDTH / 2;
    var toX = GRAPH_PADDING + commit.lane * GRAPH_LANE_WIDTH + GRAPH_LANE_WIDTH / 2;
    var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', 'M' + fromX + ' 0 C ' + fromX + ' ' + cy + ' ' + toX + ' ' + cy + ' ' + toX + ' ' + cy);
    path.setAttribute('stroke', GRAPH_LANE_COLORS[fromLane % GRAPH_LANE_COLORS.length]);
    path.setAttribute('stroke-width', '2');
    path.setAttribute('fill', 'none');
    svg.appendChild(path);
  }

  // Draw commit node
  var cx = GRAPH_PADDING + commit.lane * GRAPH_LANE_WIDTH + GRAPH_LANE_WIDTH / 2;
  var circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
  circle.setAttribute('cx', cx);
  circle.setAttribute('cy', cy);
  circle.setAttribute('r', '3');
  circle.setAttribute('fill', GRAPH_LANE_COLORS[commit.lane % GRAPH_LANE_COLORS.length]);
  svg.appendChild(circle);

  return svg;
}
```

- [ ] **Step 3: Add `createGitGraphSection`**

```javascript
function createGitGraphSection(graphLog) {
  var state = computeGraphLanes(graphLog, graphLaneState);
  graphLaneState = { lanes: state.lanes, commitLanes: state.commitLanes };

  var section = document.createElement('div');
  section.className = 'git-section';

  var header = document.createElement('div');
  header.className = 'git-section-header';
  var arrow = document.createElement('span');
  arrow.className = 'git-section-arrow';
  arrow.textContent = '\u25BE';
  var label = document.createElement('span');
  label.className = 'git-section-label';
  label.textContent = 'Commits (' + graphLog.length + ')';
  header.appendChild(arrow);
  header.appendChild(label);
  section.appendChild(header);

  var list = document.createElement('div');
  list.className = 'git-section-list git-graph-list';

  for (var i = 0; i < state.commits.length; i++) {
    (function (commit) {
      var row = document.createElement('div');
      row.className = 'git-graph-row';
      row.addEventListener('click', function () {
        addDiffColumn({
          commitHash: commit.hash,
          filePath: null
        }, { title: commit.abbrev + ' — ' + commit.message });
      });

      var svg = renderGraphSvg(commit);
      row.appendChild(svg);

      var hashEl = document.createElement('span');
      hashEl.className = 'git-graph-hash';
      hashEl.textContent = commit.abbrev;

      var msgEl = document.createElement('span');
      msgEl.className = 'git-graph-msg';
      msgEl.textContent = commit.message;

      // Ref badges
      var refsEl = document.createElement('span');
      refsEl.className = 'git-graph-refs';
      for (var r = 0; r < commit.refs.length; r++) {
        var ref = commit.refs[r];
        var badge = document.createElement('span');
        badge.className = 'git-graph-ref' + (ref.startsWith('tag:') ? ' git-graph-tag' : '');
        badge.textContent = ref.replace(/^HEAD -> /, '').replace(/^tag: /, '');
        refsEl.appendChild(badge);
      }

      var authorEl = document.createElement('span');
      authorEl.className = 'git-graph-author';
      authorEl.textContent = commit.author;

      var dateEl = document.createElement('span');
      dateEl.className = 'git-graph-date';
      dateEl.textContent = commit.relativeDate;

      row.appendChild(hashEl);
      row.appendChild(msgEl);
      row.appendChild(refsEl);
      row.appendChild(authorEl);
      row.appendChild(dateEl);
      list.appendChild(row);
    })(state.commits[i]);
  }

  section.appendChild(list);

  header.addEventListener('click', function () {
    var collapsed = list.style.display === 'none';
    list.style.display = collapsed ? '' : 'none';
    arrow.textContent = collapsed ? '\u25BE' : '\u25B8';
  });

  return section;
}
```

- [ ] **Step 4: Reset graph state on project switch**

Find where `renderGitStatus` is — at the top of the function, add:

```javascript
  graphLaneState = null; // reset lane state on re-render
```

(Add as the first line inside `renderGitStatus`, before the `while` loops that clear children.)

- [ ] **Step 5: Add commit graph CSS**

Append to `styles.css`:

```css
/* Commit Graph */

.git-graph-list {
  max-height: 400px;
  overflow-y: auto;
}

.git-graph-row {
  display: flex;
  align-items: center;
  height: 28px;
  padding-right: 8px;
  cursor: pointer;
  gap: 6px;
  font-size: 12px;
}

.git-graph-row:hover {
  background: var(--hover-subtle);
}

.git-graph-hash {
  font-family: 'Cascadia Code', 'Consolas', monospace;
  font-size: 11px;
  color: var(--text-dimmer);
  flex-shrink: 0;
  width: 44px;
}

.git-graph-msg {
  flex: 1;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--text-body);
}

.git-graph-refs {
  display: flex;
  gap: 3px;
  flex-shrink: 0;
}

.git-graph-ref {
  font-size: 9px;
  padding: 1px 5px;
  border-radius: 3px;
  background: rgba(var(--accent-rgb, 233,69,96), 0.15);
  color: var(--accent);
  white-space: nowrap;
}

.git-graph-tag {
  background: rgba(var(--color-cyan-rgb, 0,200,200), 0.15);
  color: var(--color-cyan);
}

.git-graph-author {
  font-size: 11px;
  color: var(--text-dimmer);
  flex-shrink: 0;
  width: 55px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.git-graph-date {
  font-size: 10px;
  color: var(--text-dimmer);
  flex-shrink: 0;
  width: 55px;
  text-align: right;
  white-space: nowrap;
}
```

- [ ] **Step 6: Commit**

```
git add renderer.js styles.css
git commit -m "feat: visual commit graph with lane algorithm, SVG rendering, and ref badges"
```

---

### Task 7: Integration Testing and Polish

**Files:**
- All modified files

- [ ] **Step 1: Syntax check all files**

```bash
node -c renderer.js && node -c preload.js && echo "All OK"
```

- [ ] **Step 2: Launch and test**

```bash
npx electron .
```

Verify:
- Git tab shows tree-structured file list with folder grouping
- File stat counts (+N −N) appear next to filenames
- Clicking a filename opens a diff column in the main area
- Unified/split toggle works in the diff column
- Commit graph shows with colored lane lines and commit nodes
- Clicking a commit opens its diff with file tabs
- Branch badges and tag badges appear on commits
- Stage/unstage/discard buttons still work
- Pull/push/stash/commit still work
- No console errors

- [ ] **Step 3: Commit any fixes**

```
git add -A
git commit -m "fix: integration fixes for git tab enhancement"
```
