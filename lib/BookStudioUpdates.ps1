# Self-update for git-cloned installs.
#
# Designers install Book Studio with `git clone` from the distribution repo and
# update it from Settings. Everything here runs git non-interactively (no
# credential prompts can hang the server), refuses to update while a book is
# generating or a Codex request is running, and only ever fast-forwards, so a
# designer's folder can never end up in a merge. Book data (.bookstudio, dist,
# codex-path.txt) is ignored by git and untouched by an update.

function Resolve-BookStudioGitCommand {
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) | Where-Object { $_ }
    foreach ($base in $bases) {
        $candidate = Join-Path $base 'Git\cmd\git.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Invoke-BookStudioGit {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60
    )

    $git = Resolve-BookStudioGitCommand
    if (-not $git) { throw 'Git for Windows is not installed or not on PATH. Install it from https://git-scm.com/download/win, then reopen Book Studio.' }
    $quoted = @('-C', $ProjectRoot) + $Arguments | ForEach-Object { if ($_ -match '\s' -and $_ -notmatch '^".*"$') { '"' + $_ + '"' } else { $_ } }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $git
    $info.Arguments = ($quoted -join ' ')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    # Never block on a credential or SSH prompt inside a hidden server process.
    $info.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $info.EnvironmentVariables['GCM_INTERACTIVE'] = 'Never'
    $process = [System.Diagnostics.Process]::Start($info)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "git $($Arguments -join ' ') did not finish within $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    return [pscustomobject]@{
        command = "git $($Arguments -join ' ')"
        exitCode = $process.ExitCode
        stdout = $stdoutTask.Result.TrimEnd()
        stderr = $stderrTask.Result.TrimEnd()
    }
}

