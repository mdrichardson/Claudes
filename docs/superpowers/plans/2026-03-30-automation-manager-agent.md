# Automation Manager Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional Manager Agent to multi-agent automations that autonomously investigates pipeline failures, takes corrective action (re-running agents), and escalates to the human via Windows notifications only when it genuinely needs help.

**Architecture:** The manager runs as a headless `--print` background job (Phase 1), using the same execution pattern as regular agents. It parses structured `:::manager-result` output containing actions (rerun_agent, rerun_all) which the backend executes. If the manager sets `needsHuman: true`, a Windows notification fires and the automation gets a "Needs You" badge. Clicking it spawns an interactive terminal column. All new code goes in the existing 4-file architecture (main.js, preload.js, renderer.js, index.html, styles.css).

**Tech Stack:** Electron IPC, child_process.spawn (Claude CLI), Electron Notification API, vanilla JS DOM

**Spec:** `docs/superpowers/specs/2026-03-30-automation-manager-agent.md`

---

## Phase 1: Backend — Manager Execution Engine

### Task 1: Add manager tracking state and parseManagerResult

**Files:**
- Modify: `main.js` (after `agentQueue` declaration ~line 1678, and after `parseAgentResult` ~line 1720)

- [ ] **Step 1: Add manager tracking state**

After the `agentQueue` declaration (line 1678), add:

```javascript
const runningManagers = new Map(); // automationId -> child process
const managerRetryCounters = new Map(); // automationId -> number of retries this cycle
```

- [ ] **Step 2: Add MANAGER_PROMPT_TEMPLATE constant**

After `AGENT_PROMPT_SUFFIX` (line 1680), add:

```javascript
const MANAGER_PROMPT_TEMPLATE = `You are the Automation Manager for "{name}".

A pipeline run has just completed. Your job is to:
1. Review all agent results below
2. Identify any failures or issues
3. Investigate root causes using the codebase and database
4. Take corrective action if possible (re-running agents, etc.)
5. Escalate to the human ONLY if you cannot resolve the issue

{pipelineReport}

RULES:
- If an agent failed due to a transient error (timeout, network issue), re-run it
- If an agent failed due to a code or data issue, investigate the root cause
- Do NOT re-run an agent more than {maxRetries} time(s) — you have used {retriesUsed} retries so far
- If you cannot resolve the issue, set needsHuman to true and provide clear context for the human
- Always explain what you found and what you did

{customPrompt}

End your response with a JSON block wrapped in :::manager-result markers like this:
:::manager-result
{"summary": "Brief description", "attentionItems": [{"summary": "...", "detail": "..."}], "actions": [{"type": "rerun_agent", "agentId": "agent_id_here"} or {"type": "rerun_all"} or {"type": "report"}], "needsHuman": false, "humanContext": "Only if needsHuman is true"}
:::manager-result`;
```

- [ ] **Step 3: Add parseManagerResult function**

After `parseAgentResult` (~line 1720), add:

```javascript
function parseManagerResult(output) {
  const result = { summary: '', attentionItems: [], actions: [], needsHuman: false, humanContext: null };
  const match = output.match(/:::manager-result\s*\n([\s\S]*?)\n\s*:::manager-result/);
  if (match) {
    try {
      const parsed = JSON.parse(match[1]);
      result.summary = parsed.summary || '';
      result.attentionItems = parsed.attentionItems || [];
      result.actions = parsed.actions || [];
      result.needsHuman = !!parsed.needsHuman;
      result.humanContext = parsed.humanContext || null;
      return result;
    } catch { /* fall through */ }
  }
  // Fallback: treat entire output as summary, assume needs human
  const lines = output.trim().split('\n');
  result.summary = lines[lines.length - 1].substring(0, 200);
  result.needsHuman = true;
  result.humanContext = 'Manager did not produce structured output. Please review the raw output.';
  return result;
}
```

- [ ] **Step 4: Add buildPipelineReport function**

