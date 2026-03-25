# Scheduled Background Loops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent scheduled background agents that run Claude CLI on a recurring schedule, with a LOOPS explorer tab, flyout dashboard, and actionable attention items.

**Architecture:** Extends the existing 4-file architecture (main.js, preload.js, renderer.js, index.html). main.js gets a loop scheduler + execution engine using `child_process.spawn`. Renderer gets a new LOOPS explorer tab and a flyout dashboard panel. No new JS files — follows the existing monolithic pattern.

**Tech Stack:** Electron IPC, child_process.spawn (Claude CLI), vanilla JS DOM, CSS animations

**Spec:** `docs/superpowers/specs/2026-03-24-scheduled-loops-design.md`

---

### Task 1: Loops data persistence layer in main.js

**Files:**
- Modify: `main.js:15-38` (after CONFIG_FILE constant and read/write helpers)

Add loops.json read/write helpers and run history storage functions alongside the existing config helpers.

- [ ] **Step 1: Add loops constants and read/write functions**

After line 16 (`const CONFIG_FILE = ...`), add:

```javascript
const LOOPS_FILE = path.join(CONFIG_DIR, 'loops.json');
const LOOPS_RUNS_DIR = path.join(CONFIG_DIR, 'loop-runs');

function readLoops() {
  ensureConfigDir();
  try {
    return JSON.parse(fs.readFileSync(LOOPS_FILE, 'utf8'));
  } catch {
    return { globalEnabled: true, maxConcurrentRuns: 3, loops: [] };
  }
}

function writeLoops(data) {
  ensureConfigDir();
  fs.writeFileSync(LOOPS_FILE, JSON.stringify(data, null, 2), 'utf8');
}

function ensureLoopRunsDir(loopId) {
  const dir = path.join(LOOPS_RUNS_DIR, loopId);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  return dir;
}

function saveLoopRun(loopId, runData) {
  var dir = ensureLoopRunsDir(loopId);
  var filename = new Date(runData.startedAt).toISOString().replace(/[:.]/g, '-') + '.json';
  // Truncate output to 50KB max
  if (runData.output && runData.output.length > 50000) {
    runData.output = runData.output.substring(0, 50000) + '\n...[truncated]';
  }
  fs.writeFileSync(path.join(dir, filename), JSON.stringify(runData, null, 2), 'utf8');
  // Prune old runs beyond 50
  pruneLoopRuns(loopId, dir);
}

function pruneLoopRuns(loopId, dir) {
  try {
    var files = fs.readdirSync(dir).filter(function (f) { return f.endsWith('.json'); }).sort();
    while (files.length > 50) {
      fs.unlinkSync(path.join(dir, files.shift()));
    }
  } catch { /* ignore */ }
}

function getLoopHistory(loopId, count) {
  var dir = path.join(LOOPS_RUNS_DIR, loopId);
  try {
    var files = fs.readdirSync(dir).filter(function (f) { return f.endsWith('.json'); }).sort().reverse();
    var results = [];
    for (var i = 0; i < Math.min(count || 5, files.length); i++) {
      var data = JSON.parse(fs.readFileSync(path.join(dir, files[i]), 'utf8'));
      // Don't send full output in list view — just summary + attention items
      results.push({
        startedAt: data.startedAt,
        completedAt: data.completedAt,
        durationMs: data.durationMs,
        status: data.status,
        summary: data.summary,
        attentionItems: data.attentionItems || [],
        costUsd: data.costUsd,
        exitCode: data.exitCode
      });
    }
    return results;
  } catch {
    return [];
  }
}

function generateLoopId() {
  return 'loop_' + Date.now().toString(36) + Math.random().toString(36).substring(2, 7);
}
```

- [ ] **Step 2: Verify the helpers work**

Run: `npm start`
Open DevTools console, verify app still loads without errors. No visible changes yet — this is just backend plumbing.

- [ ] **Step 3: Commit**

```bash
git add main.js
git commit -m "feat(loops): add loops.json persistence helpers and run history storage"
```

---

### Task 2: Loop IPC handlers in main.js

**Files:**
- Modify: `main.js` (after the last IPC handler at ~line 935, before the app lifecycle section)

Add all IPC handlers for loop CRUD operations.

- [ ] **Step 1: Add loop CRUD IPC handlers**

Insert before the `const isDev = !app.isPackaged;` line (~line 940):

```javascript
// --- Loop Management IPC ---

ipcMain.handle('loops:getAll', () => {
  return readLoops();
});

ipcMain.handle('loops:getForProject', (event, projectPath) => {
  var data = readLoops();
  var normalized = projectPath.replace(/\\/g, '/');
  return data.loops.filter(function (l) {
    return l.projectPath.replace(/\\/g, '/') === normalized;
  });
});

ipcMain.handle('loops:create', (event, loopConfig) => {
  var data = readLoops();
  var loop = Object.assign({
    id: generateLoopId(),
    enabled: true,
    createdAt: new Date().toISOString(),
    lastRunAt: null,
    lastRunStatus: null,
    lastError: null,
    currentRunStartedAt: null
  }, loopConfig);
  data.loops.push(loop);
  writeLoops(data);
  return loop;
});

ipcMain.handle('loops:update', (event, loopId, updates) => {
  var data = readLoops();
  var loop = data.loops.find(function (l) { return l.id === loopId; });
  if (!loop) return null;
  Object.assign(loop, updates);
  writeLoops(data);
  return loop;
});

ipcMain.handle('loops:delete', (event, loopId) => {
  var data = readLoops();
  data.loops = data.loops.filter(function (l) { return l.id !== loopId; });
  writeLoops(data);
  // Clean up run history
  var runDir = path.join(LOOPS_RUNS_DIR, loopId);
  try { fs.rmSync(runDir, { recursive: true, force: true }); } catch { /* ignore */ }
  return true;
});

ipcMain.handle('loops:toggle', (event, loopId) => {
  var data = readLoops();
  var loop = data.loops.find(function (l) { return l.id === loopId; });
  if (!loop) return null;
  loop.enabled = !loop.enabled;
  if (loop.enabled) loop.lastError = null; // Clear error on re-enable
  writeLoops(data);
  return loop;
});

ipcMain.handle('loops:toggleGlobal', () => {
  var data = readLoops();
  data.globalEnabled = !data.globalEnabled;
  writeLoops(data);
  return data.globalEnabled;
});

ipcMain.handle('loops:runNow', (event, loopId) => {
  runLoop(loopId);
  return true;
});

ipcMain.handle('loops:getHistory', (event, loopId, count) => {
  return getLoopHistory(loopId, count);
});
```

- [ ] **Step 2: Verify IPC handlers load**

Run: `npm start`
Open DevTools console, run: `window.electronAPI.getLoops()` — should return `{ globalEnabled: true, maxConcurrentRuns: 3, loops: [] }`. (This will fail until preload is updated in Task 3, but main.js should load without errors.)

- [ ] **Step 3: Commit**

```bash
git add main.js
git commit -m "feat(loops): add IPC handlers for loop CRUD operations"
```

---

### Task 3: Preload bridge for loops

**Files:**
- Modify: `preload.js:1-66`

Expose all loop IPC channels to the renderer.

- [ ] **Step 1: Add loop methods to the context bridge**

In `preload.js`, add these methods inside the `contextBridge.exposeInMainWorld('electronAPI', {` block, before the closing `});`:

```javascript
  // Loops
  getLoops: () => ipcRenderer.invoke('loops:getAll'),
  getLoopsForProject: (projectPath) => ipcRenderer.invoke('loops:getForProject', projectPath),
  createLoop: (config) => ipcRenderer.invoke('loops:create', config),
  updateLoop: (loopId, updates) => ipcRenderer.invoke('loops:update', loopId, updates),
  deleteLoop: (loopId) => ipcRenderer.invoke('loops:delete', loopId),
  toggleLoop: (loopId) => ipcRenderer.invoke('loops:toggle', loopId),
  toggleLoopsGlobal: () => ipcRenderer.invoke('loops:toggleGlobal'),
  runLoopNow: (loopId) => ipcRenderer.invoke('loops:runNow', loopId),
  getLoopHistory: (loopId, count) => ipcRenderer.invoke('loops:getHistory', loopId, count),
  onLoopRunStarted: (callback) => ipcRenderer.on('loops:run-started', (_, data) => callback(data)),
  onLoopRunCompleted: (callback) => ipcRenderer.on('loops:run-completed', (_, data) => callback(data)),
```

