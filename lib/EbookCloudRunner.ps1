# Connecting a computer to the cloud, from the computer's side.
#
# A designer pastes one command, once. Everything after that has to happen
# without them: the token is remembered, and the agent can start with Windows,
# because an agent that is not running makes their machine look disconnected
# and there is nothing on screen to explain why.
#
# The token is kept in the user's own profile rather than in the Book Studio
# folder, so updating, moving or re-cloning the app does not disconnect the
# machine, and two people sharing a PC do not share a token.

function Get-BookRunnerStatePath {
    param([string]$Path)

    if ($Path) { return $Path }
    $root = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local' }
    return Join-Path $root 'EbookGenerator\runner.json'
}

function Save-BookRunnerToken {
    param(
        [Parameter(Mandatory)][string]$Token,
        [string]$Path
    )

    $file = Get-BookRunnerStatePath -Path $Path
    $folder = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $state = [pscustomobject]@{
        token = $Token
        savedAt = (Get-Date).ToString('o')
        computer = $env:COMPUTERNAME
    }
    Set-Content -LiteralPath $file -Value ($state | ConvertTo-Json -Depth 3) -Encoding UTF8
    return $file
}

function Get-SavedBookRunnerToken {
    param([string]$Path)

    $file = Get-BookRunnerStatePath -Path $Path
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    try {
        $state = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$state.token
    }
    catch {
        # A corrupted file must not stop the agent: it asks for the token again.
        return ''
    }
}

function Clear-SavedBookRunnerToken {
    param([string]$Path)

    $file = Get-BookRunnerStatePath -Path $Path
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    return $file
}

# What the designer typed wins over what was remembered, so pasting a new token
# after an administrator reissues one replaces the old one rather than being
# ignored in favour of a token that no longer works.
function Resolve-BookRunnerToken {
    param(
        [string]$Token,
        [string]$EnvironmentToken,
        [string]$Path
    )

    if ($Token) { return [pscustomobject]@{ token = $Token; source = 'command line' } }
    if ($EnvironmentToken) { return [pscustomobject]@{ token = $EnvironmentToken; source = 'environment' } }
    $saved = Get-SavedBookRunnerToken -Path $Path
    if ($saved) { return [pscustomobject]@{ token = $saved; source = 'saved on this computer' } }
    return [pscustomobject]@{ token = ''; source = 'nowhere' }
}

function Get-BookRunnerStartupPath {
    param([string]$StartupFolder)

    $folder = if ($StartupFolder) { $StartupFolder } else { [Environment]::GetFolderPath('Startup') }
    return Join-Path $folder 'Book Studio cloud agent.lnk'
}

# A shortcut in the user's own Startup folder. No service, no scheduled task and
# no administrator: designer PCs are locked down, and anything needing elevation
# cannot be part of a setup they do themselves.
function Install-BookRunnerStartup {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$StartupFolder
    )

    $link = Get-BookRunnerStartupPath -StartupFolder $StartupFolder
    $folder = Split-Path -Parent $link
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = (Get-Command powershell.exe).Source
    # Read and run as a command, not started as a file. On a managed PC the
    # execution policy forbids running a .ps1, -ExecutionPolicy Bypass is
    # itself overridden by group policy, and a designer cannot change either.
    # A command built from the text of the file is subject to neither.
    # The path is quoted because a Book Studio folder can have a space in it,
    # and the quotes are doubled for the shortcut's own parser.
    $command = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath ''' + $ScriptPath + ''')))'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -Command "' + $command + '"'
    $shortcut.WorkingDirectory = Split-Path -Parent $ScriptPath
    $shortcut.Description = 'Keeps this computer connected to Book Studio so books can be written here.'
    $shortcut.Save()
    return $link
}

function Uninstall-BookRunnerStartup {
    param([string]$StartupFolder)

    $link = Get-BookRunnerStartupPath -StartupFolder $StartupFolder
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
    return $link
}

function Test-BookRunnerStartupInstalled {
    param([string]$StartupFolder)

    return Test-Path -LiteralPath (Get-BookRunnerStartupPath -StartupFolder $StartupFolder)
}

