$cacheDir = Join-Path $env:USERPROFILE ".claude\plugins\cache"

if (-not (Test-Path $cacheDir)) {
    Write-Host "Plugin cache not found at: $cacheDir" -ForegroundColor Red
    exit 1
}

$hookFiles = Get-ChildItem -Path $cacheDir -Recurse -Filter "stop-hook.sh" -ErrorAction SilentlyContinue

if ($hookFiles.Count -eq 0) {
    Write-Host "No stop-hook.sh files found in: $cacheDir" -ForegroundColor Yellow
    exit 0
}

# Commands that need full paths on Windows Git Bash
$commands = @{
    '\bcat\b' = '/usr/bin/cat'
    '\bsed\b' = '/usr/bin/sed'
    '\bgrep\b' = '/usr/bin/grep'
    '\btail\b' = '/usr/bin/tail'
    '\bawk\b' = '/usr/bin/awk'
    '\brm\b' = '/usr/bin/rm'
    '\bmv\b' = '/usr/bin/mv'
}

foreach ($file in $hookFiles) {
    $content = Get-Content $file.FullName -Raw
    $modified = $false

    foreach ($cmd in $commands.Keys) {
        $fullPath = $commands[$cmd]
        # Only replace if not already using full path
        if ($content -match $cmd -and $content -notmatch [regex]::Escape($fullPath)) {
            $content = $content -replace $cmd, $fullPath
            Write-Host "  Patched: $cmd -> $fullPath" -ForegroundColor Green
            $modified = $true
        }
    }

    if ($modified) {
        Set-Content $file.FullName -Value $content -NoNewline
        Write-Host "Updated: $($file.FullName)" -ForegroundColor Cyan
    } else {
        Write-Host "Already fully patched: $($file.FullName)" -ForegroundColor Gray
    }
}

Write-Host "`nDone!" -ForegroundColor Cyan
Write-Host "Restart Claude Code for changes to take effect." -ForegroundColor Yellow