```javascript
function buildPipelineReport(automation, includeFullOutput) {
  let report = 'PIPELINE STRUCTURE:\n';
  automation.agents.forEach((ag, i) => {
    const mode = ag.runMode === 'run_after' ? 'runs after ' + (ag.runAfter || []).map(id => {
      const up = automation.agents.find(a => a.id === id);
      return up ? up.name : id;
    }).join(', ') : 'independent';
    report += '- Agent ' + (i + 1) + ': "' + ag.name + '" (' + mode + (ag.isolation && ag.isolation.enabled ? ', isolated' : '') + ')\n';
  });
  report += '\nAGENT RESULTS:\n';
  automation.agents.forEach(ag => {
    report += '\n--- ' + ag.name + ' — ' + (ag.lastRunStatus || 'not run').toUpperCase() + ' ---\n';
    if (ag.lastSummary) report += 'Summary: ' + ag.lastSummary + '\n';
    if (ag.lastError) report += 'Error: ' + ag.lastError + '\n';
    if (ag.lastAttentionItems && ag.lastAttentionItems.length > 0) {
      report += 'Attention items:\n';
      ag.lastAttentionItems.forEach(item => {
        report += '  - ' + item.summary + (item.detail ? ': ' + item.detail : '') + '\n';
      });
    }
    if (includeFullOutput) {
      const history = getAgentHistory(automation.id, ag.id, 1);
      if (history.length > 0) {
        const dir = path.join(AUTOMATIONS_RUNS_DIR, automation.id, ag.id);
        try {
          const files = fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort().reverse();
          if (files.length > 0) {
            const runData = JSON.parse(fs.readFileSync(path.join(dir, files[0]), 'utf8'));
            if (runData.output) report += 'Full output:\n' + runData.output.substring(0, 10000) + '\n';
          }
        } catch { /* ignore */ }
      }
    }
  });
  const completed = automation.agents.filter(ag => ag.lastRunStatus === 'completed').length;
  const errored = automation.agents.filter(ag => ag.lastRunStatus === 'error').length;
  const skipped = automation.agents.filter(ag => ag.lastRunStatus === 'skipped').length;
  report += '\nOVERALL STATUS: ' + completed + ' completed, ' + errored + ' error, ' + skipped + ' skipped\n';
  return report;
}
```

- [ ] **Step 5: Verify syntax and commit**

```bash
node -c main.js
git add main.js
git commit -m "feat: add manager result parser and pipeline report builder"
```

---

### Task 2: Implement runManager function

**Files:**
- Modify: `main.js` (add `runManager` after `triggerDependentAgents` ~line 2105)

- [ ] **Step 1: Add sendManagerNotification function**

At the top of main.js, the `Notification` class is already available from Electron's `require('electron')` — but it's not currently destructured. Check line 1: it imports `{ app, BrowserWindow, ipcMain, dialog, clipboard, nativeTheme, shell, Tray, Menu, nativeImage }`. Add `Notification` to the destructuring:

Change line 1 from:
```javascript
const { app, BrowserWindow, ipcMain, dialog, clipboard, nativeTheme, shell, Tray, Menu, nativeImage } = require('electron');
```
To:
```javascript
const { app, BrowserWindow, ipcMain, dialog, clipboard, nativeTheme, shell, Tray, Menu, nativeImage, Notification } = require('electron');
```

Then after `buildPipelineReport`, add:

```javascript
function sendManagerNotification(automation, summary) {
  if (mainWindow && mainWindow.isFocused()) return;
  const notif = new Notification({
    title: 'Automation Manager — ' + automation.name,
    body: (summary || '').substring(0, 100),
    icon: path.join(__dirname, 'icon.png')
  });
  notif.on('click', () => {
    if (mainWindow) {
      mainWindow.show();
      mainWindow.focus();
      mainWindow.webContents.send('automations:focus-manager', { automationId: automation.id });
    }
  });
  notif.show();
}
```

- [ ] **Step 2: Add runManager function**

After `sendManagerNotification`, add:

```javascript
async function runManager(automationId) {
  let data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation) return;
  if (!automation.manager || !automation.manager.enabled) return;
  if (runningManagers.has(automationId)) return;

  const manager = automation.manager;
  const cwd = automation.projectPath;
  if (!fs.existsSync(cwd)) return;

  // Build the prompt
  const pipelineReport = buildPipelineReport(automation, manager.includeFullOutput);
  const retriesUsed = managerRetryCounters.get(automationId) || 0;
  let prompt = MANAGER_PROMPT_TEMPLATE
    .replace('{name}', automation.name)
    .replace('{pipelineReport}', pipelineReport)
    .replace('{maxRetries}', String(manager.maxRetries || 1))
    .replace('{retriesUsed}', String(retriesUsed))
    .replace('{customPrompt}', manager.prompt || '');

  // Update state
  const freshData = readAutomations();
  const freshAuto = freshData.automations.find(a => a.id === automationId);
  if (freshAuto && freshAuto.manager) {
    freshAuto.manager.lastRunAt = new Date().toISOString();
    freshAuto.manager.lastRunStatus = 'running';
    freshAuto.manager.needsHuman = false;
    freshAuto.manager.humanContext = null;
    writeAutomations(freshData);
  }

  if (mainWindow) mainWindow.webContents.send('automations:manager-started', { automationId });

  const startedAt = new Date().toISOString();
  const textChunks = [];

  const args = ['--print', prompt, '--output-format', 'stream-json', '--verbose'];
  if (manager.skipPermissions) args.push('--dangerously-skip-permissions');

  // Database MCP config (same pattern as agents)
  let mcpConfigPath = null;
  if (manager.dbConnectionString) {
    const mcpArgs = ['-y', 'mongodb-mcp-server@latest'];
    if (manager.dbReadOnly !== false) mcpArgs.push('--readOnly');
    const mcpConfig = {
      mcpServers: {
        mongodb: {
          command: 'npx',
          args: mcpArgs,
          env: { MDB_MCP_CONNECTION_STRING: manager.dbConnectionString }
        }
      }
    };
    mcpConfigPath = path.join(AUTOMATIONS_RUNS_DIR, automationId + '_manager_mcp.json');
    fs.mkdirSync(path.dirname(mcpConfigPath), { recursive: true });
    fs.writeFileSync(mcpConfigPath, JSON.stringify(mcpConfig), 'utf8');
    args.push('--mcp-config', mcpConfigPath);

    if (manager.dbReadOnly !== false) {
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

  runningManagers.set(automationId, child);

  let streamBuffer = '';
  child.stdout.on('data', (chunk) => {
    const raw = chunk.toString();
    streamBuffer += raw;
    const lines = streamBuffer.split('\n');
    streamBuffer = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const evt = JSON.parse(line);
        let text = '';
        if (evt.type === 'assistant' && evt.message && evt.message.content) {
          evt.message.content.forEach(block => { if (block.type === 'text') text += block.text; });
        } else if (evt.type === 'content_block_delta' && evt.delta && evt.delta.type === 'text_delta') {
          text = evt.delta.text;
        } else if (evt.type === 'result' && evt.result) {
          if (typeof evt.result === 'string') text = evt.result;
          else if (Array.isArray(evt.result)) evt.result.forEach(block => { if (block.type === 'text') text += block.text; });
        }
        if (text) textChunks.push(text);
      } catch { /* skip */ }
    }
  });

  child.stderr.on('data', (chunk) => { textChunks.push(chunk.toString()); });

  child.on('close', (exitCode) => {
    runningManagers.delete(automationId);
    if (mcpConfigPath) try { fs.unlinkSync(mcpConfigPath); } catch { /* ignore */ }

    const completedAt = new Date().toISOString();
    const displayOutput = textChunks.join('');
    const parsed = parseManagerResult(displayOutput);

    // Save manager run history
    const managerRunDir = path.join(AUTOMATIONS_RUNS_DIR, automationId, '_manager');
    if (!fs.existsSync(managerRunDir)) fs.mkdirSync(managerRunDir, { recursive: true });
    const runFilename = new Date(startedAt).toISOString().replace(/[:.]/g, '-') + '.json';
    const runData = {
      startedAt, completedAt,
      durationMs: new Date(completedAt).getTime() - new Date(startedAt).getTime(),
      exitCode, status: exitCode === 0 ? 'completed' : 'error',
      summary: parsed.summary, output: displayOutput.substring(0, 50000),
      attentionItems: parsed.attentionItems, actions: parsed.actions,
      needsHuman: parsed.needsHuman, humanContext: parsed.humanContext
    };
    try { fs.writeFileSync(path.join(managerRunDir, runFilename), JSON.stringify(runData, null, 2), 'utf8'); } catch { /* ignore */ }

    // Execute actions
    let actionsExecuted = false;
    if (parsed.actions && parsed.actions.length > 0 && !parsed.needsHuman) {
      const currentRetries = managerRetryCounters.get(automationId) || 0;
      const maxRetries = (automation.manager && automation.manager.maxRetries) || 1;

      parsed.actions.forEach(action => {
        if (action.type === 'rerun_agent' && action.agentId) {
          if (currentRetries < maxRetries) {
            managerRetryCounters.set(automationId, currentRetries + 1);
            runAgent(automationId, action.agentId);
            actionsExecuted = true;
          } else {
            // Exceeded retries — escalate
            parsed.needsHuman = true;
            parsed.humanContext = (parsed.humanContext || '') + '\nMax retries (' + maxRetries + ') reached for agent re-runs. Manual intervention needed.';
          }
        } else if (action.type === 'rerun_all') {
          if (currentRetries < maxRetries) {
            managerRetryCounters.set(automationId, currentRetries + 1);
            const freshD = readAutomations();
            const freshA = freshD.automations.find(a => a.id === automationId);
            if (freshA) {
              freshA.agents.forEach(ag => {
                if (ag.enabled && ag.runMode === 'independent') runAgent(automationId, ag.id);
              });
            }
            actionsExecuted = true;
          } else {
            parsed.needsHuman = true;
            parsed.humanContext = (parsed.humanContext || '') + '\nMax retries (' + maxRetries + ') reached. Manual intervention needed.';
          }
        }
      });
    }

    // Update manager state
    const finalData = readAutomations();
    const finalAuto = finalData.automations.find(a => a.id === automationId);
    if (finalAuto && finalAuto.manager) {
      finalAuto.manager.lastRunAt = completedAt;
      finalAuto.manager.lastSummary = parsed.summary || null;

      if (exitCode !== 0) {
        finalAuto.manager.lastRunStatus = 'error';
        finalAuto.manager.needsHuman = true;
        finalAuto.manager.humanContext = 'Manager process exited with code ' + exitCode;
      } else if (parsed.needsHuman) {
        finalAuto.manager.lastRunStatus = 'escalated';
        finalAuto.manager.needsHuman = true;
        finalAuto.manager.humanContext = parsed.humanContext;
      } else if (actionsExecuted) {
        finalAuto.manager.lastRunStatus = 'acted';
        // Don't clear retry counter — it resets on next fresh pipeline trigger
      } else {
        finalAuto.manager.lastRunStatus = 'resolved';
        managerRetryCounters.delete(automationId);
      }
      writeAutomations(finalData);
    }

    // Notify renderer
    if (mainWindow) {
      mainWindow.webContents.send('automations:manager-completed', {
        automationId,
        status: finalAuto ? finalAuto.manager.lastRunStatus : 'error',
        summary: parsed.summary,
        needsHuman: parsed.needsHuman,
        humanContext: parsed.humanContext,
        actions: parsed.actions
      });

      // Windows notification + flash if needs human
      if (parsed.needsHuman) {
        mainWindow.flashFrame(true);
        sendManagerNotification(automation, parsed.summary);
      }
    }
  });

  child.on('error', (err) => {
    runningManagers.delete(automationId);
    if (mcpConfigPath) try { fs.unlinkSync(mcpConfigPath); } catch { /* ignore */ }
    const errData = readAutomations();
    const errAuto = errData.automations.find(a => a.id === automationId);
    if (errAuto && errAuto.manager) {
      errAuto.manager.lastRunStatus = 'error';
      errAuto.manager.needsHuman = true;
      errAuto.manager.humanContext = 'Manager failed to start: ' + err.message;
      writeAutomations(errData);
    }
    if (mainWindow) {
      mainWindow.webContents.send('automations:manager-completed', {
        automationId, status: 'error', needsHuman: true, summary: err.message
      });
      mainWindow.flashFrame(true);
      sendManagerNotification(automation, 'Manager failed: ' + err.message);
    }
  });
}
```

