# forge-dashboard.ps1 - Live monitoring dashboard for Forge
# Usage: .\forge-dashboard.ps1 [-Port 9847] [-NoBrowser]
#
# Starts a local HTTP server serving the Forge dashboard.
# Open http://localhost:9847 in your browser.
# Press Ctrl+C to stop.

param(
    [int]$Port = 9847,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

# Paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Get-Location
$ForgeDir = Join-Path $ProjectRoot ".forge"
$LogFile = Join-Path $ForgeDir "logs\forge.jsonl"
$StateFile = Join-Path $ForgeDir "state.json"
$ConfigFile = Join-Path $ForgeDir "config.json"
$DashboardFile = Join-Path $ScriptDir "forge-dashboard.html"

# Validate
if (-not (Test-Path $ForgeDir)) {
    Write-Host "[ERROR] .forge directory not found. Run setup-forge.ps1 first." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $DashboardFile)) {
    Write-Host "[ERROR] forge-dashboard.html not found in $ScriptDir" -ForegroundColor Red
    exit 1
}

# Load dashboard HTML once (we'll re-read it on each request to pick up changes during dev)
$DashboardHtml = ""

# Create HTTP listener
$Url = "http://localhost:${Port}/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Url)

try {
    $listener.Start()
} catch {
    if ($_.Exception.Message -match "access is denied") {
        Write-Host "[ERROR] Port $Port requires elevation. Try a different port:" -ForegroundColor Red
        Write-Host "  .\forge-dashboard.ps1 -Port 8080" -ForegroundColor Yellow
        exit 1
    }
    throw
}

Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "  FORGE DASHBOARD" -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Dashboard: " -NoNewline
Write-Host "http://localhost:${Port}/" -ForegroundColor Green
Write-Host "  Project:   $ProjectRoot"
Write-Host "  Logs:      $LogFile"
Write-Host ""
Write-Host "  Press Ctrl+C to stop" -ForegroundColor DarkGray
Write-Host ""

# Open browser
if (-not $NoBrowser) {
    Start-Process "http://localhost:${Port}/"
}

# Content type map
$ContentTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".txt"  = "text/plain; charset=utf-8"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif"  = "image/gif"
    ".svg"  = "image/svg+xml"
}

function Send-Response {
    param($Response, $Content, $ContentType, $StatusCode = 200)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    if ($Content -is [byte[]]) {
        $Response.ContentLength64 = $Content.Length
        $Response.OutputStream.Write($Content, 0, $Content.Length)
    } else {
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $Response.ContentLength64 = $buffer.Length
        $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    }
    $Response.Close()
}

function Send-404 {
    param($Response)
    Send-Response -Response $Response -Content "Not found" -ContentType "text/plain" -StatusCode 404
}

function Send-File {
    param($Response, $FilePath)
    if (-not (Test-Path $FilePath)) {
        Send-404 -Response $Response
        return
    }
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $ct = $ContentTypes[$ext]
    if (-not $ct) { $ct = "application/octet-stream" }

    # Binary files (images)
    if ($ext -match "^\.(png|jpg|jpeg|gif|svg)$") {
        $bytes = [System.IO.File]::ReadAllBytes($FilePath)
        Send-Response -Response $Response -Content $bytes -ContentType $ct
    } else {
        $text = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        Send-Response -Response $Response -Content $text -ContentType $ct
    }
}

# Main loop
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        $path = $request.Url.LocalPath

        try {
            switch -Wildcard ($path) {
                "/" {
                    Send-File -Response $response -FilePath $DashboardFile
                }
                "/api/state" {
                    if (Test-Path $StateFile) {
                        $content = [System.IO.File]::ReadAllText($StateFile, [System.Text.Encoding]::UTF8)
                        Send-Response -Response $response -Content $content -ContentType "application/json; charset=utf-8"
                    } else {
                        Send-Response -Response $response -Content "{}" -ContentType "application/json; charset=utf-8"
                    }
                }
                "/api/logs" {
                    if (Test-Path $LogFile) {
                        $content = [System.IO.File]::ReadAllText($LogFile, [System.Text.Encoding]::UTF8)
                        Send-Response -Response $response -Content $content -ContentType "text/plain; charset=utf-8"
                    } else {
                        Send-Response -Response $response -Content "" -ContentType "text/plain; charset=utf-8"
                    }
                }
                "/api/config" {
                    if (Test-Path $ConfigFile) {
                        $content = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8)
                        Send-Response -Response $response -Content $content -ContentType "application/json; charset=utf-8"
                    } else {
                        Send-Response -Response $response -Content "{}" -ContentType "application/json; charset=utf-8"
                    }
                }
                "/api/screenshots/*" {
                    # Serve screenshot files from project directory
                    $relPath = $path -replace "^/api/screenshots/", ""
                    $relPath = $relPath -replace "/", "\"
                    $fullPath = Join-Path $ProjectRoot $relPath
                    Send-File -Response $response -FilePath $fullPath
                }
                default {
                    Send-404 -Response $response
                }
            }
        } catch {
            try {
                Send-Response -Response $response -Content "Internal error: $($_.Exception.Message)" -ContentType "text/plain" -StatusCode 500
            } catch {
                # Response may already be closed
            }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
    Write-Host "`nDashboard stopped." -ForegroundColor Yellow
}
