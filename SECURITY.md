# Security Policy

Thanks for helping keep Claudes users safe.

## Supported versions

Only the **latest release** on the [Releases page](https://github.com/paulallington/Claudes/releases/latest) is supported. Installed copies auto-update via `electron-updater`, so the vast majority of users are on the latest version within a day of publication.

Older versions receive no security fixes.

## Reporting a vulnerability

Please report suspected vulnerabilities privately via GitHub's **[Private Vulnerability Reporting](https://github.com/paulallington/Claudes/security/advisories/new)** — this opens a private security advisory that only the maintainer can see.

Do **not** open a public issue for security problems.

When reporting, please include:

- A description of the issue and its impact
- Steps to reproduce (a minimal repro is ideal)
- The Claudes version (`Help → About`, or `package.json`) and OS
- Any relevant logs, stack traces, or proof-of-concept

## What to expect

This is a small personal project maintained in spare time, so please be patient:

- **Acknowledgement:** within ~7 days
- **Initial assessment:** within ~14 days
- **Fix timeline:** depends on severity and complexity — I'll share an ETA once I've triaged it

Once a fix ships in a release, I'll credit the reporter in the release notes unless they'd prefer to stay anonymous.

## Scope

**In scope** — issues in code that ships to end users:

- `main.js` (Electron main process)
- `preload.js` (context bridge)
- `renderer.js` and `index.html` (renderer)
- `pty-server.js` (local WebSocket + pty)
- Update channel (`electron-updater` / GitHub Releases integrity)
- Packaged runtime dependencies listed under `dependencies` in `package.json`

**Out of scope:**

- Vulnerabilities in **build-time dev dependencies** (`electron-builder` and its transitive deps). These run only on the maintainer's build machine and are not bundled into the distributed app. Dependabot alerts for these are routinely dismissed as *not used* unless a runtime exploitation path can be demonstrated.
- Issues in [Claude Code CLI](https://claude.ai/claude-code) itself — report those to Anthropic.
- Issues requiring the attacker to already have arbitrary code execution on the user's machine.
- Social-engineering or phishing scenarios unrelated to the app's code.

## Threat model

A few design notes that may be useful when evaluating reports:

- **Local-first.** Claudes runs entirely on the user's machine. There is no Claudes backend or remote service. The only outbound network traffic is: (a) update checks to GitHub Releases, (b) whatever Claude Code itself does, and (c) optional anonymous install telemetry.
- **The WebSocket pty server binds to localhost only.** It accepts a `cmd` parameter to spawn processes. A local attacker who can already connect to localhost already has user-level code execution on the machine, so this is not considered a privilege boundary — but reports of *remote* reachability would be taken seriously.
- **`asar` is enabled** but is not a security boundary; it's a packaging mechanism.
- **Config files** (`~/.claudes/projects.json`, `<project>/.claudes/sessions.json`) are written with default user permissions and may contain project paths. Treat them as user-level data, not secrets.

## Dependency hygiene

- Dependabot is enabled; alerts are reviewed.
- Runtime dependencies are kept patched; see the [commit history](https://github.com/paulallington/Claudes/commits/master) for bumps.
- Electron is updated to the latest patch of the currently-pinned major when security advisories land.

## Disclosure

I follow **coordinated disclosure**: once a fix has shipped in a release and users have had reasonable time to auto-update, the advisory is made public with credit to the reporter.