- [ ] **Step 2: Verify bridge works**

Run: `npm start`
Open DevTools console, run: `window.electronAPI.getLoops()` — should return the default loops config object.
Run: `window.electronAPI.createLoop({ name: 'Test', prompt: 'Hello', projectPath: 'D:/test', schedule: { type: 'interval', minutes: 60 }, budgetPerRun: 0.5, maxTurns: 15, createdBy: 'ui' })` — should create a loop and return it.
Run: `window.electronAPI.getLoops()` — should show the created loop.
Run: `window.electronAPI.deleteLoop('<id-from-above>')` — should delete it.

- [ ] **Step 3: Commit**

```bash
git add preload.js
git commit -m "feat(loops): expose loop IPC channels in preload bridge"
```

---

### Task 4: Loop scheduler and execution engine in main.js

**Files:**
- Modify: `main.js` (after loop IPC handlers, before `const isDev` line)
- Modify: `main.js:954-959` (app startup)
- Modify: `main.js:969-973` (before-quit handler)

The core execution engine: scheduler, child process spawning, result parsing, graceful shutdown.

- [ ] **Step 1: Add the loop execution engine**

Insert after the loop IPC handlers (before `const isDev`):

```javascript
// --- Loop Scheduler & Execution ---

var runningLoops = new Map(); // loopId -> child process
var loopQueue = []; // loopIds waiting for a slot

var LOOP_PROMPT_SUFFIX = '\n\nEnd your response with a JSON block wrapped in :::loop-result markers like this:\n:::loop-result\n{"summary": "Brief one-line summary", "attentionItems": [{"summary": "Short description", "detail": "Full context"}]}\n:::loop-result\nIf there are no issues, use an empty attentionItems array.';

function findClaudePath() {
  try {
    var result = execFileSync('where', ['claude'], { encoding: 'utf8' });
    return result.trim().split(/\r?\n/)[0];
  } catch {
    return 'claude';
  }
}

var claudePath = null;

function getClaudePath() {
  if (!claudePath) claudePath = findClaudePath();
  return claudePath;
}

function parseLoopResult(output) {
  var result = { summary: '', attentionItems: [] };
  // Try structured :::loop-result block first
  var match = output.match(/:::loop-result\s*\n([\s\S]*?)\n\s*:::loop-result/);
  if (match) {
    try {
      var parsed = JSON.parse(match[1]);
      result.summary = parsed.summary || '';
      result.attentionItems = parsed.attentionItems || [];
      return result;
    } catch { /* fall through to heuristic */ }
  }
  // Heuristic fallback: extract last paragraph as summary
  var lines = output.trim().split('\n');
  result.summary = lines[lines.length - 1].substring(0, 200);
  // Look for attention patterns
  var patterns = [/ACTION NEEDED:\s*(.+)/gi, /WARNING:\s*(.+)/gi, /FAILING:\s*(.+)/gi, /ERROR:\s*(.+)/gi];
  patterns.forEach(function (pat) {
    var m;
    while ((m = pat.exec(output)) !== null) {
      result.attentionItems.push({ summary: m[1].substring(0, 200), detail: '' });
    }
  });
  return result;
}

function shouldRunLoop(loop, now) {
  if (!loop.enabled) return false;
  if (loop.currentRunStartedAt) return false; // Already running

  if (loop.schedule.type === 'interval') {
    if (!loop.lastRunAt) return true; // Never run
    var elapsed = now - new Date(loop.lastRunAt).getTime();
    return elapsed >= loop.schedule.minutes * 60000;
  }

  if (loop.schedule.type === 'time_of_day') {
    var date = new Date(now);
    var dayNames = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
    var today = dayNames[date.getDay()];
    if (loop.schedule.days && loop.schedule.days.indexOf(today) === -1) return false;
    var nowMinutes = date.getHours() * 60 + date.getMinutes();
    var schedMinutes = loop.schedule.hour * 60 + (loop.schedule.minute || 0);
    if (nowMinutes < schedMinutes) return false; // Not time yet
    // Check if already ran today
    if (loop.lastRunAt) {
      var lastRun = new Date(loop.lastRunAt);
      if (lastRun.toDateString() === date.toDateString()) return false;
    }
    return true;
  }
  return false;
}

function runLoop(loopId) {
  var data = readLoops();
  var loop = data.loops.find(function (l) { return l.id === loopId; });
  if (!loop) return;
  if (runningLoops.has(loopId)) return; // Already running

  // Check concurrency limit
  if (runningLoops.size >= (data.maxConcurrentRuns || 3)) {
    if (loopQueue.indexOf(loopId) === -1) loopQueue.push(loopId);
    return;
  }

  // Validate project path
  if (!fs.existsSync(loop.projectPath)) {
    loop.lastRunStatus = 'error';
    loop.lastError = 'Project path not found: ' + loop.projectPath;
    loop.enabled = false;
    writeLoops(data);
    if (mainWindow) mainWindow.webContents.send('loops:run-completed', {
      loopId: loopId, status: 'error', error: loop.lastError
    });
    return;
  }

  // Mark as running
  loop.currentRunStartedAt = new Date().toISOString();
  writeLoops(data);

  if (mainWindow) mainWindow.webContents.send('loops:run-started', { loopId: loopId });

  var startedAt = new Date().toISOString();
  var outputChunks = [];
  var fullPrompt = loop.prompt + LOOP_PROMPT_SUFFIX;

  var args = ['--print', fullPrompt];
  if (loop.budgetPerRun) args.push('--max-budget-usd', String(loop.budgetPerRun));

  var child = spawn(getClaudePath(), args, {
    cwd: loop.projectPath,
    stdio: ['pipe', 'pipe', 'pipe'],
    env: Object.assign({}, process.env)
  });

  runningLoops.set(loopId, child);

  child.stdout.on('data', function (chunk) {
    outputChunks.push(chunk.toString());
  });

  child.stderr.on('data', function (chunk) {
    outputChunks.push(chunk.toString());
  });

  child.on('close', function (exitCode) {
    runningLoops.delete(loopId);

    var completedAt = new Date().toISOString();
    var output = outputChunks.join('');
    var parsed = parseLoopResult(output);

    var runData = {
      loopId: loopId,
      startedAt: startedAt,
      completedAt: completedAt,
      durationMs: new Date(completedAt).getTime() - new Date(startedAt).getTime(),
      exitCode: exitCode,
      status: exitCode === 0 ? 'completed' : 'error',
      summary: parsed.summary,
      output: output,
      attentionItems: parsed.attentionItems,
      costUsd: null // TODO: parse from CLI output if available
    };

    saveLoopRun(loopId, runData);

    // Update loop config
    var freshData = readLoops();
    var freshLoop = freshData.loops.find(function (l) { return l.id === loopId; });
    if (freshLoop) {
      freshLoop.currentRunStartedAt = null;
      freshLoop.lastRunAt = completedAt;
      freshLoop.lastRunStatus = runData.status;
      freshLoop.lastError = exitCode === 0 ? null : 'Exit code: ' + exitCode;
      writeLoops(freshData);
    }

    // Notify renderer
    if (mainWindow) {
      mainWindow.webContents.send('loops:run-completed', {
        loopId: loopId,
        status: runData.status,
        summary: parsed.summary,
        attentionItems: parsed.attentionItems,
        exitCode: exitCode
      });

      // Flash taskbar if attention items found
      if (parsed.attentionItems.length > 0) {
        mainWindow.flashFrame(true);
      }
    }

    // Process queue
    if (loopQueue.length > 0) {
      var nextId = loopQueue.shift();
      runLoop(nextId);
    }
  });

  child.on('error', function (err) {
    runningLoops.delete(loopId);
    var freshData = readLoops();
    var freshLoop = freshData.loops.find(function (l) { return l.id === loopId; });
    if (freshLoop) {
      freshLoop.currentRunStartedAt = null;
      freshLoop.lastRunStatus = 'error';
      freshLoop.lastError = err.message;
      writeLoops(freshData);
    }
    if (mainWindow) mainWindow.webContents.send('loops:run-completed', {
      loopId: loopId, status: 'error', error: err.message
    });
    // Process queue
    if (loopQueue.length > 0) {
      var nextId = loopQueue.shift();
      runLoop(nextId);
    }
  });
}

var loopSchedulerTimer = null;

function startLoopScheduler() {
  // Startup recovery: clear any stale "running" states
  var data = readLoops();
  var changed = false;
  data.loops.forEach(function (loop) {
    if (loop.currentRunStartedAt) {
      loop.currentRunStartedAt = null;
      loop.lastRunStatus = 'interrupted';
      loop.lastError = 'App closed during run';
      changed = true;
    }
  });
  if (changed) writeLoops(data);

  // Check every 30 seconds
  loopSchedulerTimer = setInterval(function () {
    var loopData = readLoops();
    if (!loopData.globalEnabled) return;
    var now = Date.now();
    loopData.loops.forEach(function (loop) {
      if (shouldRunLoop(loop, now)) {
        runLoop(loop.id);
      }
    });
  }, 30000);
}

function stopLoopScheduler() {
  if (loopSchedulerTimer) {
    clearInterval(loopSchedulerTimer);
    loopSchedulerTimer = null;
  }
  // Kill all running loop processes
  runningLoops.forEach(function (child, loopId) {
    try { child.kill(); } catch { /* ignore */ }
  });
  runningLoops.clear();
  // Update status for any in-progress loops
  var data = readLoops();
  var changed = false;
  data.loops.forEach(function (loop) {
    if (loop.currentRunStartedAt) {
      loop.currentRunStartedAt = null;
      loop.lastRunStatus = 'interrupted';
      loop.lastError = 'App closed during run';
      changed = true;
    }
  });
  if (changed) writeLoops(data);
}
```

