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
#
# But only the agent's own. Every Book Studio folder keeps its own books in
# .bookstudio/book-studio-db.json, and a designer can have two folders: the one
# the desktop shortcut opens, and the one the setup command installed for the
# agent. The agent used to stop every Book Studio server on the computer
# whenever the one answering was not on its release, and start one from its own
# folder. On Ann Jackson's PC that could stop the Book Studio she had opened
# from the desktop, with her books in it, and put the agent's empty folder in
# its place: her books were there on her PC and Book Studio on the web site
# showed nothing. A server is now told apart by the folder it reports, and only
# the agent's own is ever restarted.

# Two paths name the same folder, however they are cased or ended.
function Test-BookStudioSameFolder {
    param([AllowEmptyString()][string]$Left, [AllowEmptyString()][string]$Right)

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    $normalize = {
        param($path)
        $full = [string]$path
        try { $full = [System.IO.Path]::GetFullPath($path) } catch { }
        $full.TrimEnd('\', '/')
    }
    return [string]::Equals((& $normalize $Left), (& $normalize $Right), [System.StringComparison]::OrdinalIgnoreCase)
}

# The folder a server was started from, read from its command line. Every way
# Book Studio starts one names it there: the desktop launcher and an update
# restart run "<folder>\book-studio.ps1", and the agent runs
# Start-BookStudioServer -ProjectRoot '<folder>'. Nothing found means nothing
# is known, and a server whose folder is not known is never stopped.
function Get-BookStudioServerFolder {
    param([AllowEmptyString()][string]$CommandLine)

    foreach ($pattern in @("-ProjectRoot\s+'((?:[^']|'')+)'", '"([^"]+)[\\/]book-studio\.ps1"', "'([^']+)[\\/]book-studio\.ps1'", '([^\s"'']+)[\\/]book-studio\.ps1')) {
        $match = [regex]::Match([string]$CommandLine, $pattern)
        if ($match.Success) { return $match.Groups[1].Value.Replace("''", "'") }
    }
    return ''
}

function ConvertTo-BookStudioServerProcess {
    param([int]$ProcessId, [AllowEmptyString()][string]$CommandLine)

    $portMatch = [regex]::Match([string]$CommandLine, "-Port\s+['""]?(\d+)")
    return [pscustomobject]@{
        ProcessId = $ProcessId
        CommandLine = $CommandLine
        Folder = Get-BookStudioServerFolder -CommandLine $CommandLine
        # A server started without -Port listens on the default.
        Port = $(if ($portMatch.Success) { [int]$portMatch.Groups[1].Value } else { 8790 })
        # The agent starts its server with Start-BookStudioServer; a designer's
        # own window runs book-studio.ps1.
        StartedByAgent = ([string]$CommandLine -match 'Start-BookStudioServer')
    }
}

# The Book Studio servers running as this person, optionally only those from
# one folder or on one port. A standard user can read the command lines of
# their own processes, so none of this needs an administrator.
function Get-BookStudioServerProcesses {
    param([string]$ProjectRoot = '', [int]$Port = 0)

    $found = @()
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
        $line = [string]$process.CommandLine
        if ($process.ProcessId -eq $PID -or $line -notmatch 'Start-BookStudioServer|book-studio\.ps1') { continue }
        $server = ConvertTo-BookStudioServerProcess -ProcessId ([int]$process.ProcessId) -CommandLine $line
        if ($ProjectRoot -and -not (Test-BookStudioSameFolder $server.Folder $ProjectRoot)) { continue }
        if ($Port -and $server.Port -ne $Port) { continue }
        $found += $server
    }
    return $found
}

