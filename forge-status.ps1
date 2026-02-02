# forge-status.ps1 - Quick CLI status check for Forge
# Usage: .\forge-status.ps1 [-Watch]
#
# Shows current Forge state at a glance.
# Use -Watch to auto-refresh every 5 seconds.

param(
    [switch]$Watch,
    [int]$Interval = 5
)

$ProjectRoot = Get-Location
$ForgeDir = Join-Path $ProjectRoot ".forge"
$LogFile = Join-Path $ForgeDir "logs\forge.jsonl"
$StateFile = Join-Path $ForgeDir "state.json"
$ConfigFile = Join-Path $ForgeDir "config.json"

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 60) { return "$([math]::Floor($Seconds))s" }
    $m = [math]::Floor($Seconds / 60)
    $s = [math]::Floor($Seconds % 60)
    if ($m -lt 60) { return "${m}m ${s}s" }
    $h = [math]::Floor($m / 60)
    return "${h}h $($m % 60)m"
}

function Get-PipelineStep {
    param([string]$EventName)
    $map = @{
        "issues_fetched"      = "FETCH"
        "issue_selected"      = "SELECT"
        "worktree_created"    = "WORKSPACE"
        "worker_launched"     = "WORKER (coding)"
        "worker_completed"    = "WORKER (done)"
        "code_review"         = "REVIEW"
        "tests_executed"      = "TESTS"
        "dev_server_started"  = "VISUAL (server up)"
        "visual_verification" = "VISUAL (done)"
        "dev_server_stopped"  = "VISUAL (cleanup)"
        "pr_created"          = "PR"
        "pr_merged"           = "PR (merged)"
        "issue_completed"     = "COMPLETE"
        "issue_failed"        = "FAILED"
        "worktree_cleaned"    = "CLEANUP"
    }
    if ($map.ContainsKey($EventName)) { return $map[$EventName] }
    return $EventName.ToUpper()
}

