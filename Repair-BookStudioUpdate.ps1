[CmdletBinding()]
param([string]$InstallPath)
$ErrorActionPreference = 'Stop'
if (-not $InstallPath) {
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Select your book-studio folder (the folder containing Start Book Studio.cmd).'
    $picker.ShowNewFolderButton = $false
    try {
        if ($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
        $InstallPath = $picker.SelectedPath
    } finally { $picker.Dispose() }
}
$root = (Resolve-Path -LiteralPath $InstallPath).ProviderPath
$modulePath = Join-Path $root 'lib/BookStudio.psm1'
$database = Join-Path $root '.bookstudio/book-studio-db.json'
if (-not (Test-Path -LiteralPath $modulePath) -or -not (Test-Path -LiteralPath $database)) { throw 'Select the installed book-studio folder that contains your books.' }
$installedModule = Import-Module $modulePath -Force -DisableNameChecking -PassThru
# Load only the recovery functions from this download into the existing module.
# Installed app files are untouched so the normal Git updater remains usable.
$recoveryPath = Join-Path $PSScriptRoot 'lib/BookStudioRequestRecovery.ps1'
& $installedModule {
    param($dbPath, $helper)
    . $helper
    Invoke-BookStudioDatabaseLock -DatabasePath $dbPath -ScriptBlock {
        $backup = "$dbPath.before-update-recovery-$([guid]::NewGuid().ToString('N')).bak"
        Copy-Item -LiteralPath $dbPath -Destination $backup
        Write-Host "Book database backup: $backup"
    }
    $count = Repair-BookStudioStaleAiRequests -DatabasePath $dbPath
    Write-Host "Recovered $count finished or interrupted Codex request(s). No book content was changed."
    $db = Read-BookStudioDatabase -DatabasePath $dbPath
    $active = @($db.jobs | ForEach-Object {
        $job = $_
        foreach ($request in @($job.aiRequests | Where-Object status -in @('Running','Queued'))) {
            "'$($job.title)': Codex request $($request.id), process $($request.processId)"
        }
    })
    if ($active.Count) {
        Write-Host 'These requests are still active. Stopping the web server does not stop Codex:'
        $active | ForEach-Object { Write-Host $_ }
        Write-Host 'Wait for them to finish before updating. No active processes were stopped.'
    } else {
        Write-Host 'The stale Codex update block is cleared. Open Book Studio, then Settings > Check for updates > Get latest updates.'
    }
} $database $recoveryPath