- [ ] **Step 3: Verify syntax and commit**

```bash
node -c main.js
git add main.js
git commit -m "feat: add runManager execution engine with notification and action handling"
```

---

### Task 3: Add pipeline completion detection and manager IPC handlers

**Files:**
- Modify: `main.js` (add `checkPipelineComplete` after `runManager`, add IPC handlers, update `runAgent` close handler, update `stopAutomationScheduler`)

- [ ] **Step 1: Add checkPipelineComplete function**

After `runManager`, add:

```javascript
const pipelineCompleteTimers = {};

function checkPipelineComplete(automationId) {
  clearTimeout(pipelineCompleteTimers[automationId]);
  pipelineCompleteTimers[automationId] = setTimeout(() => {
    const data = readAutomations();
    const automation = data.automations.find(a => a.id === automationId);
    if (!automation) return;
    if (!automation.manager || !automation.manager.enabled) return;
    if (runningManagers.has(automationId)) return;

    // Check all agents are in terminal state
    const allDone = automation.agents.every(ag => !ag.currentRunStartedAt);
    const anyRan = automation.agents.some(ag => ag.lastRunStatus);
    if (!allDone || !anyRan) return;

    const anyFailed = automation.agents.some(ag =>
      ag.lastRunStatus === 'error' || ag.lastRunStatus === 'skipped'
    );

    if (automation.manager.triggerOn === 'always' ||
        (automation.manager.triggerOn === 'failure' && anyFailed)) {
      runManager(automationId);
    }
  }, 2000);
}
```

- [ ] **Step 2: Wire checkPipelineComplete into runAgent's close handler**

Find the line `triggerDependentAgents(automationId, agentId, runData.status, freshData);` in the `runAgent` close handler (around line 2011). Add immediately after it:

```javascript
      // Check if pipeline is fully complete — trigger manager if configured
      checkPipelineComplete(automationId);
```

- [ ] **Step 3: Add manager IPC handlers**

After the existing `automations:updateSettings` handler (~line 1672), add:

```javascript
ipcMain.handle('automations:runManager', (event, automationId) => {
  managerRetryCounters.delete(automationId); // Reset retries for manual trigger
  runManager(automationId);
  return true;
});

ipcMain.handle('automations:dismissManager', (event, automationId) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation || !automation.manager) return false;
  automation.manager.needsHuman = false;
  automation.manager.humanContext = null;
  writeAutomations(data);
  if (mainWindow) mainWindow.webContents.send('automations:manager-completed', {
    automationId, status: 'dismissed', needsHuman: false
  });
  return true;
});

ipcMain.handle('automations:getManagerStatus', (event, automationId) => {
  const data = readAutomations();
  const automation = data.automations.find(a => a.id === automationId);
  if (!automation || !automation.manager) return { enabled: false };
  return {
    enabled: automation.manager.enabled,
    lastRunStatus: automation.manager.lastRunStatus,
    lastSummary: automation.manager.lastSummary,
    needsHuman: automation.manager.needsHuman,
    humanContext: automation.manager.humanContext,
    running: runningManagers.has(automationId)
  };
});
```

- [ ] **Step 4: Update automations:update safe fields**

