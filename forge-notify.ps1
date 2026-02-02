# forge-notify.ps1 - Desktop notifications for Forge events
# Usage: .\forge-notify.ps1
#
# Watches forge.jsonl for new events and sends Windows
# desktop notifications for important events.
# Run this in a separate terminal alongside Forge.
# Press Ctrl+C to stop.

param(
    [switch]$TestNotification
)

$ProjectRoot = Get-Location
$ForgeDir = Join-Path $ProjectRoot ".forge"
$LogFile = Join-Path $ForgeDir "logs\forge.jsonl"

# Set up Windows notification capability
Add-Type -AssemblyName System.Windows.Forms

$global:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$global:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$global:NotifyIcon.Visible = $true
$global:NotifyIcon.Text = "Forge"

function Send-Notification {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Type = "Info"
    )

    $iconType = switch ($Type) {
        "Info"    { [System.Windows.Forms.ToolTipIcon]::Info }
        "Warning" { [System.Windows.Forms.ToolTipIcon]::Warning }
        "Error"   { [System.Windows.Forms.ToolTipIcon]::Error }
    }

    $global:NotifyIcon.BalloonTipTitle = $Title
    $global:NotifyIcon.BalloonTipText = $Message
    $global:NotifyIcon.BalloonTipIcon = $iconType
    $global:NotifyIcon.ShowBalloonTip(8000)
}

# Test mode
if ($TestNotification) {
    Send-Notification -Title "Forge" -Message "Notifications are working!" -Type "Info"
    Start-Sleep -Seconds 3
    Send-Notification -Title "Test: Success" -Message "Issue #42 fixed and PR created!" -Type "Info"
    Start-Sleep -Seconds 3
    Send-Notification -Title "Test: Failure" -Message "Issue #99 failed: tests not passing" -Type "Error"
    Start-Sleep -Seconds 2
    $global:NotifyIcon.Visible = $false
    $global:NotifyIcon.Dispose()
    Write-Host "Test notifications sent!" -ForegroundColor Green
    exit 0
}

# Validate
if (-not (Test-Path $ForgeDir)) {
    Write-Host "[ERROR] .forge directory not found. Run setup-forge.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  FORGE NOTIFICATION WATCHER" -ForegroundColor Cyan
Write-Host "  ==========================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Watching: $LogFile"
Write-Host "  Notifications: Windows Desktop"
Write-Host ""
Write-Host "  Events that trigger notifications:" -ForegroundColor DarkGray
Write-Host "    [+] issue_completed    - Issue fixed successfully" -ForegroundColor Green
Write-Host "    [X] issue_failed       - Issue fix failed" -ForegroundColor Red
Write-Host "    [!] visual_verification (NOT_VERIFIED)" -ForegroundColor Yellow
Write-Host "    [!] error              - Something went wrong" -ForegroundColor Red
Write-Host "    [*] pr_created         - Pull request created" -ForegroundColor Cyan
Write-Host "    [-] FORGE_COMPLETE - All done!" -ForegroundColor Green
Write-Host ""
Write-Host "  Press Ctrl+C to stop" -ForegroundColor DarkGray
Write-Host ""

# Send startup notification
Send-Notification -Title "Forge" -Message "Notification watcher started. You'll be alerted on key events." -Type "Info"

# Track what we've already seen
$lastLineCount = 0
if (Test-Path $LogFile) {
    $lastLineCount = (Get-Content $LogFile -ErrorAction SilentlyContinue | Measure-Object).Count
}

# Events that trigger notifications
$NotifiableEvents = @{
    "issue_completed" = @{
        Title = "Issue Fixed!"
        Type  = "Info"
        Message = { param($d) "Issue #$($d.issue_number) fixed in $($d.total_attempts) attempt(s). PR: $($d.pr_url)" }
    }
    "issue_failed" = @{
        Title = "Issue FAILED"
        Type  = "Error"
        Message = { param($d) "Issue #$($d.issue_number) failed after $($d.total_attempts) attempt(s). Reason: $($d.reason)" }
    }
    "pr_created" = @{
        Title = "PR Created"
        Type  = "Info"
        Message = { param($d) "PR #$($d.pr_number) for issue #$($d.issue_number)" }
    }
    "error" = @{
        Title = "Forge Error"
        Type  = "Error"
        Message = { param($d) "$($d.error_message)" }
    }
}

# Main watch loop
try {
    while ($true) {
        if (Test-Path $LogFile) {
            $lines = @(Get-Content $LogFile -ErrorAction SilentlyContinue)
            $currentCount = $lines.Count

            if ($currentCount -gt $lastLineCount) {
                # Process new lines
                for ($i = $lastLineCount; $i -lt $currentCount; $i++) {
                    $line = $lines[$i]
                    if (-not $line -or -not $line.Trim()) { continue }

                    try {
                        $entry = $line | ConvertFrom-Json
                    } catch {
                        continue
                    }

                    $eventName = $entry.event
                    $data = $entry.data

                    # Check for visual_verification with NOT_VERIFIED
                    if ($eventName -eq "visual_verification" -and $data -and $data.verdict -eq "NOT_VERIFIED") {
                        $msg = "Issue #$($data.issue_number): Visual verification FAILED. $($data.visual_assessment)"
                        Send-Notification -Title "Visual Check Failed" -Message $msg -Type "Warning"
                        $ts = if ($entry.timestamp) { ([DateTime]::Parse($entry.timestamp)).ToString("HH:mm:ss") } else { "--:--:--" }
                        Write-Host "  $ts  [!] visual_verification NOT_VERIFIED #$($data.issue_number)" -ForegroundColor Yellow
                        continue
                    }

                    # Check standard notifiable events
                    if ($NotifiableEvents.ContainsKey($eventName)) {
                        $config = $NotifiableEvents[$eventName]
                        $msg = & $config.Message $data
                        Send-Notification -Title $config.Title -Message $msg -Type $config.Type
                        $ts = if ($entry.timestamp) { ([DateTime]::Parse($entry.timestamp)).ToString("HH:mm:ss") } else { "--:--:--" }
                        $color = switch ($config.Type) {
                            "Info"    { "Green" }
                            "Warning" { "Yellow" }
                            "Error"   { "Red" }
                        }
                        Write-Host "  $ts  [$eventName] $msg" -ForegroundColor $color
                    }

                    # Check for forge output signals in worker_completed or similar
                    # These would appear in the launcher output, not JSONL, but check just in case
                }

                $lastLineCount = $currentCount
            }
        }

        # Check if the log file mentions completion
        # (Forge signals like FORGE_COMPLETE appear in launcher output)
        Start-Sleep -Seconds 2
    }
} finally {
    $global:NotifyIcon.Visible = $false
    $global:NotifyIcon.Dispose()
    Write-Host "`nNotification watcher stopped." -ForegroundColor Yellow
}
