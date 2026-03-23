# Launch Configurations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated launch configuration panel with auto-discovery, config editing, environment profiles, and typed presets so users can run .NET, Node, Python, and custom commands from within Claudes.

**Architecture:** The existing 3-file architecture (main.js, preload.js, renderer.js) is preserved. main.js handles config discovery/persistence via IPC, preload.js exposes new channels, and renderer.js builds the config list + editor UI in the existing Run tab area. No new files are created.

**Tech Stack:** Electron IPC, node-pty (via pty-server.js), xterm.js, vanilla JS DOM manipulation

**Spec:** `docs/superpowers/specs/2026-03-23-launch-configurations-design.md`

---

### Task 1: Enhanced .csproj scanning and dotnet-run type in main.js

**Files:**
- Modify: `main.js:522-567` (findLaunchSettingsConfigs + launch:getConfigs handler)

This task fixes the core .NET bug and lays the foundation for the new IPC contract.

- [ ] **Step 1: Update findLaunchSettingsConfigs to scan for .csproj files**

In `main.js`, replace the `findLaunchSettingsConfigs` function (lines 522-554) with:

```javascript
function findLaunchSettingsConfigs(projectPath) {
  const configs = [];
  function scanDir(dir) {
    try {
      const entries = fs.readdirSync(dir, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isDirectory() || entry.name.startsWith('.') || entry.name === 'node_modules' || entry.name === 'bin' || entry.name === 'obj') continue;
        const subDir = path.join(dir, entry.name);
        const lsPath = path.join(subDir, 'Properties', 'launchSettings.json');
        try {
          const data = JSON.parse(fs.readFileSync(lsPath, 'utf8'));
          if (!data.profiles) continue;
          // Scan for .csproj files in this directory
          const csprojFiles = [];
          try {
            const dirEntries = fs.readdirSync(subDir);
            for (const f of dirEntries) {
              if (f.endsWith('.csproj')) csprojFiles.push(f);
            }
          } catch { /* can't read dir */ }
          // If no .csproj found, fall back to directory name
          if (csprojFiles.length === 0) csprojFiles.push(null);
          for (const [profileName, profile] of Object.entries(data.profiles)) {
            if (profile.commandName === 'IISExpress') continue;
            for (const csproj of csprojFiles) {
              const name = csprojFiles.length > 1 && csproj
                ? profileName + ' (' + csproj + ')'
                : profileName;
              configs.push({
                name: name,
                type: 'dotnet-run',
                project: csproj ? path.join(subDir, csproj) : null,
                cwd: subDir,
                env: profile.environmentVariables || {},
                applicationUrl: profile.applicationUrl || '',
                commandLineArgs: profile.commandLineArgs || '',
                _source: 'launchSettings',
                _readonly: true
              });
            }
          }
        } catch { /* no launchSettings here, scan children */ }
        if (dir === projectPath) scanDir(subDir);
      }
    } catch { /* can't read dir */ }
  }
  scanDir(projectPath);
  return configs;
}
```

- [ ] **Step 2: Update launch:getConfigs to return new shape with custom configs and env profiles**

Replace the `launch:getConfigs` handler (lines 556-567) with:

```javascript
ipcMain.handle('launch:getConfigs', (event, projectPath) => {
  let configs = [];
  // VS Code launch.json
  const launchPath = path.join(projectPath, '.vscode', 'launch.json');
  try {
    const data = parseJsonc(launchPath);
    const vsConfigs = (data.configurations || []).map(c => Object.assign({}, c, { _source: 'launch.json', _readonly: true }));
    configs = configs.concat(vsConfigs);
  } catch { /* no launch.json or parse error */ }
  // .NET launchSettings.json
  configs = configs.concat(findLaunchSettingsConfigs(projectPath));
  // Custom configs from .claudes/launch.json
  const customPath = path.join(projectPath, '.claudes', 'launch.json');
  try {
    const customData = JSON.parse(fs.readFileSync(customPath, 'utf8'));
    const customConfigs = (customData.configurations || []).map(c => Object.assign({}, c, { _source: 'custom', _readonly: false }));
    configs = configs.concat(customConfigs);
  } catch { /* no custom config or parse error */ }
  // Env profiles from .claudes/env-profiles.json
  let envProfiles = {};
  const profilesPath = path.join(projectPath, '.claudes', 'env-profiles.json');
  try {
    envProfiles = JSON.parse(fs.readFileSync(profilesPath, 'utf8'));
  } catch { /* no profiles or parse error */ }
  return { configs, envProfiles };
});
```

- [ ] **Step 3: Add new IPC handlers for saving configs, profiles, scanning, browsing, and .env parsing**

Add after the `launch:getConfigs` handler:

```javascript
ipcMain.handle('launch:saveConfigs', (event, projectPath, configurations) => {
  const dirPath = path.join(projectPath, '.claudes');
  try { fs.mkdirSync(dirPath, { recursive: true }); } catch { /* exists */ }
  fs.writeFileSync(path.join(dirPath, 'launch.json'), JSON.stringify({ configurations }, null, 2), 'utf8');
});

ipcMain.handle('launch:saveEnvProfiles', (event, projectPath, profiles) => {
  const dirPath = path.join(projectPath, '.claudes');
  try { fs.mkdirSync(dirPath, { recursive: true }); } catch { /* exists */ }
  fs.writeFileSync(path.join(dirPath, 'env-profiles.json'), JSON.stringify(profiles, null, 2), 'utf8');
});

ipcMain.handle('launch:scanCsproj', (event, dirPath) => {
  try {
    return fs.readdirSync(dirPath).filter(f => f.endsWith('.csproj'));
  } catch { return []; }
});

ipcMain.handle('launch:browseFile', async (event, filters) => {
  const result = await dialog.showOpenDialog(mainWindow, {
    properties: ['openFile'],
    filters: filters || []
  });
  if (result.canceled || result.filePaths.length === 0) return null;
  return result.filePaths[0];
});

ipcMain.handle('launch:readEnvFile', (event, filePath) => {
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    const env = {};
    for (const line of content.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx === -1) continue;
      const key = trimmed.substring(0, eqIdx).trim();
      let val = trimmed.substring(eqIdx + 1).trim();
      // Strip surrounding quotes
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1);
      }
      env[key] = val;
    }
    return env;
  } catch { return {}; }
});
```

- [ ] **Step 4: Verify main.js loads without errors**

Run: `node -e "try { require('./main.js'); } catch(e) { console.log('Parse check...'); }" 2>&1 | head -5`

This won't fully run (needs Electron), but catches syntax errors.

- [ ] **Step 5: Commit**

```bash
git add main.js
git commit -m "feat: enhance launch config discovery with csproj scanning, custom configs, env profiles"
```