Find the `automations:update` handler (line ~1216). Change the `safeFields` array from:
```javascript
  const safeFields = ['name', 'enabled'];
```
To:
```javascript
  const safeFields = ['name', 'enabled', 'manager'];
```

- [ ] **Step 5: Update stopAutomationScheduler to kill running managers**

In `stopAutomationScheduler()` (~line 2205), after the `runningAgents` cleanup, add:

```javascript
  // Kill running managers
  runningManagers.forEach((child) => {
    try { child.kill(); } catch { /* ignore */ }
  });
  runningManagers.clear();
```

- [ ] **Step 6: Verify syntax and commit**

```bash
node -c main.js
git add main.js
git commit -m "feat: add pipeline completion detection and manager IPC handlers"
```

---

## Phase 2: Preload API

### Task 4: Add manager preload methods

**Files:**
- Modify: `preload.js` (add after existing automations section)

- [ ] **Step 1: Add manager API methods**

After the `onCloneProgress` line (~line 97), add:

```javascript
  runManager: (automationId) => ipcRenderer.invoke('automations:runManager', automationId),
  dismissManager: (automationId) => ipcRenderer.invoke('automations:dismissManager', automationId),
  getManagerStatus: (automationId) => ipcRenderer.invoke('automations:getManagerStatus', automationId),
  onManagerStarted: (callback) => ipcRenderer.on('automations:manager-started', (_, data) => callback(data)),
  onManagerCompleted: (callback) => ipcRenderer.on('automations:manager-completed', (_, data) => callback(data)),
  onFocusManager: (callback) => ipcRenderer.on('automations:focus-manager', (_, data) => callback(data)),
```

Note: ensure the previous line (`onCloneProgress`) has a trailing comma.

- [ ] **Step 2: Verify syntax and commit**

```bash
node -c preload.js
git add preload.js
git commit -m "feat: add manager preload API methods"
```

---

## Phase 3: UI — Modal Manager Section

### Task 5: Add manager section to HTML and modal logic

**Files:**
- Modify: `index.html` (~line 369, after the add-agent row, before setup panel)
- Modify: `renderer.js` (modal section — `openAutomationModal`, `saveAutomation`, `closeAutomationModal`)

- [ ] **Step 1: Add manager section HTML**

In `index.html`, after the `automation-add-agent-row` div (line 369) and before the `automation-setup-panel` div (line 372), add:

```html
          <!-- Manager configuration -->
          <div id="automation-manager-section" class="automation-manager-section" style="display:none;">
            <div class="automation-manager-header">
              <label class="automation-permission-option">
                <input type="checkbox" id="automation-manager-enabled">
                <span class="automation-manager-title">Automation Manager</span>
              </label>
            </div>
            <div id="automation-manager-fields" style="display:none;">
              <div class="automation-form-group">
                <label>Manager Prompt <span class="automation-permission-hint">(optional — appended to investigation instructions)</span></label>
                <textarea id="automation-manager-prompt" class="automation-textarea" rows="3" placeholder="Additional instructions for the manager..." spellcheck="false"></textarea>
              </div>
              <div class="automation-form-group automation-manager-row">
                <div>
                  <label>Trigger</label>
                  <select id="automation-manager-trigger">
                    <option value="failure">On failure</option>
                    <option value="always">Always</option>
                    <option value="manual">Manual only</option>
                  </select>
                </div>
                <div>
                  <label>Max retries</label>
                  <input type="number" id="automation-manager-retries" min="0" max="5" value="1" style="width:50px;">
                </div>
              </div>
              <div class="automation-form-group">
                <label class="automation-permission-option">
                  <input type="checkbox" id="automation-manager-full-output">
                  <span>Include full agent output <span class="automation-permission-hint">(increases cost)</span></span>
                </label>
              </div>
              <div class="automation-form-group">
                <label>Database <span class="automation-permission-hint">(optional)</span></label>
                <input type="password" id="automation-manager-db" class="automation-input" placeholder="mongodb+srv://..." spellcheck="false" autocomplete="off">
                <div class="automation-permissions" style="margin-top:6px;">
                  <label class="automation-permission-option"><input type="checkbox" id="automation-manager-db-readonly" checked><span>Read-only</span></label>
                </div>
              </div>
              <div class="automation-form-group">
                <label>Permissions</label>
                <div class="automation-permissions">
                  <label class="automation-permission-option"><input type="checkbox" id="automation-manager-skip-permissions"><span>Skip permissions</span></label>
                </div>
              </div>
            </div>
          </div>
```

- [ ] **Step 2: Add manager modal logic in renderer.js**

In `openAutomationModal()`, after `renderModalAgentCards();` and before `document.getElementById('automation-modal-overlay').classList.remove('hidden');`, add:

