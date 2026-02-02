<#
.SYNOPSIS
    Analyze Forge logs to evaluate performance.

.PARAMETER OutputFormat
    Output format: "text" for terminal, "json" for machine-readable, "md" for markdown

.EXAMPLE
    .\analyze-session.ps1
    .\analyze-session.ps1 -OutputFormat json
    .\analyze-session.ps1 -OutputFormat md > report.md
#>

param(
    [string]$LogPath = ".forge/logs/forge.jsonl",
    [string]$StatePath = ".forge/state.json",
    [string]$LauncherLogPath = ".forge/logs/launcher.jsonl",
    [ValidateSet("text", "json", "md")]
    [string]$OutputFormat = "text"
)

# --- Parse Logs ---

function Read-JsonlFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    Get-Content $Path -Encoding UTF8 | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ -ne $null }
}

$forgeLogs = Read-JsonlFile $LogPath
$launcherLogs = Read-JsonlFile $LauncherLogPath
$state = $null
if (Test-Path $StatePath) {
    try {
        $state = Get-Content $StatePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "[WARN] Could not parse $StatePath - file may be corrupted: $_" -ForegroundColor Yellow
        Write-Host "       Try restoring from backup: Copy-Item '$StatePath.backup' '$StatePath'" -ForegroundColor Yellow
    }
}

# --- Compute Metrics ---

$totalCycles = ($launcherLogs | Where-Object { $_.event -eq "cycle_start" }).Count
$sessionEnds = $launcherLogs | Where-Object { $_.event -eq "session_end" }

$issuesFetched = ($forgeLogs | Where-Object { $_.event -eq "issues_fetched" } | Select-Object -Last 1)
$issuesSelected = $forgeLogs | Where-Object { $_.event -eq "issue_selected" }
$issuesCompleted = $forgeLogs | Where-Object { $_.event -eq "issue_completed" }
$issuesFailed = $forgeLogs | Where-Object { $_.event -eq "issue_failed" }
$issuesSkipped = $forgeLogs | Where-Object { $_.event -eq "issue_skipped" }

$workerLaunches = $forgeLogs | Where-Object { $_.event -eq "worker_launched" }
$workerCompletions = $forgeLogs | Where-Object { $_.event -eq "worker_completed" }
$avgWorkerDuration = if ($workerCompletions.Count -gt 0) {
    ($workerCompletions | ForEach-Object { $_.data.duration_sec } | Measure-Object -Average).Average
} else { 0 }

$reviews = $forgeLogs | Where-Object { $_.event -eq "code_review" }
$approvedReviews = $reviews | Where-Object { $_.data.verdict -eq "APPROVED" }
$rejectedReviews = $reviews | Where-Object { $_.data.verdict -eq "REJECTED" }
$reviewApprovalRate = if ($reviews.Count -gt 0) {
    [math]::Round(($approvedReviews.Count / $reviews.Count) * 100, 1)
} else { 0 }

$testRuns = $forgeLogs | Where-Object { $_.event -eq "tests_executed" }
$testPasses = $testRuns | Where-Object { $_.data.passed -eq $true }
$testFailures = $testRuns | Where-Object { $_.data.passed -eq $false }
$testPassRate = if ($testRuns.Count -gt 0) {
    [math]::Round(($testPasses.Count / $testRuns.Count) * 100, 1)
} else { 0 }

$prsCreated = $forgeLogs | Where-Object { $_.event -eq "pr_created" }
$prsMerged = $forgeLogs | Where-Object { $_.event -eq "pr_merged" }
$errors = $forgeLogs | Where-Object { $_.event -eq "error" }

$retriedIssues = $workerLaunches | Group-Object { $_.data.issue_number } |
    Where-Object { $_.Count -gt 1 }
$firstAttemptSuccessRate = if ($issuesSelected.Count -gt 0) {
    $firstAttemptSuccesses = $issuesSelected.Count - $retriedIssues.Count
    [math]::Round(($firstAttemptSuccesses / $issuesSelected.Count) * 100, 1)
} else { 0 }

