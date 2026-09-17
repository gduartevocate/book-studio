[CmdletBinding()]
param(
    [int]$Port = 8790,
    [string]$DatabasePath,
    [switch]$OpenBrowser
)

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$modulePath = Join-Path $projectRoot "lib\BookStudio.psm1"
Import-Module $modulePath -Force

if ($OpenBrowser) {
    Start-Process "http://localhost:$Port/" | Out-Null
}

Start-BookStudioServer -ProjectRoot $projectRoot -Port $Port -DatabasePath $DatabasePath