```javascript
  // Manager section — only show for multi-agent
  var managerSection = document.getElementById('automation-manager-section');
  var managerEnabled = document.getElementById('automation-manager-enabled');
  var managerFields = document.getElementById('automation-manager-fields');
  if (isMulti) {
    managerSection.style.display = '';
    var mgr = existingAutomation && existingAutomation.manager ? existingAutomation.manager : {};
    managerEnabled.checked = mgr.enabled || false;
    managerFields.style.display = mgr.enabled ? '' : 'none';
    document.getElementById('automation-manager-prompt').value = mgr.prompt || '';
    document.getElementById('automation-manager-trigger').value = mgr.triggerOn || 'failure';
    document.getElementById('automation-manager-retries').value = mgr.maxRetries || 1;
    document.getElementById('automation-manager-full-output').checked = mgr.includeFullOutput || false;
    document.getElementById('automation-manager-db').value = mgr.dbConnectionString || '';
    document.getElementById('automation-manager-db-readonly').checked = mgr.dbReadOnly !== false;
    document.getElementById('automation-manager-skip-permissions').checked = mgr.skipPermissions || false;
  } else {
    managerSection.style.display = 'none';
  }
```

- [ ] **Step 3: Add manager checkbox toggle handler**

Near the other modal button bindings (after `btn-add-agent` handler), add:

```javascript
document.getElementById('automation-manager-enabled').addEventListener('change', function () {
  document.getElementById('automation-manager-fields').style.display = this.checked ? '' : 'none';
});
// Stop keyboard events from propagating in manager fields
['automation-manager-prompt', 'automation-manager-db', 'automation-manager-retries'].forEach(function (id) {
  document.getElementById(id).addEventListener('keydown', function (e) { e.stopPropagation(); });
});
```

- [ ] **Step 4: Update saveAutomation to include manager config**

In `saveAutomation()`, after building the `agents` array and before the `if (automationEditingId)` check, add:

```javascript
  // Build manager config
  var managerConfig = null;
  if (modalAgents.length > 1 && document.getElementById('automation-manager-enabled').checked) {
    managerConfig = {
      enabled: true,
      prompt: document.getElementById('automation-manager-prompt').value.trim(),
      triggerOn: document.getElementById('automation-manager-trigger').value,
      includeFullOutput: document.getElementById('automation-manager-full-output').checked,
      skipPermissions: document.getElementById('automation-manager-skip-permissions').checked,
      dbConnectionString: document.getElementById('automation-manager-db').value.trim() || null,
      dbReadOnly: document.getElementById('automation-manager-db-readonly').checked,
      maxRetries: parseInt(document.getElementById('automation-manager-retries').value) || 1,
      lastRunAt: null,
      lastRunStatus: null,
      lastSummary: null,
      needsHuman: false,
      humanContext: null
    };
  }
```

Then in the create path, add `manager` to the config object. Find:
```javascript
    var config = {
      name: automationName,
      projectPath: activeProjectKey,
      agents: agents
    };
```
Change to:
```javascript
    var config = {
      name: automationName,
      projectPath: activeProjectKey,
      agents: agents,
      manager: managerConfig
    };
```

And in the edit path, after `updateAutomation` call, add manager update. Find the `.then(function () {` after `updateAutomation` and add before the agents update:
```javascript
      return window.electronAPI.updateAutomation(automationEditingId, { name: automationName, manager: managerConfig });
```
(Replace the existing `updateAutomation` call that only sends `{ name: automationName }`.)

- [ ] **Step 5: Update closeAutomationModal to hide manager section**

In `closeAutomationModal()`, add:
```javascript
  document.getElementById('automation-manager-section').style.display = 'none';
  document.getElementById('automation-manager-fields').style.display = 'none';
```

- [ ] **Step 6: Show manager section when transitioning to multi-agent mode**

In the `btn-add-agent` click handler, after `renderModalAgentCards();`, add:
```javascript
  document.getElementById('automation-manager-section').style.display = '';
```

- [ ] **Step 7: Verify syntax and commit**

```bash
node -c renderer.js
git add index.html renderer.js
git commit -m "feat: add manager configuration section to automation modal"
```

---

## Phase 4: UI — Pipeline Detail Manager Status

### Task 6: Add manager status to pipeline detail view

**Files:**
- Modify: `renderer.js` (`renderMultiAgentDetail` function)

- [ ] **Step 1: Add manager status button to pipeline detail**

In `renderMultiAgentDetail()`, after the Run All and Pause buttons are added to `metaEl`, add manager status:

Find the `metaEl.innerHTML = ...` assignment. Replace it with:

```javascript
  var managerHtml = '';
  if (automation.manager && automation.manager.enabled) {
    var mgrStatus = automation.manager.lastRunStatus || 'idle';
    var mgrRunning = false; // Will be updated async
    if (automation.manager.needsHuman) {
      managerHtml = '<button class="automation-detail-manager-btn needs-you" title="Manager needs your attention">Needs You &#9888;</button>';
    } else if (mgrStatus === 'resolved') {
      managerHtml = '<button class="automation-detail-manager-btn resolved" title="' + escapeHtml(automation.manager.lastSummary || 'Resolved') + '">Manager: resolved &#10003;</button>';
    } else if (mgrStatus === 'acted') {
      managerHtml = '<button class="automation-detail-manager-btn acted" title="Manager took action">Manager: acted</button>';
    } else if (mgrStatus === 'running') {
      managerHtml = '<button class="automation-detail-manager-btn running" title="Manager is investigating">Manager: investigating...</button>';
    } else {
      managerHtml = '<button class="automation-detail-manager-btn idle" title="Run manager manually">Manager</button>';
    }
  }

  metaEl.innerHTML = '<button class="automation-detail-run-all" title="Run All">&#9655; Run All</button>' +
    '<button class="automation-detail-pause-all" title="Pause">&#10074;&#10074; Pause</button>' +
    managerHtml;
```

- [ ] **Step 2: Add manager button event handler**

After the existing `metaEl.querySelector('.automation-detail-pause-all').addEventListener(...)` block, add:

```javascript
  var mgrBtn = metaEl.querySelector('.automation-detail-manager-btn');
  if (mgrBtn) {
    mgrBtn.addEventListener('click', function () {
      if (automation.manager.needsHuman) {
        // Spawn interactive terminal with manager context
        launchManagerTerminal(automation);
      } else {
        // Manual trigger or show summary
        if (automation.manager.lastRunStatus === 'resolved' || automation.manager.lastRunStatus === 'acted') {
          alert('Manager summary: ' + (automation.manager.lastSummary || 'No details'));
        } else {
          window.electronAPI.runManager(automation.id);
        }
      }
    });
  }
```

- [ ] **Step 3: Add launchManagerTerminal function**

After `renderMultiAgentDetail`, add:

```javascript
var managerTerminals = {}; // automationId -> column element id

function launchManagerTerminal(automation) {
  if (!automation.manager) return;

  // Build context for the interactive terminal
  var context = 'You are the Automation Manager for "' + automation.name + '".\n\n';
  context += 'PIPELINE STATUS:\n';
  automation.agents.forEach(function (ag) {
    context += '- ' + ag.name + ': ' + (ag.lastRunStatus || 'not run') +
      (ag.lastSummary ? ' — ' + ag.lastSummary : '') + '\n';
  });
  if (automation.manager.humanContext) {
    context += '\nMANAGER INVESTIGATION FINDINGS:\n' + automation.manager.humanContext + '\n';
  }
  context += '\nThe user is here to help. Explain what you need and work together to resolve the issue.';
  context += '\nTo re-run agents, ask the user to use the Re-run buttons above this terminal.';

  var spawnArgs = buildSpawnArgs();
  if (automation.manager.skipPermissions && spawnArgs.indexOf('--dangerously-skip-permissions') === -1) {
    spawnArgs.push('--dangerously-skip-permissions');
  }
  spawnArgs.push('--append-system-prompt', context);

  var colId = addColumn(spawnArgs, null, { title: automation.name + ' Manager' });
  if (colId) managerTerminals[automation.id] = colId;

  // Dismiss the needs-human state
  window.electronAPI.dismissManager(automation.id);
  refreshAutomations();
}
```

- [ ] **Step 4: Verify syntax and commit**

```bash
node -c renderer.js
git add renderer.js
git commit -m "feat: add manager status button and interactive terminal launch to pipeline view"
```

---

### Task 7: Add manager event listeners and focus handler

**Files:**
- Modify: `renderer.js` (event listeners section)

- [ ] **Step 1: Add manager event listeners**

After the `onAgentCompleted` handler (~line 6870), add:

```javascript
window.electronAPI.onManagerStarted(function (data) {
  refreshAutomations();
  refreshAutomationsFlyout();
  if (activeAutomationDetailId === data.automationId && activeDetailAutomation) {
    window.electronAPI.getAutomationsForProject(activeProjectKey).then(function (automations) {
      var auto = automations.find(function (a) { return a.id === data.automationId; });
      if (auto) { activeDetailAutomation = auto; renderMultiAgentDetail(auto); }
    });
  }
});

window.electronAPI.onManagerCompleted(function (data) {
  refreshAutomations();
  refreshAutomationsFlyout();
  updateAutomationSidebarBadges();
  if (activeAutomationDetailId === data.automationId && activeDetailAutomation) {
    window.electronAPI.getAutomationsForProject(activeProjectKey).then(function (automations) {
      var auto = automations.find(function (a) { return a.id === data.automationId; });
      if (auto) { activeDetailAutomation = auto; renderMultiAgentDetail(auto); }
    });
  }
});

window.electronAPI.onFocusManager(function (data) {
  // Focus the automations tab and open the automation's detail
  var tab = document.querySelector('.explorer-tab[data-tab="automations"]');
  if (tab) tab.click();
  window.electronAPI.getAutomationsForProject(activeProjectKey).then(function (automations) {
    var auto = automations.find(function (a) { return a.id === data.automationId; });
    if (auto) openAutomationDetail(auto);
  });
});
```

