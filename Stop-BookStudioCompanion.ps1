[CmdletBinding()]
param(
    [int]$Port = 8790
)

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$normalizedRoot = [System.IO.Path]::GetFullPath($projectRoot)
$serverProcesses = @(
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match "book-studio\.ps1" -and
            ($_.CommandLine -match [regex]::Escape($normalizedRoot) -or $_.CommandLine -match [regex]::Escape($projectRoot))
        }
)

if ($serverProcesses.Count -eq 0 -and (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    $connections = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)
    $pids = @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
    foreach ($pid in $pids) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $pid" -ErrorAction SilentlyContinue
        if ($process -and $process.CommandLine -match "book-studio\.ps1") {
            $serverProcesses += $process
        }
    }
}

if ($serverProcesses.Count -eq 0) {
    Write-Host "No Book Studio server process was found for this folder."
    return
}

foreach ($process in $serverProcesses | Sort-Object ProcessId -Unique) {
    Write-Host "Stopping Book Studio server process $($process.ProcessId)..."
    Stop-Process -Id $process.ProcessId -Force
}

Write-Host "Book Studio server stopped."
