# codex-profiles

Windows helpers for running multiple isolated Codex desktop profiles in parallel without touching your Codex CLI home.

## What this solves

The Microsoft Store Codex desktop app behaves like a single-instance Electron app. Launching the Store app directly does **not** give you true parallel profile isolation.

This repo works around that by:

- detecting the installed `OpenAI.Codex` Store package
- cloning the desktop app binaries into `%LOCALAPPDATA%\\CodexParallelDesktop\\versions\\<version>`
- launching each profile with its own `CODEX_HOME`
- launching each profile with its own Chromium `--user-data-dir`
- scrubbing inherited proxy / API environment variables before the desktop app starts

That keeps desktop profiles separate from each other while leaving the Codex CLI home alone.

## What gets isolated

Per profile, this setup isolates local desktop state such as:

- `config.toml`
- `auth.json`
- sessions, memories, skills, sqlite files
- Chromium / Electron UI state
- logged-in desktop account state for that profile

By default, profiles live under:

- profile home: `%LOCALAPPDATA%\\CodexProfiles\\<profile>`
- UI data: `%LOCALAPPDATA%\\CodexParallelDesktop\\ui\\<profile>`

## Important caveats

- This does **not** modify `%USERPROFILE%\\.codex`, so Codex CLI stays on its own home unless you change it yourself.
- If you launch the normal Store app directly, it still inherits your normal Windows environment. If your machine has `OPENAI_BASE_URL` or similar user env vars set, the normal Store app can still use them.
- Some MCP OAuth credentials may still live in the Windows credential store outside `CODEX_HOME`. File-based profile state is isolated, but OS keychain-backed credentials can still be shared depending on how Codex stores them.

## Quick start

### 1. Clone the repo

```powershell
git clone https://github.com/ychampion/codex-profiles
cd codex-profiles
```

### 2. Create common named profiles

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Install-CodexDesktopProfiles.ps1 -ProfileName alpha,bloom,apex,prime,flow,turbo,sonic,nova -CreateDesktopShortcuts -CreateStartMenuShortcuts
```

### 3. Launch a specific profile

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Start-CodexDesktopProfile.ps1 -ProfileName alpha -DisplayName "Codex Alpha"
```

### 4. Create one profile with optional local MCP defaults

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\New-CodexDesktopProfile.ps1 -ProfileName alpha -DisplayName "Codex Alpha" -EnableCommonMcp -CreateDesktopShortcut
```

You can append `-WhatIf` to the public scripts or module functions for a dry run. The installer also accepts comma-separated profile names when invoked through `powershell -File`.

## Included scripts

- `scripts/windows/New-CodexDesktopProfile.ps1` creates one isolated profile and optional shortcuts
- `scripts/windows/Start-CodexDesktopProfile.ps1` launches one isolated profile
- `scripts/windows/Install-CodexDesktopProfiles.ps1` provisions a set of named profiles

## Optional MCP defaults

`-EnableCommonMcp` bootstraps a minimal local config with:

- ChatGPT login mode
- OpenAI model provider
- Windows elevated sandbox setting
- optional local `npx`-backed MCP entries for Playwright, Chrome DevTools, and Context7

The MCP block is created only when a new profile config is written, or when you pass `-OverwriteConfig`.

## Recommended naming set

The default profile set used by the installer is:

- `alpha`
- `bloom`
- `apex`
- `prime`
- `flow`
- `turbo`
- `sonic`
- `nova`

## Verification

The launchers are designed to avoid inherited desktop proxy settings such as:

- `OPENAI_BASE_URL`
- `OPENAI_API_KEY`
- `OPENAI_ORG_ID`
- `OPENAI_PROJECT_ID`
- `ANTHROPIC_BASE_URL`
- `ANTHROPIC_API_KEY`
- `ANTHROPIC_AUTH_TOKEN`
- `CODEX_THREAD_ID`

That is important when your CLI or shell uses a custom local endpoint but you want the desktop profiles to sign in with ChatGPT normally.