- [ ] **Step 2: Update sidebar badges to show manager needsHuman**

In `updateAutomationSidebarBadges()`, find the condition that adds projects to `projectsWithAttention`. Change from:

```javascript
        if (ag.lastRunStatus === 'error' || ag.lastError) {
```

To also check manager:

```javascript
        if (ag.lastRunStatus === 'error' || ag.lastError) {
          projectsWithAttention.add(auto.projectPath.replace(/\\/g, '/'));
        }
```

After the `auto.agents.forEach` loop (but still inside the `data.automations.forEach`), add:

```javascript
      if (auto.manager && auto.manager.needsHuman) {
        projectsWithAttention.add(auto.projectPath.replace(/\\/g, '/'));
      }
```

- [ ] **Step 3: Update flyout to show manager status**

In `refreshAutomationsFlyout()`, in the section where `statusText` and `statusColor` are determined for each row, after the `anyError` check, add a manager check:

After:
```javascript
        else if (anyError) { statusText = '\u2717 error'; statusColor = '#ef4444'; }
```
Add:
```javascript
        else if (auto.manager && auto.manager.needsHuman) { statusText = '\u26a0 needs you'; statusColor = '#f59e0b'; }
```

- [ ] **Step 4: Verify syntax and commit**

```bash
node -c renderer.js
git add renderer.js
git commit -m "feat: add manager event listeners, focus handler, and flyout/sidebar indicators"
```

---

## Phase 5: CSS

### Task 8: Add manager CSS styles

**Files:**
- Modify: `styles.css` (add after existing pipeline styles)

- [ ] **Step 1: Add manager section styles**

After the existing pipeline/settings CSS at the end of the automations block, add:

```css
/* Manager Section (Modal) */
.automation-manager-section {
  border-top: 1px solid var(--border-primary);
  padding-top: 12px;
  margin-top: 8px;
}

.automation-manager-header {
  margin-bottom: 8px;
}

.automation-manager-title {
  font-weight: 600;
  font-size: 13px;
}

.automation-manager-row {
  display: flex;
  gap: 16px;
}

.automation-manager-row > div {
  flex: 1;
}

.automation-manager-row select,
.automation-manager-row input[type="number"] {
  background: var(--bg-main);
  border: 1px solid var(--border-primary);
  color: var(--text-primary);
  padding: 4px 8px;
  border-radius: 4px;
  font-size: 12px;
  width: 100%;
}

/* Manager Status Button (Detail View) */
.automation-detail-manager-btn {
  background: rgba(255,255,255,0.06);
  border: 1px solid #444;
  color: #ccc;
  padding: 3px 10px;
  border-radius: 4px;
  font-size: 12px;
  cursor: pointer;
  margin-left: auto;
}

.automation-detail-manager-btn.needs-you {
  border-color: #f59e0b;
  color: #f59e0b;
  animation: manager-pulse 1.5s infinite;
}

.automation-detail-manager-btn.running {
  border-color: #3b82f6;
  color: #3b82f6;
  animation: manager-pulse 1.5s infinite;
}

.automation-detail-manager-btn.resolved {
  border-color: #22c55e;
  color: #22c55e;
}

.automation-detail-manager-btn.acted {
  border-color: #8b5cf6;
  color: #8b5cf6;
}

.automation-detail-manager-btn:hover {
  background: rgba(255,255,255,0.1);
}

@keyframes manager-pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.6; }
}
```

- [ ] **Step 2: Verify and commit**

```bash
git add styles.css
git commit -m "feat: add manager CSS styles for modal and detail view"
```

---

## Phase 6: Integration & Verification

### Task 9: End-to-end verification

- [ ] **Step 1: Verify syntax across all files**

```bash
node -c main.js && node -c preload.js && node -c renderer.js
```

- [ ] **Step 2: Test manager configuration in modal**

1. Open automation modal for a multi-agent automation
2. Verify "Automation Manager" section appears
3. Check the checkbox — fields should appear
4. Fill in prompt, set trigger to "On failure"
5. Save — verify manager config is stored in automations.json

- [ ] **Step 3: Test manager auto-trigger**

1. Create an automation with a manager (trigger: always)
2. Run the automation
3. After all agents complete, verify manager starts automatically (2s delay)
4. Check console for manager execution output

- [ ] **Step 4: Test manager needsHuman flow**

1. Create an automation where an agent will fail
2. Configure manager with trigger: on failure
3. Run the automation
4. After failure, manager should run, investigate, and (likely) set needsHuman
5. Verify Windows notification appears
6. Verify "Needs You" badge in pipeline detail
7. Click badge — verify interactive terminal spawns with context

- [ ] **Step 5: Test notification click focus**

1. Minimize the app
2. Trigger a manager that escalates
3. Click the Windows notification
4. Verify app restores and navigates to the automation's detail view

- [ ] **Step 6: Commit final state**

```bash
git add -A
git commit -m "feat: complete automation manager agent implementation"
```
