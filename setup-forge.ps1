<#
.SYNOPSIS
    Initialize Forge in your project.

.DESCRIPTION
    Copies the Forge scaffold into your existing project,
    validates prerequisites, and prepares for first run.

.PARAMETER ProjectPath
    Path to your project (default: current directory)

.PARAMETER Repo
    GitHub repo in owner/repo format (auto-detected if omitted)

.PARAMETER TestCommand
    Test command to run (default: "npx playwright test")

.PARAMETER BaseBranch
    Base branch name (auto-detected from remote, defaults to "main")

.EXAMPLE
    .\setup-forge.ps1
    .\setup-forge.ps1 -Repo "myuser/rooted" -TestCommand "npm test"
#>

param(
    [string]$ProjectPath = ".",
    [string]$Repo = "",
    [string]$TestCommand = "npx playwright test",
    [string]$BuildCommand = "npm run build",
    [string]$InstallCommand = "npm install",
    [string]$BaseBranch = "main",
    [string[]]$IssueLabels = @("bug"),
    [switch]$AutoMerge,
    [ValidateSet("bug", "feature")]
    [string]$DefaultMode = "bug"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "         FORGE -- Project Setup               " -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# --- Validate Prerequisites ---

Write-Host "  [CHECK] Checking prerequisites..." -ForegroundColor Yellow

$checks = @(
    @{ Name = "git";    Cmd = "git --version" },
    @{ Name = "gh";     Cmd = "gh --version" },
    @{ Name = "claude"; Cmd = "claude --version" }
)

$allGood = $true
foreach ($check in $checks) {
    try {
        $null = Invoke-Expression $check.Cmd 2>&1
        Write-Host "     [OK] $($check.Name) found" -ForegroundColor Green
    } catch {
        Write-Host "     [FAIL] $($check.Name) not found" -ForegroundColor Red
        $allGood = $false
    }
}

# Check gh auth
$ghAuth = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "     [FAIL] gh not authenticated. Run: gh auth login" -ForegroundColor Red
    $allGood = $false
} else {
    Write-Host "     [OK] gh authenticated" -ForegroundColor Green
}

# Check we are in a git repo
Push-Location $ProjectPath
if (-not (Test-Path ".git")) {
    Write-Host "     [FAIL] Not a git repository" -ForegroundColor Red
    Pop-Location
    exit 1
}

# Auto-detect repo if not provided
if (-not $Repo) {
    $remoteUrl = git remote get-url origin 2>&1
    if ($remoteUrl -match "github\.com[:/](.+?)(?:\.git)?$") {
        $Repo = $Matches[1]
        Write-Host "     [OK] Detected repo: $Repo" -ForegroundColor Green
    } else {
        Write-Host "     [WARN] Could not detect repo. Provide with -Repo" -ForegroundColor Yellow
    }
}

# Auto-detect base branch if using default
if ($BaseBranch -eq "main") {
    # Try to detect from git remote
    $defaultBranch = git symbolic-ref refs/remotes/origin/HEAD 2>$null
    if ($defaultBranch -match "refs/remotes/origin/(.+)$") {
        $detectedBranch = $Matches[1]
        if ($detectedBranch -ne "main") {
            $BaseBranch = $detectedBranch
            Write-Host "     [OK] Detected base branch: $BaseBranch" -ForegroundColor Green
        }
    } else {
        # Fallback: check if master exists but main doesn't
        $hasMaster = git show-ref --verify --quiet refs/remotes/origin/master 2>$null; $hasMasterResult = $LASTEXITCODE -eq 0
        $hasMain = git show-ref --verify --quiet refs/remotes/origin/main 2>$null; $hasMainResult = $LASTEXITCODE -eq 0
        if ($hasMasterResult -and -not $hasMainResult) {
            $BaseBranch = "master"
            Write-Host "     [OK] Detected base branch: master (no main branch found)" -ForegroundColor Green
        }
    }
}

if (-not $allGood) {
    Write-Host ""
    Write-Host "  Fix the above issues and try again." -ForegroundColor Red
    Pop-Location
    exit 1
}

# --- Create Directory Structure ---

Write-Host ""
Write-Host "  [DIRS] Creating Forge structure..." -ForegroundColor Yellow

$dirs = @(
    ".forge",
    ".forge/templates",
    ".forge/logs",
    ".forge/logs/workers",
    ".forge/screenshots",
    ".worktrees"
)

foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "     Created $dir/" -ForegroundColor DarkGray
    }
}

# --- Write Config ---

Write-Host "  [CONFIG] Writing configuration..." -ForegroundColor Yellow