---

### Task 2: Expose new IPC channels in preload.js

**Files:**
- Modify: `preload.js:35` (add new API methods after getLaunchConfigs)

- [ ] **Step 1: Add new IPC bridge methods**

In `preload.js`, replace line 35:

```javascript
  getLaunchConfigs: (projectPath) => ipcRenderer.invoke('launch:getConfigs', projectPath),
```

with:

```javascript
  getLaunchConfigs: (projectPath) => ipcRenderer.invoke('launch:getConfigs', projectPath),
  saveLaunchConfigs: (projectPath, configs) => ipcRenderer.invoke('launch:saveConfigs', projectPath, configs),
  saveEnvProfiles: (projectPath, profiles) => ipcRenderer.invoke('launch:saveEnvProfiles', projectPath, profiles),
  scanCsproj: (dirPath) => ipcRenderer.invoke('launch:scanCsproj', dirPath),
  browseFile: (filters) => ipcRenderer.invoke('launch:browseFile', filters),
  readEnvFile: (filePath) => ipcRenderer.invoke('launch:readEnvFile', filePath),
```

- [ ] **Step 2: Commit**

```bash
git add preload.js
git commit -m "feat: expose launch config IPC channels in preload"
```

---

### Task 3: Update Run tab HTML structure

**Files:**
- Modify: `index.html:46-52` (replace run tab content)

- [ ] **Step 1: Replace the run tab HTML**

In `index.html`, replace lines 46-52 (the `<div id="tab-run">` block) with:

```html
        <div id="tab-run" class="tab-content">
          <div id="run-list-view">
            <div class="explorer-section-header">
              <span>LAUNCH CONFIGURATIONS</span>
              <div style="display:flex;gap:4px;">
                <button class="explorer-refresh" id="btn-add-run-config" title="Add Configuration">+</button>
                <button class="explorer-refresh" id="btn-refresh-run" title="Refresh">&#8635;</button>
              </div>
            </div>
            <div id="run-configs"></div>
          </div>
          <div id="run-editor-view" class="hidden">
            <div class="run-editor-header">
              <button id="btn-run-editor-back" class="run-editor-back" title="Back">&larr;</button>
              <span id="run-editor-title">New Configuration</span>
            </div>
            <div id="run-editor-form" class="run-editor-form"></div>
            <div class="run-editor-footer">
              <button id="btn-run-save" class="run-editor-btn run-editor-save">Save</button>
              <button id="btn-run-cancel" class="run-editor-btn">Cancel</button>
              <button id="btn-run-delete" class="run-editor-btn run-editor-delete">Delete</button>
            </div>
          </div>
          <div id="run-profiles-view" class="hidden">
            <div class="run-editor-header">
              <button id="btn-profiles-back" class="run-editor-back" title="Back">&larr;</button>
              <span>Environment Profiles</span>
            </div>
            <div id="run-profiles-list"></div>
            <div id="run-profile-editor"></div>
          </div>
        </div>
```

- [ ] **Step 2: Commit**

```bash
git add index.html
git commit -m "feat: add run tab HTML structure for config list, editor, and profile manager"
```

---

### Task 4: Add CSS styles for launch configuration panel

**Files:**
- Modify: `styles.css` (add after existing run config styles at ~line 1821)

- [ ] **Step 1: Add styles for the config list, editor, and profile manager**

In `styles.css`, find the end of the existing run config styles (after `.run-config-type` block, around line 1821) and add:

```css
/* Launch Config - Source Groups */

.run-source-group {
  margin-bottom: 4px;
}

.run-source-header {
  display: flex;
  align-items: center;
  padding: 4px 12px;
  font-size: 10px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: var(--text-dimmer);
  cursor: pointer;
  user-select: none;
}

.run-source-header:hover {
  background: var(--hover-subtle);
}

.run-source-arrow {
  width: 14px;
  font-size: 10px;
  flex-shrink: 0;
  transition: transform 0.1s;
}

.run-source-arrow.expanded {
  transform: rotate(90deg);
}

.run-source-items.collapsed {
  display: none;
}

.run-config-actions {
  display: flex;
  gap: 2px;
  flex-shrink: 0;
  opacity: 0;
  transition: opacity 0.1s;
}

.run-config-item:hover .run-config-actions {
  opacity: 1;
}

.run-config-action-btn {
  background: none;
  border: none;
  color: var(--text-dimmer);
  font-size: 12px;
  cursor: pointer;
  padding: 2px 4px;
  border-radius: 3px;
}

.run-config-action-btn:hover {
  background: var(--hover-intense);
  color: var(--text-primary);
}

.run-config-badge {
  font-size: 9px;
  padding: 1px 4px;
  border-radius: 3px;
  background: var(--hover-subtle);
  color: var(--text-dimmer);
  flex-shrink: 0;
}

.run-config-badge.warning {
  background: var(--hover-yellow, rgba(255,200,0,0.15));
  color: var(--color-yellow, #e2b93d);
}

/* Launch Config - Editor & Profiles Views */

#tab-run.active {
  display: flex;
  flex-direction: column;
}

#run-list-view,
#run-editor-view,
#run-profiles-view {
  display: flex;
  flex-direction: column;
  flex: 1;
  overflow: hidden;
}

#run-editor-view.hidden,
#run-profiles-view.hidden {
  display: none;
}

.run-editor-header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 12px;
  border-bottom: 1px solid var(--border-subtle);
  font-size: 12px;
  font-weight: 600;
  color: var(--text-primary);
}

.run-editor-back {
  background: none;
  border: none;
  color: var(--text-secondary);
  font-size: 16px;
  cursor: pointer;
  padding: 2px 4px;
  border-radius: 3px;
}

.run-editor-back:hover {
  background: var(--hover-intense);
  color: var(--text-primary);
}

.run-editor-form {
  padding: 8px 12px;
  overflow-y: auto;
  flex: 1;
}

.run-editor-section {
  margin-bottom: 12px;
}

.run-editor-section-header {
  font-size: 10px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: var(--text-dimmer);
  margin-bottom: 6px;
  cursor: pointer;
  user-select: none;
  display: flex;
  align-items: center;
  gap: 4px;
}

.run-editor-section-header:hover {
  color: var(--text-secondary);
}

.run-editor-section-body.collapsed {
  display: none;
}

.run-editor-field {
  margin-bottom: 8px;
}

.run-editor-label {
  display: block;
  font-size: 11px;
  color: var(--text-dim);
  margin-bottom: 3px;
}

.run-editor-input,
.run-editor-select {
  width: 100%;
  padding: 4px 8px;
  background: var(--bg-deep);
  border: 1px solid var(--border-primary);
  border-radius: 4px;
  color: var(--text-body);
  font-size: 12px;
  font-family: inherit;
  box-sizing: border-box;
}

.run-editor-input:focus,
.run-editor-select:focus {
  outline: none;
  border-color: var(--accent);
}

.run-editor-input-row {
  display: flex;
  gap: 4px;
  align-items: center;
}

.run-editor-input-row .run-editor-input {
  flex: 1;
}

.run-editor-browse-btn {
  background: var(--hover-subtle);
  border: 1px solid var(--border-primary);
  border-radius: 4px;
  color: var(--text-secondary);
  font-size: 11px;
  cursor: pointer;
  padding: 4px 8px;
  white-space: nowrap;
}

.run-editor-browse-btn:hover {
  background: var(--hover-intense);
  color: var(--text-primary);
}

.run-editor-footer {
  display: flex;
  gap: 6px;
  padding: 8px 12px;
  border-top: 1px solid var(--border-subtle);
}

.run-editor-btn {
  padding: 4px 12px;
  border: 1px solid var(--border-primary);
  border-radius: 4px;
  background: var(--hover-subtle);
  color: var(--text-secondary);
  font-size: 11px;
  cursor: pointer;
  font-family: inherit;
}

.run-editor-btn:hover {
  background: var(--hover-intense);
  color: var(--text-primary);
}

.run-editor-save {
  background: var(--accent-muted, rgba(230,57,70,0.2));
  border-color: var(--accent);
  color: var(--accent);
}

.run-editor-save:hover {
  background: var(--accent);
  color: var(--text-bright);
}

.run-editor-delete {
  margin-left: auto;
  color: var(--accent);
  border-color: transparent;
}

.run-editor-delete:hover {
  background: rgba(230,57,70,0.15);
}

.run-editor-link {
  background: none;
  border: none;
  color: var(--accent);
  font-size: 11px;
  cursor: pointer;
  padding: 0;
  text-decoration: underline;
}

.run-editor-link:hover {
  color: var(--text-primary);
}

/* Env Key-Value Table */

.run-env-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 11px;
  margin-top: 4px;
}

.run-env-table th {
  text-align: left;
  padding: 2px 4px;
  font-size: 10px;
  color: var(--text-dimmer);
  font-weight: 600;
}

.run-env-table td {
  padding: 2px 4px;
}

.run-env-table input {
  width: 100%;
  padding: 2px 4px;
  background: var(--bg-deep);
  border: 1px solid var(--border-subtle);
  border-radius: 3px;
  color: var(--text-body);
  font-size: 11px;
  font-family: inherit;
  box-sizing: border-box;
}

.run-env-table input:focus {
  outline: none;
  border-color: var(--accent);
}

.run-env-remove-btn {
  background: none;
  border: none;
  color: var(--text-dimmer);
  cursor: pointer;
  font-size: 12px;
  padding: 0 4px;
}

.run-env-remove-btn:hover {
  color: var(--accent);
}

.run-env-add-btn {
  background: none;
  border: none;
  color: var(--text-dim);
  font-size: 11px;
  cursor: pointer;
  padding: 4px 0;
}

.run-env-add-btn:hover {
  color: var(--text-primary);
}

/* Env Profile Manager */

.run-profile-item {
  display: flex;
  align-items: center;
  padding: 4px 12px;
  gap: 6px;
  cursor: pointer;
  font-size: 12px;
  color: var(--text-body);
}

.run-profile-item:hover {
  background: var(--hover-subtle);
}

.run-profile-item.active {
  background: var(--hover-intense);
  color: var(--text-primary);
}

.run-profile-actions {
  display: flex;
  gap: 4px;
  padding: 6px 12px;
}

.run-profile-add-btn {
  background: none;
  border: 1px solid var(--border-primary);
  border-radius: 4px;
  color: var(--text-dim);
  font-size: 11px;
  cursor: pointer;
  padding: 3px 8px;
}

.run-profile-add-btn:hover {
  background: var(--hover-subtle);
  color: var(--text-primary);
}

#run-profile-editor {
  padding: 8px 12px;
  border-top: 1px solid var(--border-subtle);
}

/* Checkbox row */
.run-editor-checkbox-row {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 11px;
  color: var(--text-dim);
}

.run-editor-checkbox-row input[type="checkbox"] {
  margin: 0;
}

/* Run status message (like git-status-msg) */
.run-status-msg {
  font-size: 11px;
  color: var(--color-green);
  padding: 4px 12px;
  min-height: 14px;
  word-break: break-word;
}

.run-status-msg:empty {
  display: none;
}

.run-status-msg.run-status-error {
  color: var(--accent);
}
```

- [ ] **Step 2: Commit**

```bash
git add styles.css
git commit -m "feat: add CSS styles for launch config list, editor, and profile manager"
```

---

### Task 5: Implement config list view in renderer.js

**Files:**
- Modify: `renderer.js:2393-2428` (replace refreshRunConfigs)

This replaces the simple flat list with a grouped, actionable config list.

- [ ] **Step 1: Add run panel state variables**

In `renderer.js`, find the line `var runConfigsEl = document.getElementById('run-configs');` (line 1692) and add after it:

```javascript
var runListView = document.getElementById('run-list-view');
var runEditorView = document.getElementById('run-editor-view');
var runProfilesView = document.getElementById('run-profiles-view');
var runEditorForm = document.getElementById('run-editor-form');
var runEditorTitle = document.getElementById('run-editor-title');
var runProfilesList = document.getElementById('run-profiles-list');
var runProfileEditor = document.getElementById('run-profile-editor');
var runCachedData = null; // { configs, envProfiles }
var runEditingConfig = null; // config being edited, or null for new
var runEditingIndex = -1; // index in custom configs array, or -1 for new
```

- [ ] **Step 2: Replace refreshRunConfigs with grouped list renderer**

Replace the existing `refreshRunConfigs` function (lines 2393-2428) with:

```javascript
function refreshRunConfigs() {
  if (!activeProjectKey || !window.electronAPI) return;
  while (runConfigsEl.firstChild) runConfigsEl.removeChild(runConfigsEl.firstChild);
  window.electronAPI.getLaunchConfigs(activeProjectKey).then(function (data) {
    runCachedData = data;
    var configs = data.configs || [];
    if (configs.length === 0) {
      var empty = document.createElement('div');
      empty.className = 'run-empty';
      empty.textContent = 'No launch configurations found. Click + to add one.';
      runConfigsEl.appendChild(empty);
      return;
    }
    // Group by _source
    var groups = { custom: [], launchSettings: [], 'launch.json': [] };
    for (var i = 0; i < configs.length; i++) {
      var src = configs[i]._source || 'custom';
      if (!groups[src]) groups[src] = [];
      groups[src].push(configs[i]);
    }
    var groupLabels = { custom: 'Custom', launchSettings: 'Launch Settings', 'launch.json': 'VS Code' };
    var groupOrder = ['custom', 'launchSettings', 'launch.json'];
    for (var g = 0; g < groupOrder.length; g++) {
      var key = groupOrder[g];
      var items = groups[key];
      if (!items || items.length === 0) continue;
      var group = document.createElement('div');
      group.className = 'run-source-group';
      var hdr = document.createElement('div');
      hdr.className = 'run-source-header';
      var arrow = document.createElement('span');
      arrow.className = 'run-source-arrow expanded';
      arrow.textContent = '\u25B8';
      var label = document.createElement('span');
      label.textContent = (groupLabels[key] || key) + ' (' + items.length + ')';
      hdr.appendChild(arrow);
      hdr.appendChild(label);
      group.appendChild(hdr);
      var list = document.createElement('div');
      list.className = 'run-source-items';
      hdr.addEventListener('click', (function (a, l) {
        return function () {
          a.classList.toggle('expanded');
          l.classList.toggle('collapsed');
        };
      })(arrow, list));
      for (var j = 0; j < items.length; j++) {
        (function (config) {
          var item = document.createElement('div');
          item.className = 'run-config-item';
          var playBtn = document.createElement('button');
          playBtn.className = 'run-play-btn';
          playBtn.textContent = '\u25B6';
          playBtn.title = 'Run ' + config.name;
          playBtn.addEventListener('click', function () { launchConfig(config); });
          var nameEl = document.createElement('span');
          nameEl.className = 'run-config-name';
          nameEl.textContent = config.name;
          var typeEl = document.createElement('span');
          var knownTypes = ['dotnet-run', 'dotnet-exec', 'coreclr', 'node', 'pwa-node', 'python', 'custom'];
          var isUnknown = config.type && knownTypes.indexOf(config.type) === -1;
          typeEl.className = 'run-config-badge' + (isUnknown ? ' warning' : '');
          typeEl.textContent = config.type || '';
          var actions = document.createElement('div');
          actions.className = 'run-config-actions';
          if (config._readonly) {
            var cloneBtn = document.createElement('button');
            cloneBtn.className = 'run-config-action-btn';
            cloneBtn.textContent = '\u2398'; // clone icon
            cloneBtn.title = 'Clone to custom configs';
            cloneBtn.addEventListener('click', function () { cloneConfig(config); });
            actions.appendChild(cloneBtn);
          } else {
            var editBtn = document.createElement('button');
            editBtn.className = 'run-config-action-btn';
            editBtn.textContent = '\u270E'; // pencil
            editBtn.title = 'Edit';
            editBtn.addEventListener('click', function () { openConfigEditor(config); });
            actions.appendChild(editBtn);
          }
          item.appendChild(playBtn);
          item.appendChild(nameEl);
          item.appendChild(typeEl);
          item.appendChild(actions);
          list.appendChild(item);
        })(items[j]);
      }
      group.appendChild(list);
      runConfigsEl.appendChild(group);
    }
  });
}
```

- [ ] **Step 3: Add cloneConfig function**

Add after `refreshRunConfigs`:

```javascript
function cloneConfig(config) {
  var cloned = JSON.parse(JSON.stringify(config));
  cloned.name = config.name + ' (Copy)';
  cloned._source = 'custom';
  cloned._readonly = false;
  // Open editor with this clone
  openConfigEditor(cloned, true);
}
```

- [ ] **Step 4: Add view switching helpers**

Add after `cloneConfig`:

```javascript
function showRunListView() {
  runListView.classList.remove('hidden');
  runEditorView.classList.add('hidden');
  runProfilesView.classList.add('hidden');
}

function showRunEditorView() {
  runListView.classList.add('hidden');
  runEditorView.classList.remove('hidden');
  runProfilesView.classList.add('hidden');
}

function showRunProfilesView() {
  runListView.classList.add('hidden');
  runEditorView.classList.add('hidden');
  runProfilesView.classList.remove('hidden');
}
```

- [ ] **Step 5: Wire up the Add and Back buttons**

Find the event listener for `btn-refresh-run` (around line 2487) and add after it:

```javascript
document.getElementById('btn-add-run-config').addEventListener('click', function () {
  openConfigEditor(null, true);
});
document.getElementById('btn-run-editor-back').addEventListener('click', function () {
  showRunListView();
});
document.getElementById('btn-run-cancel').addEventListener('click', function () {
  showRunListView();
  refreshRunConfigs();
});
document.getElementById('btn-profiles-back').addEventListener('click', function () {
  showRunEditorView();
});
```

- [ ] **Step 6: Verify the app launches and shows grouped configs**

Run: `npm start`

Open a project that has `launchSettings.json` or `.vscode/launch.json`. Confirm the Run tab shows configs grouped by source with play, edit/clone buttons.

- [ ] **Step 7: Commit**

```bash
git add renderer.js
git commit -m "feat: implement grouped config list view with clone and edit actions"
```

---

### Task 6: Implement config editor form in renderer.js

**Files:**
- Modify: `renderer.js` (add openConfigEditor, buildEditorForm, saveConfig functions)

- [ ] **Step 1: Add openConfigEditor function**

Add after the view switching helpers:

```javascript
function openConfigEditor(config, isNew) {
  runEditingConfig = config ? JSON.parse(JSON.stringify(config)) : {
    name: '',
    type: 'custom',
    command: '',
    args: [],
    cwd: '',
    env: {},
    envProfile: '',
    envFile: '',
    applicationUrl: '',
    openBrowserOnLaunch: false
  };
  if (isNew && !config) {
    runEditingIndex = -1;
  } else if (isNew && config) {
    // Clone — will be appended
    runEditingIndex = -1;
  } else {
    // Editing existing custom config — find index
    runEditingIndex = findCustomConfigIndex(config);
  }
  runEditorTitle.textContent = isNew ? 'New Configuration' : 'Edit: ' + config.name;
  document.getElementById('btn-run-delete').classList.toggle('hidden', runEditingIndex < 0);
  buildEditorForm();
  showRunEditorView();
}

function findCustomConfigIndex(config) {
  if (!runCachedData) return -1;
  var customs = (runCachedData.configs || []).filter(function (c) { return c._source === 'custom'; });
  for (var i = 0; i < customs.length; i++) {
    if (customs[i].name === config.name && customs[i].type === config.type) return i;
  }
  return -1;
}
```

- [ ] **Step 2: Add buildEditorForm function**

Add after `openConfigEditor`:

```javascript
function buildEditorForm() {
  var form = runEditorForm;
  while (form.firstChild) form.removeChild(form.firstChild);
  var cfg = runEditingConfig;

  // General section
  var general = createEditorSection('General', true);
  general.body.appendChild(createTextField('Name', cfg.name, function (v) { cfg.name = v; }));
  var typeOpts = [
    { value: 'dotnet-run', label: 'dotnet run' },
    { value: 'dotnet-exec', label: 'dotnet (exec)' },
    { value: 'node', label: 'Node.js' },
    { value: 'python', label: 'Python' },
    { value: 'custom', label: 'Custom Command' }
  ];
  general.body.appendChild(createSelectField('Type', cfg.type || 'custom', typeOpts, function (v) {
    cfg.type = v;
    buildEditorForm(); // rebuild to show type-specific fields
  }));
  form.appendChild(general.el);

  // Command section — type-specific
  var command = createEditorSection('Command', true);
  if (cfg.type === 'dotnet-run') {
    command.body.appendChild(createFileField('Project (.csproj)', cfg.project || '', function (v) { cfg.project = v; },
      [{ name: 'C# Project', extensions: ['csproj'] }]));
    command.body.appendChild(createTextField('Application URL', cfg.applicationUrl || '', function (v) { cfg.applicationUrl = v; }));
    command.body.appendChild(createTextField('Framework (TFM)', cfg.framework || '', function (v) { cfg.framework = v; }));
  } else if (cfg.type === 'dotnet-exec') {
    command.body.appendChild(createFileField('Program (.dll)', cfg.program || '', function (v) { cfg.program = v; },
      [{ name: 'DLL', extensions: ['dll'] }]));
  } else if (cfg.type === 'node') {
    command.body.appendChild(createTextField('Program', cfg.program || '', function (v) { cfg.program = v; }));
    command.body.appendChild(createTextField('Runtime Executable', cfg.runtimeExecutable || '', function (v) { cfg.runtimeExecutable = v; }));
    command.body.appendChild(createTextField('Runtime Args', (cfg.runtimeArgs || []).join(' '), function (v) { cfg.runtimeArgs = v ? v.split(/\s+/) : []; }));
  } else if (cfg.type === 'python') {
    command.body.appendChild(createTextField('Script', cfg.script || cfg.program || '', function (v) { cfg.script = v; }));
    command.body.appendChild(createTextField('Interpreter Path', cfg.interpreter || '', function (v) { cfg.interpreter = v; }));
  } else {
    command.body.appendChild(createTextField('Command', cfg.command || '', function (v) { cfg.command = v; }));
  }
  form.appendChild(command.el);

  // Arguments
  var argsSection = createEditorSection('Arguments', true);
  var argsVal = Array.isArray(cfg.args) ? cfg.args.join(' ') : (cfg.args || cfg.commandLineArgs || '');
  argsSection.body.appendChild(createTextField('Command Line Args', argsVal, function (v) {
    cfg.args = v ? v.split(/\s+/) : [];
    cfg.commandLineArgs = v;
  }));
  form.appendChild(argsSection.el);

  // Working Directory
  var cwdSection = createEditorSection('Working Directory', true);
  cwdSection.body.appendChild(createTextField('Path', cfg.cwd || '', function (v) { cfg.cwd = v; }));
  form.appendChild(cwdSection.el);

  // Environment
  var envSection = createEditorSection('Environment', true);
  var profiles = (runCachedData && runCachedData.envProfiles) ? runCachedData.envProfiles : {};
  var profileNames = Object.keys(profiles);
  var profileOpts = [{ value: '', label: 'None' }];
  for (var p = 0; p < profileNames.length; p++) {
    profileOpts.push({ value: profileNames[p], label: profileNames[p] });
  }
  envSection.body.appendChild(createSelectField('Env Profile', cfg.envProfile || '', profileOpts, function (v) { cfg.envProfile = v; }));
  var manageLink = document.createElement('button');
  manageLink.className = 'run-editor-link';
  manageLink.textContent = 'Manage Profiles';
  manageLink.addEventListener('click', function () { openProfileManager(); });
  envSection.body.appendChild(manageLink);
  envSection.body.appendChild(createEnvTable(cfg.env || {}, function (env) { cfg.env = env; }));
  envSection.body.appendChild(createTextField('Env File Path', cfg.envFile || '', function (v) { cfg.envFile = v; }));
  form.appendChild(envSection.el);

  // URL section (for web apps)
  if (cfg.type === 'dotnet-run' || cfg.type === 'node' || cfg.type === 'custom') {
    var urlSection = createEditorSection('URL', false);
    if (cfg.type !== 'dotnet-run') {
      urlSection.body.appendChild(createTextField('Application URL', cfg.applicationUrl || '', function (v) { cfg.applicationUrl = v; }));
    }
    var cbRow = document.createElement('div');
    cbRow.className = 'run-editor-checkbox-row';
    var cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = cfg.openBrowserOnLaunch || false;
    cb.addEventListener('change', function () { cfg.openBrowserOnLaunch = cb.checked; });
    var cbLabel = document.createElement('span');
    cbLabel.textContent = 'Open browser on launch';
    cbRow.appendChild(cb);
    cbRow.appendChild(cbLabel);
    urlSection.body.appendChild(cbRow);
    form.appendChild(urlSection.el);
  }
}
```

- [ ] **Step 3: Add editor form helper functions**

Add after `buildEditorForm`:

```javascript
function createEditorSection(title, startOpen) {
  var section = document.createElement('div');
  section.className = 'run-editor-section';
  var header = document.createElement('div');
  header.className = 'run-editor-section-header';
  var arrow = document.createElement('span');
  arrow.className = 'run-source-arrow' + (startOpen ? ' expanded' : '');
  arrow.textContent = '\u25B8';
  header.appendChild(arrow);
  var lbl = document.createElement('span');
  lbl.textContent = title;
  header.appendChild(lbl);
  section.appendChild(header);
  var body = document.createElement('div');
  body.className = 'run-editor-section-body' + (startOpen ? '' : ' collapsed');
  section.appendChild(body);
  header.addEventListener('click', function () {
    arrow.classList.toggle('expanded');
    body.classList.toggle('collapsed');
  });
  return { el: section, body: body };
}

function createTextField(label, value, onChange) {
  var field = document.createElement('div');
  field.className = 'run-editor-field';
  var lbl = document.createElement('label');
  lbl.className = 'run-editor-label';
  lbl.textContent = label;
  field.appendChild(lbl);
  var input = document.createElement('input');
  input.type = 'text';
  input.className = 'run-editor-input';
  input.value = value;
  input.addEventListener('change', function () { onChange(input.value); });
  input.addEventListener('input', function () { onChange(input.value); });
  field.appendChild(input);
  return field;
}

function createSelectField(label, value, options, onChange) {
  var field = document.createElement('div');
  field.className = 'run-editor-field';
  var lbl = document.createElement('label');
  lbl.className = 'run-editor-label';
  lbl.textContent = label;
  field.appendChild(lbl);
  var select = document.createElement('select');
  select.className = 'run-editor-select';
  for (var i = 0; i < options.length; i++) {
    var opt = document.createElement('option');
    opt.value = options[i].value;
    opt.textContent = options[i].label;
    if (options[i].value === value) opt.selected = true;
    select.appendChild(opt);
  }
  select.addEventListener('change', function () { onChange(select.value); });
  field.appendChild(select);
  return field;
}

function createFileField(label, value, onChange, filters) {
  var field = document.createElement('div');
  field.className = 'run-editor-field';
  var lbl = document.createElement('label');
  lbl.className = 'run-editor-label';
  lbl.textContent = label;
  field.appendChild(lbl);
  var row = document.createElement('div');
  row.className = 'run-editor-input-row';
  var input = document.createElement('input');
  input.type = 'text';
  input.className = 'run-editor-input';
  input.value = value;
  input.addEventListener('change', function () { onChange(input.value); });
  input.addEventListener('input', function () { onChange(input.value); });
  row.appendChild(input);
  var btn = document.createElement('button');
  btn.className = 'run-editor-browse-btn';
  btn.textContent = 'Browse';
  btn.addEventListener('click', function () {
    window.electronAPI.browseFile(filters || []).then(function (path) {
      if (path) {
        input.value = path;
        onChange(path);
      }
    });
  });
  row.appendChild(btn);
  field.appendChild(row);
  return field;
}

function createEnvTable(env, onChange) {
  var wrapper = document.createElement('div');
  var entries = Object.entries(env);
  function rebuild() {
    while (wrapper.firstChild) wrapper.removeChild(wrapper.firstChild);
    var table = document.createElement('table');
    table.className = 'run-env-table';
    if (entries.length > 0) {
      var thead = document.createElement('thead');
      var tr = document.createElement('tr');
      var th1 = document.createElement('th'); th1.textContent = 'Variable';
      var th2 = document.createElement('th'); th2.textContent = 'Value';
      var th3 = document.createElement('th'); th3.textContent = '';
      tr.appendChild(th1); tr.appendChild(th2); tr.appendChild(th3);
      thead.appendChild(tr);
      table.appendChild(thead);
    }
    var tbody = document.createElement('tbody');
    for (var i = 0; i < entries.length; i++) {
      (function (idx) {
        var row = document.createElement('tr');
        var td1 = document.createElement('td');
        var keyInput = document.createElement('input');
        keyInput.value = entries[idx][0];
        keyInput.placeholder = 'KEY';
        keyInput.addEventListener('change', function () {
          entries[idx][0] = keyInput.value;
          syncEnv();
        });
        td1.appendChild(keyInput);
        var td2 = document.createElement('td');
        var valInput = document.createElement('input');
        valInput.value = entries[idx][1];
        valInput.placeholder = 'value';
        valInput.addEventListener('change', function () {
          entries[idx][1] = valInput.value;
          syncEnv();
        });
        td2.appendChild(valInput);
        var td3 = document.createElement('td');
        var rmBtn = document.createElement('button');
        rmBtn.className = 'run-env-remove-btn';
        rmBtn.textContent = '\u00D7';
        rmBtn.addEventListener('click', function () {
          entries.splice(idx, 1);
          rebuild();
          syncEnv();
        });
        td3.appendChild(rmBtn);
        row.appendChild(td1); row.appendChild(td2); row.appendChild(td3);
        tbody.appendChild(row);
      })(i);
    }
    table.appendChild(tbody);
    wrapper.appendChild(table);
    var addBtn = document.createElement('button');
    addBtn.className = 'run-env-add-btn';
    addBtn.textContent = '+ Add Variable';
    addBtn.addEventListener('click', function () {
      entries.push(['', '']);
      rebuild();
    });
    wrapper.appendChild(addBtn);
  }
  function syncEnv() {
    var obj = {};
    for (var i = 0; i < entries.length; i++) {
      if (entries[i][0]) obj[entries[i][0]] = entries[i][1];
    }
    onChange(obj);
  }
  rebuild();
  return wrapper;
}
```

- [ ] **Step 4: Add Save and Delete handlers**

Add after the helper functions:

```javascript
document.getElementById('btn-run-save').addEventListener('click', function () {
  if (!activeProjectKey || !runEditingConfig) return;
  var cfg = runEditingConfig;
  // Validate required fields
  if (!cfg.name) { alert('Name is required'); return; }
  if (cfg.type === 'dotnet-run' && !cfg.project) { alert('Project (.csproj) is required for dotnet-run'); return; }
  if (cfg.type === 'custom' && !cfg.command) { alert('Command is required for custom type'); return; }

  // Remove readonly/source markers before saving
  var toSave = JSON.parse(JSON.stringify(cfg));
  delete toSave._source;
  delete toSave._readonly;

  // Load existing custom configs
  window.electronAPI.getLaunchConfigs(activeProjectKey).then(function (data) {
    var customs = (data.configs || []).filter(function (c) { return c._source === 'custom'; });
    // Strip internal fields
    customs = customs.map(function (c) {
      var copy = JSON.parse(JSON.stringify(c));
      delete copy._source;
      delete copy._readonly;
      return copy;
    });
    if (runEditingIndex >= 0 && runEditingIndex < customs.length) {
      customs[runEditingIndex] = toSave;
    } else {
      customs.push(toSave);
    }
    return window.electronAPI.saveLaunchConfigs(activeProjectKey, customs);
  }).then(function () {
    showRunListView();
    refreshRunConfigs();
  });
});

document.getElementById('btn-run-delete').addEventListener('click', function () {
  if (!activeProjectKey || runEditingIndex < 0) return;
  if (!confirm('Delete this configuration?')) return;
  window.electronAPI.getLaunchConfigs(activeProjectKey).then(function (data) {
    var customs = (data.configs || []).filter(function (c) { return c._source === 'custom'; });
    customs = customs.map(function (c) {
      var copy = JSON.parse(JSON.stringify(c));
      delete copy._source;
      delete copy._readonly;
      return copy;
    });
    customs.splice(runEditingIndex, 1);
    return window.electronAPI.saveLaunchConfigs(activeProjectKey, customs);
  }).then(function () {
    showRunListView();
    refreshRunConfigs();
  });
});
```

- [ ] **Step 5: Verify the editor opens and saves**

Run: `npm start`

Open a project, go to Run tab, click `+` to add a new config. Fill in fields, save. Confirm it appears in the custom group. Click edit, change a field, save. Confirm changes persist.

- [ ] **Step 6: Commit**

