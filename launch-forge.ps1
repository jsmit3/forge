<#
.SYNOPSIS
    Forge Launcher — prepares state, then opens Claude Code
    for you to start the ralph-loop.

.DESCRIPTION
    This script:
    1. Checks prerequisites (claude, gh, git, config files)
    2. Initializes session state (state.json, log dirs)
    3. Opens Claude Code interactively

    Once inside Claude Code, paste the /ralph-loop command that this
    script prints. The ralph-loop plugin handles cycling automatically.

.PARAMETER MaxCycles
    Maximum iterations for the ralph-loop. Default: 10

.PARAMETER Clean
    If set, wipes state.json and logs for a fresh session.

.EXAMPLE
    .\launch-forge.ps1
    .\launch-forge.ps1 -MaxCycles 5
    .\launch-forge.ps1 -Clean -MaxCycles 3
#>

param(
    [int]$MaxCycles = 10,
    [switch]$Clean,
    [ValidateSet("bug", "feature", "brief", "")]
    [string]$Mode = "",
    [string]$BriefPath = ""
)

$ErrorActionPreference = "Continue"
$sessionId = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + (Get-Random -Maximum 9999).ToString("D4")

# --- Helper: Validate Config ---
function Test-ConfigValid {
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )

    $errors = @()

    # Check project section
    if (-not $Config.project) {
        $errors += "Missing 'project' section"
    } else {
        if ([string]::IsNullOrWhiteSpace($Config.project.repo)) {
            $errors += "project.repo is empty - run setup-forge.ps1 with -Repo parameter"
        } elseif ($Config.project.repo -notmatch '^[^/]+/[^/]+$') {
            $errors += "project.repo must be in 'owner/repo' format (got: $($Config.project.repo))"
        }
        if ([string]::IsNullOrWhiteSpace($Config.project.test_command)) {
            $errors += "project.test_command is empty"
        }
    }

    # Check github section
    if (-not $Config.github) {
        $errors += "Missing 'github' section"
    } else {
        if (-not $Config.github.bug_labels -and -not $Config.github.issue_labels) {
            $errors += "Missing github.bug_labels (or legacy github.issue_labels)"
        }
    }

    # Check modes section (new feature)
    if ($Config.modes) {
        if ($Config.modes.default -and $Config.modes.default -notin @("bug", "feature")) {
            $errors += "modes.default must be 'bug' or 'feature' (got: $($Config.modes.default))"
        }
    }

    # Check forge section
    if (-not $Config.forge) {
        $errors += "Missing 'forge' section"
    }

    return $errors
}

# --- Helper: Atomic State Write with Backup ---
function Write-StateAtomic {
    param(
        [Parameter(Mandatory)]
        [object]$State,
        [string]$Path = ".forge/state.json"
    )

    $tempPath = "$Path.tmp"
    $backupPath = "$Path.backup"

    try {
        # Write to temp file first
        $State | ConvertTo-Json -Depth 10 | Out-File $tempPath -Encoding UTF8 -ErrorAction Stop

        # Validate the temp file is valid JSON
        $null = Get-Content $tempPath -Raw | ConvertFrom-Json -ErrorAction Stop

        # Backup existing state (if exists)
        if (Test-Path $Path) {
            Copy-Item $Path $backupPath -Force -ErrorAction SilentlyContinue
        }

        # Atomic move (rename is atomic on same filesystem)
        Move-Item $tempPath $Path -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "  [ERROR] Failed to write state: $_" -ForegroundColor Red
        # Cleanup temp file if it exists
        Remove-Item $tempPath -ErrorAction SilentlyContinue
        return $false
    }
}

# --- Prerequisites -------------------------------------------------------

$missing = @()
if (-not (Get-Command "claude" -ErrorAction SilentlyContinue)) { $missing += "claude" }
if (-not (Get-Command "gh" -ErrorAction SilentlyContinue)) { $missing += "gh" }
if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) { $missing += "git" }
if (-not (Test-Path ".forge/CLAUDE.md")) { $missing += ".forge/CLAUDE.md" }
if (-not (Test-Path ".forge/config.json")) { $missing += ".forge/config.json" }

if ($missing.Count -gt 0) {
    Write-Host "Missing: $($missing -join ', ')" -ForegroundColor Red
    exit 1
}

$ghAuth = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Run 'gh auth login' first." -ForegroundColor Red
    exit 1
}

# --- Clean if requested ---------------------------------------------------

