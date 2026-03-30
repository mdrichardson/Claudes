# Automations System (Loops Redesign) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename "Loops" to "Automations" and add multi-agent pipeline support with optional per-agent repo isolation (git clone into separate directories), dependency chaining (run-after), and a 3-stage creation modal.

**Architecture:** Extends the existing 4-file architecture (main.js, preload.js, renderer.js, index.html). The data model wraps each former "loop" in an `automation` envelope containing an `agents[]` array. The execution engine gains dependency resolution (topological scheduling) and per-agent git clone isolation. The UI adds multi-agent card rendering, a pipeline visualization, and a 3-stage creation/edit modal. No new JS files.

**Tech Stack:** Electron IPC, child_process.spawn (Claude CLI), child_process.execFile (git), vanilla JS DOM, CSS animations

**Spec:** `docs/superpowers/specs/2026-03-27-automations-redesign.md`

---

## Phase 1: Data Model, Migration & Persistence

### Task 1: Add automations constants and ID generators

**Files:**
- Modify: `main.js:17-21` (constants section)
- Modify: `main.js:111-113` (ID generator section)

Replace the loops constants and add new ID generators. Keep the old constants temporarily for migration.

- [ ] **Step 1: Add new constants after existing ones**

At `main.js:19-20`, add new constants below the existing `LOOPS_FILE` and `LOOPS_RUNS_DIR` (keep old ones for migration):

```javascript
const AUTOMATIONS_FILE = path.join(CONFIG_DIR, 'automations.json');
const AUTOMATIONS_RUNS_DIR = path.join(CONFIG_DIR, 'automation-runs');
```

- [ ] **Step 2: Add new ID generators after existing `generateLoopId()`**

After `main.js:113`, add:

```javascript
function generateAutomationId() {
  return 'auto_' + Date.now().toString(36) + '_' + Math.random().toString(36).substring(2, 7);
}

function generateAgentId() {
  return 'agent_' + Date.now().toString(36) + '_' + Math.random().toString(36).substring(2, 7);
}
```

- [ ] **Step 3: Commit**

```bash
git add main.js
git commit -m "feat: add automations constants and ID generators"
```

---

### Task 2: Add automations persistence functions

**Files:**
- Modify: `main.js:44-109` (persistence section — add new functions after existing loop functions)

Add `readAutomations()`, `writeAutomations()`, `ensureAgentRunsDir()`, `saveAgentRun()`, `pruneAgentRuns()`, `getAgentHistory()`.

- [ ] **Step 1: Add readAutomations and writeAutomations**

After the existing `writeLoops()` function (around line 58), add:

```javascript
function readAutomations() {
  ensureConfigDir();
  try {
    return JSON.parse(fs.readFileSync(AUTOMATIONS_FILE, 'utf8'));
  } catch {
    return { globalEnabled: true, maxConcurrentRuns: 3, agentReposBaseDir: path.join(os.homedir(), '.claudes', 'agents'), automations: [] };
  }
}

function writeAutomations(data) {
  ensureConfigDir();
  fs.writeFileSync(AUTOMATIONS_FILE, JSON.stringify(data, null, 2), 'utf8');
}
```

- [ ] **Step 2: Add agent run history functions**

After the new `writeAutomations()`, add:

```javascript
function ensureAgentRunsDir(automationId, agentId) {
  const dir = path.join(AUTOMATIONS_RUNS_DIR, automationId, agentId);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  return dir;
}

function saveAgentRun(automationId, agentId, runData) {
  const dir = ensureAgentRunsDir(automationId, agentId);
  const filename = new Date(runData.startedAt).toISOString().replace(/[:.]/g, '-') + '.json';
  if (runData.output && runData.output.length > 50000) {
    runData.output = runData.output.substring(0, 50000) + '\n...[truncated]';
  }
  fs.writeFileSync(path.join(dir, filename), JSON.stringify(runData, null, 2), 'utf8');
  pruneAgentRuns(dir);
}

function pruneAgentRuns(dir) {
  try {
    const files = fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort();
    while (files.length > 50) {
      fs.unlinkSync(path.join(dir, files.shift()));
    }
  } catch { /* ignore */ }
}

function getAgentHistory(automationId, agentId, count) {
  const dir = path.join(AUTOMATIONS_RUNS_DIR, automationId, agentId);
  try {
    const files = fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort().reverse();
    const results = [];
    for (let i = 0; i < Math.min(count || 5, files.length); i++) {
      const data = JSON.parse(fs.readFileSync(path.join(dir, files[i]), 'utf8'));
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
```

- [ ] **Step 3: Verify no syntax errors**

Run: `node -c main.js`
Expected: no output (syntax OK)

- [ ] **Step 4: Commit**

```bash
git add main.js
git commit -m "feat: add automations persistence layer"
```

---

### Task 3: Migration from loops.json to automations.json

**Files:**
- Modify: `main.js` (add migration function after persistence section, call it from app startup)

On startup, if `loops.json` exists and `automations.json` does not, transform loop data into the new format.

- [ ] **Step 1: Add the migration function**

After the `getAgentHistory()` function, add:

```javascript
function migrateLoopsToAutomations() {
  // Only migrate if loops.json exists and automations.json does not
  if (!fs.existsSync(LOOPS_FILE) || fs.existsSync(AUTOMATIONS_FILE)) return;

  console.log('[Migration] Migrating loops.json to automations.json...');

  // Backup loops.json
  const backupPath = path.join(CONFIG_DIR, 'loops.backup.json');
  fs.copyFileSync(LOOPS_FILE, backupPath);
  console.log('[Migration] Backed up loops.json to loops.backup.json');

  const loopData = JSON.parse(fs.readFileSync(LOOPS_FILE, 'utf8'));

  const automationsData = {
    globalEnabled: loopData.globalEnabled !== undefined ? loopData.globalEnabled : true,
    maxConcurrentRuns: loopData.maxConcurrentRuns || 3,
    agentReposBaseDir: path.join(os.homedir(), '.claudes', 'agents'),
    automations: []
  };

  // Transform each loop into an automation with a single agent
  (loopData.loops || []).forEach(loop => {
    const automationId = generateAutomationId();
    const agentId = generateAgentId();

    const agent = {
      id: agentId,
      name: loop.name,
      prompt: loop.prompt,
      schedule: loop.schedule,
      runMode: 'independent',
      runAfter: [],
      runOnUpstreamFailure: false,
      isolation: { enabled: false, clonePath: null },
      enabled: loop.enabled !== undefined ? loop.enabled : true,
      skipPermissions: loop.skipPermissions || false,
      firstStartOnly: loop.firstStartOnly || false,
      dbConnectionString: loop.dbConnectionString || null,
      dbReadOnly: loop.dbReadOnly !== false,
      lastRunAt: loop.lastRunAt || null,
      lastRunStatus: loop.lastRunStatus || null,
      lastError: loop.lastError || null,
      lastSummary: loop.lastSummary || null,
      lastAttentionItems: loop.lastAttentionItems || null,
      currentRunStartedAt: loop.currentRunStartedAt || null
    };

    const automation = {
      id: automationId,
      name: loop.name,
      projectPath: loop.projectPath,
      agents: [agent],
      enabled: loop.enabled !== undefined ? loop.enabled : true,
      createdAt: loop.createdAt || new Date().toISOString()
    };

    automationsData.automations.push(automation);

    // Migrate run history: loop-runs/{loopId}/ -> automation-runs/{automationId}/{agentId}/
    const oldRunDir = path.join(LOOPS_RUNS_DIR, loop.id);
    if (fs.existsSync(oldRunDir)) {
      const newRunDir = path.join(AUTOMATIONS_RUNS_DIR, automationId, agentId);
      fs.mkdirSync(newRunDir, { recursive: true });
      const runFiles = fs.readdirSync(oldRunDir).filter(f => f.endsWith('.json'));
      runFiles.forEach(file => {
        fs.copyFileSync(path.join(oldRunDir, file), path.join(newRunDir, file));
      });
      console.log('[Migration] Migrated ' + runFiles.length + ' run files for loop "' + loop.name + '"');
    }
  });

  writeAutomations(automationsData);
  console.log('[Migration] Created automations.json with ' + automationsData.automations.length + ' automations');
}
```

- [ ] **Step 2: Call migration at app startup**

Find the `app.whenReady().then(async () => {` block in main.js. Add a call to `migrateLoopsToAutomations()` near the top of that block, before `startLoopScheduler()`:

```javascript
migrateLoopsToAutomations();
```

- [ ] **Step 3: Test the migration manually**

Run: `node -c main.js`
Expected: no output (syntax OK)

To test end-to-end: launch the app with an existing `loops.json`. Check that `automations.json` is created, `loops.backup.json` exists, and `automation-runs/` contains the migrated run files.

- [ ] **Step 4: Commit**

```bash
git add main.js
git commit -m "feat: add loops-to-automations migration"
```

---

## Phase 2: IPC Handlers (Backend API)

### Task 4: Core automations IPC handlers (CRUD)

**Files:**
- Modify: `main.js:1057-1229` (IPC handlers section — add new handlers after existing loop handlers)

Add all new `automations:*` IPC handlers for CRUD operations. Keep old `loops:*` handlers temporarily so nothing breaks during the transition.

- [ ] **Step 1: Add getAutomations and getAutomationsForProject**

After the existing `loops:getLiveOutput` handler (line 1229), add:

```javascript
// --- Automations IPC Handlers ---

ipcMain.handle('automations:getAll', () => {
  return readAutomations();
});

ipcMain.handle('automations:getForProject', (event, projectPath) => {
  const data = readAutomations();
  const normalized = projectPath.replace(/\\/g, '/');
  return data.automations.filter(a => a.projectPath.replace(/\\/g, '/') === normalized);
});
```

- [ ] **Step 2: Add createAutomation handler**

```javascript
ipcMain.handle('automations:create', (event, config) => {
  const data = readAutomations();
  const automationId = generateAutomationId();

  // Build agents array — each agent gets an ID and defaults
  const agents = (config.agents || []).map(agentConfig => {
    return Object.assign({
      id: generateAgentId(),
      runMode: 'independent',
      runAfter: [],
      runOnUpstreamFailure: false,
      isolation: { enabled: false, clonePath: null },
      enabled: true,
      skipPermissions: false,
      firstStartOnly: false,
      dbConnectionString: null,
      dbReadOnly: true,
      lastRunAt: null,
      lastRunStatus: null,
      lastError: null,
      lastSummary: null,
      lastAttentionItems: null,
      currentRunStartedAt: null
    }, agentConfig);
  });

  const automation = {
    id: automationId,
    name: config.name,
    projectPath: config.projectPath,
    agents: agents,
    enabled: true,
    createdAt: new Date().toISOString()
  };

  data.automations.push(automation);
  writeAutomations(data);
  return automation;
});
```

- [ ] **Step 3: Add updateAutomation and updateAgent handlers**

```javascript
ipcMain.handle('automations:update', (event, automationId, updates) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return null;
  const safeFields = ['name', 'enabled'];
  safeFields.forEach(field => {
    if (updates[field] !== undefined) automation[field] = updates[field];
  });
  writeAutomations(data);
  return automation;
});

ipcMain.handle('automations:updateAgent', (event, automationId, agentId, updates) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return null;
  const agent = automation.agents.find(ag => ag.id === agentId);
  if (!agent) return null;
  const safeFields = ['name', 'prompt', 'schedule', 'runMode', 'runAfter', 'runOnUpstreamFailure',
    'isolation', 'enabled', 'skipPermissions', 'firstStartOnly', 'dbConnectionString', 'dbReadOnly'];
  safeFields.forEach(field => {
    if (updates[field] !== undefined) agent[field] = updates[field];
  });
  writeAutomations(data);
  return agent;
});
```

- [ ] **Step 4: Add addAgent and removeAgent handlers**

```javascript
ipcMain.handle('automations:addAgent', (event, automationId, agentConfig) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return null;
  const agent = Object.assign({
    id: generateAgentId(),
    runMode: 'independent',
    runAfter: [],
    runOnUpstreamFailure: false,
    isolation: { enabled: false, clonePath: null },
    enabled: true,
    skipPermissions: false,
    firstStartOnly: false,
    dbConnectionString: null,
    dbReadOnly: true,
    lastRunAt: null,
    lastRunStatus: null,
    lastError: null,
    lastSummary: null,
    lastAttentionItems: null,
    currentRunStartedAt: null
  }, agentConfig);
  automation.agents.push(agent);
  writeAutomations(data);
  return agent;
});

ipcMain.handle('automations:removeAgent', (event, automationId, agentId) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return null;
  const agent = automation.agents.find(ag => ag.id === agentId);
  if (!agent) return { removed: false };

  // Clean up clone directory if isolated
  if (agent.isolation && agent.isolation.enabled && agent.isolation.clonePath) {
    try { fs.rmSync(agent.isolation.clonePath, { recursive: true, force: true }); } catch { /* ignore */ }
  }

  // Clean up run history
  const runDir = path.join(AUTOMATIONS_RUNS_DIR, automationId, agentId);
  try { fs.rmSync(runDir, { recursive: true, force: true }); } catch { /* ignore */ }

  // Remove references from other agents' runAfter arrays
  automation.agents.forEach(ag => {
    if (ag.runAfter) {
      ag.runAfter = ag.runAfter.filter(id => id !== agentId);
      if (ag.runAfter.length === 0 && ag.runMode === 'run_after') {
        ag.runMode = 'independent';
      }
    }
  });

  automation.agents = automation.agents.filter(ag => ag.id !== agentId);
  writeAutomations(data);
  return { removed: true };
});
```

- [ ] **Step 5: Add deleteAutomation handler**

```javascript
ipcMain.handle('automations:delete', (event, automationId) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (automation) {
    // Clean up clone directories
    automation.agents.forEach(agent => {
      if (agent.isolation && agent.isolation.enabled && agent.isolation.clonePath) {
        try { fs.rmSync(agent.isolation.clonePath, { recursive: true, force: true }); } catch { /* ignore */ }
      }
    });
  }
  data.automations = data.automations.filter(a => a.id !== automationId);
  writeAutomations(data);
  // Clean up run history
  const runDir = path.join(AUTOMATIONS_RUNS_DIR, automationId);
  try { fs.rmSync(runDir, { recursive: true, force: true }); } catch { /* ignore */ }
  return true;
});
```

- [ ] **Step 6: Add toggle handlers**

```javascript
ipcMain.handle('automations:toggle', (event, automationId) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return null;
  automation.enabled = !automation.enabled;
  if (automation.enabled) {
    automation.agents.forEach(ag => { ag.lastError = null; });
  }
  writeAutomations(data);
  return automation;
});

ipcMain.handle('automations:toggleAgent', (event, automationId, agentId) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return null;
  const agent = automation.agents.find(ag => ag.id === agentId);
  if (!agent) return null;
  agent.enabled = !agent.enabled;
  if (agent.enabled) agent.lastError = null;
  writeAutomations(data);
  return agent;
});

ipcMain.handle('automations:toggleGlobal', () => {
  const data = readAutomations();
  data.globalEnabled = !data.globalEnabled;
  writeAutomations(data);
  return data.globalEnabled;
});
```

- [ ] **Step 7: Verify syntax**

Run: `node -c main.js`
Expected: no output (syntax OK)

- [ ] **Step 8: Commit**

```bash
git add main.js
git commit -m "feat: add automations CRUD IPC handlers"
```

---

### Task 5: Agent history, run detail, live output, and run-now IPC handlers