```bash
git add renderer.js
git commit -m "feat: implement config editor form with type-specific fields and save/delete"
```

---

### Task 7: Implement environment profile manager in renderer.js

**Files:**
- Modify: `renderer.js` (add openProfileManager, profile CRUD functions)

- [ ] **Step 1: Add openProfileManager function**

Add after the save/delete handlers:

```javascript
var activeProfileName = null;

function openProfileManager() {
  showRunProfilesView();
  renderProfileList();
}

function renderProfileList() {
  var list = runProfilesList;
  while (list.firstChild) list.removeChild(list.firstChild);
  var profiles = (runCachedData && runCachedData.envProfiles) ? runCachedData.envProfiles : {};
  var names = Object.keys(profiles);

  for (var i = 0; i < names.length; i++) {
    (function (name) {
      var item = document.createElement('div');
      item.className = 'run-profile-item' + (name === activeProfileName ? ' active' : '');
      var nameEl = document.createElement('span');
      nameEl.textContent = name;
      nameEl.style.flex = '1';
      item.appendChild(nameEl);
      var delBtn = document.createElement('button');
      delBtn.className = 'run-config-action-btn';
      delBtn.textContent = '\u00D7';
      delBtn.title = 'Delete profile';
      delBtn.addEventListener('click', function (e) {
        e.stopPropagation();
        if (!confirm('Delete profile "' + name + '"?')) return;
        delete profiles[name];
        saveProfiles(profiles);
        if (activeProfileName === name) activeProfileName = null;
        renderProfileList();
        renderProfileEditor();
      });
      item.appendChild(delBtn);
      item.addEventListener('click', function () {
        activeProfileName = name;
        renderProfileList();
        renderProfileEditor();
      });
      list.appendChild(item);
    })(names[i]);
  }

  // Add profile button
  var actions = document.createElement('div');
  actions.className = 'run-profile-actions';
  var addBtn = document.createElement('button');
  addBtn.className = 'run-profile-add-btn';
  addBtn.textContent = '+ Add Profile';
  addBtn.addEventListener('click', function () {
    var name = prompt('Profile name:');
    if (!name) return;
    profiles[name] = {};
    saveProfiles(profiles);
    activeProfileName = name;
    renderProfileList();
    renderProfileEditor();
  });
  actions.appendChild(addBtn);
  list.appendChild(actions);

  // Auto-select first if none selected
  if (!activeProfileName && names.length > 0) {
    activeProfileName = names[0];
    renderProfileList();
  }
  renderProfileEditor();
}

function renderProfileEditor() {
  var editor = runProfileEditor;
  while (editor.firstChild) editor.removeChild(editor.firstChild);
  if (!activeProfileName) {
    var empty = document.createElement('div');
    empty.className = 'run-empty';
    empty.textContent = 'Select a profile to edit';
    editor.appendChild(empty);
    return;
  }
  var profiles = (runCachedData && runCachedData.envProfiles) ? runCachedData.envProfiles : {};
  var profileEnv = profiles[activeProfileName] || {};

  // Rename field
  var renameField = createTextField('Profile Name', activeProfileName, function (v) {
    if (v && v !== activeProfileName && !profiles[v]) {
      profiles[v] = profiles[activeProfileName];
      delete profiles[activeProfileName];
      activeProfileName = v;
      saveProfiles(profiles);
      renderProfileList();
    }
  });
  editor.appendChild(renameField);

  // Env file reference
  var envFileVal = profileEnv._envFile || '';
  editor.appendChild(createTextField('Env File', envFileVal, function (v) {
    if (v) {
      profileEnv._envFile = v;
    } else {
      delete profileEnv._envFile;
    }
    profiles[activeProfileName] = profileEnv;
    saveProfiles(profiles);
  }));

  // Key-value table (excluding _envFile)
  var envOnly = {};
  for (var k in profileEnv) {
    if (k !== '_envFile') envOnly[k] = profileEnv[k];
  }
  editor.appendChild(createEnvTable(envOnly, function (env) {
    var updated = {};
    if (profileEnv._envFile) updated._envFile = profileEnv._envFile;
    for (var key in env) updated[key] = env[key];
    profiles[activeProfileName] = updated;
    saveProfiles(profiles);
  }));
}

function saveProfiles(profiles) {
  if (!activeProjectKey) return;
  runCachedData.envProfiles = profiles;
  window.electronAPI.saveEnvProfiles(activeProjectKey, profiles);
}
```

- [ ] **Step 2: Verify profile manager works**

Run: `npm start`

Open the config editor, click "Manage Profiles". Add a profile, add env vars, rename it, delete it. Go back to editor, confirm the profile appears in the dropdown.

- [ ] **Step 3: Commit**

```bash
git add renderer.js
git commit -m "feat: implement environment profile manager with CRUD and env table"
```

---

### Task 8: Update launchConfig with async env merge and all types

**Files:**
- Modify: `renderer.js:2430-2473` (replace launchConfig function)

- [ ] **Step 1: Add resolveConfigEnv function**

Add before the existing `launchConfig` function:

```javascript
function resolveConfigEnv(config) {
  var mergedEnv = {};
  var profile = null;
  if (runCachedData && config.envProfile && runCachedData.envProfiles) {
    profile = runCachedData.envProfiles[config.envProfile];
  }

  // Step 1: load profile _envFile
  var p1 = (profile && profile._envFile)
    ? window.electronAPI.readEnvFile(profile._envFile)
    : Promise.resolve({});

  // Step 2: load config envFile
  var p2 = config.envFile
    ? window.electronAPI.readEnvFile(config.envFile)
    : Promise.resolve({});

  return Promise.all([p1, p2]).then(function (results) {
    var profileFileEnv = results[0];
    var configFileEnv = results[1];

    // Merge order (lowest to highest priority):
    // 1. profile._envFile
    for (var k in profileFileEnv) mergedEnv[k] = profileFileEnv[k];
    // 2. profile key-value pairs
    if (profile) {
      for (var k2 in profile) {
        if (k2 !== '_envFile') mergedEnv[k2] = profile[k2];
      }
    }
    // 3. config envFile
    for (var k3 in configFileEnv) mergedEnv[k3] = configFileEnv[k3];
    // 4. config.env (highest priority)
    var configEnv = config.env || {};
    for (var k4 in configEnv) mergedEnv[k4] = configEnv[k4];

    return mergedEnv;
  });
}
```

- [ ] **Step 2: Replace launchConfig with async version supporting all types**

Replace the existing `launchConfig` function with:

```javascript
function launchConfig(config) {
  if (!activeProjectKey) return;
  function resolve(str) {
    if (!str) return str;
    return str.replace(/\$\{workspaceFolder\}/g, activeProjectKey);
  }

  // Check if already running
  var existing = findRunningColumn(config.name);
  if (existing) {
    if (!confirm('"' + config.name + '" is already running. Kill and restart?')) return;
    removeColumn(existing);
  }

  // Resolve environment asynchronously (env files may need loading)
  resolveConfigEnv(config).then(function (mergedEnv) {
    var cmd, cmdArgs, cwd, env;
    cwd = config.cwd ? resolve(config.cwd) : activeProjectKey;
    env = Object.keys(mergedEnv).length > 0 ? mergedEnv : null;

    if (config.type === 'dotnet-run') {
      cmd = 'dotnet';
      cmdArgs = ['run'];
      if (config.project) {
        cmdArgs.push('--project');
        cmdArgs.push(resolve(config.project));
      }
      if (config.framework) {
        cmdArgs.push('--framework');
        cmdArgs.push(config.framework);
      }
      if (config.applicationUrl) {
        cmdArgs.push('--urls');
        cmdArgs.push(config.applicationUrl);
      }
      var args = config.args || config.commandLineArgs;
      if (args) {
        cmdArgs.push('--');
        if (Array.isArray(args)) {
          cmdArgs = cmdArgs.concat(args);
        } else {
          cmdArgs = cmdArgs.concat(args.split(/\s+/));
        }
      }
    } else if (config.type === 'dotnet-exec' || config.type === 'coreclr') {
      cmd = 'dotnet';
      cmdArgs = [];
      if (config.program) cmdArgs.push(resolve(config.program));
      if (config.args) {
        cmdArgs = cmdArgs.concat(Array.isArray(config.args) ? config.args.map(resolve) : config.args.split(/\s+/));
      }
    } else if (config.type === 'node' || config.type === 'pwa-node') {
      cmd = config.runtimeExecutable || 'node';
      cmdArgs = [];
      if (config.runtimeArgs) cmdArgs = cmdArgs.concat(Array.isArray(config.runtimeArgs) ? config.runtimeArgs : config.runtimeArgs.split(/\s+/));
      if (config.program) cmdArgs.push(resolve(config.program));
      if (config.args) cmdArgs = cmdArgs.concat(Array.isArray(config.args) ? config.args.map(resolve) : config.args.split(/\s+/));
    } else if (config.type === 'python') {
      // Use venv python binary if available
      var script = config.script || config.program || '';
      cmd = config.interpreter || 'python';
      cmdArgs = [];
      if (script) cmdArgs.push(resolve(script));
      if (config.args) cmdArgs = cmdArgs.concat(Array.isArray(config.args) ? config.args : config.args.split(/\s+/));
    } else if (config.type === 'custom') {
      cmd = resolve(config.command);
      cmdArgs = [];
      if (config.args) {
        cmdArgs = Array.isArray(config.args) ? config.args.map(resolve) : config.args.split(/\s+/).map(resolve);
      }
    } else if (config.runtimeExecutable) {
      cmd = resolve(config.runtimeExecutable);
      cmdArgs = (config.args || []).map(resolve);
      if (config.program) cmdArgs.unshift(resolve(config.program));
    } else if (config.program) {
      cmd = resolve(config.program);
      cmdArgs = (config.args || []).map(resolve);
    } else if (config.command) {
      // Unknown type but has command — treat as custom
      cmd = resolve(config.command);
      cmdArgs = Array.isArray(config.args) ? config.args : [];
    } else {
      return;
    }

    var launchUrl = config.applicationUrl || null;
    addColumn(cmdArgs, null, { cmd: cmd, title: config.name, cwd: cwd, env: env, launchUrl: launchUrl });
  });
}

function findRunningColumn(configName) {
  var state = getActiveState();
  if (!state) return null;
  var found = null;
  state.columns.forEach(function (colData, id) {
    if (colData.customTitle === configName && colData.cmd) {
      found = id;
    }
  });
  return found;
}
```

- [ ] **Step 2: Verify dotnet-run passes --project flag**

Run: `npm start`

Open a project with multiple `.csproj` files in the same directory. Each profile should appear as separate entries (one per csproj). Click play — confirm the terminal shows `dotnet run --project path/to/Project.csproj`.

- [ ] **Step 3: Verify env merge with a test profile**

Create an env profile with a few vars. Create a config that references it and also has its own env vars. Click play and verify the spawned process receives the merged env (check in the terminal output or via an `env` command config).

- [ ] **Step 4: Commit**

```bash
git add renderer.js
git commit -m "feat: enhanced launchConfig with --project flag, async env merge, re-run detection, and all types"
```

---

### Task 9: Integration testing and polish

**Files:**
- Modify: `renderer.js` (minor fixes as found during testing)
- Modify: `styles.css` (visual polish as needed)

- [ ] **Step 1: Test .NET project with multiple .csproj files**

Run `npm start`, open a .NET solution directory with multiple projects. Verify:
- Each `launchSettings.json` profile appears once per `.csproj` file
- Config names show `"ProfileName (Project.csproj)"` format
- Clicking play successfully runs `dotnet run --project specific.csproj`

- [ ] **Step 2: Test custom config creation end-to-end**

Click `+`, create a custom config (e.g. `echo hello`), save, run. Verify:
- Config appears in Custom group
- Process spawns in a new column
- Config persists after refresh

- [ ] **Step 3: Test env profiles end-to-end**

Create an env profile "Dev" with `MY_VAR=hello`. Create a custom config that runs `cmd /c echo %MY_VAR%` (Windows) with envProfile "Dev". Verify the output shows `hello`.

- [ ] **Step 4: Test clone functionality**

Find an auto-discovered config (from launchSettings or launch.json). Click clone. Verify:
- Editor opens with "(Copy)" suffix
- All fields populated from original
- Saving creates a new custom config

- [ ] **Step 5: Test re-run detection**

Launch a config. Click play again on the same config. Verify the "Already running. Kill and restart?" prompt appears.

- [ ] **Step 6: Test VS Code launch.json configs still work**

Open a project with `.vscode/launch.json`. Verify configs appear under "VS Code" group and can be launched.

- [ ] **Step 7: Commit any fixes**

```bash
git add -A
git commit -m "fix: integration testing polish for launch configurations"
```

---

### Task Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Enhanced .csproj scanning + new IPC handlers | main.js |
| 2 | Expose new IPC channels | preload.js |
| 3 | Update Run tab HTML structure | index.html |
| 4 | CSS styles for config panel | styles.css |
| 5 | Config list view with grouping | renderer.js |
| 6 | Config editor form | renderer.js |
| 7 | Environment profile manager | renderer.js |
| 8 | Enhanced launchConfig with async env merge and all types | renderer.js |
| 9 | Integration testing and polish | all files |