# How many books a Book Studio folder holds, read from its database without
# locking it. -1 when the database is there but cannot be read, which is never
# taken to mean "no books".
function Get-BookStudioFolderBookCount {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $database = Join-Path $ProjectRoot '.bookstudio/book-studio-db.json'
    if (-not (Test-Path -LiteralPath $database)) { return 0 }
    try {
        $stream = [System.IO.File]::Open($database, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
        return @(($raw | ConvertFrom-Json).jobs | Where-Object { $_ }).Count
    }
    catch { return -1 }
}

# What the Book Studio on the port says about itself. Given fifteen seconds:
# it serves one request at a time, and a busy server is not a missing one.
function Get-LocalStudioHealth {
    param([int]$Port, [int]$TimeoutSec = 15)

    try { return Invoke-RestMethod -Uri "http://localhost:$Port/api/health" -TimeoutSec $TimeoutSec }
    catch { return $null }
}

# Whose Book Studio is answering on the port the web site is carried to.
function Resolve-LocalStudioServer {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [int]$Port = 8790,
        [scriptblock]$Health = { param($port) Get-LocalStudioHealth -Port $port },
        [scriptblock]$FindServers = { param($port) Get-BookStudioServerProcesses -Port $port },
        [scriptblock]$FolderBookCount = { param($folder) Get-BookStudioFolderBookCount -ProjectRoot $folder }
    )

    # Not $health: PowerShell names are not case-sensitive, and that is the
    # parameter.
    $answer = & $Health $Port
    $found = [pscustomobject]@{
        answering = [bool]$answer
        served = ''
        installPath = ''
        bookCount = $null
        databasePath = ''
        ownFolder = $false
    }
    if (-not $answer) { return $found }
    # The release the server loaded, from its health check. version.json cannot
    # say: it is read from disk per request, so an old server named the new
    # release. A server from before this reports no version at all, which is
    # itself proof it predates the files on disk.
    $found.served = $(if ($answer.runningVersion) { [string]$answer.runningVersion } else { 'an earlier release' })
    $found.installPath = [string]$answer.installPath
    $found.databasePath = [string]$answer.databasePath
    if ("$($answer.bookCount)" -match '^\d+$') { $found.bookCount = [int]$answer.bookCount }
    if ($found.installPath) {
        $found.ownFolder = Test-BookStudioSameFolder $found.installPath $ProjectRoot
    }
    else {
        # A server from before 2026.09.18 does not say which folder it runs
        # from. It counts as the agent's own only when every Book Studio on
        # that port was started from the agent's folder; anything less certain
        # is treated as someone else's and left alone.
        $servers = @(& $FindServers $Port)
        $others = @($servers | Where-Object { -not (Test-BookStudioSameFolder $_.Folder $ProjectRoot) })
        if ($servers.Count -and -not $others.Count) {
            $found.ownFolder = $true
            $found.installPath = $ProjectRoot
        }
        elseif ($others.Count) {
            $found.installPath = [string]$others[0].Folder
        }
    }
    # A server from before the count was reported: count its folder instead.
    if ($null -eq $found.bookCount -and $found.installPath) {
        $counted = [int](& $FolderBookCount $found.installPath)
        if ($counted -ge 0) { $found.bookCount = $counted }
    }
    return $found
}

