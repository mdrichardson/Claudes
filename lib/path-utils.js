async function resolveWorktreeCandidates(projectPath, value, statFn) {
  if (!value) return { kind: 'none' };
  const path = require('path');
  const candidates = [
    path.isAbsolute(value) ? value : null,
    path.isAbsolute(value) ? null : path.join(projectPath, value),
    path.isAbsolute(value) ? null : path.join(projectPath, '.claude', 'worktrees', value),
  ].filter(Boolean);
  for (const p of candidates) {
    try {
      const st = await statFn(p);
      if (st.isDirectory()) return { kind: 'cwd', path: p };
    } catch {}
  }
  return { kind: 'flag', name: value };
}

async function pathIsDirectory(p, statFn) {
  if (!p) return false;
  try {
    const st = await statFn(p);
    return st.isDirectory();
  } catch {
    return false;
  }
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { resolveWorktreeCandidates, pathIsDirectory };
}
