[CmdletBinding()]
param(
    [int]$Port = 8790,
    [switch]$OpenCodexApp,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$bookStudioScript = Join-Path $projectRoot "book-studio.ps1"
if (-not (Test-Path -LiteralPath $bookStudioScript)) {
    throw "Book Studio script not found: $bookStudioScript"
}

Write-Host ""
Write-Host "Book Studio Companion"
Write-Host "Project: $projectRoot"
Write-Host ""

$bookStudioModule = Join-Path $projectRoot "lib\BookStudio.psm1"
if (Test-Path -LiteralPath $bookStudioModule) {
    Import-Module $bookStudioModule -Force -DisableNameChecking
}

$codexCommand = if (Get-Command Resolve-BookStudioCodexCommand -ErrorAction SilentlyContinue) {
    Resolve-BookStudioCodexCommand -ProjectRoot $projectRoot
}
else {
    Get-Command codex -ErrorAction SilentlyContinue
}
if ($codexCommand) {
    Write-Host "Codex CLI: $($codexCommand.Source)"
    if ($codexCommand.PSObject.Properties.Name -contains "Discovery") {
        Write-Host "Codex discovery: $($codexCommand.Discovery)"
    }
    try {
        $version = (& $codexCommand.Source --version 2>&1 | Select-Object -First 1)
        if ($version) { Write-Host "Codex version: $version" }
    }
    catch {
        Write-Host "Codex version: could not read version"
    }

    try {
        $loginStatus = & $codexCommand.Source login status 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Codex cached sign-in detected. Use Test connection in the browser before AI generation or chat."
        }
        else {
            Write-Host "Codex sign-in: needs attention"
            Write-Host ($loginStatus -join "`n")
            Write-Host "Run this command if needed: codex login"
        }
    }
    catch {
        Write-Host "Codex sign-in: could not check"
        Write-Host "Run this command if needed: codex login"
    }
}
else {
    Write-Host "Codex CLI: not found"
    Write-Host "Format previews and manual editing work locally. AI drafting and Book Chat require a tested Codex connection."
    Write-Host "Install/sign in to Codex, or create codex-path.txt beside Start Book Studio.cmd with the full path to codex.exe."
}

# Tell the designer when a newer Book Studio is published. The update itself
# runs from Settings so it never interrupts a book that is generating.
if (Get-Command Get-BookStudioUpdateStatus -ErrorAction SilentlyContinue) {
    try {
        $update = Get-BookStudioUpdateStatus -ProjectRoot $projectRoot -Fetch
        if ($update.updateAvailable) {
            Write-Host "Update available: v$($update.installedVersion) -> v$($update.latestVersion). In Book Studio, open Settings and click Get latest updates."
        }
        elseif ($update.isRepository) {
            Write-Host "Book Studio v$($update.installedVersion) is up to date."
        }
        else {
            Write-Host "Book Studio v$($update.installedVersion) (updates: $($update.message))"
        }
    }
    catch {
        Write-Host "Update check skipped: $($_.Exception.Message)"
    }
}

$selectedPort = $Port
if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    while (Get-NetTCPConnection -LocalPort $selectedPort -ErrorAction SilentlyContinue) {
        $selectedPort++
    }
}

$bookStudioRoot = Join-Path $projectRoot ".bookstudio"
New-Item -ItemType Directory -Path $bookStudioRoot -Force | Out-Null
$outLog = Join-Path $bookStudioRoot "server.out.log"
$errLog = Join-Path $bookStudioRoot "server.err.log"
$argumentLine = "-NoProfile -ExecutionPolicy Bypass -File `"$bookStudioScript`" -Port $selectedPort"
$powershellPath = Join-Path $PSHOME "powershell.exe"
$process = Start-Process -FilePath $powershellPath -ArgumentList $argumentLine -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
$url = "http://localhost:$selectedPort/"

$serverReady = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
        $health = Invoke-WebRequest -Uri "$url/api/health" -UseBasicParsing -TimeoutSec 2
        if ($health.StatusCode -eq 200) {
            $serverReady = $true
            break
        }
    }
    catch {
        if ($process.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 250
    }
}
if (-not $serverReady) {
    Write-Host "Book Studio did not become ready. Review the server logs:"
    Write-Host "Output log: $outLog"
    Write-Host "Error log: $errLog"
    if ($process.HasExited) {
        Write-Host "Server process exited with code $($process.ExitCode)."
    }
    throw "Book Studio server failed to start on port $selectedPort."
}

Write-Host ""
Write-Host "Book Studio URL: $url"
Write-Host "Server process: $($process.Id)"
Write-Host "Output log: $outLog"
Write-Host "Error log: $errLog"

if (-not $NoBrowser) {
    Start-Process $url | Out-Null
}

if ($OpenCodexApp -and $codexCommand) {
    Start-Process -FilePath $codexCommand.Source -ArgumentList @("app", "`"$projectRoot`"") | Out-Null
}