function Update-StaleLocalStudioServer {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [int]$Port = 8790,
        # What this decides on, as parameters so the rule can be tested
        # without a server; the agent uses the defaults.
        [scriptblock]$Health = { param($port) Get-LocalStudioHealth -Port $port },
        # Whether a book is being written, asked of the database of the server
        # that would be stopped. It used to be asked of the agent's own folder,
        # which is a different database whenever the server came from another.
        [scriptblock]$Busy = {
            param($root, $databasePath)
            Import-Module (Join-Path $root 'lib/BookStudio.psm1') -DisableNameChecking -ErrorAction Stop
            & (Get-Module BookStudio) { param($path) Get-BookStudioUpdateBlocker -DatabasePath $path } $databasePath
        },
        [scriptblock]$FindServers = { param($port) Get-BookStudioServerProcesses -Port $port },
        [scriptblock]$FolderBookCount = { param($folder) Get-BookStudioFolderBookCount -ProjectRoot $folder }
    )

    $installed = Get-BookStudioInstalledVersion -ProjectRoot $ProjectRoot
    $server = Resolve-LocalStudioServer -ProjectRoot $ProjectRoot -Port $Port -Health $Health -FindServers $FindServers -FolderBookCount $FolderBookCount
    $result = [pscustomobject]@{
        status = ''
        served = $server.served
        installed = $installed
        detail = ''
        installPath = $server.installPath
        bookCount = $server.bookCount
        agentPath = $ProjectRoot
        ownFolder = $server.ownFolder
    }
    if (-not $server.answering) { $result.status = 'not-running'; return $result }
    $isBusy = {
        param($databasePath)
        # Never under a book being written or a Codex request: the same rule
        # as the update button in Book Studio itself. Not knowing counts as busy.
        try { return [string](& $Busy $ProjectRoot $databasePath) }
        catch { return "Could not tell whether a book is being written: $($_.Exception.Message)" }
    }

    if ($server.ownFolder) {
        if (-not $installed -or $server.served -eq $installed) { $result.status = 'current'; return $result }
        $database = $(if ($server.databasePath) { $server.databasePath } else { Join-Path $ProjectRoot '.bookstudio/book-studio-db.json' })
        $blocker = & $isBusy $database
        if ($blocker) { $result.status = 'busy'; $result.detail = $blocker; return $result }
        $mine = @(@(& $FindServers $Port) | Where-Object { Test-BookStudioSameFolder $_.Folder $ProjectRoot })
        if (-not $mine.Count) {
            $result.status = 'not-found'
            $result.detail = 'The Book Studio server running here was not started in a way this agent recognises; restart it by hand.'
            return $result
        }
        foreach ($process in $mine) { try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop } catch { } }
        $result.status = 'restarted'
        return $result
    }

    # Another folder's Book Studio holds the port: most often the designer's
    # own, opened from the desktop, with their books in it. It is never
    # stopped, whatever release it runs. The web site is carried to it, which
    # shows the designer the books they see on that computer, and the agent
    # reports both folders so the difference can be seen on the web site.
    $where = $(if ($server.installPath) { $server.installPath } else { 'a folder this agent cannot identify' })
    $result.status = 'other-folder'
    $result.detail = "The Book Studio answering on port $Port runs from $where, not from this agent's folder ($ProjectRoot). It is left running, and the web site shows its books."

    # One exception: the leftover of an agent that was replaced by setting
    # Book Studio up again in the folder that has the books. It was started by
    # an agent -- never a designer's own window -- it holds no books, and this
    # folder does. Left running, it would show the designer an empty Book
    # Studio on the web site until the computer restarted.
    if (-not $server.installPath -or $server.bookCount -ne 0) { return $result }
    if ([int](& $FolderBookCount $ProjectRoot) -le 0) { return $result }
    $fromThere = @(@(& $FindServers $Port) | Where-Object { Test-BookStudioSameFolder $_.Folder $server.installPath })
    $leftover = @($fromThere | Where-Object { $_.StartedByAgent })
    if (-not $leftover.Count -or $leftover.Count -ne $fromThere.Count) { return $result }
    $database = $(if ($server.databasePath) { $server.databasePath } else { Join-Path $server.installPath '.bookstudio/book-studio-db.json' })
    if (& $isBusy $database) { return $result }
    foreach ($process in $leftover) { try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop } catch { } }
    $result.status = 'replaced-empty'
    $result.detail = "Stopped the empty Book Studio an earlier agent started from $($server.installPath), so this folder's, which has the books, can answer instead."
    return $result
}

# What the web site is being shown from this computer, for the agent's
# heartbeat: the folder the Book Studio answering here runs from and how many
# books it holds, and the agent's own folder when that is a different one. A
# designer whose books are "missing" on the web site can then see at once that
# it is showing another folder than the one they open on the desktop.
function Get-LocalStudioReport {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [int]$Port = 8790,
        [scriptblock]$Health = { param($port) Get-LocalStudioHealth -Port $port },
        [scriptblock]$FindServers = { param($port) Get-BookStudioServerProcesses -Port $port },
        [scriptblock]$FolderBookCount = { param($folder) Get-BookStudioFolderBookCount -ProjectRoot $folder },
        [scriptblock]$Listening = { param($port) Test-LocalStudioPortListening -Port $port }
    )

    $server = Resolve-LocalStudioServer -ProjectRoot $ProjectRoot -Port $Port -Health $Health -FindServers $FindServers -FolderBookCount $FolderBookCount
    $report = [pscustomobject]@{
        status = ''
        installPath = [string]$server.installPath
        bookCount = $server.bookCount
        version = [string]$server.served
        agentPath = $ProjectRoot
        agentBookCount = $null
        detail = ''
    }
    if ($server.answering -and $server.ownFolder) {
        $report.status = 'own-folder'
        $report.agentBookCount = $server.bookCount
        return $report
    }
    $own = [int](& $FolderBookCount $ProjectRoot)
    if ($own -ge 0) { $report.agentBookCount = $own }
    if ($server.answering) {
        $report.status = 'other-folder'
        $report.detail = 'The Book Studio answering on this computer was started from another folder than the one this computer keeps up to date.'
    }
    elseif (& $Listening $Port) {
        $report.status = 'not-answering'
        $report.detail = 'A Book Studio is running on this computer but did not answer in time.'
    }
    else {
        $report.status = 'not-running'
    }
    return $report
}