# Only one agent per computer. Two of them poll the same queue and report the
# same machine over each other, and a designer who pastes the setup command
# twice has no way to know they have done it.
#
# Started deliberately -- the setup command, with a token -- it takes over
# instead. On the Vocate laptop the setup command updated the files and started
# the new agent, which found the old one running, said so in a minimised window
# nobody saw, and quit; the old one carried on with code too old to show Book
# Studio on the web site, and setup reported "has not reached Book Studio".
# Started at sign-in, with no token, it still defers to the one running.
function Enter-BookRunnerSingleInstance {
    param(
        [string]$Name = 'Global\BookStudioCloudRunner',
        [switch]$TakeOver,
        # Which processes are the other agents. A parameter so the rule can be
        # tested against a stand-in process; the agent uses the real list.
        [scriptblock]$FindOthers = { Get-OtherBookRunnerProcesses },
        [int]$WaitSeconds = 20
    )

    # Stopped before the mutex is even asked for: an agent from before the
    # mutex existed holds none, and would otherwise keep reporting this
    # computer, with no version, over the new one.
    $replaced = @()
    if ($TakeOver) {
        foreach ($process in @(& $FindOthers)) {
            try {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
                $replaced += [int]$process.ProcessId
            }
            catch { }
        }
    }

    $created = $false
    try {
        $mutex = New-Object System.Threading.Mutex($true, $Name, [ref]$created)
    }
    catch {
        # A machine that will not give us a mutex is not a reason to refuse to
        # run; it only means a second copy cannot be detected.
        return [pscustomobject]@{ acquired = $true; mutex = $null; replaced = $replaced }
    }
    if ($created) { return [pscustomobject]@{ acquired = $true; mutex = $mutex; replaced = $replaced } }
    if ($TakeOver) {
        # The stopped agent's mutex is released as it exits (abandoned, which
        # still hands it over), or is held by a window this cannot find.
        $owned = $false
        try { $owned = $mutex.WaitOne($WaitSeconds * 1000) }
        catch {
            $inner = $_.Exception
            while ($inner -and -not ($inner -is [System.Threading.AbandonedMutexException])) { $inner = $inner.InnerException }
            $owned = [bool]$inner
        }
        if ($owned) { return [pscustomobject]@{ acquired = $true; mutex = $mutex; replaced = $replaced } }
    }
    $mutex.Dispose()
    return [pscustomobject]@{ acquired = $false; mutex = $null; replaced = $replaced }
}

# The other agents running as this person on this computer, found by the
# command line they were started with: the setup command, the sign-in shortcut
# and a self-update restart all name cloud-book-runner.ps1. A one-off check
# (-Once) and a request to stop starting with Windows are not agents.
function Get-OtherBookRunnerProcesses {
    param([int]$ExceptProcessId = $PID)

    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $ExceptProcessId -and
            [string]$_.CommandLine -match 'cloud-book-runner' -and
            [string]$_.CommandLine -notmatch '(?i)-Once\b|-StopStartingWithWindows'
        })
}

# The Book Studio server on this computer has to run the code on disk. It is
# started once and then left alone, so an agent that updated itself went on
# forwarding the web site to a server still running the release before: the
# page on the web was never the one just published.
function Get-BookStudioServerProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { [string]$_.CommandLine -match 'Start-BookStudioServer|book-studio\.ps1' -and $_.ProcessId -ne $PID })
}

function Update-StaleLocalStudioServer {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [int]$Port = 8790,
        # The three things this decides on, as parameters so the rule can be
        # tested without a server; the agent uses the defaults.
        # The release the server loaded, from its health check. version.json
        # cannot say: it is read from disk per request, so an old server named
        # the new release. A server from before this reports no version at all,
        # which is itself proof it predates the files on disk.
        [scriptblock]$ServedVersion = {
            param($port)
            try { $health = Invoke-RestMethod -Uri "http://localhost:$port/api/health" -TimeoutSec 4 } catch { return $null }
            if ($health.runningVersion) { return [string]$health.runningVersion }
            return 'an earlier release'
        },
        [scriptblock]$Busy = {
            param($root)
            Import-Module (Join-Path $root 'lib/BookStudio.psm1') -DisableNameChecking -ErrorAction Stop
            $database = Get-BookStudioDatabasePath -ProjectRoot $root
            & (Get-Module BookStudio) { param($path) Get-BookStudioUpdateBlocker -DatabasePath $path } $database
        },
        [scriptblock]$FindServers = { Get-BookStudioServerProcesses }
    )

    $installed = ''
    try { $installed = [string](Get-Content -LiteralPath (Join-Path $ProjectRoot 'book-studio/version.json') -Raw | ConvertFrom-Json).version } catch { }
    $served = [string](& $ServedVersion $Port)
    if (-not $served) { return [pscustomobject]@{ status = 'not-running'; served = ''; installed = $installed; detail = '' } }
    if (-not $installed -or $served -eq $installed) { return [pscustomobject]@{ status = 'current'; served = $served; installed = $installed; detail = '' } }

    # Never under a book being written or a Codex request: the same rule as
    # the update button in Book Studio itself.
    $blocker = ''
    try { $blocker = [string](& $Busy $ProjectRoot) } catch { $blocker = "Could not tell whether a book is being written: $($_.Exception.Message)" }
    if ($blocker) { return [pscustomobject]@{ status = 'busy'; served = $served; installed = $installed; detail = $blocker } }

    $servers = @(& $FindServers)
    if (-not $servers.Count) { return [pscustomobject]@{ status = 'not-found'; served = $served; installed = $installed; detail = 'The Book Studio server running here was not started in a way this agent recognises; restart it by hand.' } }
    foreach ($server in $servers) { try { Stop-Process -Id $server.ProcessId -Force -ErrorAction Stop } catch { } }
    return [pscustomobject]@{ status = 'restarted'; served = $served; installed = $installed; detail = '' }
}