- [ ] **Step 2: Wire scheduler into app lifecycle**

Modify the `app.whenReady()` block (~line 954) to add `startLoopScheduler()`:

```javascript
  app.whenReady().then(async () => {
    await startPtyServer();
    startHookServer();
    createWindow();
    setupAutoUpdater();
    startLoopScheduler();
  });
```

Modify the `app.on('before-quit', ...)` handler (~line 969) to add `stopLoopScheduler()`:

```javascript
app.on('before-quit', () => {
  stopLoopScheduler();
  if (ptyServerProcess) {
    ptyServerProcess.kill();
  }
});
```

Also modify `app.on('window-all-closed', ...)` (~line 962):

```javascript
app.on('window-all-closed', () => {
  stopLoopScheduler();
  if (ptyServerProcess) {
    ptyServerProcess.kill();
  }
  app.quit();
});
```

- [ ] **Step 3: Test the scheduler**

Run: `npm start`
In DevTools console:
```javascript
// Create a test loop with 1-minute interval
window.electronAPI.createLoop({
  name: 'Test Loop',
  prompt: 'Say hello and list the files in the current directory',
  projectPath: 'D:/Git Repos/Claudes',
  schedule: { type: 'interval', minutes: 1 },
  budgetPerRun: 0.10,
  maxTurns: 5,
  createdBy: 'ui'
}).then(l => console.log('Created:', l))
```
Then trigger it manually:
```javascript
window.electronAPI.getLoops().then(d => {
  var id = d.loops[0].id;
  window.electronAPI.runLoopNow(id);
})
```
Wait ~30 seconds, then check:
```javascript
window.electronAPI.getLoops().then(d => console.log(d.loops[0]))
```
The loop should show `lastRunAt` and `lastRunStatus`. Check `~/.claudes/loop-runs/` for the run history file. Then delete the test loop.

- [ ] **Step 4: Commit**

```bash
git add main.js
git commit -m "feat(loops): add scheduler engine with child process execution and graceful shutdown"
```

---

### Task 5: LOOPS tab in explorer panel — HTML structure

**Files:**
- Modify: `index.html:17-21` (explorer tabs)
- Modify: `index.html:86` (after tab-run closing div, before explorer-content closing div)

- [ ] **Step 1: Add the LOOPS tab button**

In `index.html`, find the explorer tabs section (line 17-21). Add a new tab button after the "Run" tab:

```html
        <button class="explorer-tab" data-tab="loops">Loops</button>
```

- [ ] **Step 2: Add the LOOPS tab content**

After the closing `</div>` of `tab-run` (line 86, before the `</div>` that closes `.explorer-content`), add:

```html
        <div id="tab-loops" class="tab-content">
          <div class="explorer-section-header">
            <span>LOOPS</span>
            <div style="display:flex;gap:4px;">
              <button class="explorer-refresh" id="btn-add-loop" title="New Loop">+</button>
              <button class="explorer-refresh" id="btn-ask-claude-loop" title="Ask Claude to set it up">&#9993;</button>
              <button class="explorer-refresh" id="btn-refresh-loops" title="Refresh">&#8635;</button>
            </div>
          </div>
          <div id="loops-no-project" class="loops-placeholder" style="display:none;">
            <p style="opacity:0.5;text-align:center;padding:2rem 1rem;font-size:12px;">Select a project to see its loops</p>
          </div>
          <div id="loops-list"></div>
        </div>
```

- [ ] **Step 3: Add the flyout dashboard container**

After the closing `</div>` of `#main-area` (or at the end of `#app`), add:

```html
    <div id="loops-flyout" class="loops-flyout hidden">
      <div class="loops-flyout-header">
        <div class="loops-flyout-title">
          <span>Loop Manager</span>
          <span id="loops-flyout-counts" class="loops-flyout-counts"></span>
        </div>
        <div class="loops-flyout-actions">
          <button id="btn-loops-global-toggle" class="loops-global-toggle" title="Pause/Resume all loops">&#9654;</button>
          <button id="btn-loops-flyout-close" class="loops-flyout-close" title="Close">&times;</button>
        </div>
      </div>
      <div id="loops-flyout-list" class="loops-flyout-list"></div>
    </div>
```

- [ ] **Step 4: Add the Loop Manager toolbar button**

In the toolbar actions area (`index.html`, inside `.toolbar-actions` div, before the toolbar menu wrap), add:

```html
          <button id="btn-loops-flyout" class="toolbar-btn" title="Loop Manager">&#8634;</button>
```

- [ ] **Step 5: Add the new/edit loop modal**

At the end of `<body>` (alongside other modals), add:

```html
    <div id="loop-modal-overlay" class="modal-overlay hidden">
      <div class="modal loop-modal">
        <div class="modal-header">
          <span id="loop-modal-title">New Loop</span>
          <button class="modal-close" id="btn-loop-modal-close">&times;</button>
        </div>
        <div class="modal-body">
          <div class="form-group">
            <label for="loop-name">Name</label>
            <input type="text" id="loop-name" placeholder="e.g. Check failing tests" spellcheck="false">
          </div>
          <div class="form-group">
            <label for="loop-prompt">Prompt</label>
            <textarea id="loop-prompt" rows="6" placeholder="What should Claude do each time this runs?" spellcheck="false"></textarea>
          </div>
          <div class="form-group">
            <label>Schedule</label>
            <div class="loop-schedule-row">
              <select id="loop-schedule-type">
                <option value="interval">Every</option>
                <option value="time_of_day">Daily at</option>
              </select>
              <div id="loop-interval-fields">
                <input type="number" id="loop-interval-value" min="1" value="60" style="width:60px">
                <select id="loop-interval-unit">
                  <option value="minutes">minutes</option>
                  <option value="hours">hours</option>
                </select>
              </div>
              <div id="loop-tod-fields" style="display:none;">
                <input type="time" id="loop-tod-time" value="09:00">
                <div class="loop-days-row" id="loop-tod-days">
                  <label><input type="checkbox" value="mon" checked> Mon</label>
                  <label><input type="checkbox" value="tue" checked> Tue</label>
                  <label><input type="checkbox" value="wed" checked> Wed</label>
                  <label><input type="checkbox" value="thu" checked> Thu</label>
                  <label><input type="checkbox" value="fri" checked> Fri</label>
                  <label><input type="checkbox" value="sat"> Sat</label>
                  <label><input type="checkbox" value="sun"> Sun</label>
                </div>
              </div>
            </div>
          </div>
          <div class="form-group form-row">
            <div>
              <label for="loop-budget">Budget per run ($)</label>
              <input type="number" id="loop-budget" min="0.01" step="0.01" value="0.50" style="width:80px">
            </div>
            <div>
              <label for="loop-max-turns">Max turns</label>
              <input type="number" id="loop-max-turns" min="1" value="15" style="width:60px">
            </div>
          </div>
        </div>
        <div class="modal-footer">
          <button id="btn-loop-save" class="modal-btn modal-btn-primary">Create Loop</button>
          <button id="btn-loop-cancel" class="modal-btn">Cancel</button>
        </div>
      </div>
    </div>
```

- [ ] **Step 6: Verify HTML structure**

Run: `npm start`
Confirm the app loads without errors. The LOOPS tab should appear (empty). The toolbar button should be visible.

- [ ] **Step 7: Commit**

```bash
git add index.html
git commit -m "feat(loops): add LOOPS tab, flyout dashboard, and loop modal HTML structure"
```

---

### Task 6: Loops CSS styles

**Files:**
- Modify: `styles.css` (append at end)

- [ ] **Step 1: Add all loop-related styles**

Append to the end of `styles.css`:

```css
/* ============================================================
   Loops
   ============================================================ */

/* Explorer tab: LOOPS panel */
#loops-list {
  padding: 4px 8px;
}

.loop-card {
  background: var(--bg-panel);
  border-radius: 6px;
  padding: 10px 12px;
  margin-bottom: 6px;
  border-left: 3px solid var(--text-faint);
  cursor: default;
  font-size: 12px;
}

.loop-card.loop-idle { border-left-color: #22c55e; }
.loop-card.loop-running { border-left-color: #22c55e; }
.loop-card.loop-attention { border-left-color: #f5a623; }
.loop-card.loop-error { border-left-color: #ef4444; }
.loop-card.loop-disabled { opacity: 0.5; }

.loop-card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.loop-card-name {
  font-weight: 600;
  font-size: 12px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  flex: 1;
}

.loop-card-schedule {
  font-size: 10px;
  opacity: 0.6;
  white-space: nowrap;
  margin-left: 8px;
}

.loop-card-status {
  font-size: 11px;
  opacity: 0.7;
  margin-top: 4px;
}

.loop-card-footer {
  display: flex;
  gap: 6px;
  margin-top: 6px;
  align-items: center;
}

.loop-status-badge {
  font-size: 10px;
  padding: 1px 6px;
  border-radius: 3px;
  white-space: nowrap;
}

.loop-status-badge.badge-idle { background: rgba(34,197,94,0.2); color: #22c55e; }
.loop-status-badge.badge-running { background: rgba(34,197,94,0.2); color: #22c55e; animation: pulse-working 1.5s ease-in-out infinite; }
.loop-status-badge.badge-attention { background: rgba(245,166,35,0.2); color: #f5a623; }
.loop-status-badge.badge-error { background: rgba(239,68,68,0.2); color: #ef4444; }
.loop-status-badge.badge-scheduled { background: rgba(99,102,241,0.2); color: #6366f1; }
.loop-status-badge.badge-disabled { background: rgba(128,128,128,0.2); color: #888; }

.loop-card-next {
  font-size: 10px;
  opacity: 0.5;
}

.loop-card-actions {
  display: flex;
  gap: 4px;
  margin-left: auto;
}

.loop-card-actions button {
  background: none;
  border: none;
  color: var(--text-secondary);
  cursor: pointer;
  padding: 2px 4px;
  font-size: 12px;
  border-radius: 3px;
  opacity: 0;
  transition: opacity 0.15s;
}

.loop-card:hover .loop-card-actions button {
  opacity: 0.6;
}

.loop-card-actions button:hover {
  opacity: 1 !important;
  background: var(--hover-strong);
}

.loop-card-attention {
  margin-top: 6px;
}

.loop-attention-item {
  background: rgba(245,166,35,0.1);
  border: 1px solid rgba(245,166,35,0.2);
  border-radius: 4px;
  padding: 4px 8px;
  margin-top: 3px;
  font-size: 11px;
  cursor: pointer;
}

.loop-attention-item:hover {
  background: rgba(245,166,35,0.2);
}

/* Flyout Dashboard */
.loops-flyout {
  position: fixed;
  top: 40px;
  right: 0;
  bottom: 0;
  width: 400px;
  background: var(--bg-primary);
  border-left: 1px solid var(--border-primary);
  z-index: 200;
  display: flex;
  flex-direction: column;
  box-shadow: -4px 0 20px rgba(0,0,0,0.3);
  transition: transform 0.2s ease;
}

.loops-flyout.hidden {
  display: none;
}

.loops-flyout-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 12px 16px;
  border-bottom: 1px solid var(--border-primary);
  flex-shrink: 0;
}

.loops-flyout-title {
  display: flex;
  align-items: center;
  gap: 8px;
  font-weight: 600;
  font-size: 14px;
}

.loops-flyout-counts {
  font-size: 11px;
  font-weight: 400;
  opacity: 0.6;
}

.loops-flyout-actions {
  display: flex;
  gap: 4px;
}

.loops-flyout-actions button {
  background: none;
  border: none;
  color: var(--text-secondary);
  cursor: pointer;
  padding: 4px 8px;
  font-size: 16px;
  border-radius: 4px;
}

.loops-flyout-actions button:hover {
  background: var(--hover-strong);
}

.loops-global-toggle {
  font-size: 12px !important;
}

.loops-flyout-list {
  flex: 1;
  overflow-y: auto;
  padding: 8px 12px;
}

.loops-flyout-project-header {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  opacity: 0.5;
  margin-top: 12px;
  margin-bottom: 6px;
  padding: 0 4px;
}

.loops-flyout-project-header:first-child {
  margin-top: 4px;
}

.loops-flyout-row {
  background: var(--bg-panel);
  border-radius: 6px;
  padding: 8px 12px;
  margin-bottom: 4px;
  cursor: pointer;
  transition: background 0.15s;
}

.loops-flyout-row:hover {
  background: var(--hover-strong);
}

.loops-flyout-row-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 12px;
}

.loops-flyout-row-status {
  font-size: 10px;
}

.loops-flyout-row-expanded {
  margin-top: 8px;
  padding-top: 8px;
  border-top: 1px solid var(--border-primary);
  font-size: 11px;
  display: none;
}

.loops-flyout-row.expanded .loops-flyout-row-expanded {
  display: block;
}

.loops-flyout-row-summary {
  opacity: 0.7;
  margin-bottom: 6px;
}

.loops-flyout-history {
  display: flex;
  gap: 4px;
  margin-top: 6px;
  align-items: center;
}

.loops-flyout-history-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #22c55e;
}

.loops-flyout-history-dot.dot-error { background: #ef4444; }
.loops-flyout-history-dot.dot-attention { background: #f5a623; }
.loops-flyout-history-dot.dot-interrupted { background: #888; }

.loops-flyout-action-btn {
  background: var(--hover-strong);
  border: 1px solid var(--border-primary);
  color: var(--text-primary);
  padding: 4px 10px;
  border-radius: 4px;
  font-size: 11px;
  cursor: pointer;
  margin-top: 6px;
  width: 100%;
  text-align: center;
}

.loops-flyout-action-btn:hover {
  background: var(--accent);
  color: white;
}

/* Loop modal */
.loop-modal {
  max-width: 500px;
}

.loop-schedule-row {
  display: flex;
  gap: 8px;
  align-items: flex-start;
  flex-wrap: wrap;
}

.loop-schedule-row select,
.loop-schedule-row input[type="number"],
.loop-schedule-row input[type="time"] {
  background: var(--bg-panel);
  border: 1px solid var(--border-primary);
  color: var(--text-primary);
  padding: 4px 8px;
  border-radius: 4px;
  font-size: 12px;
}

.loop-days-row {
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  margin-top: 6px;
}

.loop-days-row label {
  font-size: 11px;
  display: flex;
  align-items: center;
  gap: 3px;
}

.form-row {
  display: flex;
  gap: 16px;
}

.form-row > div {
  flex: 1;
}

/* Toolbar Loop Manager button */
#btn-loops-flyout {
  background: none;
  border: none;
  color: var(--text-secondary);
  cursor: pointer;
  padding: 4px 8px;
  font-size: 16px;
  border-radius: 4px;
}

#btn-loops-flyout:hover {
  background: var(--hover-strong);
}

#btn-loops-flyout.has-attention {
  color: #f5a623;
  animation: pulse-attention 1.2s ease-in-out infinite;
}

/* Sidebar loop attention badge */
.project-loop-badge {
  display: inline-block;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: #f5a623;
  margin-left: 4px;
  animation: pulse-attention 1.2s ease-in-out infinite;
}

.loops-placeholder p {
  margin: 0;
}
```