# Per-issue breakdown
$issueBreakdown = @()
if ($issuesSelected) {
    $issueBreakdown = $issuesSelected | ForEach-Object {
        $num = $_.data.issue_number
        $title = $_.data.title
        $launches = @($workerLaunches | Where-Object { $_.data.issue_number -eq $num }).Count
        $review = $reviews | Where-Object { $_.data.issue_number -eq $num } | Select-Object -Last 1
        $test = $testRuns | Where-Object { $_.data.issue_number -eq $num } | Select-Object -Last 1
        $pr = $prsCreated | Where-Object { $_.data.issue_number -eq $num } | Select-Object -Last 1
        $merged = $prsMerged | Where-Object { $_.data.issue_number -eq $num } | Select-Object -Last 1
        $completed = $issuesCompleted | Where-Object { $_.data.issue_number -eq $num }
        $failed = $issuesFailed | Where-Object { $_.data.issue_number -eq $num }

        $status = if ($merged) { "MERGED" }
                  elseif ($pr) { "PR_OPEN" }
                  elseif ($failed) { "FAILED" }
                  elseif ($completed) { "COMPLETED" }
                  else { "IN_PROGRESS" }

        [PSCustomObject]@{
            Number        = $num
            Title         = $title
            Status        = $status
            Attempts      = $launches
            ReviewVerdict = if ($review) { $review.data.verdict } else { "N/A" }
            TestsPassed   = if ($test) { $test.data.passed } else { "N/A" }
            PRUrl         = if ($pr) { $pr.data.pr_url } else { "N/A" }
        }
    }
}

# --- Build Report ---

$report = @{
    session = @{
        total_cycles = $totalCycles
        total_duration_min = if ($sessionEnds.Count -gt 0) { $sessionEnds[-1].data.total_duration_min } else { "ongoing" }
    }
    issues = @{
        total_fetched    = if ($issuesFetched) { $issuesFetched.data.count } else { 0 }
        total_attempted  = @($issuesSelected).Count
        total_completed  = @($issuesCompleted).Count
        total_failed     = @($issuesFailed).Count
        total_skipped    = @($issuesSkipped).Count
        success_rate_pct = if (@($issuesSelected).Count -gt 0) {
            [math]::Round((@($issuesCompleted).Count / @($issuesSelected).Count) * 100, 1)
        } else { 0 }
    }
    workers = @{
        total_launches            = @($workerLaunches).Count
        avg_duration_sec          = [math]::Round($avgWorkerDuration, 1)
        first_attempt_success_pct = $firstAttemptSuccessRate
        retried_issues            = @($retriedIssues).Count
    }
    code_review = @{
        total_reviews     = @($reviews).Count
        approved          = @($approvedReviews).Count
        rejected          = @($rejectedReviews).Count
        approval_rate_pct = $reviewApprovalRate
    }
    testing = @{
        total_runs    = @($testRuns).Count
        passes        = @($testPasses).Count
        failures      = @($testFailures).Count
        pass_rate_pct = $testPassRate
    }
    pull_requests = @{
        created = @($prsCreated).Count
        merged  = @($prsMerged).Count
    }
    errors = @{
        total = @($errors).Count
    }
}

# --- Output ---

