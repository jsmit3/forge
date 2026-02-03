# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Forge is an autonomous code change pipeline where **Claude Code supervises Claude Code**. A Forge agent fetches GitHub issues, creates isolated git worktrees for worker agents, reviews their code changes, runs tests, performs visual verification with Playwright, and creates PRs.

Forge supports two modes:
- **Bug mode** - Minimal, focused fixes for bug issues
- **Feature mode** - Complete implementations for enhancement issues

## Architecture

```
LAUNCHER (PowerShell)         -- launch-forge.ps1, dumb restart loop
    │
    ▼
SUPERVISOR (Claude Code)      -- orchestrator, runs one cycle per issue
    │                            reads instructions from .forge/CLAUDE.md
    ▼
WORKER (Claude Code)          -- heads-down coder in isolated worktree
                                 doesn't know it's supervised
```

Forge runs inside a **ralph-loop** (a Claude Code plugin). Each iteration processes one issue, then exits. The loop re-feeds the prompt for the next iteration until all issues are done or `<promise>FORGE_COMPLETE</promise>` is output.

## Commands

### Setup in a target project
```powershell
# From target project directory
C:\tools\forge\setup-forge.ps1 -Repo "owner/repo" -TestCommand "npx playwright test"

# For feature mode by default
C:\tools\forge\setup-forge.ps1 -Repo "owner/repo" -DefaultMode feature
```

### Launch Forge
```powershell
.\launch-forge.ps1                    # Start with defaults (10 cycles)
.\launch-forge.ps1 -MaxCycles 5       # Limit to 5 cycles
.\launch-forge.ps1 -Mode feature      # Run in feature mode
.\launch-forge.ps1 -Clean             # Fresh session (wipes state/logs)
```

Once inside Claude Code, paste the `/ralph-loop:ralph-loop` command printed by the launcher.

### Monitor progress
```powershell
.\forge-status.ps1                    # Quick CLI status
.\forge-status.ps1 -Watch             # Auto-refresh every 5s
.\forge-dashboard-server.ps1          # Web dashboard at localhost:9847
.\forge-notify.ps1                    # Desktop notifications
```

### Analyze session results
```powershell
.\forge-analyze.ps1                   # Terminal output
.\forge-analyze.ps1 -OutputFormat json   # Machine-readable JSON
.\forge-analyze.ps1 -OutputFormat md     # Markdown report
```

## Key Files

| File | Purpose |
|------|---------|
| `.forge/CLAUDE.md` | **The brain** - detailed Forge instructions |
| `.forge/config.json` | Project configuration (repo, test commands, modes) |
| `.forge/state.json` | Persistent state between cycles (gitignored) |
| `.forge/logs/forge.jsonl` | Structured event log (JSONL format) |
| `launch-forge.ps1` | Entry point - checks prereqs, initializes state, launches Claude Code |
| `setup-forge.ps1` | Initializes Forge scaffold in a target project |
| `forge-analyze.ps1` | Parses logs and generates performance reports |
| `forge-status.ps1` | CLI status display |
| `forge-dashboard.html` | Web dashboard UI |
| `forge-dashboard-server.ps1` | HTTP server for dashboard |
| `forge-notify.ps1` | Desktop notification watcher |

## Forge Cycle (10 Steps)

1. **SETUP** - Read state.json and config.json
2. **FETCH** - `gh issue list` to get open issues (mode-appropriate labels)
3. **SELECT** - Pick highest priority unprocessed issue
4. **WORKSPACE** - `git worktree add` for isolation
5. **LAUNCH WORKER** - Write prompt (mode-specific), run `claude -p` in worktree
6. **REVIEW** - Evaluate the diff (mode-appropriate criteria)
7. **TEST** - Run test suite
8. **VISUAL VERIFICATION** - Launch app with Playwright, screenshot, confirm fix (conditional in feature mode)
9. **PR** - Create PR with screenshot evidence, optionally merge
10. **CLEANUP** - Update state, remove worktree

## Logging

All events are JSONL (one JSON object per line). Event types include: `issues_fetched`, `issue_selected`, `worktree_created`, `worker_launched`, `worker_completed`, `code_review`, `tests_executed`, `visual_verification`, `pr_created`, `pr_merged`, `issue_completed`, `issue_failed`, `error`, `decision`, `stale_recovery`.

## Platform Notes

This tool is Windows-focused (PowerShell scripts). When running in bash:
- Use `taskkill` or `Stop-Process` instead of `kill`
- Background processes via `Start-Process -NoNewWindow`
- Path separators: git uses `/`, some Windows tools need `\`