- [ ] **Step 2: Verify styles load**

Run: `npm start`
Confirm the LOOPS tab looks correct (should show the header with buttons). No visual glitches.

- [ ] **Step 3: Commit**

```bash
git add styles.css
git commit -m "feat(loops): add CSS styles for loop cards, flyout dashboard, and modal"
```

---

### Task 7: LOOPS tab renderer logic

**Files:**
- Modify: `renderer.js` (add after the run tab logic, around line 2200, and at the end of file)

This task adds the loop card rendering, refresh logic, and tab switching for the LOOPS tab.

- [ ] **Step 1: Add loops state variables**

Near the top of `renderer.js` (after the existing global state variables around line 45), add:

```javascript
// Loops state
var loopsForProject = [];
var allLoopsData = null;
```

- [ ] **Step 2: Add tab switching for LOOPS tab**

In the explorer tab click handler (line 2192-2203), add a case for the loops tab. Modify the handler to add:

```javascript
    else if (tabName === 'loops') { stopGitPolling(); refreshLoops(); }
```

This goes after the existing `else if (tabName === 'run')` line.

Also find `refreshExplorer()` (~line 3987) and add a case for the loops tab:

```javascript
    else if (tabName === 'loops') { refreshLoops(); }
```

- [ ] **Step 3: Add the refreshLoops function and loop card rendering**

Add after the run tab functions (or at the end of the file before the update notification code around line 5200):

```javascript
// ============================================================
// Loops Tab
// ============================================================

function refreshLoops() {
  var listEl = document.getElementById('loops-list');
  var noProjectEl = document.getElementById('loops-no-project');
  if (!listEl) return;

  if (!activeProjectKey) {
    listEl.innerHTML = '';
    if (noProjectEl) noProjectEl.style.display = '';
    return;
  }
  if (noProjectEl) noProjectEl.style.display = 'none';

  window.electronAPI.getLoopsForProject(activeProjectKey).then(function (loops) {
    loopsForProject = loops;
    renderLoopCards(loops, listEl);
  });
}

function renderLoopCards(loops, container) {
  container.innerHTML = '';

  if (loops.length === 0) {
    container.innerHTML = '<p style="opacity:0.5;text-align:center;padding:2rem 1rem;font-size:12px;">No loops configured.<br>Click + to create one.</p>';
    return;
  }

  loops.forEach(function (loop) {
    var card = document.createElement('div');
    card.className = 'loop-card';

    var statusClass = 'loop-idle';
    var badgeClass = 'badge-idle';
    var badgeText = 'idle';

    if (!loop.enabled) {
      statusClass = 'loop-disabled';
      badgeClass = 'badge-disabled';
      badgeText = 'disabled';
    } else if (loop.currentRunStartedAt) {
      statusClass = 'loop-running';
      badgeClass = 'badge-running';
      badgeText = 'running...';
    } else if (loop.lastRunStatus === 'error') {
      statusClass = 'loop-error';
      badgeClass = 'badge-error';
      badgeText = 'error';
    } else if (loop.lastRunStatus === 'completed') {
      badgeClass = 'badge-idle';
      badgeText = 'idle';
    }

    card.classList.add(statusClass);

    // Schedule text
    var schedText = '';
    if (loop.schedule.type === 'interval') {
      var mins = loop.schedule.minutes;
      if (mins >= 60) schedText = 'Every ' + (mins / 60) + 'h';
      else schedText = 'Every ' + mins + 'm';
    } else {
      var h = loop.schedule.hour;
      var m = loop.schedule.minute || 0;
      schedText = 'Daily ' + (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m;
    }

    // Last run text
    var lastRunText = '';
    if (loop.lastRunAt) {
      var elapsed = Date.now() - new Date(loop.lastRunAt).getTime();
      if (elapsed < 60000) lastRunText = 'Last: just now';
      else if (elapsed < 3600000) lastRunText = 'Last: ' + Math.floor(elapsed / 60000) + 'm ago';
      else if (elapsed < 86400000) lastRunText = 'Last: ' + Math.floor(elapsed / 3600000) + 'h ago';
      else lastRunText = 'Last: ' + Math.floor(elapsed / 86400000) + 'd ago';
    } else {
      lastRunText = 'Never run';
    }

    // Next run text
    var nextRunText = '';
    if (loop.enabled && loop.schedule.type === 'interval') {
      if (loop.lastRunAt) {
        var nextMs = new Date(loop.lastRunAt).getTime() + loop.schedule.minutes * 60000 - Date.now();
        if (nextMs <= 0) nextRunText = 'Due now';
        else if (nextMs < 60000) nextRunText = 'Next: <1m';
        else if (nextMs < 3600000) nextRunText = 'Next: ' + Math.floor(nextMs / 60000) + 'm';
        else nextRunText = 'Next: ' + Math.floor(nextMs / 3600000) + 'h';
      } else {
        nextRunText = 'Next: pending';
      }
    }

    var html = '<div class="loop-card-header">' +
      '<span class="loop-card-name">' + escapeHtml(loop.name) + '</span>' +
      '<span class="loop-card-schedule">' + schedText + '</span>' +
      '</div>' +
      '<div class="loop-card-status">' + lastRunText + (loop.lastError ? ' — ' + escapeHtml(loop.lastError) : '') + '</div>' +
      '<div class="loop-card-footer">' +
        '<span class="loop-status-badge ' + badgeClass + '">' + badgeText + '</span>' +
        (nextRunText ? '<span class="loop-card-next">' + nextRunText + '</span>' : '') +
        '<span class="loop-card-actions">' +
          '<button class="loop-btn-toggle" title="' + (loop.enabled ? 'Pause' : 'Resume') + '">' + (loop.enabled ? '&#10074;&#10074;' : '&#9654;') + '</button>' +
          '<button class="loop-btn-run" title="Run Now">&#9654;</button>' +
          '<button class="loop-btn-edit" title="Edit">&#9998;</button>' +
          '<button class="loop-btn-delete" title="Delete">&times;</button>' +
        '</span>' +
      '</div>';

    card.innerHTML = html;

    // Event handlers
    card.querySelector('.loop-btn-toggle').addEventListener('click', function (e) {
      e.stopPropagation();
      window.electronAPI.toggleLoop(loop.id).then(function () { refreshLoops(); });
    });
    card.querySelector('.loop-btn-run').addEventListener('click', function (e) {
      e.stopPropagation();
      window.electronAPI.runLoopNow(loop.id);
      refreshLoops();
    });
    card.querySelector('.loop-btn-edit').addEventListener('click', function (e) {
      e.stopPropagation();
      openLoopModal(loop);
    });
    card.querySelector('.loop-btn-delete').addEventListener('click', function (e) {
      e.stopPropagation();
      if (confirm('Delete loop "' + loop.name + '"?')) {
        window.electronAPI.deleteLoop(loop.id).then(function () { refreshLoops(); });
      }
    });

    container.appendChild(card);
  });
}

function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
```