switch ($OutputFormat) {
    "json" {
        $report | ConvertTo-Json -Depth 5
    }
    "md" {
        @"
# Forge -- Session Analysis

## Overview

| Metric | Value |
|--------|-------|
| Total Cycles | $totalCycles |
| Duration | $($report.session.total_duration_min) min |
| Issues Attempted | $($report.issues.total_attempted) |
| Issues Resolved | $($report.issues.total_completed) |
| Success Rate | $($report.issues.success_rate_pct)% |
| PRs Merged | $($report.pull_requests.merged) |

## Worker Performance

| Metric | Value |
|--------|-------|
| Total Launches | $($report.workers.total_launches) |
| Avg Duration | $($report.workers.avg_duration_sec)s |
| First-Attempt Success | $($report.workers.first_attempt_success_pct)% |
| Issues Requiring Retry | $($report.workers.retried_issues) |

## Quality Gates

| Gate | Pass Rate |
|------|-----------|
| Code Review Approval | $($report.code_review.approval_rate_pct)% ($($report.code_review.approved)/$($report.code_review.total_reviews)) |
| Test Suite | $($report.testing.pass_rate_pct)% ($($report.testing.passes)/$($report.testing.total_runs)) |

## Per-Issue Breakdown

| Issue | Title | Status | Attempts | Review | Tests | PR |
|-------|-------|--------|----------|--------|-------|-----|
$($issueBreakdown | ForEach-Object { "| #$($_.Number) | $($_.Title) | $($_.Status) | $($_.Attempts) | $($_.ReviewVerdict) | $($_.TestsPassed) | $($_.PRUrl) |" } | Out-String)

## Errors

Total errors logged: $($report.errors.total)
$($errors | ForEach-Object { "- [$($_.timestamp)] $($_.data.error_message)" } | Out-String)
"@
    }
    default {
        Write-Host ""
        Write-Host "========================================================" -ForegroundColor Cyan
        Write-Host "           SESSION ANALYSIS REPORT                       " -ForegroundColor Cyan
        Write-Host "========================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  OVERVIEW" -ForegroundColor Yellow
        Write-Host "     Cycles:           $totalCycles"
        Write-Host "     Duration:         $($report.session.total_duration_min) min"
        Write-Host ""
        Write-Host "  ISSUES" -ForegroundColor Yellow
        Write-Host "     Attempted:        $($report.issues.total_attempted)"
        Write-Host "     Resolved:         $($report.issues.total_completed)" -ForegroundColor Green
        $failColor = if ($report.issues.total_failed -gt 0) { "Red" } else { "Gray" }
        Write-Host "     Failed:           $($report.issues.total_failed)" -ForegroundColor $failColor
        Write-Host "     Skipped:          $($report.issues.total_skipped)" -ForegroundColor Gray
        Write-Host "     Success Rate:     $($report.issues.success_rate_pct)%"
        Write-Host ""
        Write-Host "  WORKERS" -ForegroundColor Yellow
        Write-Host "     Launches:         $($report.workers.total_launches)"
        Write-Host "     Avg Duration:     $($report.workers.avg_duration_sec)s"
        Write-Host "     First-Attempt:    $($report.workers.first_attempt_success_pct)%"
        Write-Host "     Retried Issues:   $($report.workers.retried_issues)"
        Write-Host ""
        Write-Host "  QUALITY GATES" -ForegroundColor Yellow
        Write-Host "     Review Approval:  $($report.code_review.approval_rate_pct)% ($($report.code_review.approved)/$($report.code_review.total_reviews))"
        Write-Host "     Test Pass Rate:   $($report.testing.pass_rate_pct)% ($($report.testing.passes)/$($report.testing.total_runs))"
        Write-Host ""
        Write-Host "  PULL REQUESTS" -ForegroundColor Yellow
        Write-Host "     Created:          $($report.pull_requests.created)"
        Write-Host "     Merged:           $($report.pull_requests.merged)"
        Write-Host ""

        if ($issueBreakdown) {
            Write-Host "  PER-ISSUE BREAKDOWN" -ForegroundColor Yellow
            $issueBreakdown | ForEach-Object {
                $icon = switch ($_.Status) {
                    "MERGED"      { "[MERGED]" }
                    "PR_OPEN"     { "[PR]    " }
                    "COMPLETED"   { "[DONE]  " }
                    "FAILED"      { "[FAIL]  " }
                    "IN_PROGRESS" { "[WIP]   " }
                    default       { "[?]     " }
                }
                $statusColor = switch ($_.Status) {
                    "MERGED"    { "Green" }
                    "COMPLETED" { "Green" }
                    "FAILED"    { "Red" }
                    default     { "Yellow" }
                }
                Write-Host "     $icon #$($_.Number) -- $($_.Title)" -ForegroundColor $statusColor
                Write-Host "             Attempts: $($_.Attempts) | Review: $($_.ReviewVerdict) | Tests: $($_.TestsPassed)"
            }
        }

        if (@($errors).Count -gt 0) {
            Write-Host ""
            Write-Host "  ERRORS ($(@($errors).Count))" -ForegroundColor Red
            $errors | Select-Object -Last 5 | ForEach-Object {
                Write-Host "     [$($_.timestamp)] $($_.data.error_message)" -ForegroundColor DarkRed
            }
        }

        Write-Host ""
    }
}