function Get-BookStudioInstalledVersion {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    try { return [string](Get-Content -LiteralPath (Join-Path $ProjectRoot 'book-studio/version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version }
    catch { return '' }
}

function Get-BookStudioUpdateStatus {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$Fetch
    )

    $status = [pscustomobject]@{
        installedVersion = Get-BookStudioInstalledVersion -ProjectRoot $ProjectRoot
        latestVersion = ''
        gitAvailable = $false
        gitPath = ''
        isRepository = $false
        branch = ''
        remote = ''
        localCommit = ''
        remoteCommit = ''
        ahead = 0
        behind = 0
        dirty = $false
        dirtyFiles = @()
        fetched = [bool]$Fetch
        updateAvailable = $false
        canUpdate = $false
        changes = @()
        message = ''
        checkedAt = (Get-Date).ToString('o')
    }

    $git = Resolve-BookStudioGitCommand
    if (-not $git) {
        $status.message = 'Git for Windows is not installed, so Book Studio cannot check for updates. Install it from https://git-scm.com/download/win and reopen Book Studio.'
        return $status
    }
    $status.gitAvailable = $true
    $status.gitPath = $git

    $inside = Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('rev-parse', '--is-inside-work-tree')
    $top = if ($inside.exitCode -eq 0 -and $inside.stdout -eq 'true') { Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('rev-parse', '--show-toplevel') } else { $null }
    $sameRoot = $top -and $top.exitCode -eq 0 -and ([System.IO.Path]::GetFullPath($top.stdout).TrimEnd('\') -eq [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\'))
    if (-not $sameRoot) {
        $status.message = 'This Book Studio folder was not installed with git clone, so it cannot update itself. Clone the distribution repository into a new folder (see docs/book-studio-colleague-setup.md) or install the latest package by hand.'
        return $status
    }
    $status.isRepository = $true

    $branch = (Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).stdout
    $status.branch = $branch
    $remoteName = (Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('config', "branch.$branch.remote")).stdout
    if ([string]::IsNullOrWhiteSpace($remoteName)) { $remoteName = 'origin' }
    $status.remote = (Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('remote', 'get-url', $remoteName)).stdout
    if ([string]::IsNullOrWhiteSpace($status.remote)) {
        $status.message = "No update source is configured for this folder (branch '$branch' has no remote)."
        return $status
    }

    if ($Fetch) {
        $fetchResult = Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('fetch', '--quiet', $remoteName) -TimeoutSeconds 120
        if ($fetchResult.exitCode -ne 0) {
            $status.message = "Could not reach the update server ($($status.remote)). $($fetchResult.stderr)".Trim()
            return $status
        }
    }

    $upstream = "$remoteName/$branch"
    $status.localCommit = (Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('rev-parse', '--short', 'HEAD')).stdout
    $remoteRev = Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('rev-parse', '--short', $upstream)
    if ($remoteRev.exitCode -ne 0) {
        $status.message = "The update server has no '$branch' branch yet. Click Check for updates after the first release is published."
        return $status
    }
    $status.remoteCommit = $remoteRev.stdout

    $counts = Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('rev-list', '--left-right', '--count', "HEAD...$upstream")
    if ($counts.exitCode -eq 0 -and $counts.stdout -match '^(\d+)\s+(\d+)$') {
        $status.ahead = [int]$Matches[1]
        $status.behind = [int]$Matches[2]
    }
    $porcelain = Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('status', '--porcelain', '--untracked-files=no')
    $status.dirtyFiles = @($porcelain.stdout -split "\r?\n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Substring([Math]::Min(3, $_.Length)).Trim() })
    $status.dirty = $status.dirtyFiles.Count -gt 0

    $latest = Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('show', "${upstream}:book-studio/version.json")
    if ($latest.exitCode -eq 0) {
        try { $status.latestVersion = [string]($latest.stdout | ConvertFrom-Json).version } catch { $status.latestVersion = '' }
    }
    if ($status.behind -gt 0) {
        $log = Invoke-BookStudioGit -ProjectRoot $ProjectRoot -Arguments @('log', '--no-merges', '--pretty=format:%h %s', '-n', '20', "HEAD..$upstream")
        $status.changes = @($log.stdout -split "\r?\n" | Where-Object { $_.Trim() })
    }

    $status.updateAvailable = $status.behind -gt 0
    $status.canUpdate = $status.updateAvailable -and -not $status.dirty -and $status.ahead -eq 0
    $latestLabel = if ($status.latestVersion) { "v$($status.latestVersion)" } else { "$($status.behind) newer change(s)" }
    if ($status.updateAvailable) {
        $status.message = "Update available: $latestLabel ($($status.behind) change(s) since v$($status.installedVersion))."
        if ($status.dirty) { $status.message += " Local changes block the update; review or discard them first: $($status.dirtyFiles -join ', ')." }
        elseif ($status.ahead -gt 0) { $status.message += " This folder has $($status.ahead) local commit(s) that are not on the update server, so it cannot fast-forward." }
    }
    elseif ($Fetch) {
        $status.message = "Book Studio v$($status.installedVersion) is up to date."
    }
    else {
        $status.message = "Installed v$($status.installedVersion). Click Check for updates to contact the update server."
    }
    return $status
}

function Get-BookStudioUpdateBlocker {
    # An update restarts the server; never do that under a running job or Codex request.
    param([Parameter(Mandatory)][string]$DatabasePath)

    $db = Read-BookStudioDatabase -DatabasePath $DatabasePath
    foreach ($job in @($db.jobs)) {
        $label = if ($job.title) { [string]$job.title } else { [string]$job.id }
        if ($job.status -in @('Queued', 'Running')) { return "'$label' is still generating. Wait for it to finish before updating." }
        foreach ($request in @($job.aiRequests)) {
            if ($request.status -eq 'Running') { return "A Codex request is still running for '$label'. Wait for it to finish before updating." }
        }
    }
    return ''
}

function Start-BookStudioUpdate {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$DatabasePath = '',
        [int]$Port = 8790,
        [int]$ServerProcessId = 0,
        [switch]$NoRestart,
        [switch]$Wait
    )

    $status = Get-BookStudioUpdateStatus -ProjectRoot $ProjectRoot -Fetch
    if (-not $status.isRepository) { throw $status.message }
    if ($status.dirty) { throw "Local changes block the update. Review or discard them first: $($status.dirtyFiles -join ', ')." }
    if ($status.ahead -gt 0) { throw "This folder has $($status.ahead) local commit(s) that are not on the update server, so it cannot fast-forward. Ask for help before updating." }
    if (-not $status.updateAvailable) {
        if ($status.message -and -not $status.remoteCommit) { throw $status.message }
        throw "Book Studio v$($status.installedVersion) is already up to date."
    }
    if ($DatabasePath) {
        $blocker = Get-BookStudioUpdateBlocker -DatabasePath $DatabasePath
        if ($blocker) { throw $blocker }
    }

    $updateId = Get-Date -Format 'yyyyMMdd-HHmmss'
    $folder = Join-Path $ProjectRoot ".bookstudio/updates/$updateId"
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $statusPath = Join-Path $folder 'status.json'
    $logPath = Join-Path $folder 'update.log'
    $scriptPath = Join-Path $folder 'apply-update.ps1'
    $record = [pscustomobject]@{
        id = $updateId
        status = 'Running'
        phase = 'Starting'
        message = "Updating Book Studio from v$($status.installedVersion) to v$($status.latestVersion)..."
        fromVersion = $status.installedVersion
        toVersion = $status.latestVersion
        restart = -not $NoRestart
        port = $Port
        startedAt = (Get-Date).ToString('o')
        completedAt = ''
        logPath = $logPath
    }
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statusPath -Encoding UTF8

    $escapedRoot = $ProjectRoot.Replace("'", "''")
    $escapedStatus = $statusPath.Replace("'", "''")
    $escapedLog = $logPath.Replace("'", "''")
    $escapedGit = $status.gitPath.Replace("'", "''")
    $restartFlag = if ($NoRestart) { '$false' } else { '$true' }
    # The apply script runs outside the server process so it can replace files,
    # stop this server, and start the updated one.
    $script = @"
`$ErrorActionPreference = 'Continue'
`$root = '$escapedRoot'
`$statusPath = '$escapedStatus'
`$logPath = '$escapedLog'
`$git = '$escapedGit'
`$port = $Port
`$serverPid = $ServerProcessId
`$restart = $restartFlag
function Write-UpdateStatus([string]`$Status, [string]`$Phase, [string]`$Message) {
    `$record = Get-Content -LiteralPath `$statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    `$record.status = `$Status
    `$record.phase = `$Phase
    `$record.message = `$Message
    if (`$Status -ne 'Running') { `$record.completedAt = (Get-Date).ToString('o') }
    `$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath `$statusPath -Encoding UTF8
    Add-Content -LiteralPath `$logPath -Value "[`$((Get-Date).ToString('s'))] `$Phase - `$Message" -Encoding UTF8
}
`$env:GIT_TERMINAL_PROMPT = '0'
`$env:GCM_INTERACTIVE = 'Never'
Write-UpdateStatus 'Running' 'Downloading' 'Downloading the latest Book Studio from the update server...'
`$output = (& `$git -C `$root pull --ff-only 2>&1 | Out-String)
`$pullExit = `$LASTEXITCODE
Add-Content -LiteralPath `$logPath -Value `$output -Encoding UTF8
if (`$pullExit -ne 0) {
    Write-UpdateStatus 'Failed' 'Download failed' "The update could not be applied. `$(`$output.Trim())"
    exit 1
}
`$newVersion = try { [string](Get-Content -LiteralPath (Join-Path `$root 'book-studio/version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { '' }
if (-not `$restart) {
    Write-UpdateStatus 'Completed' 'Updated' "Book Studio files were updated to v`$newVersion. Restart Book Studio to use the new version."
    exit 0
}
Write-UpdateStatus 'Running' 'Restarting' "Files updated to v`$newVersion. Restarting Book Studio..."
if (`$serverPid -gt 0) { Stop-Process -Id `$serverPid -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
`$logs = Join-Path `$root '.bookstudio'
`$server = Start-Process -FilePath (Join-Path `$PSHOME 'powershell.exe') -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path `$root 'book-studio.ps1') + '"'), '-Port', `$port) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path `$logs 'server.out.log') -RedirectStandardError (Join-Path `$logs 'server.err.log')
`$ready = `$false
for (`$i = 0; `$i -lt 60; `$i++) {
    try { `$null = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:`$port/api/health" -TimeoutSec 2; `$ready = `$true; break } catch { Start-Sleep -Milliseconds 500 }
}
if (`$ready) { Write-UpdateStatus 'Completed' 'Restarted' "Book Studio v`$newVersion is running." }
else { Write-UpdateStatus 'Failed' 'Restart failed' "Book Studio v`$newVersion was installed but did not start on port `$port. Run Start Book Studio.cmd and check .bookstudio\server.err.log." }
"@
    Set-Content -LiteralPath $scriptPath -Value $script -Encoding UTF8

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")
    if ($Wait) {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -Wait | Out-Null
    }
    else {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    }
    return (Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-BookStudioUpdateProgress {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $root = Join-Path $ProjectRoot '.bookstudio/updates'
    $latest = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)[0]
    if (-not $latest) { return [pscustomobject]@{ status = 'None'; message = 'No update has been started on this computer.'; logTail = @() } }
    $statusPath = Join-Path $latest.FullName 'status.json'
    if (-not (Test-Path -LiteralPath $statusPath)) { return [pscustomobject]@{ status = 'None'; message = 'No update has been started on this computer.'; logTail = @() } }
    $record = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $logPath = Join-Path $latest.FullName 'update.log'
    # Read with .NET, not Get-Content: Get-Content attaches provider properties
    # (PSPath, PSDrive, ...) to each line, and ConvertTo-Json -Depth 20 then
    # walks that object graph without end, pinning the server at full CPU.
    $tail = @()
    if (Test-Path -LiteralPath $logPath) {
        try { $tail = @([System.IO.File]::ReadAllLines($logPath) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() } | Select-Object -Last 20) } catch { $tail = @() }
    }
    Add-OrSet-BookStudioNoteProperty -InputObject $record -Name 'logTail' -Value ([string[]]$tail)
    Add-OrSet-BookStudioNoteProperty -InputObject $record -Name 'installedVersion' -Value (Get-BookStudioInstalledVersion -ProjectRoot $ProjectRoot)
    return $record
}
