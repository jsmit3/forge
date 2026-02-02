# Forge

**Claude Code supervising Claude Code** — an autonomous code change pipeline that fetches GitHub issues, spins up worker agents in isolated git worktrees, reviews their code, runs Playwright tests, and creates PRs.

Supports two modes:
- **Bug mode** - Minimal, focused fixes for bug issues
- **Feature mode** - Complete implementations for enhancement issues

## Architecture

```
┌─────────────────────────────────────────────────┐
│  LAUNCHER (PowerShell — dumb while loop)        │
│  launch-forge.ps1                               │
└────────────────────┬────────────────────────────┘
                     │ launches repeatedly
┌────────────────────▼────────────────────────────┐
│  FORGE (Claude Code instance)                   │
│                                                  │
│  Reads .forge/CLAUDE.md for instructions        │
│  Each cycle:                                     │
│  1. Fetch open issues from GitHub (gh CLI)      │
│  2. Pick highest priority unprocessed issue     │
│  3. Create git worktree for isolation           │
│  4. Write focused prompt for worker             │
│  5. Launch worker Claude Code in worktree       │
│  6. Review the code diff                        │
│  7. Run Playwright tests                        │
│  8. Visual verification (if required)           │
│  9. Create PR + merge if everything passes      │
│  10. Clean up worktree                          │
└────────────────────┬────────────────────────────┘
                     │ launches per-issue
┌────────────────────▼────────────────────────────┐
│  WORKER (Claude Code instance in worktree)      │
│                                                  │
│  Heads-down coding. Doesn't know it's           │
│  supervised. Works in .worktrees/issue-NN/      │
└─────────────────────────────────────────────────┘
```

## Prerequisites

- **Claude Code CLI**: `npm install -g @anthropic-ai/claude-code`
- **GitHub CLI**: `winget install GitHub.cli` or https://cli.github.com
- **Git** with worktree support (any modern version)
- **Node.js** (for Playwright tests)
- **PowerShell 5.1+** (included with Windows)

Authenticate GitHub CLI:
```powershell
gh auth login
```

## Quick Start

### 1. Clone this repo

```powershell
git clone <this-repo> forge
```

### 2. Run setup in your project

```powershell
cd C:\path\to\your\project

# Run the setup wizard
C:\path\to\forge\setup-forge.ps1 -Repo "owner/repo"
```

Or with explicit options:
```powershell
.\setup-forge.ps1 `
    -Repo "youruser/project" `
    -TestCommand "npx playwright test" `
    -BaseBranch "main" `
    -DefaultMode "bug" `
    -AutoMerge
```

### 3. Launch Forge

```powershell
.\launch-forge.ps1
```

With options:
```powershell
# Limit to 5 cycles
.\launch-forge.ps1 -MaxCycles 5

# Run in feature mode
.\launch-forge.ps1 -Mode feature

# Clean start (wipe state/logs)
.\launch-forge.ps1 -Clean
```

### 4. Monitor progress

```powershell
# Quick CLI status
.\forge-status.ps1

# Auto-refresh every 5 seconds
.\forge-status.ps1 -Watch

# Web dashboard
.\forge-dashboard-server.ps1

# Desktop notifications
.\forge-notify.ps1
```

### 5. Analyze results

```powershell
# Terminal output
.\forge-analyze.ps1

# Machine-readable JSON
.\forge-analyze.ps1 -OutputFormat json