Note: `escapeHtml` may already exist in renderer.js. If so, skip adding it. Search for `function escapeHtml` first.

- [ ] **Step 4: Verify the LOOPS tab renders**

Run: `npm start`
Create a test loop via console:
```javascript
window.electronAPI.createLoop({
  name: 'Test Loop',
  prompt: 'List files',
  projectPath: '<current-project-path>',
  schedule: { type: 'interval', minutes: 30 },
  budgetPerRun: 0.25,
  maxTurns: 10,
  createdBy: 'ui'
})
```
Switch to the LOOPS tab — should show the loop card with name, schedule, status badge, and action buttons.

- [ ] **Step 5: Commit**

```bash
git add renderer.js
git commit -m "feat(loops): add LOOPS tab rendering with loop cards and quick actions"
```

---

### Task 8: New/Edit loop modal logic

**Files:**
- Modify: `renderer.js` (add after the loops tab code)

- [ ] **Step 1: Add modal open/close and save logic**

```javascript
// ============================================================
// Loop Modal (New / Edit)
// ============================================================

var loopEditingId = null;

function openLoopModal(existingLoop) {
  loopEditingId = existingLoop ? existingLoop.id : null;
  document.getElementById('loop-modal-title').textContent = existingLoop ? 'Edit Loop' : 'New Loop';
  document.getElementById('btn-loop-save').textContent = existingLoop ? 'Save Changes' : 'Create Loop';

  document.getElementById('loop-name').value = existingLoop ? existingLoop.name : '';
  document.getElementById('loop-prompt').value = existingLoop ? existingLoop.prompt : '';
  document.getElementById('loop-budget').value = existingLoop ? existingLoop.budgetPerRun : 0.50;
  document.getElementById('loop-max-turns').value = existingLoop ? existingLoop.maxTurns : 15;

  var schedType = existingLoop ? existingLoop.schedule.type : 'interval';
  document.getElementById('loop-schedule-type').value = schedType;
  toggleScheduleFields(schedType);

  if (existingLoop && existingLoop.schedule.type === 'interval') {
    var mins = existingLoop.schedule.minutes;
    if (mins >= 60 && mins % 60 === 0) {
      document.getElementById('loop-interval-value').value = mins / 60;
      document.getElementById('loop-interval-unit').value = 'hours';
    } else {
      document.getElementById('loop-interval-value').value = mins;
      document.getElementById('loop-interval-unit').value = 'minutes';
    }
  } else {
    document.getElementById('loop-interval-value').value = 60;
    document.getElementById('loop-interval-unit').value = 'minutes';
  }

  if (existingLoop && existingLoop.schedule.type === 'time_of_day') {
    var h = existingLoop.schedule.hour;
    var m = existingLoop.schedule.minute || 0;
    document.getElementById('loop-tod-time').value = (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m;
    var checkboxes = document.querySelectorAll('#loop-tod-days input[type="checkbox"]');
    checkboxes.forEach(function (cb) {
      cb.checked = existingLoop.schedule.days ? existingLoop.schedule.days.indexOf(cb.value) !== -1 : false;
    });
  }

  document.getElementById('loop-modal-overlay').classList.remove('hidden');
  document.getElementById('loop-name').focus();
}

function closeLoopModal() {
  document.getElementById('loop-modal-overlay').classList.add('hidden');
  loopEditingId = null;
}

function toggleScheduleFields(type) {
  document.getElementById('loop-interval-fields').style.display = type === 'interval' ? '' : 'none';
  document.getElementById('loop-tod-fields').style.display = type === 'time_of_day' ? '' : 'none';
}

function saveLoop() {
  var name = document.getElementById('loop-name').value.trim();
  var prompt = document.getElementById('loop-prompt').value.trim();
  if (!name || !prompt) { alert('Name and prompt are required.'); return; }

  var schedType = document.getElementById('loop-schedule-type').value;
  var schedule;
  if (schedType === 'interval') {
    var val = parseInt(document.getElementById('loop-interval-value').value) || 60;
    var unit = document.getElementById('loop-interval-unit').value;
    schedule = { type: 'interval', minutes: unit === 'hours' ? val * 60 : val };
  } else {
    var timeParts = document.getElementById('loop-tod-time').value.split(':');
    var days = [];
    document.querySelectorAll('#loop-tod-days input:checked').forEach(function (cb) {
      days.push(cb.value);
    });
    schedule = { type: 'time_of_day', hour: parseInt(timeParts[0]), minute: parseInt(timeParts[1]), days: days };
  }

  var budget = parseFloat(document.getElementById('loop-budget').value) || 0.50;
  var maxTurns = parseInt(document.getElementById('loop-max-turns').value) || 15;

  if (loopEditingId) {
    window.electronAPI.updateLoop(loopEditingId, {
      name: name, prompt: prompt, schedule: schedule, budgetPerRun: budget, maxTurns: maxTurns
    }).then(function () {
      closeLoopModal();
      refreshLoops();
      refreshLoopsFlyout();
    });
  } else {
    window.electronAPI.createLoop({
      name: name, prompt: prompt, projectPath: activeProjectKey, schedule: schedule,
      budgetPerRun: budget, maxTurns: maxTurns, createdBy: 'ui'
    }).then(function () {
      closeLoopModal();
      refreshLoops();
      refreshLoopsFlyout();
    });
  }
}

// Wire up modal events
document.getElementById('loop-schedule-type').addEventListener('change', function () {
  toggleScheduleFields(this.value);
});
document.getElementById('btn-loop-modal-close').addEventListener('click', closeLoopModal);
document.getElementById('btn-loop-cancel').addEventListener('click', closeLoopModal);
document.getElementById('btn-loop-save').addEventListener('click', saveLoop);
document.getElementById('loop-modal-overlay').addEventListener('click', function (e) {
  if (e.target === this) closeLoopModal();
});
document.getElementById('btn-add-loop').addEventListener('click', function () {
  if (!activeProjectKey) { alert('Select a project first.'); return; }
  openLoopModal(null);
});
document.getElementById('btn-refresh-loops').addEventListener('click', refreshLoops);
```

- [ ] **Step 2: Verify the modal works**

Run: `npm start`
Switch to LOOPS tab, click "+". The modal should open with empty fields. Fill in a name and prompt, set a schedule, click "Create Loop". The loop card should appear. Click the edit button on the card — modal should open pre-filled.

- [ ] **Step 3: Commit**

```bash
git add renderer.js
git commit -m "feat(loops): add new/edit loop modal with schedule configuration"
```

---

### Task 9: Flyout dashboard renderer logic

**Files:**
- Modify: `renderer.js` (add after the modal code)

- [ ] **Step 1: Add flyout dashboard rendering**