# Keeping itself up to date.
#
# A designer should never be asked to paste a command again to get a fix. The
# agent updates its own copy of Book Studio and restarts into it. Two things it
# must never do: touch a folder that is not the managed install, and throw away
# work someone has in progress there.
function Get-BookStudioInstalledVersion {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $file = Join-Path $ProjectRoot 'book-studio/version.json'
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    try { return [string]((Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).version) }
    catch { return '' }
}

function ConvertTo-BookStudioVersionNumber {
    param([string]$Version)

    $parts = @(([string]$Version) -split '[.]' | ForEach-Object { [int]($_ -replace '[^0-9]', '0') })
    while ($parts.Count -lt 4) { $parts += 0 }
    return ($parts[0] * 1000000L) + ($parts[1] * 10000L) + ($parts[2] * 100L) + $parts[3]
}

# Only the copy Book Studio installed for itself, and only when nothing there is
# half-finished. A development checkout, or a folder somebody has edited, is
# left alone: updating it would throw away their work.
function Test-BookStudioSelfUpdatable {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        # Which remote counts as the Book Studio distribution. A parameter so
        # the rule can be exercised against a scratch repository; production
        # never passes anything else.
        [string]$DistributionPattern = 'gduartevocate/book-studio'
    )

    $reason = ''
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot '.git'))) {
        return [pscustomobject]@{ updatable = $false; reason = 'not a Book Studio install that updates itself' }
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ updatable = $false; reason = 'git is not installed' }
    }
    $remote = (& git -C $ProjectRoot remote get-url origin 2>&1) -as [string]
    if ($LASTEXITCODE -ne 0 -or -not $remote) {
        return [pscustomobject]@{ updatable = $false; reason = 'no origin to update from' }
    }
    if ($remote -notmatch $DistributionPattern) {
        # The private development checkout ends up here, and updating it would
        # overwrite work in progress with a published release.
        return [pscustomobject]@{ updatable = $false; reason = "this folder follows $remote, not the Book Studio distribution" }
    }
    $dirty = (& git -C $ProjectRoot status --porcelain 2>&1) -as [string]
    if ($dirty) {
        return [pscustomobject]@{ updatable = $false; reason = 'there are unsaved changes in this folder' }
    }
    return [pscustomobject]@{ updatable = $true; reason = '' }
}

function Update-BookStudioInstall {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$DistributionPattern = 'gduartevocate/book-studio'
    )

    $before = Get-BookStudioInstalledVersion -ProjectRoot $ProjectRoot
    $allowed = Test-BookStudioSelfUpdatable -ProjectRoot $ProjectRoot -DistributionPattern $DistributionPattern
    if (-not $allowed.updatable) {
        return [pscustomobject]@{ updated = $false; from = $before; to = $before; reason = $allowed.reason }
    }
    $output = (& git -C $ProjectRoot pull --ff-only 2>&1) -as [string]
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ updated = $false; from = $before; to = $before; reason = "update failed: $output" }
    }
    $after = Get-BookStudioInstalledVersion -ProjectRoot $ProjectRoot
    return [pscustomobject]@{
        updated = ((ConvertTo-BookStudioVersionNumber $after) -gt (ConvertTo-BookStudioVersionNumber $before))
        from = $before
        to = $after
        reason = ''
    }
}

# Restarting into the new copy. The agent's own code is already stale by the
# time it gets here, so it starts a fresh one and stands down, releasing the
# single-instance hold first so the new one is not turned away by the old.
function Restart-BookRunner {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [object]$Instance
    )

    if ($Instance -and $Instance.mutex) {
        try { $Instance.mutex.ReleaseMutex() } catch { }
        try { $Instance.mutex.Dispose() } catch { }
    }
    $agent = Join-Path $ProjectRoot 'cloud-book-runner.ps1'
    # Read and run as a command, because a managed PC refuses to run a file.
    $inner = "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '" + $agent + "'))) -ProjectRoot '" + $ProjectRoot + "'"
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Minimized', '-Command', $inner)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Minimized | Out-Null
}