if ($Clean) {
    Write-Host "Cleaning old state..." -ForegroundColor Yellow
    Remove-Item .forge/state.json -ErrorAction SilentlyContinue
    Remove-Item .forge/logs -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Init state ------------------------------------------------------------

if (-not (Test-Path ".forge/logs")) {
    New-Item -ItemType Directory -Path ".forge/logs/workers" -Force | Out-Null
}

# Read and validate config
try {
    $config = Get-Content ".forge/config.json" -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Host "Failed to parse config.json: $_" -ForegroundColor Red
    Write-Host "Ensure the file contains valid JSON. You may need to run setup-forge.ps1 again." -ForegroundColor Yellow
    exit 1
}

# Validate required config fields
$configErrors = Test-ConfigValid -Config $config
if ($configErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "Configuration errors in .forge/config.json:" -ForegroundColor Red
    foreach ($err in $configErrors) {
        Write-Host "  - $err" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Fix these issues or run setup-forge.ps1 to regenerate config." -ForegroundColor Gray
    exit 1
}

# Determine effective mode: CLI param > config default > "bug"
$effectiveMode = $Mode
if (-not $effectiveMode) {
    if ($config.modes -and $config.modes.default) {
        $effectiveMode = $config.modes.default
    } else {
        $effectiveMode = "bug"
    }
}

# Validate brief mode requirements
if ($effectiveMode -eq "brief") {
    if (-not $BriefPath) {
        Write-Host "[ERROR] Brief mode requires -BriefPath parameter" -ForegroundColor Red
        Write-Host "  Example: .\launch-forge.ps1 -Mode brief -BriefPath '.forge/briefs/my-feature.md'" -ForegroundColor Yellow
        exit 1
    }
    if (-not (Test-Path $BriefPath)) {
        Write-Host "[ERROR] Brief file not found: $BriefPath" -ForegroundColor Red
        exit 1
    }
}

if (-not (Test-Path ".forge/state.json")) {
    $newState = @{
        version = "1.2.0"
        last_updated = (Get-Date -Format "o")
        current_cycle = 0
        session_id = $sessionId
        mode = $effectiveMode
        issues = @{
            fetched = @(); in_progress = $null
            completed = @(); failed = @(); skipped = @()
        }
        stats = @{
            total_issues_processed = 0; total_prs_created = 0; total_prs_merged = 0
            total_worker_launches = 0; total_test_runs = 0; total_test_passes = 0
            total_test_failures = 0; total_visual_verifications = 0
            total_visual_passes = 0; total_visual_failures = 0
            total_visual_skipped = 0
        }
        current_worktree = $null
        last_decision = "Session initialized"
        blocked_reason = $null
    }

    # Add brief-specific state if in brief mode
    if ($effectiveMode -eq "brief") {
        $newState.brief = @{
            path = $BriefPath
            title = $null
            plan = $null
            tasks = @()
            progress = @{
                total = 0
                completed = 0
                in_progress = 0
                pending = 0
                failed = 0
                percentage = 0
            }
        }
    }

    if (-not (Write-StateAtomic -State $newState)) {
        Write-Host "Failed to initialize state.json" -ForegroundColor Red
        exit 1
    }
} else {
    # Update mode in existing state.json if Mode param was explicitly provided
    if ($Mode) {
        try {
            $state = Get-Content ".forge/state.json" -Raw | ConvertFrom-Json
            $state.mode = $Mode
            $state.last_updated = (Get-Date -Format "o")

            # Add brief-specific state if switching to brief mode
            if ($Mode -eq "brief" -and -not $state.brief) {
                $state | Add-Member -NotePropertyName "brief" -NotePropertyValue @{
                    path = $BriefPath
                    title = $null
                    plan = $null
                    tasks = @()
                    progress = @{
                        total = 0
                        completed = 0
                        in_progress = 0
                        pending = 0
                        failed = 0
                        percentage = 0
                    }
                } -Force
            } elseif ($Mode -eq "brief" -and $BriefPath) {
                $state.brief.path = $BriefPath
            }

            if (-not (Write-StateAtomic -State $state)) {
                Write-Host "Failed to update mode in state.json" -ForegroundColor Red
                exit 1
            }
        }
        catch {
            Write-Host "Failed to parse state.json: $_" -ForegroundColor Red
            exit 1
        }
    }
}

# --- Print command and launch ----------------------------------------------

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "         FORGE -- Session $sessionId" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# Mode-specific display
$modeColor = switch ($effectiveMode) {
    "bug"     { "Yellow" }
    "feature" { "Magenta" }
    "brief"   { "Cyan" }
    default   { "White" }
}
Write-Host "Mode: " -NoNewline
Write-Host $effectiveMode.ToUpper() -ForegroundColor $modeColor

if ($effectiveMode -eq "brief") {
    Write-Host "Brief: " -NoNewline
    Write-Host $BriefPath -ForegroundColor Gray
}

Write-Host ""
Write-Host "State initialized. Launching Claude Code..." -ForegroundColor Green
Write-Host ""
Write-Host "Paste this command once inside:" -ForegroundColor Yellow
Write-Host ""

# Build mode-specific prompt
$modeDesc = switch ($effectiveMode) {
    "bug"     { "fix one bug" }
    "feature" { "implement one feature" }
    "brief"   { "execute tasks from the implementation plan" }
    default   { "process one item" }
}

$prompt = "You are the FORGE agent. Session: $sessionId. Mode: $effectiveMode. Read .forge/CLAUDE.md for your full instructions. Read .forge/config.json for configuration. Read .forge/state.json for current state."

if ($effectiveMode -eq "brief") {
    $prompt += " Brief path: $BriefPath. If no plan exists, read the brief and create a comprehensive implementation plan. Then execute tasks from the plan. Continue until all tasks are complete."
} else {
    $prompt += " Execute ONE forge cycle ($modeDesc), then exit. When ALL issues are done, output <promise>FORGE_COMPLETE</promise>"
}

Write-Host "/ralph-loop:ralph-loop `"$prompt`" --max-iterations $MaxCycles --completion-promise `"FORGE_COMPLETE`"" -ForegroundColor White
Write-Host ""
Write-Host "========================================================" -ForegroundColor DarkGray

# Launch Claude Code interactively with auto-approve and Opus 4.5
claude --dangerously-skip-permissions --model claude-opus-4-5-20251101