```javascript
// ============================================================
// Loops Flyout Dashboard
// ============================================================

function toggleLoopsFlyout() {
  var flyout = document.getElementById('loops-flyout');
  flyout.classList.toggle('hidden');
  if (!flyout.classList.contains('hidden')) {
    refreshLoopsFlyout();
  }
}

function refreshLoopsFlyout() {
  var flyout = document.getElementById('loops-flyout');
  if (flyout.classList.contains('hidden')) return;

  window.electronAPI.getLoops().then(function (data) {
    allLoopsData = data;
    var listEl = document.getElementById('loops-flyout-list');
    var countsEl = document.getElementById('loops-flyout-counts');

    // Update global toggle button
    var globalBtn = document.getElementById('btn-loops-global-toggle');
    globalBtn.innerHTML = data.globalEnabled ? '&#10074;&#10074;' : '&#9654;';
    globalBtn.title = data.globalEnabled ? 'Pause all loops' : 'Resume all loops';

    // Counts
    var active = data.loops.filter(function (l) { return l.enabled; }).length;
    var attention = data.loops.filter(function (l) {
      return l.lastRunStatus === 'error' || l.lastError;
    }).length;
    countsEl.textContent = active + ' active' + (attention > 0 ? ' \u00b7 ' + attention + ' need attention' : '');

    // Group by project
    var byProject = {};
    data.loops.forEach(function (loop) {
      var projName = loop.projectPath.split('/').pop().split('\\').pop();
      if (!byProject[projName]) byProject[projName] = { path: loop.projectPath, loops: [] };
      byProject[projName].loops.push(loop);
    });

    listEl.innerHTML = '';

    if (data.loops.length === 0) {
      listEl.innerHTML = '<p style="opacity:0.5;text-align:center;padding:2rem;font-size:12px;">No loops configured yet.</p>';
      return;
    }

    Object.keys(byProject).forEach(function (projName) {
      var group = byProject[projName];
      var header = document.createElement('div');
      header.className = 'loops-flyout-project-header';
      header.textContent = projName;
      listEl.appendChild(header);

      group.loops.forEach(function (loop) {
        var row = document.createElement('div');
        row.className = 'loops-flyout-row';

        var statusText = '';
        var statusColor = '#22c55e';
        if (!loop.enabled) {
          statusText = 'disabled';
          statusColor = '#888';
        } else if (loop.currentRunStartedAt) {
          statusText = 'running...';
        } else if (loop.lastRunStatus === 'error') {
          statusText = '✗ error';
          statusColor = '#ef4444';
        } else if (loop.lastRunStatus === 'completed') {
          statusText = '✓ ok';
        } else {
          statusText = 'pending';
          statusColor = '#6366f1';
        }

        row.innerHTML = '<div class="loops-flyout-row-header">' +
          '<span>' + escapeHtml(loop.name) + '</span>' +
          '<span class="loops-flyout-row-status" style="color:' + statusColor + '">' + statusText + '</span>' +
          '</div>' +
          '<div class="loops-flyout-row-expanded">' +
            '<div class="loops-flyout-row-summary">Loading...</div>' +
            '<div class="loops-flyout-history"></div>' +
            '<button class="loops-flyout-action-btn" disabled>Open Live (Coming soon)</button>' +
          '</div>';

        row.addEventListener('click', function () {
          var wasExpanded = row.classList.contains('expanded');
          // Collapse all
          listEl.querySelectorAll('.loops-flyout-row').forEach(function (r) { r.classList.remove('expanded'); });
          if (!wasExpanded) {
            row.classList.add('expanded');
            // Load history
            window.electronAPI.getLoopHistory(loop.id, 5).then(function (history) {
              var summaryEl = row.querySelector('.loops-flyout-row-summary');
              var historyEl = row.querySelector('.loops-flyout-history');

              if (history.length > 0) {
                var latest = history[0];
                summaryEl.textContent = latest.summary || 'No summary available';

                // Attention items
                if (latest.attentionItems && latest.attentionItems.length > 0) {
                  var attHtml = '';
                  latest.attentionItems.forEach(function (item) {
                    attHtml += '<div class="loop-attention-item" data-loop-id="' + loop.id + '" data-detail="' + escapeHtml(item.detail || '') + '">' +
                      '→ ' + escapeHtml(item.summary) + '</div>';
                  });
                  summaryEl.innerHTML = summaryEl.textContent + attHtml;

                  // Click attention items to open Claude
                  summaryEl.querySelectorAll('.loop-attention-item').forEach(function (el) {
                    el.addEventListener('click', function (e) {
                      e.stopPropagation();
                      var detail = el.getAttribute('data-detail');
                      var followUpPrompt = 'The loop "' + loop.name + '" flagged this issue:\n' + el.textContent.replace('→ ', '') + '\n\nDetails: ' + detail + '\n\nPlease investigate and help resolve this.';
                      // Spawn a new Claude column with context
                      addColumn(['-p', followUpPrompt]);
                      toggleLoopsFlyout(); // Close flyout
                    });
                  });
                }

                // History dots
                var dotsHtml = '<span style="font-size:10px;opacity:0.5;margin-right:4px;">History:</span>';
                history.forEach(function (run) {
                  var dotClass = '';
                  if (run.status === 'error') dotClass = 'dot-error';
                  else if (run.attentionItems && run.attentionItems.length > 0) dotClass = 'dot-attention';
                  else if (run.status === 'interrupted') dotClass = 'dot-interrupted';
                  dotsHtml += '<span class="loops-flyout-history-dot ' + dotClass + '" title="' + (run.startedAt || '') + ' - ' + run.status + '"></span>';
                });
                historyEl.innerHTML = dotsHtml;
              } else {
                summaryEl.textContent = 'No runs yet';
                historyEl.innerHTML = '';
              }
            });
          }
        });

        listEl.appendChild(row);
      });
    });
  });
}

// Wire up flyout buttons
document.getElementById('btn-loops-flyout').addEventListener('click', toggleLoopsFlyout);
document.getElementById('btn-loops-flyout-close').addEventListener('click', toggleLoopsFlyout);
document.getElementById('btn-loops-global-toggle').addEventListener('click', function () {
  window.electronAPI.toggleLoopsGlobal().then(function () {
    refreshLoopsFlyout();
  });
});
```

- [ ] **Step 2: Verify the flyout works**

Run: `npm start`
Create a loop, trigger a run manually. Click the Loop Manager button in the toolbar — flyout should open showing all loops grouped by project. Click a loop row to expand and see history.

- [ ] **Step 3: Commit**

```bash
git add renderer.js
git commit -m "feat(loops): add flyout dashboard with cross-project loop overview"
```

---

### Task 10: Loop event listeners and sidebar integration

**Files:**
- Modify: `renderer.js` (add after flyout code)

Wire up IPC events from main process so the UI updates in real-time when loops start/complete, and add sidebar badge integration.

- [ ] **Step 1: Add IPC event listeners for loop events**

```javascript
// ============================================================
// Loop Events & Sidebar Integration
// ============================================================

// Listen for loop events from main process
window.electronAPI.onLoopRunStarted(function (data) {
  refreshLoops();
  refreshLoopsFlyout();
});

window.electronAPI.onLoopRunCompleted(function (data) {
  refreshLoops();
  refreshLoopsFlyout();
  updateLoopSidebarBadges();

  // Show attention notification if items were flagged
  if (data.attentionItems && data.attentionItems.length > 0) {
    var flyoutBtn = document.getElementById('btn-loops-flyout');
    flyoutBtn.classList.add('has-attention');
  }
});

function updateLoopSidebarBadges() {
  window.electronAPI.getLoops().then(function (data) {
    // Track which projects have loop attention
    var projectsWithAttention = new Set();
    data.loops.forEach(function (loop) {
      if (loop.lastRunStatus === 'error' || loop.lastError) {
        projectsWithAttention.add(loop.projectPath.replace(/\\/g, '/'));
      }
    });

    // Apply badges to project list items
    var items = document.querySelectorAll('.project-item');
    items.forEach(function (item) {
      // Remove existing loop badges
      var existing = item.querySelector('.project-loop-badge');
      if (existing) existing.remove();
    });

    if (config && config.projects) {
      config.projects.forEach(function (project, index) {
        var normalizedPath = project.path.replace(/\\/g, '/');
        if (projectsWithAttention.has(normalizedPath) && items[index]) {
          var badge = document.createElement('span');
          badge.className = 'project-loop-badge';
          badge.title = 'Loop needs attention';
          var nameEl = items[index].querySelector('.project-name');
          if (nameEl) nameEl.appendChild(badge);
        }
      });
    }

    // Update flyout button
    var flyoutBtn = document.getElementById('btn-loops-flyout');
    if (projectsWithAttention.size > 0) {
      flyoutBtn.classList.add('has-attention');
    } else {
      flyoutBtn.classList.remove('has-attention');
    }
  });
}

// Refresh loop badges on project switch
var origSwitchProject = typeof switchProject === 'function' ? switchProject : null;
// Note: instead of overriding switchProject, call updateLoopSidebarBadges() after renderProjectList()
// This will be wired by adding a call to updateLoopSidebarBadges() inside renderProjectList or after its calls
```

