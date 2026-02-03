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

foreach ($file in $hookFiles) {
    $content = Get-Content $file.FullName -Raw
    if ($content -match '\bcat\b' -and $content -notmatch '/usr/bin/cat') {
        $newContent = $content -replace '\bcat\b', '/usr/bin/cat'
        Set-Content $file.FullName -Value $newContent -NoNewline
        Write-Host "Patched: $($file.FullName)" -ForegroundColor Green
    } else {
        Write-Host "Already patched or no cat found: $($file.FullName)" -ForegroundColor Gray
    }
}

Write-Host "`nDone!" -ForegroundColor Cyan