function Show-Status {
    Clear-Host

    # Check if Forge directory exists
    if (-not (Test-Path $ForgeDir)) {
        Write-Host "  [!] No .forge directory found. Run setup-forge.ps1 first." -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "  FORGE STATUS" -ForegroundColor Cyan
    Write-Host "  =======================" -ForegroundColor Cyan
    Write-Host ""

    # Read state
    $state = $null
    if (Test-Path $StateFile) {
        try {
            $stateContent = Get-Content $StateFile -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($stateContent)) {
                Write-Host "  [!] state.json is empty" -ForegroundColor Red
            } else {
                $state = $stateContent | ConvertFrom-Json -ErrorAction Stop
            }
        } catch {
            Write-Host "  [!] Could not parse state.json: $_" -ForegroundColor Red
            Write-Host "      Try restoring from backup:" -ForegroundColor Yellow
            Write-Host "      Copy-Item '.forge/state.json.backup' '.forge/state.json'" -ForegroundColor Yellow
        }
    }

    # Display mode
    if ($state -and $state.mode) {
        $modeColor = if ($state.mode -eq "bug") { "Yellow" } else { "Magenta" }
        Write-Host "  Mode:     " -NoNewline
        Write-Host $state.mode.ToUpper() -ForegroundColor $modeColor
    }

    # Read events
    $events = @()
    if (Test-Path $LogFile) {
        $lines = Get-Content $LogFile -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ($line.Trim()) {
                try {
                    $events += ($line | ConvertFrom-Json)
                } catch {}
            }
        }
    }

    if ($events.Count -eq 0 -and $null -eq $state) {
        Write-Host "  Status: " -NoNewline
        Write-Host "NOT RUNNING" -ForegroundColor DarkGray
        Write-Host "  No events or state found."
        Write-Host ""
        return
    }

    # Session info
    $sessionId = if ($state -and $state.session_id) { $state.session_id } elseif ($events.Count -gt 0) { $events[0].session_id } else { "--" }
    $cycle = if ($state -and $state.current_cycle) { $state.current_cycle } elseif ($events.Count -gt 0) { $events[-1].cycle } else { 0 }

    Write-Host "  Session:  $sessionId"
    Write-Host "  Cycle:    $cycle"

    # Uptime
    if ($events.Count -gt 0) {
        $startTs = [DateTime]::Parse($events[0].timestamp)
        $elapsed = (Get-Date) - $startTs
        Write-Host "  Uptime:   $(Format-Duration $elapsed.TotalSeconds)"
    }

    # Current status
    $lastEvent = if ($events.Count -gt 0) { $events[-1] } else { $null }

    if ($lastEvent) {
        $step = Get-PipelineStep -EventName $lastEvent.event
        $isTerminal = $lastEvent.event -in @("issue_completed", "issue_failed", "issue_skipped")
        $isError = $lastEvent.event -eq "error"

        Write-Host ""
        Write-Host "  Pipeline: " -NoNewline

        if ($isTerminal) {
            if ($lastEvent.event -eq "issue_completed") {
                Write-Host "COMPLETE" -ForegroundColor Green
            } elseif ($lastEvent.event -eq "issue_failed") {
                Write-Host "FAILED" -ForegroundColor Red
            } else {
                Write-Host "SKIPPED" -ForegroundColor Yellow
            }
        } elseif ($isError) {
            Write-Host "ERROR" -ForegroundColor Red
        } else {
            Write-Host "$step" -ForegroundColor Yellow
        }

        # Pipeline progress bar
        $steps = @("FETCH", "SELECT", "WKSPACE", "WORKER", "REVIEW", "TESTS", "VISUAL", "PR", "CLEAN")
        $stepEvents = @(
            @("issues_fetched"),
            @("issue_selected"),
            @("worktree_created"),
            @("worker_completed"),
            @("code_review"),
            @("tests_executed"),
            @("visual_verification"),
            @("pr_created"),
            @("worktree_cleaned", "issue_completed", "issue_failed")
        )

        $eventNames = $events | ForEach-Object { $_.event }
        Write-Host ""
        Write-Host "  " -NoNewline

        for ($i = 0; $i -lt $steps.Count; $i++) {
            $isDone = $false
            $isActive = $false
            $isFail = $false

            foreach ($se in $stepEvents[$i]) {
                if ($eventNames -contains $se) {
                    if ($se -eq "issue_failed") { $isFail = $true }
                    else { $isDone = $true }
                }
            }

            # Check if this is the active step
            if (-not $isDone -and -not $isFail) {
                # Check if previous step is done
                if ($i -eq 0 -or ($i -gt 0 -and ($stepEvents[$i-1] | Where-Object { $eventNames -contains $_ }))) {
                    if (-not $isTerminal) { $isActive = $true }
                }
            }

            if ($isFail) {
                Write-Host "[X]" -ForegroundColor Red -NoNewline
            } elseif ($isDone) {
                Write-Host "[+]" -ForegroundColor Green -NoNewline
            } elseif ($isActive) {
                Write-Host "[>]" -ForegroundColor Yellow -NoNewline
            } else {
                Write-Host "[ ]" -ForegroundColor DarkGray -NoNewline
            }

            if ($i -lt $steps.Count - 1) { Write-Host "-" -ForegroundColor DarkGray -NoNewline }
        }
        Write-Host ""
        Write-Host "  " -NoNewline
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $lbl = $steps[$i].PadRight(4).Substring(0,4)
            Write-Host "$lbl" -ForegroundColor DarkGray -NoNewline
            if ($i -lt $steps.Count - 1) { Write-Host " " -NoNewline }
        }
        Write-Host ""
    }

    # Current issue
    Write-Host ""
    if ($state -and $state.issues -and $state.issues.in_progress) {
        $ip = $state.issues.in_progress
        Write-Host "  Current:  " -NoNewline
        Write-Host "#$($ip.number)" -ForegroundColor Cyan -NoNewline
        Write-Host " - $($ip.title)"
        if ($ip.started_at) {
            $elapsed = (Get-Date) - [DateTime]::Parse($ip.started_at)
            Write-Host "  Elapsed:  $(Format-Duration $elapsed.TotalSeconds)"
        }
        Write-Host "  Attempts: $($ip.attempts)"
    }

    # Issues summary
    Write-Host ""
    Write-Host "  ISSUES" -ForegroundColor Cyan
    Write-Host "  ------"

    $completed = @()
    $failed = @()
    $skipped = @()
    $pending = @()

    if ($state -and $state.issues) {
        if ($state.issues.completed) { $completed = @($state.issues.completed) }
        if ($state.issues.failed) { $failed = @($state.issues.failed) }
        if ($state.issues.skipped) { $skipped = @($state.issues.skipped) }
        if ($state.issues.fetched) {
            $processedNums = @()
            $processedNums += $completed | ForEach-Object { $_.number }
            $processedNums += $failed | ForEach-Object { $_.number }
            $processedNums += $skipped | ForEach-Object { $_.number }
            if ($state.issues.in_progress) { $processedNums += $state.issues.in_progress.number }
            $pending = @($state.issues.fetched | Where-Object { $_.number -notin $processedNums })
        }
    }

    foreach ($i in $completed) {
        Write-Host "  " -NoNewline
        Write-Host "[+]" -ForegroundColor Green -NoNewline
        Write-Host " #$($i.number) - $($i.title)" -NoNewline
        if ($i.pr_url) { Write-Host " (PR)" -ForegroundColor Green -NoNewline }
        Write-Host ""
    }
    foreach ($i in $failed) {
        Write-Host "  " -NoNewline
        Write-Host "[X]" -ForegroundColor Red -NoNewline
        Write-Host " #$($i.number) - $($i.title) ($($i.reason))"
    }
    foreach ($i in $skipped) {
        Write-Host "  " -NoNewline
        Write-Host "[-]" -ForegroundColor Yellow -NoNewline
        Write-Host " #$($i.number) - $($i.title)"
    }
    if ($state -and $state.issues -and $state.issues.in_progress) {
        $ip = $state.issues.in_progress
        Write-Host "  " -NoNewline
        Write-Host "[>]" -ForegroundColor Yellow -NoNewline
        Write-Host " #$($ip.number) - $($ip.title) (in progress)"
    }
    foreach ($i in $pending) {
        Write-Host "  " -NoNewline
        Write-Host "[ ]" -ForegroundColor DarkGray -NoNewline
        Write-Host " #$($i.number) - $($i.title)" -ForegroundColor DarkGray
    }

    # Stats
    Write-Host ""
    Write-Host "  STATS" -ForegroundColor Cyan
    Write-Host "  -----"

    if ($state -and $state.stats) {
        $s = $state.stats
        Write-Host "  Processed:  $($s.total_issues_processed ?? 0)"
        Write-Host "  PRs:        $($s.total_prs_created ?? 0) created, $($s.total_prs_merged ?? 0) merged"
        if ($s.total_test_runs -and $s.total_test_runs -gt 0) {
            $rate = [math]::Round(($s.total_test_passes / $s.total_test_runs) * 100)
            Write-Host "  Tests:      ${rate}% pass rate ($($s.total_test_runs) runs)"
        }
        if ($s.total_visual_verifications -and $s.total_visual_verifications -gt 0) {
            Write-Host "  Visual:     $($s.total_visual_passes ?? 0)/$($s.total_visual_verifications) passed"
        }
        if ($s.total_visual_skipped -and $s.total_visual_skipped -gt 0) {
            Write-Host "  V.Skipped:  $($s.total_visual_skipped)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  No stats yet"
    }

    # Last 5 events
    Write-Host ""
    Write-Host "  RECENT EVENTS" -ForegroundColor Cyan
    Write-Host "  -------------"

    $recentEvents = $events | Select-Object -Last 5
    foreach ($e in $recentEvents) {
        $ts = if ($e.timestamp) {
            try { ([DateTime]::Parse($e.timestamp)).ToString("HH:mm:ss") } catch { "--:--:--" }
        } else { "--:--:--" }

        $evtName = $e.event.PadRight(22)
        $color = switch -Wildcard ($e.event) {
            "error"            { "Red" }
            "issue_failed"     { "Red" }
            "issue_completed"  { "Green" }
            "pr_created"       { "Green" }
            "worker_launched"  { "Yellow" }
            default            { "DarkGray" }
        }
        Write-Host "  $ts  " -NoNewline -ForegroundColor DarkGray
        Write-Host "$evtName" -NoNewline -ForegroundColor $color

        # Brief detail
        $detail = ""
        if ($e.data) {
            switch ($e.event) {
                "issues_fetched"      { $detail = "$($e.data.count) issues" }
                "issue_selected"      { $detail = "#$($e.data.issue_number)" }
                "worker_launched"     { $detail = "attempt $($e.data.attempt)" }
                "worker_completed"    { $detail = "$($e.data.duration_sec)s" }
                "code_review"         { $detail = $e.data.verdict }
                "tests_executed"      { $detail = "$($e.data.test_count) tests, $($e.data.failures) failed" }
                "visual_verification" { $detail = $e.data.verdict }
                "pr_created"          { $detail = "PR #$($e.data.pr_number)" }
                "issue_completed"     { $detail = "#$($e.data.issue_number)" }
                "issue_failed"        { $detail = "#$($e.data.issue_number): $($e.data.reason)" }
                "error"               { $detail = $e.data.error_message }
            }
        }
        Write-Host " $detail"
    }

    Write-Host ""

    if ($Watch) {
        Write-Host "  Refreshing every ${Interval}s... (Ctrl+C to stop)" -ForegroundColor DarkGray
    }
}

# Run
if ($Watch) {
    while ($true) {
        Show-Status
        Start-Sleep -Seconds $Interval
    }
} else {
    Show-Status
}