# The bridge's way to the local Book Studio.
#
# Whether anything is listening on the port: a TCP connection and nothing more.
# A Book Studio busy with one request -- a Codex test inside a request can take
# forty seconds -- still has its port open; it just cannot answer yet. The page
# helpers used to ask it for version.json with four seconds to spare, took a
# busy server for a missing one, and each started another, which could not
# listen but did open that folder's book database.
function Test-LocalStudioPortListening {
    param([int]$Port, [int]$TimeoutMilliseconds = 1500)

    foreach ($address in @([System.Net.IPAddress]::Loopback, [System.Net.IPAddress]::IPv6Loopback)) {
        $client = $null
        try {
            $client = [System.Net.Sockets.TcpClient]::new($address.AddressFamily)
            $attempt = $client.BeginConnect($address, $Port, $null, $null)
            if ($attempt.AsyncWaitHandle.WaitOne($TimeoutMilliseconds) -and $client.Connected) {
                $client.EndConnect($attempt)
                return $true
            }
        }
        catch { }
        finally { if ($client) { $client.Close() } }
    }
    return $false
}

# Starts this agent's own Book Studio when nothing at all is on the port, and
# never otherwise. Whatever is already there -- busy, still starting, or a
# designer's own window from another folder -- is what the page is carried to.
function Start-LocalStudioServer {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [int]$Port = 8790,
        # As parameters so the rule can be tested without a server.
        [scriptblock]$Listening = { param($port) Test-LocalStudioPortListening -Port $port },
        [scriptblock]$Launch = {
            param($root, $port)
            # Started without book-studio.ps1, which opens a browser window:
            # nothing should appear on a designer's screen because someone
            # clicked in the cloud.
            $command = "Import-Module '" + (Join-Path $root 'lib\BookStudio.psm1').Replace("'", "''") + "' -Force -DisableNameChecking; " +
                       "Start-BookStudioServer -ProjectRoot '" + $root.Replace("'", "''") + "' -Port " + $port
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Minimized', '-Command', $command) -WindowStyle Minimized | Out-Null
        },
        [string]$LockName = '',
        [int]$StartWaitSeconds = 30
    )

    if (& $Listening $Port) { return $true }

    # One start at a time. Three helpers carry pages side by side, and all
    # three used to find the server missing at the same moment and start one
    # each.
    $name = $(if ($LockName) { $LockName } else { "Local\BookStudioServerStart-$Port" })
    $mutex = $null
    $owned = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, $name)
        try { $owned = $mutex.WaitOne(($StartWaitSeconds + 15) * 1000) }
        catch {
            # A helper that stopped while starting the server leaves the lock
            # abandoned, which still hands it over.
            $inner = $_.Exception
            while ($inner -and -not ($inner -is [System.Threading.AbandonedMutexException])) { $inner = $inner.InnerException }
            $owned = [bool]$inner
        }
    }
    catch {
        # No lock to be had is not a reason to leave the page unanswered.
        $mutex = $null
        $owned = $true
    }
    try {
        # Another helper started it while this one waited for the lock.
        if (& $Listening $Port) { return $true }
        if (-not $owned) { return $false }
        & $Launch $ProjectRoot $Port | Out-Null
        $deadline = (Get-Date).AddSeconds($StartWaitSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            if (& $Listening $Port) { return $true }
        }
        return $false
    }
    finally {
        if ($mutex) {
            if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
            $mutex.Dispose()
        }
    }
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

# Whether the Book Studio on disk is newer than the code this agent is running,
# however it got there. The agent only restarted after an update it downloaded
# itself; one installed by Get latest updates in Book Studio's Settings left it
# running the old code, finding nothing new to download, until the next
# Windows sign-in -- so a fix could reach the files and never the agent.
function Test-BookRunnerBehindInstall {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [AllowEmptyString()][string]$RunningVersion
    )

    if ([string]::IsNullOrWhiteSpace($RunningVersion)) { return $false }
    $installed = Get-BookStudioInstalledVersion -ProjectRoot $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($installed)) { return $false }
    return ((ConvertTo-BookStudioVersionNumber $installed) -gt (ConvertTo-BookStudioVersionNumber $RunningVersion))
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