$labelsJson = ($IssueLabels | ForEach-Object { "`"$_`"" }) -join ","
$autoMergeValue = if ($AutoMerge.IsPresent) { "true" } else { "false" }

$config = @"
{
  "project": {
    "name": "$(Split-Path $ProjectPath -Leaf)",
    "repo": "$Repo",
    "base_branch": "$BaseBranch",
    "test_command": "$TestCommand",
    "build_command": "$BuildCommand",
    "install_command": "$InstallCommand"
  },
  "github": {
    "bug_labels": ["bug"],
    "feature_labels": ["enhancement", "feature"],
    "issue_state": "open",
    "max_issues_per_session": 10,
    "auto_merge": $autoMergeValue,
    "pr_base_branch": "$BaseBranch",
    "pr_reviewers": []
  },
  "modes": {
    "default": "$DefaultMode",
    "available": ["bug", "feature"],
    "bug": {
      "visual_verification": "always",
      "max_files_warning": 5,
      "commit_prefix": "fix:",
      "scope": "minimal",
      "refactoring": "discouraged"
    },
    "feature": {
      "visual_verification": "conditional",
      "max_files_warning": 20,
      "commit_prefix": "feat:",
      "scope": "complete",
      "refactoring": "encouraged"
    }
  },
  "worker": {
    "max_iterations": 15,
    "timeout_minutes": 20,
    "allowed_tools": "Write,Read,Edit,Bash(git *),Bash(npm *),Bash(npx *),Bash(node *)",
    "max_retries_per_issue": 2
  },
  "forge": {
    "max_cycles": 20,
    "worktree_base": ".worktrees",
    "require_tests_pass": true,
    "require_code_review": true,
    "auto_cleanup_worktrees": true,
    "stale_timeout_minutes": 30
  },
  "logging": {
    "level": "verbose",
    "format": "jsonl",
    "forge_log": ".forge/logs/forge.jsonl",
    "worker_log_dir": ".forge/logs/workers",
    "summary_file": ".forge/logs/summary.md"
  }
}
"@

$config | Out-File ".forge/config.json" -Encoding UTF8
Write-Host "     Written .forge/config.json" -ForegroundColor DarkGray

# --- Write Initial State ---

$stateFile = ".forge/state.json"
if (-not (Test-Path $stateFile)) {
    @"
{
  "version": "1.1.0",
  "last_updated": null,
  "current_cycle": 0,
  "session_id": null,
  "mode": "$DefaultMode",
  "issues": {
    "fetched": [],
    "in_progress": null,
    "completed": [],
    "failed": [],
    "skipped": []
  },
  "stats": {
    "total_issues_processed": 0,
    "total_prs_created": 0,
    "total_prs_merged": 0,
    "total_worker_launches": 0,
    "total_test_runs": 0,
    "total_test_passes": 0,
    "total_test_failures": 0,
    "total_visual_skipped": 0
  },
  "current_worktree": null,
  "last_decision": null,
  "blocked_reason": null
}
"@ | Out-File $stateFile -Encoding UTF8
    Write-Host "     Written .forge/state.json" -ForegroundColor DarkGray
}

# --- Write Summary Header ---

$summaryFile = ".forge/logs/summary.md"
if (-not (Test-Path $summaryFile)) {
    @"
# Forge -- Session Log

**Project:** $Repo
**Created:** $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

---

"@ | Out-File $summaryFile -Encoding UTF8
}

# --- Copy CLAUDE.md if not present ---

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceClaudeMd = Join-Path $scriptDir ".forge/CLAUDE.md"

if (-not (Test-Path ".forge/CLAUDE.md")) {
    if (Test-Path $sourceClaudeMd) {
        Copy-Item $sourceClaudeMd ".forge/CLAUDE.md"
        Write-Host "     Copied .forge/CLAUDE.md" -ForegroundColor DarkGray
    } else {
        Write-Host "     [WARN] No CLAUDE.md template found. You need to create .forge/CLAUDE.md manually." -ForegroundColor Yellow
    }
}

# --- Update .gitignore ---

$gitignoreEntries = @(
    "",
    "# Forge",
    ".worktrees/",
    ".forge/logs/",
    ".forge/state.json",
    ".forge/worker-prompt-active.md"
)

$gitignorePath = ".gitignore"
$existingContent = if (Test-Path $gitignorePath) { Get-Content $gitignorePath -Raw } else { "" }

if ($existingContent -notmatch "Forge") {
    $gitignoreEntries -join "`n" | Add-Content $gitignorePath -Encoding UTF8
    Write-Host "     Updated .gitignore" -ForegroundColor DarkGray
}

# --- Verify ---

Write-Host ""
Write-Host "  [DONE] Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Files created:" -ForegroundColor Yellow
Get-ChildItem ".forge" -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Replace((Get-Location).Path + "\", "")
    Write-Host "     $rel" -ForegroundColor DarkGray
}

# Show issue count
Write-Host ""
Write-Host "  [ISSUES] Checking for open issues..." -ForegroundColor Yellow
Write-Host "     Default mode: $DefaultMode" -ForegroundColor DarkGray

# Check bug issues
$bugList = gh issue list --label "bug" --state open --json number 2>&1
$bugCount = 0
if ($LASTEXITCODE -eq 0) {
    $bugCount = ($bugList | ConvertFrom-Json).Count
}

# Check feature issues
$featureList = gh issue list --label "enhancement,feature" --state open --json number 2>&1
$featureCount = 0
if ($LASTEXITCODE -eq 0) {
    $featureCount = ($featureList | ConvertFrom-Json).Count
}

if ($LASTEXITCODE -eq 0) {
    $bugColor = if ($bugCount -gt 0) { "Yellow" } else { "Green" }
    $featureColor = if ($featureCount -gt 0) { "Magenta" } else { "Green" }
    Write-Host "     Bug issues:     $bugCount" -ForegroundColor $bugColor
    Write-Host "     Feature issues: $featureCount" -ForegroundColor $featureColor
} else {
    Write-Host "     Could not fetch issues (check repo permissions)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Ready! Next steps:" -ForegroundColor Cyan
Write-Host "     1. Copy launcher scripts into your project:" -ForegroundColor White
Write-Host "        Copy-Item $scriptDir\launch-forge.ps1 ." -ForegroundColor Gray
Write-Host "        Copy-Item $scriptDir\forge-analyze.ps1 ." -ForegroundColor Gray
Write-Host ""
Write-Host "     2. Run Forge:" -ForegroundColor White
Write-Host "        .\launch-forge.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "     3. Analyze results:" -ForegroundColor White
Write-Host "        .\forge-analyze.ps1" -ForegroundColor Gray
Write-Host ""

Pop-Location