- [ ] **Step 2: Add updateLoopSidebarBadges call after renderProjectList**

Find the `renderProjectList()` function (~line 512-609). At the very end of that function, before its closing `}`, add:

```javascript
  updateLoopSidebarBadges();
```

- [ ] **Step 3: Verify events and badges work**

Run: `npm start`
Create and manually trigger a loop. When it completes, the LOOPS tab should update, the flyout should refresh, and the toolbar button should show attention animation if attention items exist.

- [ ] **Step 4: Commit**

```bash
git add renderer.js
git commit -m "feat(loops): add real-time loop event handling and sidebar badge integration"
```

---

### Task 11: Conversational loop setup ("Ask Claude")

**Files:**
- Modify: `renderer.js` (add after the event listeners code)

- [ ] **Step 1: Add the conversational setup handler**

```javascript
// ============================================================
// Conversational Loop Setup
// ============================================================

document.getElementById('btn-ask-claude-loop').addEventListener('click', function () {
  if (!activeProjectKey) { alert('Select a project first.'); return; }

  // Spawn a Claude column with loop-setup system prompt
  var setupPrompt = 'The user wants to create a scheduled background loop for their project at ' + activeProjectKey + '. ' +
    'Ask them what they want to monitor or check, how often it should run, and any budget constraints. ' +
    'When you have enough info, output a structured JSON config block wrapped in :::loop-config markers like this:\n' +
    ':::loop-config\n' +
    '{"name": "...", "prompt": "...", "schedule": {"type": "interval", "minutes": 60}, "budgetPerRun": 0.50, "maxTurns": 15}\n' +
    ':::loop-config\n' +
    'The user can then refine the config by asking you to change values.';

  addColumn(['-p', setupPrompt], null, { title: 'Loop Setup', isLoopSetup: true });
});

// NOTE: addColumn must be modified to pass opts.isLoopSetup into colData.
// In the addColumn function (~line 1077), add to the colData object:
//   isLoopSetup: opts.isLoopSetup || false,

// Watch for :::loop-config markers in loop-setup columns
// This is done by hooking into the WebSocket data handler.
// We add a check in the existing ws.onmessage handler.

function checkLoopConfig(colId, data) {
  var col = allColumns.get(colId);
  if (!col || !col.isLoopSetup) return;

  // Accumulate data for pattern matching
  if (!col._loopSetupBuffer) col._loopSetupBuffer = '';
  col._loopSetupBuffer += data;

  // Look for :::loop-config block
  var match = col._loopSetupBuffer.match(/:::loop-config\s*\n([\s\S]*?)\n\s*:::loop-config/);
  if (match) {
    try {
      var configData = JSON.parse(match[1]);
      // Create the loop
      window.electronAPI.createLoop(Object.assign({
        projectPath: activeProjectKey,
        createdBy: 'claude'
      }, configData)).then(function (loop) {
        refreshLoops();
        refreshLoopsFlyout();
        // Show a toast-like notification in the column header
        if (col.headerEl) {
          var toast = document.createElement('div');
          toast.style.cssText = 'position:absolute;top:28px;left:0;right:0;background:#22c55e;color:#fff;padding:6px 12px;font-size:11px;z-index:100;text-align:center;';
          toast.textContent = 'Loop "' + (configData.name || 'Untitled') + '" created!';
          col.element.appendChild(toast);
          setTimeout(function () { toast.remove(); }, 4000);
        }
      });
      // Clear buffer so we don't re-detect
      col._loopSetupBuffer = '';
    } catch (e) {
      // JSON parse failed — wait for more data
    }
  }

  // Prevent buffer from growing unbounded
  if (col._loopSetupBuffer.length > 100000) {
    col._loopSetupBuffer = col._loopSetupBuffer.substring(col._loopSetupBuffer.length - 10000);
  }
}
```

- [ ] **Step 2: Hook checkLoopConfig into the WebSocket data handler**

In the existing `ws.onmessage` handler (around line 131-134), after `col.terminal.write(msg.data);`, add:

```javascript
        checkLoopConfig(msg.id, msg.data);
```

This goes right after the `col.terminal.write(msg.data);` line and before the activity detection `if` block.

- [ ] **Step 3: Verify conversational setup works**

Run: `npm start`
Switch to LOOPS tab, click the envelope icon ("Ask Claude to set it up"). A Claude column should spawn with the setup prompt. Interact with Claude, and when it outputs a `:::loop-config` block, a green toast should appear and the loop should be created.

- [ ] **Step 4: Commit**

```bash
git add renderer.js
git commit -m "feat(loops): add conversational loop setup with :::loop-config detection"
```

---

### Task 12: Fix the notification flash bug

**Files:**
- Modify: `renderer.js:1033-1041` (onData handler)

While we're in the codebase, fix the bug where activity notifications fire before the user has sent their first message (pasting text sets `hasUserInput` prematurely).

- [ ] **Step 1: Track actual submission vs just typing**

Change the `onData` handler to only set `hasUserInput` when the user presses Enter (sends a newline), not when they type or paste:

Replace the existing `terminal.onData` handler (~line 1033-1042):

```javascript
  terminal.onData(function (data) {
    wsSend({ type: 'write', id: id, data: data });
    var c = allColumns.get(id);
    if (c && data.length > 0 && data.charCodeAt(0) !== 0x1b) {
      // Only set hasUserInput when user actually submits (Enter key = \r or \n)
      // Not on typing/pasting, which happens before submission
      if (data.indexOf('\r') !== -1 || data.indexOf('\n') !== -1) {
        c.hasUserInput = true;
        c.notified = false;
      }
    }
  });
```

- [ ] **Step 2: Verify the fix**

Run: `npm start`
Spawn a new Claude column. Paste text into the terminal (but don't press Enter). Wait 5+ seconds. The header should NOT flash orange. Now press Enter to send the message. After Claude responds and shows a prompt, the attention notification should fire correctly.

- [ ] **Step 3: Commit**

```bash
git add renderer.js
git commit -m "fix: only trigger activity notifications after user submits input, not on typing/pasting"
```

---

### Task 13: Integration testing and polish

**Files:**
- All modified files

- [ ] **Step 1: End-to-end test of the full loop lifecycle**

Run: `npm start`

1. Create a loop via the "+ New Loop" button in the LOOPS tab
2. Set it to run every 1 minute with a simple prompt like "Check if there are any TODO comments in the codebase and list them"
3. Verify the loop card appears with correct status
4. Click "Run Now" — verify the card shows "running..." status
5. Wait for completion — verify the card updates with results
6. Open the flyout dashboard — verify the loop appears under the correct project
7. Click the loop row to expand — verify history dots and summary show
8. If attention items exist, click one — verify a Claude column spawns with context
9. Edit the loop — change the schedule, verify it saves
10. Pause the loop — verify it shows "disabled" status
11. Delete the loop — verify it's removed

- [ ] **Step 2: Test conversational setup**

1. Click "Ask Claude to set it up"
2. Describe what you want monitored
3. Verify Claude outputs a `:::loop-config` block
4. Verify the green toast appears and the loop is created
5. Verify the loop appears in both the LOOPS tab and flyout dashboard

- [ ] **Step 3: Test graceful shutdown recovery**

1. Create a loop and trigger "Run Now"
2. While it's running, quit the app (Ctrl+Q)
3. Reopen the app
4. Check the loop — should show "interrupted" status with "App closed during run" error

- [ ] **Step 4: Test the notification flash fix**

1. Spawn a new Claude column
2. Type or paste text (don't press Enter)
3. Wait 5+ seconds — no orange flash should appear
4. Press Enter, wait for response — attention notification should fire correctly

- [ ] **Step 5: Final commit with any polish fixes**

```bash
git add -A
git commit -m "feat(loops): complete scheduled background loops feature with all UI components"
```