**Files:**
- Modify: `main.js` (continue adding IPC handlers after Task 4's additions)

- [ ] **Step 1: Add history and run detail handlers**

```javascript
ipcMain.handle('automations:getAgentHistory', (event, automationId, agentId, count) => {
  return getAgentHistory(automationId, agentId, count);
});

ipcMain.handle('automations:getAgentRunDetail', (event, automationId, agentId, startedAt) => {
  const dir = path.join(AUTOMATIONS_RUNS_DIR, automationId, agentId);
  try {
    const filename = new Date(startedAt).toISOString().replace(/[:.]/g, '-') + '.json';
    const filePath = path.join(dir, filename);
    if (fs.existsSync(filePath)) {
      return JSON.parse(fs.readFileSync(filePath, 'utf8'));
    }
    // Fallback: search by startedAt field
    const files = fs.readdirSync(dir).filter(f => f.endsWith('.json'));
    for (const f of files) {
      const data = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
      if (data.startedAt === startedAt) return data;
    }
  } catch { /* ignore */ }
  return null;
});

ipcMain.handle('automations:getAgentLiveOutput', (event, automationId, agentId) => {
  const key = automationId + ':' + agentId;
  const liveChunks = agentLiveOutputBuffers.get(key);
  if (liveChunks) return liveChunks.join('');
  return null;
});
```

Note: `agentLiveOutputBuffers` will be defined in Task 7 (execution engine). For now, add it as a placeholder near the existing `liveOutputBuffers`:

```javascript
const agentLiveOutputBuffers = new Map(); // 'automationId:agentId' -> string[] chunks
```

- [ ] **Step 2: Add runAgentNow and runAutomationNow handlers**

```javascript
ipcMain.handle('automations:runAgentNow', (event, automationId, agentId) => {
  runAgent(automationId, agentId);
  return true;
});

ipcMain.handle('automations:runAutomationNow', (event, automationId) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return false;
  // Run all independent agents — dependents will cascade
  automation.agents.forEach(agent => {
    if (agent.enabled && agent.runMode === 'independent') {
      runAgent(automationId, agent.id);
    }
  });
  return true;
});
```

Note: `runAgent()` is defined in Task 7.

- [ ] **Step 3: Commit**

```bash
git add main.js
git commit -m "feat: add agent history and run-now IPC handlers"
```

---

### Task 6: Clone setup and export/import IPC handlers

**Files:**
- Modify: `main.js` (continue adding IPC handlers)

- [ ] **Step 1: Add clone setup handler**

```javascript
ipcMain.handle('automations:setupAgentClone', async (event, automationId, agentId) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return { error: 'Automation not found' };
  const agent = automation.agents.find(ag => ag.id === agentId);
  if (!agent) return { error: 'Agent not found' };
  if (!agent.isolation || !agent.isolation.enabled) return { error: 'Agent does not have isolation enabled' };

  // Determine clone path
  const baseDir = data.agentReposBaseDir || path.join(os.homedir(), '.claudes', 'agents');
  const projectName = automation.projectPath.split(/[/\\]/).pop();
  const agentDirName = agent.name.replace(/[^a-zA-Z0-9_-]/g, '-').toLowerCase();
  const clonePath = path.join(baseDir, projectName, agentDirName);

  // Check if clone already exists with correct remote
  if (fs.existsSync(clonePath)) {
    try {
      const existingRemote = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd: clonePath, encoding: 'utf8' }).trim();
      // Get source remote for comparison
      let sourceRemote = '';
      try {
        sourceRemote = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd: automation.projectPath, encoding: 'utf8' }).trim();
      } catch { /* no remote */ }
      if (existingRemote === sourceRemote || existingRemote === automation.projectPath) {
        // Correct clone already exists — reuse it
        agent.isolation.clonePath = clonePath;
        writeAutomations(data);
        return { clonePath, status: 'reused' };
      }
      return { error: 'Directory exists but has different remote: ' + existingRemote };
    } catch {
      return { error: 'Directory exists but is not a git repository: ' + clonePath };
    }
  }

  // Get remote URL from project
  let remoteUrl = '';
  try {
    remoteUrl = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd: automation.projectPath, encoding: 'utf8' }).trim();
  } catch {
    // No remote — fall back to local path clone
    remoteUrl = automation.projectPath;
    if (mainWindow) mainWindow.webContents.send('automations:clone-progress', {
      automationId, agentId, line: 'WARNING: No git remote configured. Cloning from local path.'
    });
  }

  // Ensure parent directory exists
  fs.mkdirSync(path.dirname(clonePath), { recursive: true });

  // Clone
  return new Promise((resolve) => {
    const child = spawn('git', ['clone', remoteUrl, clonePath], {
      stdio: ['ignore', 'pipe', 'pipe']
    });

    child.stdout.on('data', (chunk) => {
      if (mainWindow) mainWindow.webContents.send('automations:clone-progress', {
        automationId, agentId, line: chunk.toString()
      });
    });
    child.stderr.on('data', (chunk) => {
      if (mainWindow) mainWindow.webContents.send('automations:clone-progress', {
        automationId, agentId, line: chunk.toString()
      });
    });

    child.on('close', (exitCode) => {
      if (exitCode === 0) {
        const freshData = readAutomations();
        const freshAuto = freshData.automations.find(a => a.id === automationId);
        if (freshAuto) {
          const freshAgent = freshAuto.agents.find(ag => ag.id === agentId);
          if (freshAgent) {
            freshAgent.isolation.clonePath = clonePath;
            writeAutomations(freshData);
          }
        }
        resolve({ clonePath, status: 'cloned' });
      } else {
        resolve({ error: 'git clone failed with exit code ' + exitCode });
      }
    });

    child.on('error', (err) => {
      resolve({ error: 'git clone error: ' + err.message });
    });
  });
});

ipcMain.handle('automations:getCloneStatus', (event, automationId) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return {};
  const status = {};
  automation.agents.forEach(agent => {
    if (agent.isolation && agent.isolation.enabled) {
      if (agent.isolation.clonePath && fs.existsSync(agent.isolation.clonePath)) {
        status[agent.id] = 'ready';
      } else if (agent.isolation.clonePath) {
        status[agent.id] = 'missing'; // Directory was deleted externally
      } else {
        status[agent.id] = 'pending'; // Needs cloning
      }
    } else {
      status[agent.id] = 'not-isolated';
    }
  });
  return status;
});
```

- [ ] **Step 2: Add export/import handlers**

```javascript
ipcMain.handle('automations:export', (event, projectPath) => {
  const data = readAutomations();
  const normalized = projectPath.replace(/\\/g, '/');
  const automations = data.automations
    .filter(a => a.projectPath.replace(/\\/g, '/') === normalized)
    .map(a => ({
      name: a.name,
      agents: a.agents.map(ag => ({
        name: ag.name, prompt: ag.prompt, schedule: ag.schedule,
        runMode: ag.runMode, runAfter: ag.runAfter, runOnUpstreamFailure: ag.runOnUpstreamFailure,
        isolation: { enabled: ag.isolation ? ag.isolation.enabled : false },
        skipPermissions: ag.skipPermissions || false, firstStartOnly: ag.firstStartOnly || false,
        dbConnectionString: ag.dbConnectionString || null, dbReadOnly: ag.dbReadOnly !== false
      }))
    }));
  if (automations.length === 0) return { cancelled: true };
  const result = dialog.showSaveDialogSync(mainWindow, {
    title: 'Export Automations',
    defaultPath: 'automations-export.json',
    filters: [{ name: 'JSON', extensions: ['json'] }]
  });
  if (!result) return { cancelled: true };
  const payload = { exportedAt: new Date().toISOString(), source: projectPath, automations };
  fs.writeFileSync(result, JSON.stringify(payload, null, 2), 'utf8');
  return { path: result, count: automations.length };
});

ipcMain.handle('automations:exportOne', (event, automationId) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return { cancelled: true };
  const exported = {
    name: automation.name,
    agents: automation.agents.map(ag => ({
      name: ag.name, prompt: ag.prompt, schedule: ag.schedule,
      runMode: ag.runMode, runAfter: ag.runAfter, runOnUpstreamFailure: ag.runOnUpstreamFailure,
      isolation: { enabled: ag.isolation ? ag.isolation.enabled : false },
      skipPermissions: ag.skipPermissions || false, firstStartOnly: ag.firstStartOnly || false,
      dbConnectionString: ag.dbConnectionString || null, dbReadOnly: ag.dbReadOnly !== false
    }))
  };
  const safeName = automation.name.replace(/[^a-zA-Z0-9_-]/g, '_').toLowerCase();
  const result = dialog.showSaveDialogSync(mainWindow, {
    title: 'Export Automation',
    defaultPath: 'automation-' + safeName + '.json',
    filters: [{ name: 'JSON', extensions: ['json'] }]
  });
  if (!result) return { cancelled: true };
  const payload = { exportedAt: new Date().toISOString(), automations: [exported] };
  fs.writeFileSync(result, JSON.stringify(payload, null, 2), 'utf8');
  return { path: result, count: 1 };
});

ipcMain.handle('automations:import', (event, projectPath) => {
  const result = dialog.showOpenDialogSync(mainWindow, {
    title: 'Import Automations',
    filters: [{ name: 'JSON', extensions: ['json'] }],
    properties: ['openFile']
  });
  if (!result || result.length === 0) return { cancelled: true };
  try {
    const raw = JSON.parse(fs.readFileSync(result[0], 'utf8'));

    // Support both old loops format and new automations format
    let automations = raw.automations || [];
    if (automations.length === 0 && raw.loops) {
      // Legacy loops format — convert each loop to a single-agent automation
      automations = raw.loops.map(l => ({
        name: l.name,
        agents: [{
          name: l.name, prompt: l.prompt, schedule: l.schedule,
          skipPermissions: l.skipPermissions || false, firstStartOnly: l.firstStartOnly || false,
          dbConnectionString: l.dbConnectionString || null, dbReadOnly: l.dbReadOnly !== false
        }]
      }));
    }
    if (automations.length === 0 && raw.name && raw.agents) {
      // Single automation object
      automations = [raw];
    }
    if (automations.length === 0 && raw.name && raw.prompt) {
      // Single legacy loop object
      automations = [{
        name: raw.name,
        agents: [{
          name: raw.name, prompt: raw.prompt, schedule: raw.schedule,
          skipPermissions: raw.skipPermissions || false, firstStartOnly: raw.firstStartOnly || false,
          dbConnectionString: raw.dbConnectionString || null, dbReadOnly: raw.dbReadOnly !== false
        }]
      }];
    }
    if (automations.length === 0) return { error: 'No automations found in file' };

    const data = readAutomations();
    let count = 0;

    automations.forEach(imported => {
      const automationId = generateAutomationId();
      // Map exported agent names to new IDs for runAfter references
      const idMap = {};
      const agents = (imported.agents || []).map((ag, idx) => {
        const newId = generateAgentId();
        idMap['agent_' + idx] = newId;
        idMap[ag.name] = newId;
        return Object.assign({
          id: newId,
          runMode: 'independent',
          runAfter: [],
          runOnUpstreamFailure: false,
          isolation: { enabled: false, clonePath: null },
          enabled: true,
          skipPermissions: false,
          firstStartOnly: false,
          dbConnectionString: null,
          dbReadOnly: true,
          lastRunAt: null,
          lastRunStatus: null,
          lastError: null,
          lastSummary: null,
          lastAttentionItems: null,
          currentRunStartedAt: null
        }, ag, { id: newId, isolation: { enabled: ag.isolation ? ag.isolation.enabled : false, clonePath: null } });
      });

      data.automations.push({
        id: automationId,
        name: imported.name,
        projectPath: projectPath,
        agents: agents,
        enabled: true,
        createdAt: new Date().toISOString()
      });
      count++;
    });

    writeAutomations(data);
    return { count };
  } catch (err) {
    return { error: 'Failed to import: ' + err.message };
  }
});
```

- [ ] **Step 3: Verify syntax**

Run: `node -c main.js`
Expected: no output (syntax OK)

- [ ] **Step 4: Commit**

```bash
git add main.js
git commit -m "feat: add clone setup and export/import IPC handlers"
```

---

## Phase 3: Execution Engine

### Task 7: Agent execution function (runAgent)

**Files:**
- Modify: `main.js` (add after existing `runLoop()` function, around line 1539)

This is the core agent runner — nearly identical to `runLoop()` but keyed by `(automationId, agentId)`, uses the agent's working directory (isolation or project), and does a pre-run pull for isolated agents.

- [ ] **Step 1: Add running agents tracking maps**

Near the existing `runningLoops` map (line 1233), add:

```javascript
const runningAgents = new Map(); // 'automationId:agentId' -> child process
const agentLiveOutputBuffers = new Map(); // 'automationId:agentId' -> string[] chunks
const agentQueue = []; // {automationId, agentId} objects waiting for a slot
```

- [ ] **Step 2: Add the pre-run pull function**

After the tracking maps:

```javascript
function preRunPull(clonePath) {
  return new Promise((resolve) => {
    try {
      execFileSync('git', ['checkout', 'master'], { cwd: clonePath, encoding: 'utf8', stdio: 'pipe' });
    } catch {
      try {
        execFileSync('git', ['checkout', 'main'], { cwd: clonePath, encoding: 'utf8', stdio: 'pipe' });
      } catch (e) {
        resolve({ error: 'Failed to checkout master/main: ' + e.message });
        return;
      }
    }
    try {
      execFileSync('git', ['pull', 'origin'], { cwd: clonePath, encoding: 'utf8', stdio: 'pipe', timeout: 60000 });
      resolve({ ok: true });
    } catch (e) {
      resolve({ error: 'git pull failed: ' + e.message });
    }
  });
}
```

- [ ] **Step 3: Add the runAgent function**

```javascript
async function runAgent(automationId, agentId) {
  let data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return;
  const agent = automation.agents.find(ag => ag.id === agentId);
  if (!agent) return;

  const key = automationId + ':' + agentId;
  if (runningAgents.has(key)) return;

  // Check concurrency limit (shared across loops and agents)
  const totalRunning = runningLoops.size + runningAgents.size;
  if (totalRunning >= (data.maxConcurrentRuns || 3)) {
    if (!agentQueue.some(q => q.automationId === automationId && q.agentId === agentId)) {
      agentQueue.push({ automationId, agentId });
    }
    return;
  }

  // Determine working directory
  let cwd = automation.projectPath;
  if (agent.isolation && agent.isolation.enabled) {
    if (!agent.isolation.clonePath || !fs.existsSync(agent.isolation.clonePath)) {
      agent.lastRunStatus = 'error';
      agent.lastError = 'Working directory not found — run setup again';
      writeAutomations(data);
      if (mainWindow) mainWindow.webContents.send('automations:agent-completed', {
        automationId, agentId, status: 'error', error: agent.lastError
      });
      return;
    }
    cwd = agent.isolation.clonePath;

    // Pre-run pull
    const pullResult = await preRunPull(cwd);
    if (pullResult.error) {
      agent.lastRunStatus = 'error';
      agent.lastError = pullResult.error;
      writeAutomations(data);
      if (mainWindow) mainWindow.webContents.send('automations:agent-completed', {
        automationId, agentId, status: 'error', error: agent.lastError
      });
      return;
    }
    // Re-read data after async pull
    data = readAutomations();
  }

  // Validate working directory
  if (!fs.existsSync(cwd)) {
    agent.lastRunStatus = 'error';
    agent.lastError = 'Working directory not found: ' + cwd;
    agent.enabled = false;
    writeAutomations(data);
    if (mainWindow) mainWindow.webContents.send('automations:agent-completed', {
      automationId, agentId, status: 'error', error: agent.lastError
    });
    return;
  }

  // Mark as running
  agent.currentRunStartedAt = new Date().toISOString();
  writeAutomations(data);

  if (mainWindow) mainWindow.webContents.send('automations:agent-started', { automationId, agentId });

  const startedAt = new Date().toISOString();
  const outputChunks = [];
  const textChunks = [];

  let promptPrefix = '';
  if (agent.dbConnectionString && agent.dbReadOnly !== false) {
    promptPrefix = 'CRITICAL CONSTRAINT: This agent has READ-ONLY database access. You MUST NOT attempt to write, update, insert, delete, drop, rename, or modify any data in the database. This includes using $merge, $out, or any write stages in aggregation pipelines. Do NOT attempt to bypass this restriction by using shell commands (mongosh, mongo, etc.) or any other method. If the task requires writing to the database, report it as an attention item explaining what write would be needed, but do not perform it.\n\n';
  }
  const fullPrompt = promptPrefix + agent.prompt + LOOP_PROMPT_SUFFIX;

  const args = ['--print', fullPrompt, '--output-format', 'stream-json', '--verbose'];
  if (agent.skipPermissions) args.push('--dangerously-skip-permissions');

  // Database MCP config
  let mcpConfigPath = null;
  if (agent.dbConnectionString) {
    const mcpArgs = ['-y', 'mongodb-mcp-server@latest'];
    if (agent.dbReadOnly !== false) mcpArgs.push('--readOnly');
    const mcpConfig = {
      mcpServers: {
        mongodb: {
          command: 'npx',
          args: mcpArgs,
          env: { MDB_MCP_CONNECTION_STRING: agent.dbConnectionString }
        }
      }
    };
    mcpConfigPath = path.join(AUTOMATIONS_RUNS_DIR, automationId + '_' + agentId + '_mcp.json');
    fs.mkdirSync(path.dirname(mcpConfigPath), { recursive: true });
    fs.writeFileSync(mcpConfigPath, JSON.stringify(mcpConfig), 'utf8');
    args.push('--mcp-config', mcpConfigPath);

    if (agent.dbReadOnly !== false) {
      const allowedTools = [
        'mcp__mongodb__find', 'mcp__mongodb__count', 'mcp__mongodb__collection-indexes',
        'mcp__mongodb__collection-schema', 'mcp__mongodb__collection-storage-size',
        'mcp__mongodb__db-stats', 'mcp__mongodb__explain', 'mcp__mongodb__export',
        'mcp__mongodb__list-collections', 'mcp__mongodb__list-databases',
        'mcp__mongodb__mongodb-logs', 'mcp__mongodb__list-knowledge-sources',
        'mcp__mongodb__search-knowledge',
        'Read', 'Glob', 'Grep', 'WebFetch', 'WebSearch'
      ];
      args.push('--allowedTools', allowedTools.join(','));
    }
  }

  const child = spawn(getClaudePath(), args, {
    cwd: cwd,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: Object.assign({}, process.env)
  });

  runningAgents.set(key, child);
  agentLiveOutputBuffers.set(key, textChunks);

  let streamBuffer = '';
  child.stdout.on('data', (chunk) => {
    const raw = chunk.toString();
    outputChunks.push(raw);
    streamBuffer += raw;
    const lines = streamBuffer.split('\n');
    streamBuffer = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const evt = JSON.parse(line);
        let text = '';
        if (evt.type === 'assistant' && evt.message && evt.message.content) {
          evt.message.content.forEach(block => {
            if (block.type === 'text') text += block.text;
          });
        } else if (evt.type === 'content_block_delta' && evt.delta) {
          if (evt.delta.type === 'text_delta') text = evt.delta.text;
        } else if (evt.type === 'result' && evt.result) {
          if (typeof evt.result === 'string') {
            text = evt.result;
          } else if (Array.isArray(evt.result)) {
            evt.result.forEach(block => {
              if (block.type === 'text') text += block.text;
            });
          }
        }
        if (text) {
          textChunks.push(text);
          if (mainWindow) mainWindow.webContents.send('automations:agent-output', { automationId, agentId, chunk: text });
        }
      } catch { /* skip non-JSON lines */ }
    }
  });

  child.stderr.on('data', (chunk) => {
    const text = chunk.toString();
    textChunks.push(text);
    if (mainWindow) mainWindow.webContents.send('automations:agent-output', { automationId, agentId, chunk: text });
  });

  child.on('close', (exitCode) => {
    runningAgents.delete(key);
    agentLiveOutputBuffers.delete(key);
    if (mcpConfigPath) try { fs.unlinkSync(mcpConfigPath); } catch { /* ignore */ }

    const completedAt = new Date().toISOString();
    const displayOutput = textChunks.join('');
    const parsed = parseLoopResult(displayOutput);

    const runData = {
      automationId, agentId,
      startedAt, completedAt,
      durationMs: new Date(completedAt).getTime() - new Date(startedAt).getTime(),
      exitCode,
      status: exitCode === 0 ? 'completed' : 'error',
      summary: parsed.summary,
      output: displayOutput,
      attentionItems: parsed.attentionItems,
      costUsd: null
    };

    saveAgentRun(automationId, agentId, runData);

    // Update agent config
    const freshData = readAutomations();
    const freshAuto = freshData.automations.find(a => a.id === automationId);
    if (freshAuto) {
      const freshAgent = freshAuto.agents.find(ag => ag.id === agentId);
      if (freshAgent) {
        freshAgent.currentRunStartedAt = null;
        freshAgent.lastRunAt = completedAt;
        freshAgent.lastRunStatus = runData.status;
        freshAgent.lastError = exitCode === 0 ? null : 'Exit code: ' + exitCode;
        freshAgent.lastSummary = parsed.summary || null;
        freshAgent.lastAttentionItems = parsed.attentionItems || [];
        writeAutomations(freshData);
      }

      // Trigger dependent agents
      triggerDependentAgents(automationId, agentId, runData.status, freshData);
    }

    // Notify renderer
    if (mainWindow) {
      mainWindow.webContents.send('automations:agent-completed', {
        automationId, agentId,
        status: runData.status,
        summary: parsed.summary,
        attentionItems: parsed.attentionItems,
        exitCode
      });

      if (parsed.attentionItems.length > 0) {
        mainWindow.flashFrame(true);
      }
    }

    // Process queue
    if (agentQueue.length > 0) {
      const next = agentQueue.shift();
      runAgent(next.automationId, next.agentId);
    }
  });

  child.on('error', (err) => {
    runningAgents.delete(key);
    if (mcpConfigPath) try { fs.unlinkSync(mcpConfigPath); } catch { /* ignore */ }
    const freshData = readAutomations();
    const freshAuto = freshData.automations.find(a => a.id === automationId);
    if (freshAuto) {
      const freshAgent = freshAuto.agents.find(ag => ag.id === agentId);
      if (freshAgent) {
        freshAgent.currentRunStartedAt = null;
        freshAgent.lastRunStatus = 'error';
        freshAgent.lastError = err.message;
        writeAutomations(freshData);
      }
    }
    if (mainWindow) mainWindow.webContents.send('automations:agent-completed', {
      automationId, agentId, status: 'error', error: err.message
    });
    if (agentQueue.length > 0) {
      const next = agentQueue.shift();
      runAgent(next.automationId, next.agentId);
    }
  });
}
```

- [ ] **Step 4: Verify syntax**

Run: `node -c main.js`
Expected: no output (syntax OK)

- [ ] **Step 5: Commit**

```bash
git add main.js
git commit -m "feat: add agent execution engine with isolation and pre-run pull"
```

---

### Task 8: Dependency resolution and cascade logic

**Files:**
- Modify: `main.js` (add `triggerDependentAgents` and `hasCyclicDependencies` after `runAgent()`)

- [ ] **Step 1: Add triggerDependentAgents function**

```javascript
function triggerDependentAgents(automationId, completedAgentId, completedStatus, data) {
  const automation = data ? data.automations.find(a => a.id === automationId) : null;
  if (!automation) return;

  automation.agents.forEach(agent => {
    if (agent.runMode !== 'run_after') return;
    if (!agent.enabled) return;
    if (!agent.runAfter || !agent.runAfter.includes(completedAgentId)) return;

    // Check if ALL upstream agents have completed
    const allUpstreamDone = agent.runAfter.every(upstreamId => {
      const upstream = automation.agents.find(ag => ag.id === upstreamId);
      if (!upstream) return true; // Missing upstream treated as complete
      return upstream.lastRunStatus && !upstream.currentRunStartedAt;
    });

    if (!allUpstreamDone) return;

    // Check if any upstream failed
    const anyFailed = agent.runAfter.some(upstreamId => {
      const upstream = automation.agents.find(ag => ag.id === upstreamId);
      return upstream && (upstream.lastRunStatus === 'error' || upstream.lastRunStatus === 'skipped');
    });

    if (anyFailed && !agent.runOnUpstreamFailure) {
      // Skip this agent and cascade the skip
      const freshData = readAutomations();
      const freshAuto = freshData.automations.find(a => a.id === automationId);
      if (freshAuto) {
        const freshAgent = freshAuto.agents.find(ag => ag.id === agent.id);
        if (freshAgent) {
          freshAgent.lastRunStatus = 'skipped';
          freshAgent.lastError = 'Upstream agent failed or was skipped';
          writeAutomations(freshData);
        }
        // Cascade skip to agents depending on this one
        triggerDependentAgents(automationId, agent.id, 'skipped', freshData);
      }
      if (mainWindow) mainWindow.webContents.send('automations:agent-completed', {
        automationId, agentId: agent.id, status: 'skipped'
      });
      return;
    }

    // All upstream done and either all succeeded or runOnUpstreamFailure is true
    runAgent(automationId, agent.id);
  });
}
```

- [ ] **Step 2: Add cycle detection function**

```javascript
function hasCyclicDependencies(agents) {
  // Build adjacency list: agent -> agents that depend on it
  const visited = new Set();
  const inStack = new Set();

  function dfs(agentId) {
    if (inStack.has(agentId)) return true; // Cycle found
    if (visited.has(agentId)) return false;
    visited.add(agentId);
    inStack.add(agentId);

    const agent = agents.find(ag => ag.id === agentId);
    if (agent && agent.runAfter) {
      for (const upstreamId of agent.runAfter) {
        if (dfs(upstreamId)) return true;
      }
    }

    inStack.delete(agentId);
    return false;
  }

  for (const agent of agents) {
    if (dfs(agent.id)) return true;
  }
  return false;
}
```

- [ ] **Step 3: Add cycle validation IPC handler**

```javascript
ipcMain.handle('automations:validateDependencies', (event, agents) => {
  if (hasCyclicDependencies(agents)) {
    return { valid: false, error: 'Circular dependency detected in agent run-after chain' };
  }
  return { valid: true };
});
```

- [ ] **Step 4: Commit**

```bash
git add main.js
git commit -m "feat: add dependency resolution with cascade and cycle detection"
```

---

### Task 9: Automations scheduler (replace loop scheduler)

**Files:**
- Modify: `main.js:1543-1607` (replace `startLoopScheduler` and `stopLoopScheduler`)

The scheduler now iterates automations and their agents. Independent agents use the same schedule logic as before. `run_after` agents are triggered by completions, not the scheduler.

- [ ] **Step 1: Add shouldRunAgent function**

Before the existing `shouldRunLoop` function, add:

```javascript
function shouldRunAgent(agent, now) {
  if (!agent.enabled) return false;
  if (agent.currentRunStartedAt) return false;
  if (agent.runMode === 'run_after') return false; // Only triggered by upstream completion
  if (agent.schedule.type === 'app_startup') return false;
  if (agent.schedule.type === 'manual') return false;

  if (agent.schedule.type === 'interval') {
    if (!agent.lastRunAt) return true;
    const elapsed = now - new Date(agent.lastRunAt).getTime();
    return elapsed >= agent.schedule.minutes * 60000;
  }

  if (agent.schedule.type === 'time_of_day') {
    const date = new Date(now);
    const dayNames = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
    const today = dayNames[date.getDay()];
    if (agent.schedule.days && agent.schedule.days.indexOf(today) === -1) return false;
    const nowMinutes = date.getHours() * 60 + date.getMinutes();
    const times = agent.schedule.times || [{ hour: agent.schedule.hour, minute: agent.schedule.minute || 0 }];
    const lastRun = agent.lastRunAt ? new Date(agent.lastRunAt) : null;

    for (const t of times) {
      const schedMinutes = t.hour * 60 + (t.minute || 0);
      if (nowMinutes < schedMinutes) continue;
      if (lastRun && lastRun.toDateString() === date.toDateString()) {
        const lastRunMinutes = lastRun.getHours() * 60 + lastRun.getMinutes();
        if (lastRunMinutes >= schedMinutes) continue;
      }
      return true;
    }
    return false;
  }
  return false;
}
```

- [ ] **Step 2: Replace startLoopScheduler with startAutomationScheduler**

Replace the `startLoopScheduler()` function (lines 1543-1585) with:

```javascript
function startAutomationScheduler() {
  // Startup recovery: clear stale "running" states
  const data = readAutomations();
  let changed = false;
  data.automations.forEach(automation => {
    automation.agents.forEach(agent => {
      if (agent.currentRunStartedAt) {
        agent.currentRunStartedAt = null;
        agent.lastRunStatus = 'interrupted';
        agent.lastError = 'App closed during run';
        changed = true;
      }
    });
  });
  if (changed) writeAutomations(data);

  // Also clean up legacy loop states
  if (fs.existsSync(LOOPS_FILE)) {
    try {
      const loopData = JSON.parse(fs.readFileSync(LOOPS_FILE, 'utf8'));
      let loopChanged = false;
      (loopData.loops || []).forEach(loop => {
        if (loop.currentRunStartedAt) {
          loop.currentRunStartedAt = null;
          loop.lastRunStatus = 'interrupted';
          loopChanged = true;
        }
      });
      if (loopChanged) fs.writeFileSync(LOOPS_FILE, JSON.stringify(loopData, null, 2), 'utf8');
    } catch { /* ignore */ }
  }

  // Run agents scheduled as app_startup
  setTimeout(() => {
    const startupData = readAutomations();
    if (!startupData.globalEnabled) return;
    const todayStr = new Date().toDateString();
    startupData.automations.forEach(automation => {
      if (!automation.enabled) return;
      automation.agents.forEach(agent => {
        if (!agent.enabled) return;
        if (agent.runMode === 'run_after') return;
        if (!agent.schedule || agent.schedule.type !== 'app_startup') return;

        if (agent.firstStartOnly && agent.lastRunAt) {
          const lastRunDate = new Date(agent.lastRunAt).toDateString();
          if (lastRunDate === todayStr) return;
        }
        runAgent(automation.id, agent.id);
      });
    });
  }, 5000);

  // Check every 30 seconds
  loopSchedulerTimer = setInterval(() => {
    const autoData = readAutomations();
    if (!autoData.globalEnabled) return;
    const now = Date.now();
    autoData.automations.forEach(automation => {
      if (!automation.enabled) return;
      automation.agents.forEach(agent => {
        if (shouldRunAgent(agent, now)) {
          runAgent(automation.id, agent.id);
        }
      });
    });
  }, 30000);
}
```

- [ ] **Step 3: Replace stopLoopScheduler with stopAutomationScheduler**

Replace the `stopLoopScheduler()` function (lines 1587-1607) with:

```javascript
function stopAutomationScheduler() {
  if (loopSchedulerTimer) {
    clearInterval(loopSchedulerTimer);
    loopSchedulerTimer = null;
  }

  // Kill running agents
  runningAgents.forEach((child) => {
    try { child.kill(); } catch { /* ignore */ }
  });
  runningAgents.clear();

  // Kill running loops (legacy)
  runningLoops.forEach((child) => {
    try { child.kill(); } catch { /* ignore */ }
  });
  runningLoops.clear();

  // Mark all running agents as interrupted
  const data = readAutomations();
  let changed = false;
  data.automations.forEach(automation => {
    automation.agents.forEach(agent => {
      if (agent.currentRunStartedAt) {
        agent.currentRunStartedAt = null;
        agent.lastRunStatus = 'interrupted';
        agent.lastError = 'App closed during run';
        changed = true;
      }
    });
  });
  if (changed) writeAutomations(data);
}
```

- [ ] **Step 4: Update call sites**

Find all calls to `startLoopScheduler()` in main.js and replace with `startAutomationScheduler()`. Find all calls to `stopLoopScheduler()` and replace with `stopAutomationScheduler()`.

Search for these in main.js — there should be one `startLoopScheduler()` in the `app.whenReady()` block and one `stopLoopScheduler()` in the `before-quit` handler.

- [ ] **Step 5: Verify syntax**

Run: `node -c main.js`
Expected: no output (syntax OK)

- [ ] **Step 6: Commit**

```bash
git add main.js
git commit -m "feat: replace loop scheduler with automations scheduler"
```

---

## Phase 4: Preload API Bridge

### Task 10: Update preload.js with automations API

**Files:**
- Modify: `preload.js:69-87` (replace loops section with automations)

Keep the old loops API methods intact (legacy support) and add the new automations API.

- [ ] **Step 1: Add automations API methods**

After the existing loops section (line 86), add:

```javascript

  // Automations
  getAutomations: () => ipcRenderer.invoke('automations:getAll'),
  getAutomationsForProject: (projectPath) => ipcRenderer.invoke('automations:getForProject', projectPath),
  createAutomation: (config) => ipcRenderer.invoke('automations:create', config),
  updateAutomation: (automationId, updates) => ipcRenderer.invoke('automations:update', automationId, updates),
  deleteAutomation: (automationId) => ipcRenderer.invoke('automations:delete', automationId),
  updateAgent: (automationId, agentId, updates) => ipcRenderer.invoke('automations:updateAgent', automationId, agentId, updates),
  addAgent: (automationId, agentConfig) => ipcRenderer.invoke('automations:addAgent', automationId, agentConfig),
  removeAgent: (automationId, agentId) => ipcRenderer.invoke('automations:removeAgent', automationId, agentId),
  toggleAutomation: (automationId) => ipcRenderer.invoke('automations:toggle', automationId),
  toggleAgent: (automationId, agentId) => ipcRenderer.invoke('automations:toggleAgent', automationId, agentId),
  toggleAutomationsGlobal: () => ipcRenderer.invoke('automations:toggleGlobal'),
  runAgentNow: (automationId, agentId) => ipcRenderer.invoke('automations:runAgentNow', automationId, agentId),
  runAutomationNow: (automationId) => ipcRenderer.invoke('automations:runAutomationNow', automationId),
  getAgentHistory: (automationId, agentId, count) => ipcRenderer.invoke('automations:getAgentHistory', automationId, agentId, count),
  getAgentRunDetail: (automationId, agentId, startedAt) => ipcRenderer.invoke('automations:getAgentRunDetail', automationId, agentId, startedAt),
  getAgentLiveOutput: (automationId, agentId) => ipcRenderer.invoke('automations:getAgentLiveOutput', automationId, agentId),
  setupAgentClone: (automationId, agentId) => ipcRenderer.invoke('automations:setupAgentClone', automationId, agentId),
  getCloneStatus: (automationId) => ipcRenderer.invoke('automations:getCloneStatus', automationId),
  validateDependencies: (agents) => ipcRenderer.invoke('automations:validateDependencies', agents),
  exportAutomations: (projectPath) => ipcRenderer.invoke('automations:export', projectPath),
  exportAutomation: (automationId) => ipcRenderer.invoke('automations:exportOne', automationId),
  importAutomations: (projectPath) => ipcRenderer.invoke('automations:import', projectPath),
  onAgentStarted: (callback) => ipcRenderer.on('automations:agent-started', (_, data) => callback(data)),
  onAgentCompleted: (callback) => ipcRenderer.on('automations:agent-completed', (_, data) => callback(data)),
  onAgentOutput: (callback) => ipcRenderer.on('automations:agent-output', (_, data) => callback(data)),
  onCloneProgress: (callback) => ipcRenderer.on('automations:clone-progress', (_, data) => callback(data)),
```

- [ ] **Step 2: Verify syntax**

Run: `node -c preload.js`
Expected: no output (syntax OK)

- [ ] **Step 3: Commit**

```bash
git add preload.js
git commit -m "feat: add automations preload API bridge"
```

---

## Phase 5: UI Rename (Loops -> Automations)

### Task 11: Rename HTML elements

**Files:**
- Modify: `index.html`

Rename all "Loops" / "Loop" text and IDs to "Automations" / "Automation" in the HTML. This affects the tab label, headers, button titles, flyout header, and placeholder text.

- [ ] **Step 1: Rename the tab label and section header**

In `index.html:88-104`, change:
- `<div id="tab-loops"` stays as `id="tab-loops"` (rename later with CSS/JS, or rename now — prefer renaming for consistency)

Actually, to minimize breakage during the transition, rename IDs in a coordinated way. Change:

- Line 88: `id="tab-loops"` → `id="tab-automations"`
- Line 90: `<span>LOOPS</span>` → `<span>AUTOMATIONS</span>`
- Line 92: `id="btn-add-loop"` → `id="btn-add-automation"`, title `"New Loop"` → `"New Automation"`
- Line 93: `id="btn-import-loops"` → `id="btn-import-automations"`, title `"Import Loops"` → `"Import Automations"`
- Line 94: `id="btn-export-loops"` → `id="btn-export-automations"`, title `"Export All Loops"` → `"Export All"`
- Line 95: `id="btn-refresh-loops"` → `id="btn-refresh-automations"`
- Line 98-100: `id="loops-search-bar"` → `id="automations-search-bar"`, `id="loops-search-input"` → `id="automations-search-input"`, placeholder `"Search loops..."` → `"Search automations..."`
- Line 101: `id="loops-no-project"` → `id="automations-no-project"`, text `"Select a project to see its loops"` → `"Select a project to see its automations"`
- Line 104: `id="loops-list"` → `id="automations-list"`
- Lines 105-123: All `loop-detail-*` IDs → `automation-detail-*` IDs, `loop-status-badge` → `automation-status-badge`

- [ ] **Step 2: Rename the detail panel IDs**

- Line 105: `id="loop-detail-panel"` → `id="automation-detail-panel"`, class `"loop-detail-panel"` → `"automation-detail-panel"`
- Line 107: `id="btn-loop-detail-back"` → `id="btn-automation-detail-back"`, class `"loop-detail-back"` → `"automation-detail-back"`
- Line 108: `id="loop-detail-name"` → `id="automation-detail-name"`, class `"loop-detail-name"` → `"automation-detail-name"`
- Line 109: `id="loop-detail-status-badge"` → `id="automation-detail-status-badge"`, class `"loop-status-badge"` → `"automation-status-badge"`
- Line 111: class `"loop-detail-meta"` → `"automation-detail-meta"`, `id="loop-detail-meta"` → `id="automation-detail-meta"`
- Line 112: `id="loop-detail-summary"` → `id="automation-detail-summary"`, class `"loop-detail-summary"` → `"automation-detail-summary"`
- Line 113: `id="loop-detail-attention"` → `id="automation-detail-attention"`, class `"loop-detail-attention"` → `"automation-detail-attention"`
- Line 114: class `"loop-detail-output-header"` → `"automation-detail-output-header"`
- Line 117: `id="btn-loop-open-claude"` → `id="btn-automation-open-claude"`, class `"loop-detail-icon-btn"` → `"automation-detail-icon-btn"`
- Line 118: `id="btn-loop-copy-output"` → `id="btn-automation-copy-output"`, class `"loop-detail-icon-btn"` → `"automation-detail-icon-btn"`
- Line 119: `id="loop-detail-run-select"` → `id="automation-detail-run-select"`, class `"loop-detail-run-select"` → `"automation-detail-run-select"`
- Line 122: `id="loop-detail-output"` → `id="automation-detail-output"`, class `"loop-detail-output"` → `"automation-detail-output"`

- [ ] **Step 3: Rename flyout IDs**

- Line 137: `id="btn-loops-flyout"` → `id="btn-automations-flyout"`, title `"Loop Manager"` → `"Automations"`
- Line 198: `id="loops-flyout"` → `id="automations-flyout"`, class `"loops-flyout"` → `"automations-flyout"`
- Line 199: class `"loops-flyout-header"` → `"automations-flyout-header"`
- Line 200: class `"loops-flyout-title"` → `"automations-flyout-title"`
- Line 201: `<span>Loop Manager</span>` → `<span>Automations</span>`
- Line 202: `id="loops-flyout-counts"` → `id="automations-flyout-counts"`, class `"loops-flyout-counts"` → `"automations-flyout-counts"`
- Line 205: `id="btn-loops-global-toggle"` → `id="btn-automations-global-toggle"`, class `"loops-global-toggle"` → `"automations-global-toggle"`, title `"Pause/Resume all loops"` → `"Pause/Resume all automations"`
- Line 206: `id="btn-loops-flyout-close"` → `id="btn-automations-flyout-close"`, class `"loops-flyout-close"` → `"automations-flyout-close"`
- Line 209: `id="loops-flyout-list"` → `id="automations-flyout-list"`, class `"loops-flyout-list"` → `"automations-flyout-list"`

- [ ] **Step 4: Rename the explorer tab data attribute**

Find the tab button that references `data-tab="loops"` (line 21 area in HTML — search for it):

```html
<button class="explorer-tab" data-tab="loops">Loops</button>
```

Change to:

```html
<button class="explorer-tab" data-tab="automations">Automations</button>
```

- [ ] **Step 5: Commit**

```bash
git add index.html
git commit -m "refactor: rename loops to automations in HTML"
```

---

### Task 12: Rename modal HTML and add multi-agent structure

**Files:**
- Modify: `index.html:339-432` (the loop modal)

Rename IDs and add the structural elements for multi-agent mode.

- [ ] **Step 1: Replace the modal HTML**

Replace the entire modal block (`index.html:339-432`) with:

```html
    <div id="automation-modal-overlay" class="modal-overlay hidden">
      <div class="modal-dialog automation-modal">
        <div class="modal-header">
          <span class="modal-title" id="automation-modal-title">New Automation</span>
          <button class="modal-close" id="btn-automation-modal-close">&times;</button>
        </div>
        <div class="modal-body automation-modal-body">
          <!-- Automation-level name (shown in multi-agent mode) -->
          <div id="automation-name-group" class="automation-form-group" style="display:none;">
            <label for="automation-name">Automation Name</label>
            <input type="text" id="automation-name" class="automation-input" placeholder="e.g. TaskBoard Pipeline" spellcheck="false">
          </div>

          <!-- Agent cards container -->
          <div id="automation-agents-list"></div>

          <!-- Add Agent link -->
          <div id="automation-add-agent-row" class="automation-add-agent-row">
            <button type="button" id="btn-add-agent" class="automation-add-agent-btn">+ Add Agent</button>
          </div>

          <!-- Clone setup progress (Stage 3) -->
          <div id="automation-setup-panel" class="automation-setup-panel" style="display:none;">
            <div class="automation-setup-header">Setting up agent repositories...</div>
            <div id="automation-setup-agents" class="automation-setup-agents"></div>
            <pre id="automation-setup-log" class="automation-setup-log"></pre>
          </div>
        </div>
        <div class="modal-footer">
          <button id="btn-automation-save" class="modal-btn-save">Create Automation</button>
          <button id="btn-automation-cancel" class="modal-btn-save">Cancel</button>
        </div>
      </div>
    </div>
```

- [ ] **Step 2: Commit**

```bash
git add index.html
git commit -m "refactor: replace loop modal with automation modal structure"
```

---

### Task 13: Add agentReposBaseDir to settings modal

**Files:**
- Modify: `index.html:220-243` (settings modal body)

- [ ] **Step 1: Add the Automations settings section**

After the Notifications section (before the closing `</div>` of `modal-body`), add:

```html
        <div class="settings-section">
          <h3 class="settings-section-title">Automations</h3>
          <div class="settings-field">
            <label for="setting-agent-repos-dir">Agent repos directory</label>
            <div class="settings-path-row">
              <input type="text" id="setting-agent-repos-dir" class="settings-input" placeholder="~/.claudes/agents/" spellcheck="false">
              <button id="btn-browse-agent-repos" class="settings-browse-btn" title="Browse...">...</button>
            </div>
            <span class="settings-hint">Base directory for isolated agent repository clones</span>
          </div>
        </div>
```

- [ ] **Step 2: Add IPC handler for reading/writing the setting**

In `main.js`, add handlers:

```javascript
ipcMain.handle('automations:getSettings', () => {
  const data = readAutomations();
  return {
    agentReposBaseDir: data.agentReposBaseDir || path.join(os.homedir(), '.claudes', 'agents')
  };
});

ipcMain.handle('automations:updateSettings', (event, settings) => {
  const data = readAutomations();
  if (settings.agentReposBaseDir !== undefined) {
    data.agentReposBaseDir = settings.agentReposBaseDir;
  }
  writeAutomations(data);
  return true;
});
```

- [ ] **Step 3: Add preload methods**

In `preload.js`, add within the automations section:

```javascript
  getAutomationSettings: () => ipcRenderer.invoke('automations:getSettings'),
  updateAutomationSettings: (settings) => ipcRenderer.invoke('automations:updateSettings', settings),
```

- [ ] **Step 4: Add renderer logic for the setting**

In `renderer.js`, in the settings modal open handler, add logic to load and save the agent repos directory. Find where the settings modal is opened (search for `btn-settings`) and add:

```javascript
// Load agent repos dir setting
window.electronAPI.getAutomationSettings().then(function (settings) {
  document.getElementById('setting-agent-repos-dir').value = settings.agentReposBaseDir || '';
});
```

Add browse button handler:

```javascript
document.getElementById('btn-browse-agent-repos').addEventListener('click', function () {
  window.electronAPI.openDirectoryDialog().then(function (result) {
    if (result) {
      document.getElementById('setting-agent-repos-dir').value = result;
      window.electronAPI.updateAutomationSettings({ agentReposBaseDir: result });
    }
  });
});

document.getElementById('setting-agent-repos-dir').addEventListener('change', function () {
  window.electronAPI.updateAutomationSettings({ agentReposBaseDir: this.value.trim() });
});
```

- [ ] **Step 5: Commit**

```bash
git add index.html main.js preload.js renderer.js
git commit -m "feat: add agent repos directory setting"
```

---

## Phase 6: Renderer — Core Automations UI

### Task 14: Rename renderer variables and core functions

**Files:**
- Modify: `renderer.js` (global rename of loop references to automation)

This is a large mechanical rename. The key variables and functions to rename:

| Old | New |
|-----|-----|
| `loopsForProject` | `automationsForProject` |
| `activeLoopDetailId` | `activeAutomationDetailId` / `activeAgentDetailId` |
| `loopDetailViewingLive` | `agentDetailViewingLive` |
| `refreshLoops()` | `refreshAutomations()` |
| `renderLoopCards()` | `renderAutomationCards()` |
| `formatLoopScheduleText()` | `formatScheduleText()` |
| `getNextScheduledTime()` | `getNextScheduledTime()` (keep name) |
| `openLoopDetail()` | `openAutomationDetail()` |
| `closeLoopDetail()` | `closeAutomationDetail()` |
| `openLoopModal()` | `openAutomationModal()` |
| `closeLoopModal()` | `closeAutomationModal()` |
| `saveLoop()` | `saveAutomation()` |
| `toggleLoopsFlyout()` | `toggleAutomationsFlyout()` |
| `refreshLoopsFlyout()` | `refreshAutomationsFlyout()` |
| `updateLoopsTabIndicator()` | `updateAutomationsTabIndicator()` |
| `updateLoopSidebarBadges()` | `updateAutomationSidebarBadges()` |
| `allLoopsData` | `allAutomationsData` |

- [ ] **Step 1: Rename the global variables**

Find and replace these variable declarations in renderer.js:
- `var loopsForProject` → `var automationsForProject`
- `var activeLoopDetailId` → `var activeAutomationDetailId`
- `var loopDetailViewingLive` → `var agentDetailViewingLive`
- `var allLoopsData` → `var allAutomationsData`
- `var loopEditingId` → `var automationEditingId`
- `var loopModalTimes` → `var automationModalTimes`

And all references to these throughout renderer.js.

**Important:** This is a large find-and-replace operation. Do it carefully, function by function. Each old `getElementById('loop-*')` call must change to use the new `'automation-*'` IDs. Each old `window.electronAPI.getLoops*()` call must change to the new `window.electronAPI.getAutomations*()` methods.

Given the size, break this into sub-steps:
1. Global variable renames
2. Function renames
3. Element ID references
4. API call updates
5. Event listener updates

- [ ] **Step 2: Rename functions**

Apply these function renames throughout renderer.js:
- `function refreshLoops()` → `function refreshAutomations()`
- `function renderLoopCards()` → `function renderAutomationCards()`
- `function formatLoopScheduleText()` → `function formatScheduleText()`
- `function openLoopDetail()` → `function openAutomationDetail()`
- `function switchToLiveView()` → `function switchToAgentLiveView()`
- `function switchToRunView()` → `function switchToAgentRunView()`
- `function showRunSummary()` → `function showAgentRunSummary()`
- `function closeLoopDetail()` → `function closeAutomationDetail()`
- `function openLoopModal()` → `function openAutomationModal()`
- `function closeLoopModal()` → `function closeAutomationModal()`
- `function saveLoop()` → `function saveAutomation()`
- `function addLoopTime()` → `function addAgentTime()`
- `function removeLoopTime()` → `function removeAgentTime()`
- `function renderLoopTimeChips()` → `function renderAgentTimeChips()`
- `function toggleScheduleFields()` → `function toggleAgentScheduleFields()`
- `function toggleLoopsFlyout()` → `function toggleAutomationsFlyout()`
- `function refreshLoopsFlyout()` → `function refreshAutomationsFlyout()`
- `function updateLoopsTabIndicator()` → `function updateAutomationsTabIndicator()`
- `function updateLoopSidebarBadges()` → `function updateAutomationSidebarBadges()`
- `function toggleLoopPromptFind()` → `function togglePromptFind()`
- `function searchLoopPrompt()` → `function searchPrompt()`
- `function highlightLoopPromptMatch()` → `function highlightPromptMatch()`
- `function loopPromptFindNext()` → `function promptFindNext()`
- `function loopPromptFindPrev()` → `function promptFindPrev()`

Also rename all call sites of these functions.

- [ ] **Step 3: Update all getElementById calls**

Replace all `getElementById('loop-*')` with corresponding `getElementById('automation-*')` references. Replace all `getElementById('loops-*')` with `getElementById('automations-*')`.

Replace all `getElementById('btn-loop-*')` with `getElementById('btn-automation-*')`.
Replace all `getElementById('btn-loops-*')` with `getElementById('btn-automations-*')`.

- [ ] **Step 4: Update all electronAPI calls**

Replace:
- `window.electronAPI.getLoopsForProject(` → `window.electronAPI.getAutomationsForProject(`
- `window.electronAPI.getLoops()` → `window.electronAPI.getAutomations()`
- `window.electronAPI.createLoop(` → `window.electronAPI.createAutomation(`
- `window.electronAPI.updateLoop(` → `window.electronAPI.updateAutomation(` (note: this needs logic changes too — handled in Task 16)
- `window.electronAPI.deleteLoop(` → `window.electronAPI.deleteAutomation(`
- `window.electronAPI.toggleLoop(` → `window.electronAPI.toggleAutomation(`
- `window.electronAPI.toggleLoopsGlobal()` → `window.electronAPI.toggleAutomationsGlobal()`
- `window.electronAPI.runLoopNow(` → handled later (needs automationId + agentId)
- `window.electronAPI.getLoopHistory(` → handled later (needs automationId + agentId)
- `window.electronAPI.getLoopRunDetail(` → handled later
- `window.electronAPI.getLoopLiveOutput(` → handled later
- `window.electronAPI.exportLoops(` → `window.electronAPI.exportAutomations(`
- `window.electronAPI.exportLoop(` → `window.electronAPI.exportAutomation(`
- `window.electronAPI.importLoops(` → `window.electronAPI.importAutomations(`

- [ ] **Step 5: Update event listeners**

Replace:
- `window.electronAPI.onLoopRunStarted(` → `window.electronAPI.onAgentStarted(`
- `window.electronAPI.onLoopRunCompleted(` → `window.electronAPI.onAgentCompleted(`
- `window.electronAPI.onLoopOutput(` → `window.electronAPI.onAgentOutput(`

Update the callback parameters — the new events send `{automationId, agentId}` instead of `{loopId}`.

- [ ] **Step 6: Update CSS class references in renderer.js**

Replace all CSS class names generated in JavaScript:
- `loop-card` → `automation-card`
- `loop-idle` → `automation-idle`
- `loop-running` → `automation-running`
- `loop-error` → `automation-error`
- `loop-disabled` → `automation-disabled`
- `loop-card-*` → `automation-card-*`
- `loop-btn-*` → `automation-btn-*`
- `loop-status-badge` → `automation-status-badge`
- `loop-section-*` → `automation-section-*`
- `loops-flyout-*` → `automations-flyout-*`
- `loop-attention-item` → `automation-attention-item`
- `loop-processing-indicator` → `automation-processing-indicator`
- `project-loop-badge` → `project-automation-badge`
- `has-running` and `has-loops` → `has-running` and `has-automations`

- [ ] **Step 7: Update tab data attribute reference**

Find `data-tab="loops"` in renderer.js and change to `data-tab="automations"`.

- [ ] **Step 8: Verify no broken references**

Search renderer.js for any remaining `loop` or `Loop` references (case-sensitive) and fix them. Some legitimate uses (like the word "loop" inside prompt text or comments) can stay.

Run: `node -c renderer.js`
Expected: no output (syntax OK)

- [ ] **Step 9: Commit**

```bash
git add renderer.js
git commit -m "refactor: rename all loop references to automations in renderer"
```

---

### Task 15: Rename CSS classes

**Files:**
- Modify: `styles.css:3373-4191` (loops styling section)

Bulk rename all `loop-*` and `loops-*` CSS classes to `automation-*` and `automations-*`.

- [ ] **Step 1: Rename all CSS selectors**

In the loops section of styles.css (lines 3373-4191), do a global find-and-replace:
- `#loops-` → `#automations-`
- `.loops-` → `.automations-`
- `.loop-` → `.automation-`
- `#loop-` → `#automation-`
- `#btn-loops-` → `#btn-automations-`
- `#btn-loop-` → `#btn-automation-`
- `@keyframes loop-` → `@keyframes automation-`

Also rename the comment headers:
- `/* Loops */` → `/* Automations */`

- [ ] **Step 2: Verify the CSS parses correctly**

Open the app and check that the Automations tab renders with correct styles. No broken layout or missing colors.

- [ ] **Step 3: Commit**

```bash
git add styles.css
git commit -m "refactor: rename all loop CSS classes to automation"
```

---

## Phase 7: Multi-Agent Creation Modal

### Task 16: Implement the creation/edit modal with agent cards

**Files:**
- Modify: `renderer.js` (replace `openAutomationModal`, `saveAutomation`, and related functions)

The modal starts in simple mode (single agent, identical to old loop modal). Clicking "+ Add Agent" transforms it into multi-agent mode.

- [ ] **Step 1: Add agent card HTML template function**

Add this function in renderer.js (in the modal section):

```javascript
function createAgentCardHtml(agentIndex, agent, isCollapsed, allAgents) {
  var isMulti = allAgents.length > 1;
  var cardId = 'agent-card-' + agentIndex;
  var name = agent ? agent.name : '';
  var prompt = agent ? agent.prompt : '';
  var schedType = agent && agent.schedule ? agent.schedule.type : 'interval';
  var runMode = agent ? (agent.runMode || 'independent') : 'independent';

  var header = '';
  if (isMulti) {
    var badges = '';
    if (runMode === 'run_after') badges += '<span class="agent-badge agent-badge-chained">Chained</span>';
    if (agent && agent.isolation && agent.isolation.enabled) badges += '<span class="agent-badge agent-badge-isolated">Isolated</span>';
    var schedSummary = agent ? formatScheduleText(agent) : '';

    header = '<div class="agent-card-header" data-agent-index="' + agentIndex + '">' +
      '<span class="agent-card-collapse-icon">' + (isCollapsed ? '&#9654;' : '&#9660;') + '</span>' +
      '<span class="agent-card-title">' + escapeHtml(name || 'Agent ' + (agentIndex + 1)) + '</span>' +
      badges +
      (schedSummary ? '<span class="agent-card-schedule-summary">' + schedSummary + '</span>' : '') +
      '<button type="button" class="agent-card-remove" data-agent-index="' + agentIndex + '" title="Remove agent">&times;</button>' +
      '</div>';
  }

  var runAfterHtml = '';
  if (isMulti) {
    // Build multi-select chips for runAfter
    var otherAgents = allAgents.filter(function (_, i) { return i !== agentIndex; });
    var chipOptions = otherAgents.map(function (ag, i) {
      var originalIndex = allAgents.indexOf(ag);
      var selected = agent && agent.runAfter && agent.runAfter.indexOf(ag.id || ('temp_' + originalIndex)) !== -1;
      return '<label class="agent-runafter-chip' + (selected ? ' selected' : '') + '">' +
        '<input type="checkbox" value="' + originalIndex + '"' + (selected ? ' checked' : '') + '> ' +
        escapeHtml(ag.name || 'Agent ' + (originalIndex + 1)) +
        '</label>';
    }).join('');

    runAfterHtml = '<div class="automation-form-group agent-runafter-group" style="' + (runMode === 'run_after' ? '' : 'display:none;') + '">' +
      '<label>Run after</label>' +
      '<div class="agent-runafter-chips">' + chipOptions + '</div>' +
      '</div>';
  }

  var isolationHtml = '';
  if (isMulti) {
    var isolationEnabled = agent && agent.isolation && agent.isolation.enabled;
    var clonePath = '';
    if (isolationEnabled) {
      // Predict the clone path
      clonePath = agent.isolation.clonePath || '(will be set during setup)';
    }
    isolationHtml = '<div class="automation-form-group">' +
      '<label class="automation-permission-option">' +
      '<input type="checkbox" class="agent-isolation-checkbox"' + (isolationEnabled ? ' checked' : '') + '>' +
      '<span>Repo isolation <span class="automation-permission-hint">(clone into separate directory)</span></span>' +
      '</label>' +
      '<div class="agent-isolation-path" style="' + (isolationEnabled ? '' : 'display:none;') + '">' +
      '<span class="automation-permission-hint">Clone path: ' + escapeHtml(clonePath) + '</span>' +
      '</div>' +
      '</div>';
  }

  var scheduleDisplay = runMode === 'run_after' ? 'display:none;' : '';

  var bodyStyle = isCollapsed ? 'display:none;' : '';

  var html = '<div class="agent-card" id="' + cardId + '" data-agent-index="' + agentIndex + '">' +
    header +
    '<div class="agent-card-body" style="' + bodyStyle + '">' +
      '<div class="automation-form-group">' +
        '<label>Name</label>' +
        '<input type="text" class="automation-input agent-name" value="' + escapeHtml(name) + '" placeholder="e.g. Bug Resolution Agent" spellcheck="false">' +
      '</div>' +
      '<div class="automation-form-group">' +
        '<label>Prompt</label>' +
        '<textarea class="automation-textarea agent-prompt" rows="6" placeholder="What should Claude do each time this runs?" spellcheck="false">' + escapeHtml(prompt) + '</textarea>' +
      '</div>' +
      (isMulti ? '<div class="automation-form-group">' +
        '<label>Run Mode</label>' +
        '<select class="agent-run-mode">' +
          '<option value="independent"' + (runMode === 'independent' ? ' selected' : '') + '>Independent (own schedule)</option>' +
          '<option value="run_after"' + (runMode === 'run_after' ? ' selected' : '') + '>Run after (wait for other agents)</option>' +
        '</select>' +
      '</div>' : '') +
      runAfterHtml +
      isolationHtml +
      '<div class="agent-schedule-section" style="' + scheduleDisplay + '">' +
        '<div class="automation-form-group">' +
          '<label>Schedule</label>' +
          '<div class="automation-schedule-row">' +
            '<select class="agent-schedule-type">' +
              '<option value="manual"' + (schedType === 'manual' ? ' selected' : '') + '>Manual</option>' +
              '<option value="interval"' + (schedType === 'interval' ? ' selected' : '') + '>Every</option>' +
              '<option value="time_of_day"' + (schedType === 'time_of_day' ? ' selected' : '') + '>At specific times</option>' +
              '<option value="app_startup"' + (schedType === 'app_startup' ? ' selected' : '') + '>On app startup</option>' +
            '</select>' +
            buildScheduleFieldsHtml(agent, schedType) +
          '</div>' +
        '</div>' +
      '</div>' +
      '<div class="automation-form-group">' +
        '<label>Database <span class="automation-permission-hint">(optional)</span></label>' +
        '<input type="password" class="automation-input agent-db-connection" value="' + escapeHtml(agent && agent.dbConnectionString ? agent.dbConnectionString : '') + '" placeholder="mongodb+srv://..." spellcheck="false" autocomplete="off">' +
        '<div class="automation-permissions" style="margin-top:6px;">' +
          '<label class="automation-permission-option"><input type="checkbox" class="agent-db-readonly"' + (agent && agent.dbReadOnly === false ? '' : ' checked') + '><span>Read-only</span></label>' +
        '</div>' +
      '</div>' +
      '<div class="automation-form-group">' +
        '<label>Permissions</label>' +
        '<div class="automation-permissions">' +
          '<label class="automation-permission-option"><input type="checkbox" class="agent-skip-permissions"' + (agent && agent.skipPermissions ? ' checked' : '') + '><span>Skip permissions</span></label>' +
        '</div>' +
      '</div>' +
    '</div>' +
    '</div>';

  return html;
}
```

- [ ] **Step 2: Add buildScheduleFieldsHtml helper**

```javascript
function buildScheduleFieldsHtml(agent, schedType) {
  var intervalMins = agent && agent.schedule && agent.schedule.minutes ? agent.schedule.minutes : 60;
  var intervalVal = intervalMins >= 60 && intervalMins % 60 === 0 ? intervalMins / 60 : intervalMins;
  var intervalUnit = intervalMins >= 60 && intervalMins % 60 === 0 ? 'hours' : 'minutes';

  var html = '<div class="agent-interval-fields" style="' + (schedType === 'interval' ? '' : 'display:none;') + '">' +
    '<input type="number" class="agent-interval-value" min="1" value="' + intervalVal + '" style="width:60px">' +
    '<select class="agent-interval-unit">' +
      '<option value="minutes"' + (intervalUnit === 'minutes' ? ' selected' : '') + '>minutes</option>' +
      '<option value="hours"' + (intervalUnit === 'hours' ? ' selected' : '') + '>hours</option>' +
    '</select>' +
    '</div>';

  var firstStartOnly = agent && agent.firstStartOnly;
  html += '<div class="agent-startup-fields" style="' + (schedType === 'app_startup' ? '' : 'display:none;') + '">' +
    '<label class="automation-permission-option" style="margin-top:4px;">' +
      '<input type="checkbox" class="agent-first-start-only"' + (firstStartOnly ? ' checked' : '') + '>' +
      '<span>Only on first start of the day</span>' +
    '</label>' +
    '</div>';

  html += '<div class="agent-tod-fields" style="' + (schedType === 'time_of_day' ? '' : 'display:none;') + '">' +
    '<div class="automation-time-add-row">' +
      '<input type="time" class="agent-tod-time" value="09:00">' +
      '<button type="button" class="agent-btn-add-time" title="Add time">+</button>' +
    '</div>' +
    '<div class="agent-tod-times-list automation-times-chips"></div>' +
    '<div class="automation-days-row agent-tod-days">';

  var days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  var checkedDays = agent && agent.schedule && agent.schedule.days ? agent.schedule.days : ['mon', 'tue', 'wed', 'thu', 'fri'];
  days.forEach(function (d) {
    var checked = checkedDays.indexOf(d) !== -1 ? ' checked' : '';
    html += '<label><input type="checkbox" value="' + d + '"' + checked + '> ' + d.charAt(0).toUpperCase() + d.slice(1) + '</label>';
  });
  html += '</div></div>';

  return html;
}
```

- [ ] **Step 3: Rewrite openAutomationModal**

Replace the `openAutomationModal()` function with:

```javascript
var modalAgents = []; // Tracks agent data for the modal

function openAutomationModal(existingAutomation) {
  automationEditingId = existingAutomation ? existingAutomation.id : null;
  var title = existingAutomation ? 'Edit Automation' : 'New Automation';
  document.getElementById('automation-modal-title').textContent = title;
  document.getElementById('btn-automation-save').textContent = existingAutomation ? 'Save Changes' : 'Create Automation';

  // Hide setup panel, show form
  document.getElementById('automation-setup-panel').style.display = 'none';

  if (existingAutomation) {
    modalAgents = existingAutomation.agents.map(function (ag) { return Object.assign({}, ag); });
  } else {
    // Start with one empty agent
    modalAgents = [{ name: '', prompt: '', schedule: { type: 'interval', minutes: 60 }, runMode: 'independent', runAfter: [], isolation: { enabled: false, clonePath: null }, skipPermissions: false, dbConnectionString: null, dbReadOnly: true, firstStartOnly: false }];
  }

  var isMulti = modalAgents.length > 1;
  document.getElementById('automation-name-group').style.display = isMulti ? '' : 'none';
  document.getElementById('automation-name').value = existingAutomation ? existingAutomation.name : '';

  renderModalAgentCards();

  document.getElementById('automation-modal-overlay').classList.remove('hidden');
  // Focus first agent name
  var firstNameInput = document.querySelector('.agent-name');
  if (firstNameInput) firstNameInput.focus();
}
```

- [ ] **Step 4: Add renderModalAgentCards function**

```javascript
function renderModalAgentCards() {
  var container = document.getElementById('automation-agents-list');
  var isMulti = modalAgents.length > 1;

  document.getElementById('automation-name-group').style.display = isMulti ? '' : 'none';

  container.innerHTML = '';
  modalAgents.forEach(function (agent, index) {
    var html = createAgentCardHtml(index, agent, false, modalAgents);
    container.innerHTML += html;
  });

  // Bind event handlers for each agent card
  container.querySelectorAll('.agent-card').forEach(function (card) {
    var idx = parseInt(card.dataset.agentIndex);
    bindAgentCardEvents(card, idx);
  });
}

function bindAgentCardEvents(card, agentIndex) {
  // Collapse toggle
  var header = card.querySelector('.agent-card-header');
  if (header) {
    header.addEventListener('click', function (e) {
      if (e.target.classList.contains('agent-card-remove')) return;
      var body = card.querySelector('.agent-card-body');
      var icon = card.querySelector('.agent-card-collapse-icon');
      if (body.style.display === 'none') {
        body.style.display = '';
        icon.innerHTML = '&#9660;';
      } else {
        // Save current values before collapsing
        syncAgentFromCard(card, agentIndex);
        body.style.display = 'none';
        icon.innerHTML = '&#9654;';
        // Update header title
        var title = header.querySelector('.agent-card-title');
        if (title) title.textContent = modalAgents[agentIndex].name || 'Agent ' + (agentIndex + 1);
      }
    });
  }

  // Remove button
  var removeBtn = card.querySelector('.agent-card-remove');
  if (removeBtn) {
    removeBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      if (modalAgents.length <= 1) { alert('Cannot remove the only agent.'); return; }

      // Check if other agents depend on this one
      var dependents = modalAgents.filter(function (ag, i) {
        return i !== agentIndex && ag.runAfter && ag.runAfter.some(function (id) {
          return id === (modalAgents[agentIndex].id || 'temp_' + agentIndex);
        });
      });
      if (dependents.length > 0) {
        var names = dependents.map(function (ag) { return ag.name || 'unnamed'; }).join(', ');
        if (!confirm('Agent "' + (modalAgents[agentIndex].name || 'unnamed') + '" is depended on by: ' + names + '. They will become independent. Continue?')) return;
      }

      syncAllAgentsFromCards();
      modalAgents.splice(agentIndex, 1);
      // Clean up runAfter references
      modalAgents.forEach(function (ag) {
        if (ag.runAfter) {
          ag.runAfter = ag.runAfter.filter(function (id) { return id !== ('temp_' + agentIndex); });
        }
      });
      renderModalAgentCards();
    });
  }

  // Run mode change
  var runModeSelect = card.querySelector('.agent-run-mode');
  if (runModeSelect) {
    runModeSelect.addEventListener('change', function () {
      var val = this.value;
      modalAgents[agentIndex].runMode = val;
      var runAfterGroup = card.querySelector('.agent-runafter-group');
      var schedSection = card.querySelector('.agent-schedule-section');
      if (runAfterGroup) runAfterGroup.style.display = val === 'run_after' ? '' : 'none';
      if (schedSection) schedSection.style.display = val === 'run_after' ? 'none' : '';
    });
  }

  // Schedule type change
  var schedSelect = card.querySelector('.agent-schedule-type');
  if (schedSelect) {
    schedSelect.addEventListener('change', function () {
      var type = this.value;
      var intervalFields = card.querySelector('.agent-interval-fields');
      var todFields = card.querySelector('.agent-tod-fields');
      var startupFields = card.querySelector('.agent-startup-fields');
      if (intervalFields) intervalFields.style.display = type === 'interval' ? '' : 'none';
      if (todFields) todFields.style.display = type === 'time_of_day' ? '' : 'none';
      if (startupFields) startupFields.style.display = type === 'app_startup' ? '' : 'none';
    });
  }

  // Isolation checkbox
  var isoCheckbox = card.querySelector('.agent-isolation-checkbox');
  if (isoCheckbox) {
    isoCheckbox.addEventListener('change', function () {
      var pathEl = card.querySelector('.agent-isolation-path');
      if (pathEl) pathEl.style.display = this.checked ? '' : 'none';
    });
  }

  // Time add button
  var addTimeBtn = card.querySelector('.agent-btn-add-time');
  if (addTimeBtn) {
    addTimeBtn.addEventListener('click', function () {
      var timeInput = card.querySelector('.agent-tod-time');
      if (!timeInput || !timeInput.value) return;
      var parts = timeInput.value.split(':');
      var h = parseInt(parts[0]);
      var m = parseInt(parts[1]);
      if (!modalAgents[agentIndex]._modalTimes) modalAgents[agentIndex]._modalTimes = [];
      var exists = modalAgents[agentIndex]._modalTimes.some(function (t) { return t.hour === h && t.minute === m; });
      if (exists) return;
      modalAgents[agentIndex]._modalTimes.push({ hour: h, minute: m });
      modalAgents[agentIndex]._modalTimes.sort(function (a, b) { return (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute); });
      renderAgentTimeChipsInCard(card, agentIndex);
    });
  }

  // Stop keyboard events from propagating
  card.querySelectorAll('input, textarea, select').forEach(function (el) {
    el.addEventListener('keydown', function (e) { e.stopPropagation(); });
  });

  // Initialize time chips if existing agent has times
  if (modalAgents[agentIndex].schedule && modalAgents[agentIndex].schedule.times) {
    modalAgents[agentIndex]._modalTimes = modalAgents[agentIndex].schedule.times.slice();
    renderAgentTimeChipsInCard(card, agentIndex);
  }
}

function renderAgentTimeChipsInCard(card, agentIndex) {
  var container = card.querySelector('.agent-tod-times-list');
  if (!container) return;
  var times = modalAgents[agentIndex]._modalTimes || [];
  container.innerHTML = '';
  if (times.length === 0) {
    container.innerHTML = '<span style="opacity:0.4;font-size:11px;">No times added yet</span>';
    return;
  }
  times.forEach(function (t, i) {
    var chip = document.createElement('span');
    chip.className = 'automation-time-chip';
    var label = (t.hour < 10 ? '0' : '') + t.hour + ':' + (t.minute < 10 ? '0' : '') + t.minute;
    chip.innerHTML = label + '<button type="button" class="automation-time-chip-remove" title="Remove">&times;</button>';
    chip.querySelector('.automation-time-chip-remove').addEventListener('click', function () {
      times.splice(i, 1);
      renderAgentTimeChipsInCard(card, agentIndex);
    });
    container.appendChild(chip);
  });
}
```

- [ ] **Step 5: Add syncAgentFromCard and syncAllAgentsFromCards**

```javascript
function syncAgentFromCard(card, agentIndex) {
  var agent = modalAgents[agentIndex];
  agent.name = (card.querySelector('.agent-name') || {}).value || '';
  agent.prompt = (card.querySelector('.agent-prompt') || {}).value || '';

  var runModeEl = card.querySelector('.agent-run-mode');
  if (runModeEl) agent.runMode = runModeEl.value;

  // Sync runAfter from checkboxes
  var runAfterChecks = card.querySelectorAll('.agent-runafter-chips input:checked');
  agent.runAfter = [];
  runAfterChecks.forEach(function (cb) {
    var targetIdx = parseInt(cb.value);
    var targetAgent = modalAgents[targetIdx];
    if (targetAgent) agent.runAfter.push(targetAgent.id || 'temp_' + targetIdx);
  });

  var isoCheckbox = card.querySelector('.agent-isolation-checkbox');
  if (isoCheckbox) {
    agent.isolation = agent.isolation || {};
    agent.isolation.enabled = isoCheckbox.checked;
  }

  var schedTypeEl = card.querySelector('.agent-schedule-type');
  if (schedTypeEl) {
    var schedType = schedTypeEl.value;
    if (schedType === 'manual') {
      agent.schedule = { type: 'manual' };
    } else if (schedType === 'interval') {
      var val = parseInt((card.querySelector('.agent-interval-value') || {}).value) || 60;
      var unit = (card.querySelector('.agent-interval-unit') || {}).value || 'minutes';
      agent.schedule = { type: 'interval', minutes: unit === 'hours' ? val * 60 : val };
    } else if (schedType === 'app_startup') {
      agent.schedule = { type: 'app_startup' };
      agent.firstStartOnly = (card.querySelector('.agent-first-start-only') || {}).checked || false;
    } else if (schedType === 'time_of_day') {
      var days = [];
      card.querySelectorAll('.agent-tod-days input:checked').forEach(function (cb) { days.push(cb.value); });
      agent.schedule = { type: 'time_of_day', times: (agent._modalTimes || []).slice(), days: days };
    }
  }

  agent.skipPermissions = (card.querySelector('.agent-skip-permissions') || {}).checked || false;
  agent.dbConnectionString = (card.querySelector('.agent-db-connection') || {}).value.trim() || null;
  agent.dbReadOnly = (card.querySelector('.agent-db-readonly') || {}).checked !== false;
}

function syncAllAgentsFromCards() {
  document.querySelectorAll('#automation-agents-list .agent-card').forEach(function (card) {
    var idx = parseInt(card.dataset.agentIndex);
    syncAgentFromCard(card, idx);
  });
}
```

- [ ] **Step 6: Add "+ Add Agent" button handler**

```javascript
document.getElementById('btn-add-agent').addEventListener('click', function () {
  syncAllAgentsFromCards();

  // If transitioning from single to multi, set automation name from first agent
  if (modalAgents.length === 1 && !document.getElementById('automation-name').value) {
    document.getElementById('automation-name').value = modalAgents[0].name || '';
  }

  modalAgents.push({
    name: '', prompt: '', schedule: { type: 'interval', minutes: 60 },
    runMode: 'independent', runAfter: [], isolation: { enabled: false, clonePath: null },
    skipPermissions: false, dbConnectionString: null, dbReadOnly: true, firstStartOnly: false
  });

  renderModalAgentCards();
});
```

- [ ] **Step 7: Rewrite saveAutomation**

Replace the `saveAutomation()` function with:

```javascript
function saveAutomation() {
  syncAllAgentsFromCards();

  var isMulti = modalAgents.length > 1;
  var automationName = isMulti ? document.getElementById('automation-name').value.trim() : (modalAgents[0].name || '');

  // Validate
  if (isMulti && !automationName) { alert('Automation name is required.'); return; }
  for (var i = 0; i < modalAgents.length; i++) {
    if (!modalAgents[i].name || !modalAgents[i].prompt) {
      alert('Agent ' + (i + 1) + ' needs a name and prompt.'); return;
    }
  }
  if (!activeProjectKey) { alert('Select a project first.'); return; }

  // Check for circular dependencies
  var hasIsolated = modalAgents.some(function (ag) { return ag.isolation && ag.isolation.enabled; });

  // Build the agents config — clean up temp fields
  var agents = modalAgents.map(function (ag, idx) {
    var clean = Object.assign({}, ag);
    delete clean._modalTimes;
    // Convert temp IDs in runAfter to real agent refs
    if (!clean.id) clean.id = undefined; // Will be assigned by backend
    return clean;
  });

  if (automationEditingId) {
    // Update existing automation
    window.electronAPI.updateAutomation(automationEditingId, { name: automationName }).then(function () {
      // Update each agent
      var promises = agents.map(function (ag) {
        if (ag.id && !ag.id.startsWith('temp_')) {
          return window.electronAPI.updateAgent(automationEditingId, ag.id, ag);
        } else {
          return window.electronAPI.addAgent(automationEditingId, ag);
        }
      });
      return Promise.all(promises);
    }).then(function () {
      if (hasIsolated) {
        startCloneSetup(automationEditingId);
      } else {
        closeAutomationModal();
        refreshAutomations();
        refreshAutomationsFlyout();
      }
    });
  } else {
    // Create new automation
    var config = {
      name: automationName,
      projectPath: activeProjectKey,
      agents: agents
    };
    window.electronAPI.createAutomation(config).then(function (automation) {
      if (hasIsolated) {
        automationEditingId = automation.id;
        startCloneSetup(automation.id);
      } else {
        closeAutomationModal();
        refreshAutomations();
        refreshAutomationsFlyout();
      }
    });
  }
}
```

- [ ] **Step 8: Add clone setup function (Stage 3)**

```javascript
function startCloneSetup(automationId) {
  var formBody = document.querySelector('.automation-modal-body');
  var setupPanel = document.getElementById('automation-setup-panel');
  var setupAgents = document.getElementById('automation-setup-agents');
  var setupLog = document.getElementById('automation-setup-log');

  // Hide form fields, show setup panel
  document.getElementById('automation-agents-list').style.display = 'none';
  document.getElementById('automation-add-agent-row').style.display = 'none';
  document.getElementById('automation-name-group').style.display = 'none';
  setupPanel.style.display = '';
  setupLog.textContent = '';

  document.getElementById('btn-automation-save').textContent = 'Setting up...';
  document.getElementById('btn-automation-save').disabled = true;

  // Show per-agent status
  window.electronAPI.getAutomationsForProject(activeProjectKey).then(function (automations) {
    var automation = automations.find(function (a) { return a.id === automationId; });
    if (!automation) return;

    var isolatedAgents = automation.agents.filter(function (ag) { return ag.isolation && ag.isolation.enabled; });
    setupAgents.innerHTML = '';
    isolatedAgents.forEach(function (ag) {
      var row = document.createElement('div');
      row.className = 'automation-setup-agent-row';
      row.id = 'setup-agent-' + ag.id;
      row.innerHTML = '<span class="automation-setup-agent-icon">&#9711;</span> ' + escapeHtml(ag.name);
      setupAgents.appendChild(row);
    });

    // Listen for clone progress
    var progressHandler = function (data) {
      if (data.automationId !== automationId) return;
      setupLog.textContent += data.line;
      setupLog.scrollTop = setupLog.scrollHeight;
    };
    window.electronAPI.onCloneProgress(progressHandler);

    // Clone each isolated agent sequentially
    var cloneNext = function (index) {
      if (index >= isolatedAgents.length) {
        // All done
        document.getElementById('btn-automation-save').textContent = 'Done';
        document.getElementById('btn-automation-save').disabled = false;
        document.getElementById('btn-automation-save').onclick = function () {
          closeAutomationModal();
          refreshAutomations();
          refreshAutomationsFlyout();
        };
        return;
      }
      var ag = isolatedAgents[index];
      var row = document.getElementById('setup-agent-' + ag.id);
      if (row) row.querySelector('.automation-setup-agent-icon').innerHTML = '&#8987;'; // spinner

      window.electronAPI.setupAgentClone(automationId, ag.id).then(function (result) {
        if (row) {
          row.querySelector('.automation-setup-agent-icon').innerHTML = result.error ? '&#10007;' : '&#10003;';
          if (result.error) row.style.color = '#ef4444';
          else row.style.color = '#22c55e';
        }
        if (result.error) {
          setupLog.textContent += '\nERROR: ' + result.error + '\n';
        }
        cloneNext(index + 1);
      });
    };
    cloneNext(0);
  });
}
```

- [ ] **Step 9: Add closeAutomationModal**

```javascript
function closeAutomationModal() {
  document.getElementById('automation-modal-overlay').classList.add('hidden');
  // Reset state
  document.getElementById('automation-agents-list').style.display = '';
  document.getElementById('automation-add-agent-row').style.display = '';
  document.getElementById('automation-setup-panel').style.display = 'none';
  document.getElementById('btn-automation-save').disabled = false;
  document.getElementById('btn-automation-save').onclick = null;
  automationEditingId = null;
  modalAgents = [];
}
```

- [ ] **Step 10: Bind modal buttons**

```javascript
document.getElementById('btn-automation-modal-close').addEventListener('click', closeAutomationModal);
document.getElementById('btn-automation-cancel').addEventListener('click', closeAutomationModal);
document.getElementById('btn-automation-save').addEventListener('click', saveAutomation);
document.getElementById('btn-add-automation').addEventListener('click', function () {
  if (!activeProjectKey) { alert('Select a project first.'); return; }
  openAutomationModal(null);
});
```

- [ ] **Step 11: Verify syntax**

Run: `node -c renderer.js`
Expected: no output (syntax OK)

- [ ] **Step 12: Commit**

```bash
git add renderer.js
git commit -m "feat: implement multi-agent creation/edit modal"
```

---

## Phase 8: List View & Detail View

### Task 17: Rewrite renderAutomationCards for multi-agent support

**Files:**
- Modify: `renderer.js` (replace `renderAutomationCards` function)

Simple automations (1 agent) render as before. Multi-agent automations show agent count, dependency summary, and a mini pipeline visualization.

- [ ] **Step 1: Replace renderAutomationCards**

Replace the existing `renderAutomationCards()` function with:

```javascript
function renderAutomationCards(automations, container) {
  container.innerHTML = '';

  if (automations.length === 0) {
    container.innerHTML = '<p style="opacity:0.5;text-align:center;padding:2rem 1rem;font-size:12px;">No automations configured.<br>Click + to create one.</p>';
    return;
  }

  automations.forEach(function (automation) {
    var card = document.createElement('div');
    card.className = 'automation-card';
    var isMulti = automation.agents.length > 1;
    var isSimple = !isMulti;

    // Determine overall status
    var anyRunning = automation.agents.some(function (ag) { return !!ag.currentRunStartedAt; });
    var anyError = automation.agents.some(function (ag) { return ag.lastRunStatus === 'error'; });
    var allDisabled = !automation.enabled;

    var statusClass = 'automation-idle';
    var badgeClass = 'badge-idle';
    var badgeText = 'idle';

    if (allDisabled) {
      statusClass = 'automation-disabled'; badgeClass = 'badge-disabled'; badgeText = 'disabled';
    } else if (anyRunning) {
      statusClass = 'automation-running'; badgeClass = 'badge-running'; badgeText = 'running...';
    } else if (anyError) {
      statusClass = 'automation-error'; badgeClass = 'badge-error'; badgeText = 'error';
    }

    card.classList.add(statusClass);

    if (isSimple) {
      // Simple automation — same as old loop card
      var agent = automation.agents[0];
      var schedText = formatScheduleText(agent);
      var lastRunText = '';
      if (agent.lastRunAt) {
        var elapsed = Date.now() - new Date(agent.lastRunAt).getTime();
        if (elapsed < 60000) lastRunText = 'Last: just now';
        else if (elapsed < 3600000) lastRunText = 'Last: ' + Math.floor(elapsed / 60000) + 'm ago';
        else if (elapsed < 86400000) lastRunText = 'Last: ' + Math.floor(elapsed / 3600000) + 'h ago';
        else lastRunText = 'Last: ' + Math.floor(elapsed / 86400000) + 'd ago';
      } else {
        lastRunText = 'Never run';
      }

      var summaryHtml = '';
      if (agent.currentRunStartedAt) {
        summaryHtml = '<div class="automation-card-summary automation-card-summary-running">Running...</div>';
      } else if (agent.lastSummary) {
        summaryHtml = '<div class="automation-card-summary">' + escapeHtml(agent.lastSummary) + '</div>';
      }

      var attentionHtml = '';
      if (agent.lastAttentionItems && agent.lastAttentionItems.length > 0) {
        attentionHtml = '<div class="automation-card-attention-summary">';
        agent.lastAttentionItems.forEach(function (item) {
          attentionHtml += '<div class="automation-card-attention-item">&#9888; ' + escapeHtml(item.summary) + '</div>';
        });
        attentionHtml += '</div>';
      }

      var toggleIcon = automation.enabled ? '&#10074;&#10074;' : '&#9654;';
      var actionsHtml = '<span class="automation-card-actions">' +
        '<button class="automation-btn-toggle" title="' + (automation.enabled ? 'Pause' : 'Enable') + '">' + toggleIcon + '</button>';
      if (!agent.currentRunStartedAt) {
        actionsHtml += '<button class="automation-btn-run" title="Run Now">&#9655;</button>';
      }
      actionsHtml += '<button class="automation-btn-export" title="Export">&#8613;</button>' +
        '<button class="automation-btn-edit" title="Edit">&#9998;</button>' +
        '<button class="automation-btn-delete" title="Delete">&times;</button></span>';

      card.innerHTML = '<div class="automation-card-header">' +
        '<span class="automation-card-name">' + escapeHtml(agent.name) + '</span>' +
        '<span class="automation-card-schedule">' + schedText + '</span>' +
        '</div>' +
        '<div class="automation-card-status">' + lastRunText + '</div>' +
        summaryHtml + attentionHtml +
        '<div class="automation-card-footer">' +
          '<span class="automation-status-badge ' + badgeClass + '">' + badgeText + '</span>' +
          actionsHtml +
        '</div>';
    } else {
      // Multi-agent automation — summary card with pipeline dots
      var independentCount = automation.agents.filter(function (ag) { return ag.runMode === 'independent'; }).length;
      var chainedCount = automation.agents.length - independentCount;
      var agentSummary = automation.agents.length + ' agents, ' + independentCount + ' independent' + (chainedCount > 0 ? ', ' + chainedCount + ' chained' : '');

      // Mini pipeline dots
      var dotsHtml = '<div class="automation-pipeline-mini">';
      automation.agents.forEach(function (ag, i) {
        var dotClass = 'pipeline-dot-idle';
        if (ag.currentRunStartedAt) dotClass = 'pipeline-dot-running';
        else if (ag.lastRunStatus === 'error') dotClass = 'pipeline-dot-error';
        else if (ag.lastRunStatus === 'skipped' || !ag.enabled) dotClass = 'pipeline-dot-waiting';

        dotsHtml += '<span class="pipeline-dot ' + dotClass + '" title="' + escapeHtml(ag.name) + '"></span>';
        // Add arrow if this agent has dependents
        if (ag.runMode === 'independent' && i < automation.agents.length - 1) {
          var nextAg = automation.agents[i + 1];
          if (nextAg && nextAg.runMode === 'run_after' && nextAg.runAfter && nextAg.runAfter.includes(ag.id)) {
            dotsHtml += '<span class="pipeline-arrow">&#8594;</span>';
          }
        }
      });
      dotsHtml += '</div>';

      var toggleIcon2 = automation.enabled ? '&#10074;&#10074;' : '&#9654;';
      var actionsHtml2 = '<span class="automation-card-actions">' +
        '<button class="automation-btn-toggle" title="' + (automation.enabled ? 'Pause' : 'Enable') + '">' + toggleIcon2 + '</button>' +
        '<button class="automation-btn-run" title="Run All">&#9655;</button>' +
        '<button class="automation-btn-export" title="Export">&#8613;</button>' +
        '<button class="automation-btn-edit" title="Edit">&#9998;</button>' +
        '<button class="automation-btn-delete" title="Delete">&times;</button></span>';

      card.innerHTML = '<div class="automation-card-header">' +
        '<span class="automation-card-name">' + escapeHtml(automation.name) + '</span>' +
        '<span class="automation-card-schedule">' + agentSummary + '</span>' +
        '</div>' +
        dotsHtml +
        '<div class="automation-card-footer">' +
          '<span class="automation-status-badge ' + badgeClass + '">' + badgeText + '</span>' +
          actionsHtml2 +
        '</div>';
    }

    card.style.cursor = 'pointer';
    card.addEventListener('click', function () {
      openAutomationDetail(automation);
    });

    // Action button handlers
    card.querySelector('.automation-btn-toggle').addEventListener('click', function (e) {
      e.stopPropagation();
      window.electronAPI.toggleAutomation(automation.id).then(function () { refreshAutomations(); });
    });
    var runBtn = card.querySelector('.automation-btn-run');
    if (runBtn) {
      runBtn.addEventListener('click', function (e) {
        e.stopPropagation();
        if (isSimple) {
          window.electronAPI.runAgentNow(automation.id, automation.agents[0].id);
        } else {
          window.electronAPI.runAutomationNow(automation.id);
        }
        refreshAutomations();
      });
    }
    card.querySelector('.automation-btn-export').addEventListener('click', function (e) {
      e.stopPropagation();
      window.electronAPI.exportAutomation(automation.id);
    });
    card.querySelector('.automation-btn-edit').addEventListener('click', function (e) {
      e.stopPropagation();
      openAutomationModal(automation);
    });
    card.querySelector('.automation-btn-delete').addEventListener('click', function (e) {
      e.stopPropagation();
      if (confirm('Delete automation "' + (automation.name || automation.agents[0].name) + '"?')) {
        window.electronAPI.deleteAutomation(automation.id).then(function () { refreshAutomations(); });
      }
    });

    container.appendChild(card);
  });
}
```

- [ ] **Step 2: Commit**

```bash
git add renderer.js
git commit -m "feat: add multi-agent automation cards with pipeline dots"
```

---

### Task 18: Rewrite detail view for multi-agent support

**Files:**
- Modify: `renderer.js` (replace `openAutomationDetail` and related functions)

Simple automations show the same detail as before (output pane, run selector). Multi-agent automations show a pipeline view with per-agent rows.

- [ ] **Step 1: Add tracking variables**

Near the existing `activeAutomationDetailId`:

```javascript
var activeDetailAutomation = null;  // Full automation object for detail view
var activeAgentDetailId = null;     // Currently selected agent in detail view
```

- [ ] **Step 2: Replace openAutomationDetail**

```javascript
function openAutomationDetail(automation) {
  activeAutomationDetailId = automation.id;
  activeDetailAutomation = automation;

  var listEl = document.getElementById('automations-list');
  var detailEl = document.getElementById('automation-detail-panel');
  var searchBar = document.getElementById('automations-search-bar');
  if (listEl) listEl.style.display = 'none';
  if (searchBar) searchBar.style.display = 'none';
  detailEl.style.display = '';

  var isSimple = automation.agents.length === 1;

  if (isSimple) {
    renderSimpleDetail(automation, automation.agents[0]);
  } else {
    renderMultiAgentDetail(automation);
  }
}

function renderSimpleDetail(automation, agent) {
  document.getElementById('automation-detail-name').textContent = agent.name;
  var badge = document.getElementById('automation-detail-status-badge');
  badge.className = 'automation-status-badge';
  if (agent.currentRunStartedAt) {
    badge.classList.add('badge-running');
    badge.textContent = 'running...';
  } else if (agent.lastRunStatus === 'error') {
    badge.classList.add('badge-error');
    badge.textContent = 'error';
  } else {
    badge.classList.add('badge-idle');
    badge.textContent = 'idle';
  }

  var metaEl = document.getElementById('automation-detail-meta');
  metaEl.textContent = formatScheduleText(agent) + (agent.lastRunAt ? ' \u00b7 Last: ' + new Date(agent.lastRunAt).toLocaleString() : '');

  activeAgentDetailId = agent.id;

  // Load run history
  window.electronAPI.getAgentHistory(automation.id, agent.id, 10).then(function (history) {
    var select = document.getElementById('automation-detail-run-select');
    select.innerHTML = '';
    if (agent.currentRunStartedAt) {
      var opt = document.createElement('option');
      opt.value = 'live';
      opt.textContent = 'Live';
      select.appendChild(opt);
    }
    history.forEach(function (run) {
      var opt = document.createElement('option');
      opt.value = run.startedAt;
      opt.textContent = new Date(run.startedAt).toLocaleString() + ' - ' + run.status;
      select.appendChild(opt);
    });

    if (agent.currentRunStartedAt) {
      switchToAgentLiveView(automation.id, agent);
    } else if (history.length > 0) {
      switchToAgentRunView(automation.id, agent.id, history[0].startedAt);
    } else {
      document.getElementById('automation-detail-output').textContent = 'No runs yet.';
      document.getElementById('automation-detail-summary').style.display = 'none';
      document.getElementById('automation-detail-attention').style.display = 'none';
    }
  });
}

function renderMultiAgentDetail(automation) {
  document.getElementById('automation-detail-name').textContent = automation.name;
  var badge = document.getElementById('automation-detail-status-badge');
  badge.className = 'automation-status-badge';
  var anyRunning = automation.agents.some(function (ag) { return !!ag.currentRunStartedAt; });
  if (anyRunning) {
    badge.classList.add('badge-running');
    badge.textContent = 'running...';
  } else {
    badge.classList.add('badge-idle');
    badge.textContent = automation.agents.length + ' agents';
  }

  var metaEl = document.getElementById('automation-detail-meta');
  metaEl.innerHTML = '<button class="automation-detail-run-all" title="Run All Independent">&#9655; Run All</button>' +
    '<button class="automation-detail-pause-all" title="Pause All">&#10074;&#10074; Pause</button>';

  metaEl.querySelector('.automation-detail-run-all').addEventListener('click', function () {
    window.electronAPI.runAutomationNow(automation.id);
  });
  metaEl.querySelector('.automation-detail-pause-all').addEventListener('click', function () {
    window.electronAPI.toggleAutomation(automation.id).then(function () {
      refreshAutomations();
    });
  });

  // Build pipeline view in the output area
  var outputEl = document.getElementById('automation-detail-output');
  outputEl.innerHTML = '';
  document.getElementById('automation-detail-summary').style.display = 'none';
  document.getElementById('automation-detail-attention').style.display = 'none';

  // Hide run selector for multi-agent view
  document.getElementById('automation-detail-run-select').style.display = 'none';

  var pipelineEl = document.createElement('div');
  pipelineEl.className = 'automation-pipeline-view';

  automation.agents.forEach(function (agent) {
    var borderColor = '#666';
    if (agent.currentRunStartedAt) borderColor = '#3b82f6'; // blue
    else if (agent.lastRunStatus === 'completed') borderColor = '#22c55e'; // green
    else if (agent.lastRunStatus === 'error') borderColor = '#ef4444'; // red
    else if (agent.lastRunStatus === 'skipped' || !agent.enabled) borderColor = '#666'; // grey

    var row = document.createElement('div');
    row.className = 'automation-pipeline-agent';
    row.style.borderLeftColor = borderColor;

    var statusText = agent.currentRunStartedAt ? 'running...' : (agent.lastRunStatus || 'pending');
    var schedText = agent.runMode === 'run_after' ? 'Waits for upstream' : formatScheduleText(agent);

    row.innerHTML = '<div class="pipeline-agent-header">' +
      '<span class="pipeline-agent-name">' + escapeHtml(agent.name) + '</span>' +
      '<span class="pipeline-agent-status" style="color:' + borderColor + '">' + statusText + '</span>' +
      '</div>' +
      '<div class="pipeline-agent-meta">' + schedText +
        (agent.isolation && agent.isolation.enabled ? ' \u00b7 Isolated' : '') +
      '</div>' +
      (agent.lastSummary ? '<div class="pipeline-agent-summary">' + escapeHtml(agent.lastSummary) + '</div>' : '') +
      '<div class="pipeline-agent-actions">' +
        '<button class="pipeline-btn-view-output" title="View Output">Output</button>' +
        '<button class="pipeline-btn-history" title="History">History</button>' +
      '</div>';

    // View Output button
    row.querySelector('.pipeline-btn-view-output').addEventListener('click', function () {
      activeAgentDetailId = agent.id;
      document.getElementById('automation-detail-run-select').style.display = '';
      renderSimpleDetail(automation, agent);
    });

    // History button
    row.querySelector('.pipeline-btn-history').addEventListener('click', function () {
      activeAgentDetailId = agent.id;
      document.getElementById('automation-detail-run-select').style.display = '';
      renderSimpleDetail(automation, agent);
    });

    pipelineEl.appendChild(row);

    // Add connector line for dependencies
    if (agent.runMode === 'run_after' && agent.runAfter && agent.runAfter.length > 0) {
      var connector = document.createElement('div');
      connector.className = 'pipeline-connector';
      var upstreamNames = agent.runAfter.map(function (id) {
        var up = automation.agents.find(function (ag) { return ag.id === id; });
        return up ? up.name : 'unknown';
      });
      connector.textContent = 'waits for: ' + upstreamNames.join(', ');
      // Insert connector before this row
      pipelineEl.insertBefore(connector, row);
    }
  });

  outputEl.appendChild(pipelineEl);
}
```

- [ ] **Step 3: Update switchToAgentLiveView and switchToAgentRunView**

```javascript
function switchToAgentLiveView(automationId, agent) {
  agentDetailViewingLive = true;
  var outputEl = document.getElementById('automation-detail-output');
  outputEl.innerHTML = '<div class="automation-processing-indicator">Processing...</div>';
  document.getElementById('automation-detail-summary').style.display = 'none';
  document.getElementById('automation-detail-attention').style.display = 'none';

  window.electronAPI.getAgentLiveOutput(automationId, agent.id).then(function (text) {
    if (text) {
      outputEl.textContent = text;
      outputEl.scrollTop = outputEl.scrollHeight;
    }
  });
}

function switchToAgentRunView(automationId, agentId, startedAt) {
  agentDetailViewingLive = false;
  window.electronAPI.getAgentRunDetail(automationId, agentId, startedAt).then(function (run) {
    if (run) {
      document.getElementById('automation-detail-output').textContent = run.output || 'No output recorded.';
      showAgentRunSummary(run);
    }
  });
}

function showAgentRunSummary(run) {
  var summaryEl = document.getElementById('automation-detail-summary');
  var attentionEl = document.getElementById('automation-detail-attention');

  if (run.summary) {
    summaryEl.textContent = run.summary;
    summaryEl.style.display = '';
  } else {
    summaryEl.style.display = 'none';
  }

  if (run.attentionItems && run.attentionItems.length > 0) {
    attentionEl.innerHTML = '';
    run.attentionItems.forEach(function (item) {
      var div = document.createElement('div');
      div.className = 'automation-detail-attention-item';
      div.innerHTML = '<strong>&#9888; ' + escapeHtml(item.summary) + '</strong>' +
        (item.detail ? '<div>' + escapeHtml(item.detail) + '</div>' : '');
      attentionEl.appendChild(div);
    });
    attentionEl.style.display = '';
  } else {
    attentionEl.style.display = 'none';
  }
}
```

- [ ] **Step 4: Update the run-select change handler**

```javascript
document.getElementById('automation-detail-run-select').addEventListener('change', function () {
  if (this.value === 'live') {
    var auto = activeDetailAutomation;
    if (auto) {
      var agent = auto.agents.find(function (ag) { return ag.id === activeAgentDetailId; });
      if (agent) switchToAgentLiveView(auto.id, agent);
    }
  } else {
    switchToAgentRunView(activeAutomationDetailId, activeAgentDetailId, this.value);
  }
});
```

- [ ] **Step 5: Update closeAutomationDetail**

```javascript
function closeAutomationDetail() {
  activeAutomationDetailId = null;
  activeDetailAutomation = null;
  activeAgentDetailId = null;
  agentDetailViewingLive = false;
  document.getElementById('automation-detail-panel').style.display = 'none';
  document.getElementById('automations-list').style.display = '';
  document.getElementById('automation-detail-run-select').style.display = '';
}
```

- [ ] **Step 6: Commit**

```bash
git add renderer.js
git commit -m "feat: add multi-agent pipeline detail view"
```

---

### Task 19: Update event listeners for automations

**Files:**
- Modify: `renderer.js` (replace the event listeners section)

- [ ] **Step 1: Replace event listeners**

Replace the old loop event listeners (around lines 6405-6449) with:

```javascript
window.electronAPI.onAgentStarted(function (data) {
  refreshAutomations();
  refreshAutomationsFlyout();
  updateAutomationsTabIndicator();
  updateAutomationSidebarBadges();
  if (activeAutomationDetailId === data.automationId) {
    window.electronAPI.getAutomationsForProject(activeProjectKey).then(function (automations) {
      var auto = automations.find(function (a) { return a.id === data.automationId; });
      if (auto) openAutomationDetail(auto);
    });
  }
});

window.electronAPI.onAgentOutput(function (data) {
  if (activeAutomationDetailId === data.automationId && activeAgentDetailId === data.agentId && agentDetailViewingLive) {
    var outputEl = document.getElementById('automation-detail-output');
    if (outputEl) {
      var indicator = outputEl.querySelector('.automation-processing-indicator');
      if (indicator) outputEl.textContent = '';
      outputEl.textContent += data.chunk;
      outputEl.scrollTop = outputEl.scrollHeight;
    }
  }
});

window.electronAPI.onAgentCompleted(function (data) {
  refreshAutomations();
  refreshAutomationsFlyout();
  updateAutomationSidebarBadges();
  updateAutomationsTabIndicator();
  if (activeAutomationDetailId === data.automationId) {
    window.electronAPI.getAutomationsForProject(activeProjectKey).then(function (automations) {
      var auto = automations.find(function (a) { return a.id === data.automationId; });
      if (auto) openAutomationDetail(auto);
    });
  }
  if (data.attentionItems && data.attentionItems.length > 0) {
    var flyoutBtn = document.getElementById('btn-automations-flyout');
    if (flyoutBtn) flyoutBtn.classList.add('has-attention');
  }
});
```

- [ ] **Step 2: Update the tab indicator and sidebar badges**

Replace `updateAutomationsTabIndicator`:

```javascript
function updateAutomationsTabIndicator() {
  if (!activeProjectKey) return;
  window.electronAPI.getAutomationsForProject(activeProjectKey).then(function (automations) {
    var hasAutomations = automations.length > 0;
    var anyRunning = automations.some(function (auto) {
      return auto.agents.some(function (ag) { return !!ag.currentRunStartedAt; });
    });
    var tab = document.querySelector('.explorer-tab[data-tab="automations"]');
    if (tab) {
      if (anyRunning) {
        tab.classList.add('has-running');
        tab.classList.remove('has-automations');
      } else if (hasAutomations) {
        tab.classList.remove('has-running');
        tab.classList.add('has-automations');
      } else {
        tab.classList.remove('has-running');
        tab.classList.remove('has-automations');
      }
    }
  });
}
```

Replace `updateAutomationSidebarBadges`:

```javascript
function updateAutomationSidebarBadges() {
  window.electronAPI.getAutomations().then(function (data) {
    var projectsWithAttention = new Set();
    data.automations.forEach(function (auto) {
      auto.agents.forEach(function (ag) {
        if (ag.lastRunStatus === 'error' || ag.lastError) {
          projectsWithAttention.add(auto.projectPath.replace(/\\/g, '/'));
        }
      });
    });

    var items = document.querySelectorAll('.project-item');
    items.forEach(function (item) {
      var existing = item.querySelector('.project-automation-badge');
      if (existing) existing.remove();
    });

    if (config && config.projects) {
      config.projects.forEach(function (project, index) {
        var normalizedPath = project.path.replace(/\\/g, '/');
        if (projectsWithAttention.has(normalizedPath) && items[index]) {
          var badge = document.createElement('span');
          badge.className = 'project-automation-badge';
          badge.title = 'Automation needs attention';
          var nameEl = items[index].querySelector('.project-name');
          if (nameEl) nameEl.appendChild(badge);
        }
      });
    }
  });
}
```

- [ ] **Step 3: Commit**

```bash
git add renderer.js
git commit -m "feat: update event listeners for automations system"
```

---

## Phase 9: Flyout & Final Polish

### Task 20: Update flyout for automations

**Files:**
- Modify: `renderer.js` (replace `refreshAutomationsFlyout`)

The flyout groups automations by project. Multi-agent automations show the mini pipeline dots.

- [ ] **Step 1: Replace refreshAutomationsFlyout**

Replace the existing flyout refresh function with one that works with the automations data model. The key changes:
- Iterate `data.automations` instead of `data.loops`
- Group by `automation.projectPath`
- For multi-agent automations, show pipeline dots
- Use `getAgentHistory` for history (passing `automationId, agentId`)

```javascript
function refreshAutomationsFlyout() {
  var flyout = document.getElementById('automations-flyout');
  if (!flyout || flyout.classList.contains('hidden')) return;

  window.electronAPI.getAutomations().then(function (data) {
    allAutomationsData = data;
    var listEl = document.getElementById('automations-flyout-list');
    var countsEl = document.getElementById('automations-flyout-counts');

    var globalBtn = document.getElementById('btn-automations-global-toggle');
    globalBtn.innerHTML = data.globalEnabled ? '&#10074;&#10074;' : '&#9654;';
    globalBtn.title = data.globalEnabled ? 'Pause all automations' : 'Resume all automations';

    var totalAgents = 0;
    var activeAgents = 0;
    var attentionCount = 0;
    data.automations.forEach(function (auto) {
      auto.agents.forEach(function (ag) {
        totalAgents++;
        if (ag.enabled) activeAgents++;
        if (ag.lastRunStatus === 'error' || ag.lastError) attentionCount++;
      });
    });

    countsEl.textContent = activeAgents + ' active' + (attentionCount > 0 ? ' \u00b7 ' + attentionCount + ' need attention' : '');

    var byProject = {};
    data.automations.forEach(function (auto) {
      var projName = auto.projectPath.split('/').pop().split('\\').pop();
      if (!byProject[projName]) byProject[projName] = { path: auto.projectPath, automations: [] };
      byProject[projName].automations.push(auto);
    });

    listEl.innerHTML = '';

    if (data.automations.length === 0) {
      listEl.innerHTML = '<p style="opacity:0.5;text-align:center;padding:2rem;font-size:12px;">No automations configured yet.</p>';
      return;
    }

    Object.keys(byProject).forEach(function (projName) {
      var group = byProject[projName];
      var header = document.createElement('div');
      header.className = 'automations-flyout-project-header';
      header.textContent = projName;
      listEl.appendChild(header);

      group.automations.forEach(function (auto) {
        var row = document.createElement('div');
        row.className = 'automations-flyout-row';
        var isSimple = auto.agents.length === 1;

        var statusText = '';
        var statusColor = '#22c55e';
        var anyRunning = auto.agents.some(function (ag) { return !!ag.currentRunStartedAt; });
        var anyError = auto.agents.some(function (ag) { return ag.lastRunStatus === 'error'; });

        if (!auto.enabled) { statusText = 'disabled'; statusColor = '#888'; }
        else if (anyRunning) { statusText = 'running...'; }
        else if (anyError) { statusText = '\u2717 error'; statusColor = '#ef4444'; }
        else { statusText = '\u2713 ok'; }

        var displayName = isSimple ? auto.agents[0].name : auto.name;

        row.innerHTML = '<div class="automations-flyout-row-header">' +
          '<span>' + escapeHtml(displayName) + (isSimple ? '' : ' <span style="opacity:0.5">(' + auto.agents.length + ' agents)</span>') + '</span>' +
          '<span class="automations-flyout-row-status" style="color:' + statusColor + '">' + statusText + '</span>' +
          '</div>' +
          '<div class="automations-flyout-row-expanded">' +
            '<div class="automations-flyout-row-summary">Loading...</div>' +
            '<div class="automations-flyout-history"></div>' +
          '</div>';

        row.addEventListener('click', function () {
          var wasExpanded = row.classList.contains('expanded');
          listEl.querySelectorAll('.automations-flyout-row').forEach(function (r) { r.classList.remove('expanded'); });
          if (!wasExpanded) {
            row.classList.add('expanded');
            // Load summary from first agent (simple) or all agents (multi)
            var summaryEl = row.querySelector('.automations-flyout-row-summary');
            if (isSimple) {
              var ag = auto.agents[0];
              window.electronAPI.getAgentHistory(auto.id, ag.id, 5).then(function (history) {
                if (history.length > 0) {
                  summaryEl.textContent = history[0].summary || 'No summary';
                } else {
                  summaryEl.textContent = 'No runs yet';
                }
              });
            } else {
              summaryEl.innerHTML = '';
              auto.agents.forEach(function (ag) {
                summaryEl.innerHTML += '<div><strong>' + escapeHtml(ag.name) + ':</strong> ' + escapeHtml(ag.lastSummary || 'No runs') + '</div>';
              });
            }
          }
        });

        listEl.appendChild(row);
      });
    });
  });
}
```

- [ ] **Step 2: Update flyout button bindings**

```javascript
document.getElementById('btn-automations-flyout').addEventListener('click', toggleAutomationsFlyout);
document.getElementById('btn-automations-flyout-close').addEventListener('click', toggleAutomationsFlyout);
document.getElementById('btn-automations-global-toggle').addEventListener('click', function () {
  window.electronAPI.toggleAutomationsGlobal().then(function () {
    refreshAutomationsFlyout();
  });
});
```

- [ ] **Step 3: Commit**

```bash
git add renderer.js
git commit -m "feat: update flyout for automations with multi-agent support"
```

---

### Task 21: Add new CSS for multi-agent features

**Files:**
- Modify: `styles.css` (add after the renamed automation styles section)

- [ ] **Step 1: Add agent card styles for the modal**

```css
/* Agent Cards (Modal) */
.agent-card {
  border: 1px solid #333;
  border-radius: 6px;
  margin-bottom: 8px;
  background: rgba(255,255,255,0.02);
}

.agent-card-header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 12px;
  cursor: pointer;
  user-select: none;
}

.agent-card-header:hover {
  background: rgba(255,255,255,0.04);
}

.agent-card-collapse-icon {
  font-size: 10px;
  opacity: 0.5;
  width: 12px;
}

.agent-card-title {
  font-weight: 500;
  flex: 1;
}

.agent-card-schedule-summary {
  font-size: 11px;
  opacity: 0.5;
}

.agent-card-remove {
  background: none;
  border: none;
  color: #888;
  cursor: pointer;
  font-size: 16px;
  padding: 0 4px;
}

.agent-card-remove:hover {
  color: #ef4444;
}

.agent-card-body {
  padding: 0 12px 12px 12px;
}

.agent-badge {
  font-size: 10px;
  padding: 1px 6px;
  border-radius: 3px;
  font-weight: 500;
}

.agent-badge-chained {
  background: rgba(99, 102, 241, 0.2);
  color: #818cf8;
}

.agent-badge-isolated {
  background: rgba(34, 197, 94, 0.2);
  color: #4ade80;
}

.agent-runafter-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
}

.agent-runafter-chip {
  font-size: 11px;
  padding: 2px 8px;
  border-radius: 4px;
  border: 1px solid #444;
  cursor: pointer;
  user-select: none;
}

.agent-runafter-chip.selected {
  border-color: #6366f1;
  background: rgba(99, 102, 241, 0.15);
}

.agent-runafter-chip input { display: none; }

.automation-add-agent-row {
  padding: 4px 0;
}

.automation-add-agent-btn {
  background: none;
  border: 1px dashed #444;
  color: #888;
  padding: 6px 12px;
  border-radius: 6px;
  cursor: pointer;
  width: 100%;
  font-size: 12px;
}

.automation-add-agent-btn:hover {
  border-color: #6366f1;
  color: #a5b4fc;
}
```

- [ ] **Step 2: Add clone setup styles**

```css
/* Clone Setup Panel */
.automation-setup-panel {
  padding: 8px 0;
}

.automation-setup-header {
  font-size: 13px;
  font-weight: 500;
  margin-bottom: 8px;
}

.automation-setup-agent-row {
  padding: 4px 8px;
  font-size: 12px;
  display: flex;
  align-items: center;
  gap: 8px;
}

.automation-setup-agent-icon {
  width: 16px;
  text-align: center;
}

.automation-setup-log {
  background: rgba(0,0,0,0.3);
  border-radius: 4px;
  padding: 8px;
  font-size: 11px;
  max-height: 200px;
  overflow-y: auto;
  margin-top: 8px;
  color: #888;
  white-space: pre-wrap;
  word-break: break-all;
}
```

- [ ] **Step 3: Add pipeline visualization styles**

```css
/* Pipeline Mini (List View) */
.automation-pipeline-mini {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 4px 12px;
}

.pipeline-dot {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  display: inline-block;
}

.pipeline-dot-idle { background: #22c55e; }
.pipeline-dot-running { background: #3b82f6; animation: pulse-working 1.5s infinite; }
.pipeline-dot-error { background: #ef4444; }
.pipeline-dot-waiting { background: #666; }

.pipeline-arrow {
  font-size: 10px;
  opacity: 0.4;
}

/* Pipeline Detail View */
.automation-pipeline-view {
  display: flex;
  flex-direction: column;
  gap: 0;
}

.automation-pipeline-agent {
  border-left: 3px solid #666;
  padding: 8px 12px;
  margin-left: 8px;
}

.pipeline-agent-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.pipeline-agent-name {
  font-weight: 500;
  font-size: 13px;
}

.pipeline-agent-status {
  font-size: 11px;
}

.pipeline-agent-meta {
  font-size: 11px;
  opacity: 0.5;
  margin-top: 2px;
}

.pipeline-agent-summary {
  font-size: 12px;
  margin-top: 4px;
  opacity: 0.8;
}

.pipeline-agent-actions {
  display: flex;
  gap: 4px;
  margin-top: 6px;
}

.pipeline-agent-actions button {
  background: rgba(255,255,255,0.06);
  border: 1px solid #444;
  color: #ccc;
  padding: 2px 8px;
  border-radius: 3px;
  font-size: 11px;
  cursor: pointer;
}

.pipeline-agent-actions button:hover {
  background: rgba(255,255,255,0.1);
  border-color: #6366f1;
}

.pipeline-connector {
  margin-left: 16px;
  padding: 2px 0;
  font-size: 10px;
  opacity: 0.4;
  border-left: 1px dashed #444;
  padding-left: 8px;
}

/* Detail view run-all/pause-all buttons */
.automation-detail-run-all,
.automation-detail-pause-all {
  background: rgba(255,255,255,0.06);
  border: 1px solid #444;
  color: #ccc;
  padding: 3px 10px;
  border-radius: 4px;
  font-size: 12px;
  cursor: pointer;
  margin-right: 6px;
}

.automation-detail-run-all:hover { border-color: #22c55e; color: #22c55e; }
.automation-detail-pause-all:hover { border-color: #f59e0b; color: #f59e0b; }
```

- [ ] **Step 4: Add settings field styles**

```css
/* Settings - Agent repos dir */
.settings-field {
  margin-bottom: 12px;
}

.settings-field label {
  display: block;
  font-size: 12px;
  margin-bottom: 4px;
  opacity: 0.8;
}

.settings-path-row {
  display: flex;
  gap: 4px;
}

.settings-input {
  flex: 1;
  background: rgba(255,255,255,0.06);
  border: 1px solid #444;
  color: #ccc;
  padding: 4px 8px;
  border-radius: 4px;
  font-size: 12px;
}

.settings-browse-btn {
  background: rgba(255,255,255,0.06);
  border: 1px solid #444;
  color: #ccc;
  padding: 4px 8px;
  border-radius: 4px;
  cursor: pointer;
}

.settings-browse-btn:hover {
  border-color: #6366f1;
}

.settings-hint {
  font-size: 10px;
  opacity: 0.4;
  margin-top: 2px;
  display: block;
}
```

- [ ] **Step 5: Commit**

```bash
git add styles.css
git commit -m "feat: add CSS for multi-agent modal, pipeline, and settings"
```

---

### Task 22: Update refreshAutomations and search/export/import bindings

**Files:**
- Modify: `renderer.js`

- [ ] **Step 1: Update refreshAutomations to use new API**

Replace the `refreshAutomations()` function:

```javascript
function refreshAutomations() {
  var listEl = document.getElementById('automations-list');
  var noProjectEl = document.getElementById('automations-no-project');
  var searchBar = document.getElementById('automations-search-bar');
  if (!listEl) return;

  if (!activeProjectKey) {
    listEl.innerHTML = '';
    if (noProjectEl) noProjectEl.style.display = '';
    if (searchBar) searchBar.style.display = 'none';
    return;
  }
  if (noProjectEl) noProjectEl.style.display = 'none';

  window.electronAPI.getAutomationsForProject(activeProjectKey).then(function (automations) {
    automationsForProject = automations;
    if (searchBar) searchBar.style.display = automations.length > 0 ? '' : 'none';
    var query = document.getElementById('automations-search-input').value.toLowerCase().trim();
    if (query) {
      automations = automations.filter(function (a) {
        var nameMatch = a.name.toLowerCase().indexOf(query) !== -1;
        var agentMatch = a.agents.some(function (ag) {
          return ag.name.toLowerCase().indexOf(query) !== -1 || ag.prompt.toLowerCase().indexOf(query) !== -1;
        });
        return nameMatch || agentMatch;
      });
    }
    renderAutomationCards(automations, listEl);
  });
  updateAutomationsTabIndicator();
}
```

- [ ] **Step 2: Update search, export, import button handlers**

```javascript
document.getElementById('btn-refresh-automations').addEventListener('click', refreshAutomations);

document.getElementById('btn-export-automations').addEventListener('click', function () {
  if (!activeProjectKey) { alert('Select a project first.'); return; }
  if (automationsForProject.length === 0) { alert('No automations to export.'); return; }
  window.electronAPI.exportAutomations(activeProjectKey);
});

document.getElementById('btn-import-automations').addEventListener('click', function () {
  if (!activeProjectKey) { alert('Select a project first.'); return; }
  window.electronAPI.importAutomations(activeProjectKey).then(function (result) {
    if (result && result.error) { alert(result.error); return; }
    if (result && result.count) refreshAutomations();
  });
});

document.getElementById('automations-search-input').addEventListener('input', function () {
  var query = this.value.toLowerCase().trim();
  var listEl = document.getElementById('automations-list');
  var filtered = automationsForProject;
  if (query) {
    filtered = automationsForProject.filter(function (a) {
      var nameMatch = a.name.toLowerCase().indexOf(query) !== -1;
      var agentMatch = a.agents.some(function (ag) {
        return ag.name.toLowerCase().indexOf(query) !== -1 || ag.prompt.toLowerCase().indexOf(query) !== -1;
      });
      return nameMatch || agentMatch;
    });
  }
  renderAutomationCards(filtered, listEl);
});

document.getElementById('automations-search-input').addEventListener('keydown', function (e) {
  e.stopPropagation();
});
```

- [ ] **Step 3: Commit**

```bash
git add renderer.js
git commit -m "feat: update search, export, import for automations"
```

---

### Task 23: Remove old loop code (cleanup)

**Files:**
- Modify: `main.js` (remove old loop IPC handlers and loop execution code)
- Modify: `preload.js` (remove old loop API)
- Modify: `renderer.js` (remove any remaining old loop functions)

- [ ] **Step 1: Remove old loop IPC handlers from main.js**

Remove the entire section of `ipcMain.handle('loops:*', ...)` handlers (lines 1057-1229). Keep the old persistence functions (`readLoops`, `writeLoops`, etc.) since they're used by the migration code.

- [ ] **Step 2: Remove old loop execution code from main.js**

Remove `shouldRunLoop()`, `runLoop()`, and the old `loopQueue` usage. Keep `parseLoopResult()` (renamed if desired) as the agent execution uses it too.

- [ ] **Step 3: Remove old loop API from preload.js**

Remove the entire `// Loops` section (lines 69-86) from preload.js.

- [ ] **Step 4: Remove old loop event listeners and functions from renderer.js**

Remove any remaining old `loop-*` functions that were replaced in earlier tasks. Search for any `getLoops`, `createLoop`, `updateLoop` references and remove them.

- [ ] **Step 5: Verify syntax across all files**

Run:
```bash
node -c main.js && node -c preload.js && node -c renderer.js
```
Expected: no output (all syntax OK)

- [ ] **Step 6: Commit**

```bash
git add main.js preload.js renderer.js
git commit -m "refactor: remove legacy loop code"
```

---

### Task 24: End-to-end verification

**Files:** None (manual testing)

- [ ] **Step 1: Test migration**

1. Ensure a `~/.claudes/loops.json` file exists with at least one loop
2. Delete `~/.claudes/automations.json` if it exists
3. Launch the app (`npm start`)
4. Verify `automations.json` was created with the migrated data
5. Verify `loops.backup.json` was created
6. Verify `automation-runs/` directory structure is correct

- [ ] **Step 2: Test simple automation CRUD**

1. Open the Automations tab
2. Click + to create a new automation (single agent, manual schedule)
3. Verify the card appears in the list
4. Click Edit, change the name, save
5. Click Run Now, verify it starts and completes
6. Click the card to open detail view
7. Verify output is displayed
8. Click back, then delete the automation

- [ ] **Step 3: Test multi-agent automation**

1. Click + to create a new automation
2. Fill in name and prompt for agent 1
3. Click "+ Add Agent"
4. Verify the modal transforms to multi-agent mode
5. Fill in agent 2 with "Run after" mode, selecting agent 1
6. Enable repo isolation on agent 2
7. Save — verify the clone setup phase runs
8. Verify the card shows pipeline dots
9. Click the card — verify the pipeline detail view
10. Click "Run All" — verify agent 1 runs, then agent 2 triggers

- [ ] **Step 4: Test flyout**

1. Click the Automations flyout button in the toolbar
2. Verify the flyout shows all automations grouped by project
3. Click an automation row to expand — verify summary loads
4. Test global pause/resume toggle

- [ ] **Step 5: Test settings**

1. Open Settings modal
2. Verify the "Agent repos directory" field appears
3. Change the path using the browse button
4. Create a new isolated agent — verify it clones to the new path

- [ ] **Step 6: Test export/import**

1. Export automations for a project
2. Delete them
3. Import the exported file
4. Verify they are restored correctly

- [ ] **Step 7: Commit final state**

```bash
git add -A
git commit -m "feat: complete automations system (loops redesign)"
```
