[CmdletBinding()]
param(
    [string]$DesktopPath = ""
)

$ErrorActionPreference = "Stop"

$projectRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$startScript = Join-Path $projectRoot "Start-BookStudioCompanion.ps1"
$stopScript = Join-Path $projectRoot "Stop-BookStudioCompanion.ps1"
foreach ($requiredPath in @($startScript, $stopScript)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Book Studio launcher file not found: $requiredPath"
    }
}

if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
}
if ([string]::IsNullOrWhiteSpace($DesktopPath)) {
    throw "Windows did not provide a desktop folder path. Pass -DesktopPath explicitly."
}
$DesktopPath = [System.IO.Path]::GetFullPath($DesktopPath)
New-Item -ItemType Directory -Path $DesktopPath -Force | Out-Null

$powershellPath = Join-Path $PSHOME "powershell.exe"
if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
    throw "Windows PowerShell executable not found: $powershellPath"
}

function New-BookStudioShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    try {
        $shortcut.TargetPath = $PowerShellPath
        $shortcut.Arguments = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
        $shortcut.WorkingDirectory = $WorkingDirectory
        $shortcut.Description = $Description
        $shortcut.IconLocation = "$PowerShellPath,0"
        $shortcut.WindowStyle = 7
        $shortcut.Save()
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

$startShortcut = Join-Path $DesktopPath "Book Studio.lnk"
$stopShortcut = Join-Path $DesktopPath "Stop Book Studio.lnk"
New-BookStudioShortcut -Path $startShortcut -ScriptPath $startScript -Description "Start Book Studio in your browser" -PowerShellPath $powershellPath -WorkingDirectory $projectRoot
New-BookStudioShortcut -Path $stopShortcut -ScriptPath $stopScript -Description "Stop the local Book Studio server" -PowerShellPath $powershellPath -WorkingDirectory $projectRoot

Write-Host "Book Studio desktop shortcuts created:"
Write-Host "  Start: $startShortcut"
Write-Host "  Stop:  $stopShortcut"