# Markdown report
.\forge-analyze.ps1 -OutputFormat md > session-report.md
```

## File Structure

After setup, your project looks like:

```
your-project/
├── .forge/
│   ├── CLAUDE.md                    # Forge instructions (the brain)
│   ├── config.json                  # Configuration
│   ├── state.json                   # Persistent state (gitignored)
│   ├── worker-prompt-active.md      # Current worker prompt (gitignored)
│   └── logs/                        # All logs (gitignored)
│       ├── forge.jsonl              # Forge decisions & events
│       ├── summary.md               # Human-readable session log
│       └── workers/                 # Per-cycle raw output
│           ├── cycle-1-output.txt
│           └── cycle-2-output.txt
├── .worktrees/                      # Git worktrees (gitignored)
│   ├── issue-42/                    # Isolated workspace for issue #42
│   └── issue-43/                    # Isolated workspace for issue #43
├── launch-forge.ps1                 # Entry point
├── forge-analyze.ps1                # Post-session analysis
├── setup-forge.ps1                  # Project initializer
├── forge-status.ps1                 # CLI status display
├── forge-dashboard-server.ps1       # Web dashboard server
├── forge-dashboard.html             # Dashboard UI
└── src/                             # Your actual code
```

## Configuration

Edit `.forge/config.json`:

```jsonc
{
  "project": {
    "name": "my-project",
    "repo": "youruser/my-project",   // GitHub owner/repo
    "base_branch": "main",           // Branch to create worktrees from
    "test_command": "npx playwright test",
    "build_command": "npm run build",
    "install_command": "npm install"
  },
  "github": {
    "bug_labels": ["bug"],           // Labels for bug mode
    "feature_labels": ["enhancement", "feature"],  // Labels for feature mode
    "issue_state": "open",
    "max_issues_per_session": 10,
    "auto_merge": false,
    "pr_base_branch": "main",
    "pr_reviewers": []
  },
  "modes": {
    "default": "bug",
    "bug": {
      "visual_verification": "always",
      "max_files_warning": 5,
      "commit_prefix": "fix:"
    },
    "feature": {
      "visual_verification": "conditional",
      "max_files_warning": 20,
      "commit_prefix": "feat:"
    }
  },
  "worker": {
    "max_iterations": 15,
    "timeout_minutes": 20,
    "allowed_tools": "Write,Read,Edit,Bash(git *),Bash(npm *),Bash(npx *)",
    "max_retries_per_issue": 2
  },
  "forge": {
    "require_tests_pass": true,
    "require_code_review": true,
    "auto_cleanup_worktrees": true,
    "stale_timeout_minutes": 30
  }
}
```

## Modes

### Bug Mode (default)
- Fetches issues labeled `bug`
- Expects minimal, focused changes
- Visual verification is always required
- Warns if >5 files changed
- Commits with `fix:` prefix

### Feature Mode
- Fetches issues labeled `enhancement` or `feature`
- Expects complete implementations
- Visual verification is conditional (UI features only)
- Warns if >20 files changed
- Commits with `feat:` prefix
- Refactoring is encouraged

## Logging

All events are logged as JSONL (one JSON object per line).

### Event Types

| Event | Description |
|-------|-------------|
| `issues_fetched` | Pulled issues from GitHub |
| `issue_selected` | Picked next issue to work on |
| `worktree_created` | Created isolated workspace |
| `worker_launched` | Started worker Claude Code |
| `worker_completed` | Worker finished |
| `code_review` | Forge reviewed the diff |
| `tests_executed` | Ran test suite |
| `visual_verification` | Playwright visual check |
| `pr_created` | Created pull request |
| `pr_merged` | Merged pull request |
| `issue_completed` | Issue fully resolved |
| `issue_failed` | Issue could not be fixed |
| `stale_recovery` | Auto-recovered crashed cycle |
| `error` | Something went wrong |

## Troubleshooting

**"gh: command not found"**
Install GitHub CLI: `winget install GitHub.cli`

**"Not authenticated"**
Run `gh auth login` and follow prompts

**"Worktree already exists"**
```powershell
git worktree remove .worktrees/issue-42 --force
git branch -D fix/issue-42
```

**Worker keeps failing on the same issue**
Check `.forge/logs/workers/cycle-N-output.txt` for the raw Claude output.

**Tests timing out**
Increase `worker.timeout_minutes` in `.forge/config.json`

**Want to reset everything**
```powershell
.\launch-forge.ps1 -Clean
```

## License

MIT
