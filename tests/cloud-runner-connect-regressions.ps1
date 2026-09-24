$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

. (Join-Path $root 'lib/EbookCloudRunner.ps1')

# Connecting a computer has to cost a designer one pasted command, once. These
# are the rules that make the second start, and every start after it, cost
# nothing: the token is remembered in the person's own profile, a newly pasted
# token replaces a remembered one, and the machine can reconnect on its own
# without an administrator anywhere in it.

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-connect-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $state = Join-Path $fixture 'state\runner.json'
    $startup = Join-Path $fixture 'startup'

    # 1. With nothing to go on, the agent must say what to do, not guess.
    $none = Resolve-BookRunnerToken -Path $state
    Check ($none.token -eq '') 'A token must not be invented when there is none.'
    Check ($none.source -eq 'nowhere') 'The agent must be able to say where a token came from.'

    # 2. A pasted token is remembered, and found again on the next start with
    #    nothing on the command line. This is the whole point: paste once.
    $saved = Save-BookRunnerToken -Token 'first-token' -Path $state
    Check (Test-Path -LiteralPath $saved) 'Saving a token must write the file it reports.'
    $remembered = Resolve-BookRunnerToken -Path $state
    Check ($remembered.token -eq 'first-token') 'A saved token must be found on the next start.'
    Check ($remembered.source -like '*saved*') 'The agent must say the token came from this computer.'

    # 3. A newly pasted token wins over the remembered one. An administrator
    #    reissuing a password or a token must not be defeated by a stale file.
    $pasted = Resolve-BookRunnerToken -Token 'second-token' -Path $state
    Check ($pasted.token -eq 'second-token') 'A token given on the command line must win over the saved one.'
    Check ($pasted.source -eq 'command line') 'The source of the winning token must be reported.'
    Save-BookRunnerToken -Token 'second-token' -Path $state | Out-Null
    Check ((Resolve-BookRunnerToken -Path $state).token -eq 'second-token') 'Pasting a new token must replace what was remembered.'

    # 4. The environment still works, because the .env file on the machine that
    #    was set up before this existed is read into it.
    $fromEnvironment = Resolve-BookRunnerToken -EnvironmentToken 'env-token' -Path $state
    Check ($fromEnvironment.token -eq 'env-token') 'A token in the environment must still be honoured.'
    Check ((Resolve-BookRunnerToken -Token 'typed' -EnvironmentToken 'env-token' -Path $state).token -eq 'typed') 'The typed token must win over the environment.'

    # 5. A corrupted state file must not stop the agent starting; it asks again.
    Set-Content -LiteralPath $state -Value 'not json at all' -Encoding UTF8
    Check ((Resolve-BookRunnerToken -Path $state).token -eq '') 'A damaged token file must be ignored rather than thrown.'
    Save-BookRunnerToken -Token 'third-token' -Path $state | Out-Null
    Check ((Get-SavedBookRunnerToken -Path $state) -eq 'third-token') 'Saving over a damaged file must work.'

    # 6. The token lives in the user's profile by default, not in the Book
    #    Studio folder: updating or re-cloning the app must not disconnect the
    #    machine, and two people on one PC must not share a token.
    $default = Get-BookRunnerStatePath
    Check ($default -like "$env:LOCALAPPDATA*") "The token must be kept in the user's own profile, not in the app folder; got $default"
    Check ($default -notlike "$root*") 'The token must not be kept inside the Book Studio folder.'

    # 7. Starting with Windows is a shortcut in the person's own Startup folder.
    #    Designer PCs are locked down, so anything needing an administrator
    #    cannot be part of a setup they do themselves.
    Check (-not (Test-BookRunnerStartupInstalled -StartupFolder $startup)) 'Nothing must start with Windows until it is asked for.'
    $scriptPath = Join-Path $root 'cloud-book-runner.ps1'
    $link = Install-BookRunnerStartup -ScriptPath $scriptPath -StartupFolder $startup
    Check (Test-Path -LiteralPath $link) 'Asking for it must create the shortcut.'
    Check (Test-BookRunnerStartupInstalled -StartupFolder $startup) 'An installed shortcut must be reported as installed.'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    Check ($shortcut.TargetPath -like '*powershell.exe') 'The shortcut must start PowerShell.'
    # Quoted, because a Book Studio folder can have a space in it, and read as a
    # command rather than started as a file, because a managed computer refuses
    # to run a .ps1 at all and a designer cannot change that.
    Check ($shortcut.Arguments -match "LiteralPath '") 'The script path must be quoted; a Book Studio folder with a space in its name silently starts nothing.'
    Check ($shortcut.Arguments -match [regex]::Escape($scriptPath)) 'The shortcut must start this copy of the agent.'
    Check ($shortcut.Arguments -match '-WindowStyle Minimized') 'The agent must not sit in front of the designer all day.'
    Check ($shortcut.Arguments -notmatch 'Token') 'The shortcut must not carry the token; that is what the saved file is for.'

    # 7b. One agent per computer. Two of them poll the same queue and report
    #     the same machine over each other, and the designer who started the
    #     second one has no way to know.
    $first = Enter-BookRunnerSingleInstance -Name 'Local\BookStudioRunnerTest'
    Check ($first.acquired) 'The first agent on a computer must be allowed to run.'
    $second = Enter-BookRunnerSingleInstance -Name 'Local\BookStudioRunnerTest'
    Check (-not $second.acquired) 'A second agent on the same computer must stand down.'
    $first.mutex.ReleaseMutex(); $first.mutex.Dispose()
    $third = Enter-BookRunnerSingleInstance -Name 'Local\BookStudioRunnerTest'
    Check ($third.acquired) 'Once the first agent stops, another must be able to start.'
    $third.mutex.ReleaseMutex(); $third.mutex.Dispose()

    # 7c. But the setup command, run on purpose, replaces the agent already
    #     running. On the Vocate laptop the new agent found the old one, quit
    #     in a minimised window, and the old code carried on; setup said "has
    #     not reached Book Studio". Tested against real processes, because the
    #     point is what happens between two of them.
    $asAgents = { param($processes) @($processes | ForEach-Object { [pscustomobject]@{ ProcessId = $_.Id } }) }
    $name = 'Local\BookStudioTakeover' + [guid]::NewGuid().ToString('N')
    $ready = Join-Path $fixture 'holder-ready'
    $holder = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command',
        "`$m = New-Object System.Threading.Mutex(`$true, '$name'); Set-Content -LiteralPath '$ready' -Value 1; Start-Sleep -Seconds 120")
    foreach ($wait in 1..80) { if (Test-Path -LiteralPath $ready) { break }; Start-Sleep -Milliseconds 250 }
    Check (Test-Path -LiteralPath $ready) 'The stand-in agent must be holding the lock before the test goes on.'
    $atSignIn = Enter-BookRunnerSingleInstance -Name $name -FindOthers { & $asAgents $holder }
    $holder.Refresh()
    Check (-not $atSignIn.acquired -and -not $holder.HasExited) 'Started at sign-in, a second agent still defers to the running one and stops nothing.'
    $bySetup = Enter-BookRunnerSingleInstance -Name $name -TakeOver -FindOthers { & $asAgents $holder } -WaitSeconds 15
    $holder.Refresh()
    Check ($bySetup.acquired) 'Started by the setup command, the new agent must end up running.'
    Check ($holder.HasExited -and $bySetup.replaced -contains $holder.Id) 'And the agent it replaced must be stopped, and named.'
    if ($bySetup.mutex) { $bySetup.mutex.ReleaseMutex(); $bySetup.mutex.Dispose() }

    # An agent that takes a moment to let go -- still closing, or one this
    # could not find by name -- is waited for, not given up on at once.
    $slowName = 'Local\BookStudioTakeover' + [guid]::NewGuid().ToString('N')
    $slowReady = Join-Path $fixture 'slow-ready'
    $slow = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command',
        "`$m = New-Object System.Threading.Mutex(`$true, '$slowName'); Set-Content -LiteralPath '$slowReady' -Value 1; Start-Sleep -Seconds 3")
    foreach ($wait in 1..80) { if (Test-Path -LiteralPath $slowReady) { break }; Start-Sleep -Milliseconds 250 }
    $patient = Enter-BookRunnerSingleInstance -Name $slowName -TakeOver -FindOthers { @() } -WaitSeconds 15
    Check ($patient.acquired) 'The setup command must wait for an agent that is still letting go, then run.'
    if ($patient.mutex) { $patient.mutex.ReleaseMutex(); $patient.mutex.Dispose() }
    Stop-Process -Id $slow.Id -Force -ErrorAction SilentlyContinue

    # An agent from before the lock existed holds none, yet reports the same
    # computer; it has to be stopped all the same, or the two overwrite each
    # other's status and the web site flips between them.
    $lockless = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120')
    $fresh = Enter-BookRunnerSingleInstance -Name ('Local\BookStudioTakeover' + [guid]::NewGuid().ToString('N')) -TakeOver -FindOthers { & $asAgents $lockless }
    $lockless.WaitForExit(10000) | Out-Null
    Check ($fresh.acquired -and $lockless.HasExited -and $fresh.replaced -contains $lockless.Id) 'An old agent that holds no lock must be stopped too.'
    if ($fresh.mutex) { $fresh.mutex.ReleaseMutex(); $fresh.mutex.Dispose() }

    # Which processes count as agents: found by the command line, which a
    # standard user can read for their own processes -- no administrator.
    $marker = [guid]::NewGuid().ToString('N')
    $agentLike = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', "Start-Sleep -Seconds 60 # cloud-book-runner $marker")
    $checkLike = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', "Start-Sleep -Seconds 60 # cloud-book-runner -Once $marker")
    try {
        Start-Sleep -Milliseconds 800
        $found = @(Get-OtherBookRunnerProcesses | Where-Object { [string]$_.CommandLine -match $marker })
        Check ($found.ProcessId -contains $agentLike.Id) 'A running agent must be found by its command line, as a standard user.'
        Check ($found.ProcessId -notcontains $checkLike.Id) 'A one-off check (-Once) is not an agent and must not be stopped.'
        Check (@(Get-OtherBookRunnerProcesses).ProcessId -notcontains $PID) 'An agent never counts itself.'
    }
    finally {
        Stop-Process -Id $agentLike.Id, $checkLike.Id -Force -ErrorAction SilentlyContinue
    }

    # 7d. The Book Studio server here has to run the code on disk. An agent
    #     that updated itself used to keep forwarding the web site to a server
    #     still running the release before.
    $project = Join-Path $fixture 'project'
    New-Item -ItemType Directory -Path (Join-Path $project 'book-studio') -Force | Out-Null
    '{ "version": "2026.09.23.12" }' | Set-Content -LiteralPath (Join-Path $project 'book-studio/version.json')
    $never = { throw 'must not be asked' }
    $idle = { param($r, $d) '' }
    # The server on the port, as its health check describes it. By default it
    # is this agent's own folder's.
    $serving = { param([string]$Version, [string]$Folder = $project, $Books = 3, [string]$Database = '') { param($p) [pscustomobject]@{ status = 'ok'; runningVersion = $Version; installPath = $Folder; bookCount = $Books; databasePath = $Database } }.GetNewClosure() }
    Check ((Update-StaleLocalStudioServer -ProjectRoot $project -Health { param($p) $null } -Busy $never -FindServers $never).status -eq 'not-running') 'No server running: nothing to restart.'
    Check ((Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.23.12') -Busy $never -FindServers $never).status -eq 'current') 'A server on the installed release is left alone.'
    $busy = Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.17.3') -Busy { param($r, $d) "'RB1000' is still generating." } -FindServers $never
    Check ($busy.status -eq 'busy' -and $busy.detail -match 'RB1000') 'An old server is never restarted while a book is being written, and says which book it waits for.'
    Check ((Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.17.3') -Busy { param($r, $d) throw 'database locked' } -FindServers $never).status -eq 'busy') 'When it cannot tell whether a book is being written, it assumes one is.'
    Check ((Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.17.3') -Busy $idle -FindServers { param($p) @() }).status -eq 'not-found') 'A server it did not start and cannot find is reported, not guessed at.'
    # A stand-in for a server process, described the way the process scan
    # describes one: its folder, its port, and whether an agent started it.
    $asServer = { param($process, [string]$Folder, [bool]$ByAgent = $false, [int]$OnPort = 8790) [pscustomobject]@{ ProcessId = $process.Id; Folder = $Folder; Port = $OnPort; StartedByAgent = $ByAgent; CommandLine = '' } }
    $oldServer = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120')
    $restart = Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.17.3') -Busy $idle -FindServers { param($p) & $asServer $oldServer $project $true }
    $oldServer.WaitForExit(10000) | Out-Null
    Check ($restart.status -eq 'restarted' -and $oldServer.HasExited) 'An idle server of the agent''s own folder on an older release is stopped so the current one can start.'
    Check ($restart.served -eq '2026.09.17.3' -and $restart.installed -eq '2026.09.23.12') 'And the agent is told which release it replaced with which.'

    # Ann Jackson: her books were in the folder she opened from the desktop,
    # the agent ran from the folder the setup command installed, and the agent
    # stopped every Book Studio on the PC whenever the one answering was not on
    # its release -- hers included -- and started its own, empty one. A server
    # from another folder is never stopped, whatever release it runs, and the
    # web site is carried to it.
    $annFolder = Join-Path $fixture 'Ann books'
    $desktopServer = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120')
    try {
        # Idle, so that nothing but its folder stands between it and a restart.
        $hers = Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.17.3' $annFolder 12) -Busy $idle -FindServers { param($p) & $asServer $desktopServer $annFolder $false }
        Start-Sleep -Milliseconds 500; $desktopServer.Refresh()
        Check (-not $desktopServer.HasExited) 'A Book Studio started from another folder must never be stopped by the agent.'
        Check ($hers.status -eq 'other-folder' -and -not $hers.ownFolder) "It must be reported as another folder's, got '$($hers.status)'."
        Check ($hers.installPath -eq $annFolder -and $hers.bookCount -eq 12 -and $hers.agentPath -eq $project) 'The report must name both folders and the books the web site is being shown.'
        Check ($hers.detail -match [regex]::Escape($annFolder) -and $hers.detail -match [regex]::Escape($project)) "The agent must say which folder answers and which is its own: $($hers.detail)"
        # Nor when an agent started it: it still has the designer's books.
        $hersByAgent = Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.17.3' $annFolder 12) -Busy $never -FindServers { param($p) & $asServer $desktopServer $annFolder $true } -FolderBookCount { param($f) 0 }
        Start-Sleep -Milliseconds 500; $desktopServer.Refresh()
        Check ($hersByAgent.status -eq 'other-folder' -and -not $desktopServer.HasExited) 'A Book Studio from another folder that has books is never stopped, whoever started it.'
        # The same folder named in another case, or with a trailing separator,
        # is the same folder.
        $recased = Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.23.12' ($project.ToUpperInvariant() + '\')) -Busy $never -FindServers $never
        Check ($recased.status -eq 'current' -and $recased.ownFolder) 'A folder must be recognised however its path is cased or ended.'

        # The agent's own out-of-date server is replaced, and only it: a
        # designer's window from another folder on the list is left running.
        $ownServer = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120')
        $askedAbout = New-Object System.Collections.ArrayList
        $own = Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.17.3' $project 3 'D:\served\book-studio-db.json') `
            -Busy { param($r, $d) [void]$askedAbout.Add($d); '' } -FindServers { param($p) @((& $asServer $ownServer $project $true), (& $asServer $desktopServer $annFolder $false)) }
        $ownServer.WaitForExit(10000) | Out-Null
        Start-Sleep -Milliseconds 500; $desktopServer.Refresh()
        Check ($own.status -eq 'restarted' -and $ownServer.HasExited) 'The agent''s own out-of-date server must still be replaced.'
        Check (-not $desktopServer.HasExited) 'Replacing its own server must not stop a Book Studio from another folder.'
        # The "is a book being written?" question goes to the database of the
        # server being replaced, as that server reports it.
        Check ($askedAbout.Count -eq 1 -and $askedAbout[0] -eq 'D:\served\book-studio-db.json') "The busy check must read the served database, got '$($askedAbout -join ', ')'."
    }
    finally { Stop-Process -Id $desktopServer.Id -Force -ErrorAction SilentlyContinue }

    # The one server from another folder that may go: the leftover of an agent
    # replaced by setting Book Studio up again in the folder with the books.
    # An agent started it, it holds no books, and this folder does; left
    # running it would show the designer an empty Book Studio on the web site.
    $emptyFolder = Join-Path $fixture 'LocalAppData\Book Studio'
    $leftoverServer = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120')
    try {
        $keptBooks = Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.23.12' $emptyFolder 0) -Busy $idle -FindServers { param($p) & $asServer $leftoverServer $emptyFolder $true } -FolderBookCount { param($f) 0 }
        Check ($keptBooks.status -eq 'other-folder') 'An empty server from another folder stays when this folder has no books either.'
        $byHand = Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.23.12' $emptyFolder 0) -Busy $idle -FindServers { param($p) & $asServer $leftoverServer $emptyFolder $false } -FolderBookCount { param($f) 5 }
        Check ($byHand.status -eq 'other-folder') 'A designer''s own window is never stopped, even an empty one.'
        $unknown = Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.23.12' $emptyFolder $null) -Busy $idle -FindServers { param($p) & $asServer $leftoverServer $emptyFolder $true } -FolderBookCount { param($f) if ($f -eq $emptyFolder) { -1 } else { 5 } }
        Check ($unknown.status -eq 'other-folder') 'A server whose books cannot be counted is never taken for an empty one.'
        Start-Sleep -Milliseconds 300; $leftoverServer.Refresh()
        Check (-not $leftoverServer.HasExited) 'None of those may stop it.'
        $replaced = Update-StaleLocalStudioServer -ProjectRoot $project -Health (& $serving '2026.09.23.12' $emptyFolder 0) -Busy $idle -FindServers { param($p) & $asServer $leftoverServer $emptyFolder $true } -FolderBookCount { param($f) 5 }
        $leftoverServer.WaitForExit(10000) | Out-Null
        Check ($replaced.status -eq 'replaced-empty' -and $leftoverServer.HasExited) 'The empty leftover of a replaced agent must give way to the folder with the books.'
    }
    finally { Stop-Process -Id $leftoverServer.Id -Force -ErrorAction SilentlyContinue }

    # A server from before 2026.09.18 does not say which folder it runs from.
    # It is the agent's only when every Book Studio on the port says so on its
    # command line; otherwise it is someone else's and left alone.
    $vague = { param($p) [pscustomobject]@{ status = 'ok'; runningVersion = '2026.09.17.3' } }
    $unsaid = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120')
    try {
        $mixed = Update-StaleLocalStudioServer -ProjectRoot $project -Health $vague -Busy $idle -FindServers { param($p) @((& $asServer $unsaid $annFolder $false)) } -FolderBookCount { param($f) 1 }
        Start-Sleep -Milliseconds 300; $unsaid.Refresh()
        Check ($mixed.status -eq 'other-folder' -and -not $unsaid.HasExited) 'A server that does not name its folder, started from another one, must be left alone.'
        $mine = Update-StaleLocalStudioServer -ProjectRoot $project -Health $vague -Busy $idle -FindServers { param($p) @((& $asServer $unsaid $project $true)) } -FolderBookCount { param($f) 1 }
        $unsaid.WaitForExit(10000) | Out-Null
        Check ($mine.status -eq 'restarted' -and $unsaid.HasExited) 'One whose only command line names this folder is the agent''s, and is replaced when old.'
    }
    finally { Stop-Process -Id $unsaid.Id -Force -ErrorAction SilentlyContinue }

    # Found by their command lines, for real: each way Book Studio starts a
    # server names its folder there, and a folder whose name only begins with
    # this one's is a different folder.
    $scanRoot = Join-Path $fixture 'scan'
    $scanOwn = Join-Path $scanRoot 'book-studio'
    $scanOther = Join-Path $scanRoot 'book-studio-old'
    New-Item -ItemType Directory -Path (Join-Path $scanOwn 'book-studio') -Force | Out-Null
    '{ "version": "2026.09.23.12" }' | Set-Content -LiteralPath (Join-Path $scanOwn 'book-studio/version.json')
    $agentStarted = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', "Start-Sleep -Seconds 60 # Start-BookStudioServer -ProjectRoot '$scanOwn' -Port 8790")
    $desktopStarted = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', "Start-Sleep -Seconds 60 # -File `"$scanOther\book-studio.ps1`" -Port 8790")
    try {
        Start-Sleep -Milliseconds 800
        $ownScan = @(Get-BookStudioServerProcesses -ProjectRoot $scanOwn)
        $otherScan = @(Get-BookStudioServerProcesses -ProjectRoot $scanOther)
        Check ($ownScan.ProcessId -contains $agentStarted.Id -and $ownScan.ProcessId -notcontains $desktopStarted.Id) 'Only servers started from this folder may be found as this folder''s.'
        Check ($otherScan.ProcessId -contains $desktopStarted.Id -and $otherScan.ProcessId -notcontains $agentStarted.Id) 'A folder whose name starts the same is a different folder.'
        Check (@($ownScan | Where-Object ProcessId -eq $agentStarted.Id)[0].StartedByAgent -and -not @($otherScan | Where-Object ProcessId -eq $desktopStarted.Id)[0].StartedByAgent) 'A server the agent started must be told from a designer''s own window.'
        Check (@(Get-BookStudioServerProcesses -ProjectRoot $scanOwn -Port 8791).Count -eq 0) 'A server on another port is not the one the web site is carried to.'
        # And with the real process scan: the agent's own old server goes, the
        # other folder's stays.
        $scanned = Update-StaleLocalStudioServer -ProjectRoot $scanOwn -Health (& $serving '2026.09.17.3' $scanOwn 2) -Busy $idle
        $agentStarted.WaitForExit(10000) | Out-Null
        Start-Sleep -Milliseconds 300; $desktopStarted.Refresh()
        Check ($scanned.status -eq 'restarted' -and $agentStarted.HasExited -and -not $desktopStarted.HasExited) 'With the real process scan, only the agent''s own folder''s server may be stopped.'
    }
    finally { Stop-Process -Id $agentStarted.Id, $desktopStarted.Id -Force -ErrorAction SilentlyContinue }

    # What the heartbeat says: the folder the web site is shown, its books, and
    # the agent's own folder when that is another one.
    $ownReport = Get-LocalStudioReport -ProjectRoot $project -Health (& $serving '2026.09.23.12' $project 4) -FindServers $never -FolderBookCount $never -Listening $never
    Check ($ownReport.status -eq 'own-folder' -and $ownReport.installPath -eq $project -and $ownReport.bookCount -eq 4) 'The heartbeat must say the agent''s own folder is being served, with its books.'
    $otherReport = Get-LocalStudioReport -ProjectRoot $project -Health (& $serving '2026.09.23.12' $annFolder 12) -FindServers $never -FolderBookCount { param($f) 0 } -Listening $never
    Check ($otherReport.status -eq 'other-folder' -and $otherReport.installPath -eq $annFolder -and $otherReport.bookCount -eq 12 -and $otherReport.agentPath -eq $project -and $otherReport.agentBookCount -eq 0) 'The heartbeat must name both folders and both counts when they differ.'
    $offReport = Get-LocalStudioReport -ProjectRoot $project -Health { param($p) $null } -FindServers $never -FolderBookCount { param($f) 7 } -Listening { param($p) $false }
    Check ($offReport.status -eq 'not-running' -and $offReport.agentBookCount -eq 7 -and -not $offReport.installPath) 'With nothing running, the heartbeat must say so and name the folder that will open.'
    $busyReport = Get-LocalStudioReport -ProjectRoot $project -Health { param($p) $null } -FindServers $never -FolderBookCount { param($f) 7 } -Listening { param($p) $true }
    Check ($busyReport.status -eq 'not-answering') 'A server that is there but busy must not be reported as missing.'
    $counted = Join-Path $fixture 'counted'
    New-Item -ItemType Directory -Path (Join-Path $counted '.bookstudio') -Force | Out-Null
    Check ((Get-BookStudioFolderBookCount -ProjectRoot $counted) -eq 0) 'A folder with no database has no books.'
    '{ "schemaVersion": 1, "jobs": [ { "id": "a" }, { "id": "b" } ] }' | Set-Content -LiteralPath (Join-Path $counted '.bookstudio/book-studio-db.json') -Encoding UTF8
    Check ((Get-BookStudioFolderBookCount -ProjectRoot $counted) -eq 2) 'The books in a folder must be counted from its database.'
    'not json {' | Set-Content -LiteralPath (Join-Path $counted '.bookstudio/book-studio-db.json') -Encoding UTF8
    Check ((Get-BookStudioFolderBookCount -ProjectRoot $counted) -eq -1) 'A database that cannot be read must never count as no books.'

    # The version must come from what the server loaded (its health check),
    # never from version.json, which is the file on disk. Served by a real
    # stand-in HTTP server so the default reading is the one tested.
    $healthPort = ([Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)); $healthPort.Start(); $port = $healthPort.LocalEndpoint.Port; $healthPort.Stop()
    $standInServer = Start-Job -ArgumentList $port, $project -ScriptBlock {
        param($port, $folder)
        $listener = New-Object System.Net.HttpListener; $listener.Prefixes.Add("http://localhost:$port/"); $listener.Start()
        $answers = @(
            (@{ status = 'ok'; runningVersion = '2026.09.17.3'; installPath = $folder; bookCount = 3 } | ConvertTo-Json -Compress),
            (@{ status = 'ok'; installPath = $folder; bookCount = 3 } | ConvertTo-Json -Compress)
        )
        $served = 0
        while ($served -lt 6) {
            $context = $listener.GetContext(); $served++
            $body = if ($context.Request.Url.AbsolutePath -eq '/version.json') { '{"version":"2026.09.23.12"}' } elseif ($served -le 2) { $answers[0] } else { $answers[1] }
            $bytes = [Text.Encoding]::UTF8.GetBytes($body); $context.Response.ContentType = 'application/json'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length); $context.Response.Close()
        }
        $listener.Stop()
    }
    try {
        foreach ($wait in 1..40) { try { $null = Invoke-RestMethod "http://localhost:$port/version.json" -TimeoutSec 2; break } catch { Start-Sleep -Milliseconds 250 } }
        $old = Update-StaleLocalStudioServer -ProjectRoot $project -Port $port -Busy { param($r, $d) 'a book is being written' } -FindServers $never
        Check ($old.status -eq 'busy' -and $old.served -eq '2026.09.17.3') 'An old server whose version.json names the new release must still be seen as old.'
        Check ($old.installPath -eq $project -and $old.bookCount -eq 3) 'The folder and the books must be read from the health check itself.'
        $older = Update-StaleLocalStudioServer -ProjectRoot $project -Port $port -Busy { param($r, $d) 'a book is being written' } -FindServers $never
        Check ($older.status -eq 'busy' -and $older.served -eq 'an earlier release') 'A server too old to report its version must be treated as out of date.'
    }
    finally { Stop-Job $standInServer -ErrorAction SilentlyContinue; Remove-Job $standInServer -Force -ErrorAction SilentlyContinue }

    # The page helpers. A Book Studio busy with one request still has its port
    # open. The helpers asked it for version.json with four seconds to spare,
    # took a busy server for a missing one, and started another each -- which
    # could not listen, but did open that folder's book database.
    $busyPort = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $busyPort.Start()
    try {
        # Listening, never answering: the busy server.
        $launches = New-Object System.Collections.ArrayList
        $up = Start-LocalStudioServer -ProjectRoot $project -Port $busyPort.LocalEndpoint.Port -Launch { param($r, $p) [void]$launches.Add($p) } -StartWaitSeconds 2
        Check ($up -and $launches.Count -eq 0) 'A helper must never start a second Book Studio while one is listening, however busy it is.'
        Check (Test-LocalStudioPortListening -Port $busyPort.LocalEndpoint.Port) 'A port that is listening must be seen as listening.'
    }
    finally { $busyPort.Stop() }
    $freePort = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $freePort.Start(); $closed = $freePort.LocalEndpoint.Port; $freePort.Stop()
    Check (-not (Test-LocalStudioPortListening -Port $closed)) 'A port nothing listens on must be seen as free.'
    $startState = @{ listening = $false; launches = 0 }
    $started = Start-LocalStudioServer -ProjectRoot $project -Port $closed -LockName ('Local\BookStudioStartTest' + [guid]::NewGuid().ToString('N')) -StartWaitSeconds 5 `
        -Listening { param($p) $startState.listening } -Launch { param($r, $p) $startState.launches++; $startState.listening = $true }
    Check ($started -and $startState.launches -eq 1) 'With nothing on the port, the helper starts the agent''s own Book Studio, once.'

    # Three helpers find the server missing at the same moment: one starts it,
    # the others wait for it. Separate processes, as the helpers are.
    $lockName = 'Local\BookStudioStartTest' + [guid]::NewGuid().ToString('N')
    $sharedPort = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $sharedPort.Start(); $racePort = $sharedPort.LocalEndpoint.Port; $sharedPort.Stop()
    $launchLog = Join-Path $fixture 'launches.txt'
    $library = Join-Path $root 'lib/EbookCloudRunner.ps1'
    $helperJobs = @(foreach ($name in 'one', 'two', 'three') {
        Start-Job -ArgumentList $library, $racePort, $lockName, $launchLog, $name -ScriptBlock {
            param($library, $port, $lockName, $launchLog, $name)
            . $library
            $result = Start-LocalStudioServer -ProjectRoot 'unused' -Port $port -LockName $lockName -StartWaitSeconds 20 -Launch {
                param($r, $p)
                Add-Content -LiteralPath $launchLog -Value $name
                # A server takes a moment to open its port.
                Start-Sleep -Seconds 3
                $global:standIn = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $p)
                $global:standIn.Start()
            }
            # Whoever started it keeps it open while the others look.
            Start-Sleep -Seconds 8
            $result
        }
    })
    try {
        $results = @($helperJobs | Wait-Job -Timeout 90 | Receive-Job)
        $launched = @(Get-Content -LiteralPath $launchLog -ErrorAction SilentlyContinue)
        Check ($launched.Count -eq 1) "Three helpers at once must start one Book Studio, not $($launched.Count)."
        Check ($results.Count -eq 3 -and @($results | Where-Object { $_ -eq $true }).Count -eq 3) "Every helper must end up with a Book Studio to carry its page to: $($results -join ', ')"
    }
    finally { $helperJobs | Stop-Job -ErrorAction SilentlyContinue; $helperJobs | Remove-Job -Force -ErrorAction SilentlyContinue }

    # 8. And it can be taken off again by the same person, without an installer.
    Uninstall-BookRunnerStartup -StartupFolder $startup | Out-Null
    Check (-not (Test-BookRunnerStartupInstalled -StartupFolder $startup)) 'Removing it must stop it starting with Windows.'
    Uninstall-BookRunnerStartup -StartupFolder $startup | Out-Null
    Check ($true) 'Removing it twice must not fail.'

    # 9. The agent itself must accept what the connect page tells a designer to
    #    type, and must explain itself when there is no token at all.
    $runner = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    Check ($runner -match '(?m)^\s*\[string\]\$Token\s*=') 'The agent must take -Token, which is what the connect page shows.'
    Check ($runner -match '(?m)^\s*\[switch\]\$StartWithWindows') 'The agent must take -StartWithWindows.'
    Check ($runner -match '(?m)^\s*\[switch\]\$StopStartingWithWindows') 'There must be a way to undo it.'
    Check ($runner -match 'Resolve-BookRunnerToken') 'The agent must resolve its token through the tested path.'
    Check ($runner -match 'Save-BookRunnerToken') 'The agent must remember a token that was pasted.'
    Check ($runner -match '/connect') 'A missing token must point at the page that issues one.'
    # The agent dials one address and the designer signs in at another. Naming
    # the machine-facing one sends someone to a page they have no account on.
    Check ($runner -match 'SignInUrl\s*=\s*"https://ebookstudio\.vocate\.app/cloud/connect"') 'The agent must point a designer at the one site they sign in at.'
    Check ($runner -match 'Sign in at \$SignInUrl') 'The missing-token message must use the sign-in address, not the address the agent dials.'
    Check ($runner -notmatch 'deploy-ebook-generator-cloudflare\.ps1 once to create it') 'A designer must not be told to run a deployment script.'
    Check ($runner -match "EbookCloudRunner\.ps1") 'The agent must dot-source the connection library.'
    # A designer watching the window must be able to tell a computer that
    # reported itself from one that quietly could not: the web page looks the
    # same either way until it is refreshed.
    Check ($runner -match 'now visible in Book Studio') 'The agent must say when the cloud has accepted this computer.'
    Check ($runner -match 'could not report itself') 'The agent must say when it could not, rather than looking healthy.'
    Check ($runner -match 'reportedOnce') 'That confirmation must be said once, not on every poll.'
    Check ($runner -match 'Enter-BookRunnerSingleInstance') 'The agent must refuse to be the second one on a computer.'
    Check ($runner -match 'already running on this computer') 'A second start must say what happened, not fail silently.'
    # A function that returns a value prints it when the caller ignores it, so
    # the word True appeared in the middle of what a designer was reading.
    Check ($runner -notmatch '(?m)^\s*Publish-CodexStatus[^|
]*$') 'The result of reporting must be consumed, or it is printed at the designer.'
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

# 10. The one command the connect page hands a designer fetches a setup script
#     from the worker and runs it. It is the only thing most people will ever
#     type, so it has to be valid PowerShell, has to survive being run twice,
#     and has to say what to do about the two things it cannot install.
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $fixture2 = Join-Path ([IO.Path]::GetTempPath()) ('setup-script-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixture2 | Out-Null
    $render = Join-Path $fixture2 'render.js'
    $rendered = Join-Path $fixture2 'setup.ps1'
    $workerPath = (Join-Path $root 'cloudflare/ebook-generator-worker.js').Replace('\', '/')
    @(
        "const {readFileSync,writeFileSync,mkdtempSync}=require('fs');const {tmpdir}=require('os');const {join}=require('path');",
        "const d=mkdtempSync(join(tmpdir(),'setup-'));const c=join(d,'w.mjs');writeFileSync(c,readFileSync('$workerPath'));",
        "import(require('url').pathToFileURL(c).href).then(async m=>{",
        "  const kv={async get(){return null},async put(){},async delete(){},async list(){return{keys:[]}}};",
        "  const r=await m.default.fetch(new Request('https://ebook.vocate.app/setup.ps1?token=testtoken123'),{BOOK_STUDIO_KV:kv,BOOK_STUDIO_FILES:{},REQUIRE_ACCESS:'false'});",
        "  writeFileSync(process.argv[2], await r.text());",
        "});"
    ) -join "`n" | Set-Content -LiteralPath $render -Encoding UTF8
    & $node.Source $render $rendered | Out-Null
    Check (Test-Path -LiteralPath $rendered) 'The worker must serve a setup script at /setup.ps1.'
    $setup = Get-Content -LiteralPath $rendered -Raw -Encoding UTF8
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($setup, [ref]$null, [ref]$errors) | Out-Null
    Check ($errors.Count -eq 0) "The setup command a designer pastes is not valid PowerShell: $($errors | Select-Object -First 1)"
    Check ($setup -match "testtoken123") 'The setup script must carry the token the page issued.'
    Check ($setup -match 'git-scm\.com') 'The setup script must say where to get Git when it is missing.'
    Check ($setup -match 'npm install -g @openai/codex') 'The setup script must say how to install Codex.'
    Check ($setup -match 'codex login') 'The setup script must say Codex has to be signed in.'
    Check ($setup -match 'git clone' -and $setup -match 'git -C \$folder pull') 'The setup script must install Book Studio, and update it when it is already there.'
    Check ($setup -match '-StartWithWindows') 'The setup script must leave the computer connecting on its own.'
    Check ($setup -match 'LOCALAPPDATA') 'Book Studio must land somewhere that needs no administrator.'
    Check ($setup -notmatch 'Program Files') 'The setup script must not install anywhere that needs an administrator.'
    Check ($setup -notmatch '(?m)^\s*Remove-Item') 'The setup script must not delete anything on a designer PC.'
    Remove-Item -LiteralPath $fixture2 -Recurse -Force -ErrorAction SilentlyContinue
}
else { Write-Warning 'node was not found; the setup script was not rendered or parsed.' }

# 11. A designer PC refuses to run a .ps1 file at all. That is not a setting
#     they can change: the policy comes from their organisation, and even
#     -ExecutionPolicy Bypass is overridden by it. The first version of the
#     setup command died exactly there, after cloning, with "running scripts is
#     disabled on this system". So both ways of starting the agent are run here
#     under a Restricted policy: the file must fail, and the way Book Studio
#     actually starts it must work.
$policyFixture = Join-Path ([IO.Path]::GetTempPath()) ('exec-policy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $policyFixture | Out-Null
try {
    $sample = Join-Path $policyFixture 'sample agent.ps1'
    Set-Content -LiteralPath $sample -Value 'param([string]$Token)' -Encoding UTF8
    Add-Content -LiteralPath $sample -Value 'Write-Output ("agent ran with " + $Token)' -Encoding UTF8

    # Output goes to files, never through a pipe: PowerShell 5.1 turns a native
    # program's stderr into a terminating error, and a blocked script writing to
    # stderr is exactly what this is trying to observe.
    function Invoke-Restricted([string[]]$Arguments, [string]$Name) {
        $out = Join-Path $policyFixture "$Name.out"
        $err = Join-Path $policyFixture "$Name.err"
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $Arguments -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $process.WaitForExit(60000)) { $process.Kill() }
        return ((Get-Content -LiteralPath $out -Raw) + '' ) + ((Get-Content -LiteralPath $err -Raw) + '')
    }

    $asFile = Invoke-Restricted @('-NoProfile', '-ExecutionPolicy', 'Restricted', '-File', "`"$sample`"", '-Token', 'abc') 'file'
    Check ($asFile -notmatch 'agent ran with abc') 'This computer is not enforcing a restricted policy, so the check below proves nothing.'
    Check ($asFile -match 'cannot be loaded') "A restricted policy must refuse a script file; got: $asFile"

    $command = '& ([scriptblock]::Create((Get-Content -Raw -LiteralPath ''' + $sample + '''))) -Token abc'
    $asCommand = Invoke-Restricted @('-NoProfile', '-ExecutionPolicy', 'Restricted', '-Command', "`"$command`"") 'command'
    Check ($asCommand -match 'agent ran with abc') "Book Studio must start its agent on a computer that forbids running script files; got: $asCommand"

    # And the startup shortcut has to use that same way in, or the machine
    # connects once and never again after a restart.
    $startup2 = Join-Path $policyFixture 'startup'
    $link = Install-BookRunnerStartup -ScriptPath $sample -StartupFolder $startup2
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
    Check ($shortcut.Arguments -match 'scriptblock\]::Create') 'The startup shortcut must start the agent as a command, not as a file.'
    Check ($shortcut.Arguments -notmatch '-File ') 'The startup shortcut must not start a file; a managed PC refuses to run one.'
    $shortcutCommand = [regex]::Match($shortcut.Arguments, '-Command "(.+)"$').Groups[1].Value
    Check ([bool]$shortcutCommand) 'The shortcut must carry a command to run.'
    $fromShortcut = Invoke-Restricted @('-NoProfile', '-ExecutionPolicy', 'Restricted', '-Command', "`"$shortcutCommand`"") 'shortcut'
    Check ($fromShortcut -match 'agent ran') "What the startup shortcut runs must work under a restricted policy; got: $fromShortcut"
}
finally {
    Remove-Item -LiteralPath $policyFixture -Recurse -Force -ErrorAction SilentlyContinue
}

# 12. The setup script must say the same thing: a file is never started, and
#     the per-user policy is only ever attempted, never required.
if ($node) {
    Check ($setup -match 'scriptblock\]::Create') 'The setup script must run the agent as a command, or a managed PC stops after cloning.'
    Check ($setup -match 'Set-ExecutionPolicy -Scope CurrentUser') 'The setup script should try to make this easier for the next time.'
    Check ($setup -match '(?s)try \{ Set-ExecutionPolicy.*?catch') 'A refused policy change must not stop the setup.'
    Check ($setup -notmatch 'Scope LocalMachine') 'Nothing may need an administrator.'
    Check ($setup -match '-ProjectRoot') 'Run as a command, the agent cannot work out its own folder; it must be told.'
    # Pasting the command into a window where Book Studio was already running
    # did nothing at all: the text went to the running program as input. It now
    # starts in its own window, so the paste always takes effect and closing
    # the window a designer typed into does not take the connection with it.
    Check ($setup -match 'Start-Process -FilePath .powershell\.exe.') 'The agent must start in its own window, not in the one the command was pasted into.'
    Check ($setup -match '-ArgumentList \$arguments') 'The launch arguments must be a list, so a folder with a space in it survives.'
    # And the answer to did that work belongs on the screen the designer is
    # looking at, not on a web page they have to go and refresh.
    Check ($setup -match '/api/runner/self') 'The setup command must ask the cloud whether this computer arrived.'
    Check ($setup -match 'Connected as ') 'It must say so when the computer arrives.'
    Check ($setup -match 'has not reached Book Studio') 'It must say so when the computer does not.'
    Check ($setup -match 'You can close this window') 'A designer must be told they no longer have to keep a window open.'
    Check ($setup -match 'npm install -g @openai/codex') 'A working connection with no Codex must say how to fix Codex.'
    # The cloud and the copy of Book Studio on a PC are released separately, so
    # the PC can legitimately be behind. Saying so is the difference between a
    # designer knowing to ask for a release and reading a binding error about
    # an empty string, which is what actually happened.
    Check ($setup -match "needed = '\d{4}\.\d{2}\.\d{2}\.\d+'") 'The setup script must know the oldest Book Studio the cloud can drive.'
    Check ($setup -match 'older than the cloud expects') 'A version that is too old must be explained in words.'
    Check ($setup -match 'version\.json') 'The check must read the version actually installed.'
    Check ($setup -match '(?s)older than the cloud expects.*?return') 'A version that is too old must stop, not carry on into a confusing error.'
    # "Which version do I have?" must be answerable by reading the window, not
    # by reading the code.
    Check ($setup -match 'Book Studio on this computer: ') 'The setup script must say which version is on that computer.'
    Check ($setup -match '(?s)git -C \$folder pull --ff-only.*?LASTEXITCODE') 'A failed update must be reported, not passed over in silence.'
}

# 12b. Setting up connects the copy of Book Studio the designer's books are in.
#      Each copy keeps its own books. Ann Jackson's were in the folder her
#      desktop shortcut opens; the setup command installed a second copy under
#      LOCALAPPDATA, the agent ran from that, and Book Studio on the web site
#      showed an empty library while the one on her desktop had everything.
#      The folder-finding functions are taken out of the script the worker
#      serves and run against real folders and real git repositories.
$gitForSetup = Get-Command git -ErrorAction SilentlyContinue
if ($node -and $gitForSetup) {
    $setupTokens = $null; $setupErrors = $null
    $setupAst = [System.Management.Automation.Language.Parser]::ParseInput($setup, [ref]$setupTokens, [ref]$setupErrors)
    $wanted = @('Get-BookStudioBookCount', 'Get-BookStudioFolderProblem', 'Get-BookStudioFolderCandidates', 'Find-BookStudioFolder')
    $definitions = @($setupAst.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $wanted -contains $_.Name })
    Check ($definitions.Count -eq 4) "The setup script must define the functions that find the folder with the books; found $(@($definitions.Name) -join ', ')"
    foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
    Check ($setup -match 'Find-BookStudioFolder -Current \(Get-Location\)\.Path -Candidates \(Get-BookStudioFolderCandidates\)') 'The setup script must choose its folder with those functions.'
    Check ($setup -match "(?s)if \(\`$choice\.action -eq 'stop'\) \{.*?return\s*\}.*?git clone") 'A refusal must stop the setup before anything is cloned.'

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $setupFixture = Join-Path ([IO.Path]::GetTempPath()) ('setup-folder-' + [guid]::NewGuid().ToString('N'))
    try {
        function New-FakeInstall([string]$Path, [int]$Books = 0, [switch]$NoGit, [string]$Origin = 'https://github.com/gduartevocate/book-studio.git') {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Path 'cloud-book-runner.ps1') -Value '# agent' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $Path 'Start-BookStudioCompanion.ps1') -Value '# launcher' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $Path '.gitignore') -Value '.bookstudio/' -Encoding UTF8
            if (-not $NoGit) {
                & git init -q $Path 2>&1 | Out-Null
                & git -C $Path remote add origin $Origin 2>&1 | Out-Null
                & git -C $Path add -A 2>&1 | Out-Null
                & git -C $Path -c user.email=t@t -c user.name=t commit -q -m install 2>&1 | Out-Null
            }
            if ($Books -gt 0) {
                New-Item -ItemType Directory -Path (Join-Path $Path '.bookstudio') -Force | Out-Null
                $jobs = @(1..$Books | ForEach-Object { @{ id = "book-$_"; title = "Book $_" } })
                @{ schemaVersion = 1; jobs = $jobs } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Path '.bookstudio/book-studio-db.json') -Encoding UTF8
            }
        }
        $userHome = Join-Path $setupFixture 'home'
        $desktop = Join-Path $setupFixture 'desktop'
        $startupFolder = Join-Path $setupFixture 'startup'
        $annBooks = Join-Path $setupFixture 'Ann Jackson\book studio'
        $agentCopy = Join-Path $setupFixture 'LocalAppData\Book Studio'
        New-Item -ItemType Directory -Path $userHome, $desktop, $startupFolder -Force | Out-Null
        New-FakeInstall -Path $annBooks -Books 2
        New-FakeInstall -Path $agentCopy
        $shell = New-Object -ComObject WScript.Shell
        $desktopLink = $shell.CreateShortcut((Join-Path $desktop 'Book Studio.lnk'))
        $desktopLink.TargetPath = (Get-Command powershell.exe).Source; $desktopLink.WorkingDirectory = $annBooks; $desktopLink.Save()
        $agentLink = $shell.CreateShortcut((Join-Path $startupFolder 'Book Studio cloud agent.lnk'))
        $agentLink.TargetPath = (Get-Command powershell.exe).Source; $agentLink.WorkingDirectory = $agentCopy; $agentLink.Save()

        $candidates = @(Get-BookStudioFolderCandidates -Desktop $desktop -Startup $startupFolder -UserHome $userHome)
        Check ($candidates -contains $annBooks) "The folder the desktop shortcut opens must be looked at; saw $($candidates -join '; ')"
        Check ($candidates -contains $agentCopy) 'The folder an earlier setup connected must be looked at.'
        Check ($candidates -contains (Join-Path $userHome 'book-studio')) 'The usual folder under the user profile must be looked at.'
        Check ((Get-BookStudioBookCount $annBooks) -eq 2 -and (Get-BookStudioBookCount $agentCopy) -eq 0) 'Books must be counted from each folder''s own database.'

        $picked = Find-BookStudioFolder -Current $userHome -Candidates $candidates -Default $agentCopy
        Check ($picked.action -eq 'update' -and $picked.folder -eq $annBooks -and $picked.books -eq 2) "Setup must connect the copy with the books, not an empty one; got $($picked.action) $($picked.folder)"
        # The difference, not the selection: with no copy holding books, the
        # same search lands on setup's own folder.
        $withoutBooks = Find-BookStudioFolder -Current $userHome -Candidates @((Join-Path $userHome 'book-studio'), $agentCopy) -Default $agentCopy
        Check ($withoutBooks.folder -eq $agentCopy -and $withoutBooks.action -eq 'update') 'With no copy holding books, setup must use and update its own folder.'
        $fresh = Find-BookStudioFolder -Current $userHome -Candidates @() -Default (Join-Path $setupFixture 'nothing here\Book Studio')
        Check ($fresh.action -eq 'clone') 'A computer with no Book Studio at all must get one.'
        # Standing in a copy is a choice, and it is honoured; books found in
        # another folder are mentioned rather than silently left behind.
        $standing = Find-BookStudioFolder -Current $agentCopy -Candidates $candidates -Default $agentCopy
        Check ($standing.folder -eq $agentCopy -and $standing.action -eq 'update') 'The copy the window is standing in must be used.'
        Check (($standing.notes -join ' ') -match [regex]::Escape($annBooks)) 'The designer must be told their books are in another folder.'

        # A copy with the books that cannot be updated safely: stop, say why,
        # change nothing -- never a second, empty copy beside it.
        Set-Content -LiteralPath (Join-Path $annBooks 'my notes.txt') -Value 'mine' -Encoding UTF8
        $dirty = Find-BookStudioFolder -Current $userHome -Candidates $candidates -Default $agentCopy
        Check ($dirty.action -eq 'stop') "A copy with the books and changed files must stop the setup; got $($dirty.action) $($dirty.folder)"
        Check ($dirty.message -match [regex]::Escape($annBooks) -and $dirty.message -match '2 books' -and $dirty.message -match 'changed by hand') "The refusal must name the folder, its books and the reason: $($dirty.message)"
        Check ($dirty.message -match 'Nothing was installed or changed' -and $dirty.message -match 'do not delete') 'The refusal must say nothing was touched, and not to delete the folder.'
        Remove-Item -LiteralPath (Join-Path $annBooks 'my notes.txt') -Force
        $zipCopy = Join-Path $setupFixture 'Downloads\BookStudio-ID'
        New-FakeInstall -Path $zipCopy -Books 1 -NoGit
        $zip = Find-BookStudioFolder -Current $userHome -Candidates @($zipCopy) -Default $agentCopy
        Check ($zip.action -eq 'stop' -and $zip.message -match 'not installed with git' -and $zip.message -match '\(1 book\)') "A copy with books that cannot update itself must stop the setup: $($zip.message)"
        $devCopy = Join-Path $setupFixture 'dev checkout'
        New-FakeInstall -Path $devCopy -Books 3 -Origin 'https://github.com/someone/private-checkout.git'
        $dev = Find-BookStudioFolder -Current $userHome -Candidates @($devCopy) -Default $agentCopy
        Check ($dev.action -eq 'stop' -and $dev.message -match 'distribution') "A copy that follows another repository must never be updated by setup: $($dev.message)"
        $devHere = Find-BookStudioFolder -Current $devCopy -Candidates @() -Default $agentCopy
        Check ($devHere.action -eq 'use' -and $devHere.folder -eq $devCopy) 'Standing in a copy that cannot update itself connects it as it is, without updating it.'
        # Setup's own folder keeps its old behaviour even with books and a
        # stray file: it is updated, and the version check reports a failure.
        New-Item -ItemType Directory -Path (Join-Path $agentCopy '.bookstudio') -Force | Out-Null
        '{ "jobs": [ { "id": "online-1" } ] }' | Set-Content -LiteralPath (Join-Path $agentCopy '.bookstudio/book-studio-db.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $agentCopy 'stray.txt') -Value 'x' -Encoding UTF8
        $ownCopy = Find-BookStudioFolder -Current $userHome -Candidates @($agentCopy) -Default $agentCopy
        Check ($ownCopy.action -eq 'update' -and $ownCopy.folder -eq $agentCopy) 'The folder setup manages itself is updated as before, not refused.'
        # Two copies with books: the one the desktop opens wins, and the other
        # is named.
        $both = Find-BookStudioFolder -Current $userHome -Candidates $candidates -Default $agentCopy
        Check ($both.folder -eq $annBooks -and ($both.notes -join ' ') -match [regex]::Escape($agentCopy)) 'With books in two copies, the desktop''s is connected and the other is named.'
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Get-ChildItem -LiteralPath $setupFixture -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = [IO.FileAttributes]::Normal } catch { } }
        Remove-Item -LiteralPath $setupFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}
else { Write-Warning 'node or git was not found; the setup script''s choice of folder was not exercised.' }

# 13. Updating itself. A designer should never be asked to paste a command
#     again to get a fix, and the two ways that can go wrong are worse than
#     the problem: updating a folder that is not the managed install, and
#     throwing away work somebody has in progress there. Both are exercised
#     against real git repositories rather than described.
$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($gitCommand) {
    # git writes ordinary progress to stderr, and PowerShell 5.1 turns a native
    # program's stderr into a terminating error while ErrorActionPreference is
    # Stop. Nothing here is failing when that happens.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $updateFixture = Join-Path ([IO.Path]::GetTempPath()) ('self-update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $updateFixture | Out-Null
    try {
        $origin = Join-Path $updateFixture 'origin'
        $work = Join-Path $updateFixture 'work'
        $install = Join-Path $updateFixture 'install'
        & git init --bare -q $origin
        & git clone -q $origin $work 2>&1 | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $work 'book-studio') | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'book-studio/version.json') -Value '{"version":"2026.01.01.1"}' -Encoding UTF8
        & git -C $work add -A; & git -C $work -c user.email=t@t -c user.name=t commit -q -m first
        & git -C $work push -q origin HEAD:refs/heads/master 2>&1 | Out-Null
        & git clone -q $origin $install 2>&1 | Out-Null

        Check ((Get-BookStudioInstalledVersion -ProjectRoot $install) -eq '2026.01.01.1') 'The installed version must be readable.'
        Check ((ConvertTo-BookStudioVersionNumber '2026.09.22.7') -gt (ConvertTo-BookStudioVersionNumber '2026.09.22.6')) 'Versions must compare in order.'
        Check ((ConvertTo-BookStudioVersionNumber '2026.10.01.1') -gt (ConvertTo-BookStudioVersionNumber '2026.09.30.9')) 'A later month must count as newer.'

        # This clone follows a scratch repository, not the distribution, so it
        # must be left alone: this is what protects a development checkout.
        $verdict = Test-BookStudioSelfUpdatable -ProjectRoot $install
        Check (-not $verdict.updatable) 'A folder that does not follow the Book Studio distribution must not be updated.'
        Check ($verdict.reason -match 'distribution') "The refusal must say why: $($verdict.reason)"
        Check ((Test-BookStudioSelfUpdatable -ProjectRoot $install -DistributionPattern 'self-update-').updatable) 'The managed install must be updatable.'

        # Unsaved work in that folder stops it: an update would discard it.
        Set-Content -LiteralPath (Join-Path $install 'scratch.txt') -Value 'half-finished' -Encoding UTF8
        $dirty = Test-BookStudioSelfUpdatable -ProjectRoot $install -DistributionPattern 'self-update-'
        Check (-not $dirty.updatable) 'A folder with unsaved changes must not be updated.'
        Check ($dirty.reason -match 'unsaved') "The refusal must name the reason: $($dirty.reason)"
        Remove-Item -LiteralPath (Join-Path $install 'scratch.txt') -Force

        # Nothing new published: nothing happens, and it says so quietly.
        $quiet = Update-BookStudioInstall -ProjectRoot $install -DistributionPattern 'self-update-'
        Check (-not $quiet.updated) 'With nothing new, no update must be reported.'

        # A new release appears, and the install picks it up on its own.
        Set-Content -LiteralPath (Join-Path $work 'book-studio/version.json') -Value '{"version":"2026.01.02.1"}' -Encoding UTF8
        & git -C $work add -A; & git -C $work -c user.email=t@t -c user.name=t commit -q -m second
        & git -C $work push -q origin HEAD 2>&1 | Out-Null
        $done = Update-BookStudioInstall -ProjectRoot $install -DistributionPattern 'self-update-'
        Check ($done.updated) "A newly published release must be picked up: $($done.reason)"
        Check ($done.from -eq '2026.01.01.1' -and $done.to -eq '2026.01.02.1') "The update must report both versions, got $($done.from) to $($done.to)"
        Check ((Get-BookStudioInstalledVersion -ProjectRoot $install) -eq '2026.01.02.1') 'The files on disk must actually be the new ones.'
    }
    finally {
        Get-ChildItem -LiteralPath $updateFixture -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = [IO.FileAttributes]::Normal } catch { } }
        Remove-Item -LiteralPath $updateFixture -Recurse -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $previousPreference
    }
}
else { Write-Warning 'git was not found; the self-update checks were skipped.' }

# And the agent has to act on all that: at start, then on a timer, restarting
# into whatever it fetched.
$runnerText = Get-Content -LiteralPath (Join-Path $root 'cloud-book-runner.ps1') -Raw -Encoding UTF8
Check ($runnerText -match 'Invoke-BookRunnerSelfUpdate') 'The agent must check for its own updates.'
Check ($runnerText -match 'UpdateCheckMinutes') 'It must keep checking, not only at start.'
Check ($runnerText -match 'Restart-BookRunner') 'It must restart into what it fetched, or the update does nothing until the PC is rebooted.'

# The local Book Studio refuses any change whose Origin is not its own address:
# the right rule for a browser on that PC, the wrong one for a request that
# arrived through the cloud already authenticated. Forwarding the browser's
# Origin made every action in Settings fail with 403.
Check ($runnerText -match "'Origin', 'Referer', 'Cookie'") 'The bridge must not carry the browser Origin, Referer or the cloud cookie to the local server.'

# Page helpers. One agent carried every page request between its other work --
# job polling, reporting, update checks, a Codex test of up to 45 seconds -- so
# Ann Jackson's pages hung and then said "did not answer in time". Helpers now
# carry pages side by side, and nothing else.
$agentPath = Join-Path $root 'cloud-book-runner.ps1'
$workerAt = $runnerText.IndexOf('if ($BridgeWorker) {')
Check ($workerAt -gt 0 -and $workerAt -lt $runnerText.IndexOf('Enter-BookRunnerSingleInstance -TakeOver')) 'A helper must start before the one-agent lock, which is the agent''s, not its helpers''.'
$workerBlock = $runnerText.Substring($workerAt, $runnerText.IndexOf('return', $workerAt) - $workerAt)
Check ($workerBlock -match 'Get-Process -Id \$ParentProcessId' -and $workerBlock -match 'Invoke-BridgeCycle') 'A helper carries page requests for as long as its agent runs.'
$loopAt = $runnerText.LastIndexOf('do {')
Check ($runnerText.Substring($loopAt) -notmatch 'Invoke-BridgeCycle') 'The agent''s own loop must not carry pages: that is what made them wait.'
Check ($runnerText -match '-BridgeWorker -ParentProcessId \$PID' -and $runnerText -match "'-WindowStyle', 'Hidden', '-Command', \`$inner\) -WindowStyle Hidden -PassThru") 'The agent starts its helpers hidden, tied to itself.'
Check ($runnerText -match 'Sync-LocalStudioServer\s+\$script:bridgeWorkerProcesses = @\(Start-BridgeWorkers\)') 'Helpers start as soon as the agent does, not after its first round of other work.'
Check ($runnerText -match '\[int\]\$BridgeWorkers = 3') 'Several helpers, so one slow page does not hold up the next.'
# The helpers use the tested way to reach the local server: one that waits for
# a busy server and never starts a duplicate. A second copy of it in the agent
# would quietly take precedence.
Check ($runnerText -notmatch '(?m)^function (Start|Test)-LocalStudioServer') 'The agent must not define its own server start; the tested one in lib/EbookCloudRunner.ps1 is the one to use.'
Check ($runnerText -match 'Start-LocalStudioServer -ProjectRoot \$ProjectRoot -Port \$Port') 'Each page must go through the tested server start.'
# The heartbeat says which folder the web site is shown, and how many books it
# holds, so a second, empty copy of Book Studio is visible on the web site.
Check ($runnerText -match '\$body\.studio = \$script:studioReport') 'The heartbeat must report the Book Studio folder being served.'
Check ($runnerText -match 'Update-LocalStudioReport\s+Publish-CodexStatus') 'The report must be brought up to date before it is sent.'
Check ($runnerText -match "(?s)'other-folder' \{ Write-Warning") 'A Book Studio from another folder is reported, not stopped.'
Check ($runnerText -match "(?s)'replaced-empty' \{.*?Start-LocalStudioServer") 'When the empty leftover of an old agent goes, this folder''s Book Studio starts in its place.'
Check ($runnerText -match 'codexCheckedAt\)\.TotalMinutes -ge 8\)') 'The background Codex check must run inside the ten minutes a pass counts for.'

# And for real: a helper whose agent has gone stops by itself.
$savedToken = $env:BOOK_RUNNER_TOKEN
$env:BOOK_RUNNER_TOKEN = 'fixture-token-never-sent'
try {
    $standInAgent = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60')
    $helperArgs = "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$agentPath'))) -BridgeWorker -ParentProcessId $($standInAgent.Id) -ProjectRoot '$root' -BaseUrl 'http://127.0.0.1:9'"
    $helper = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $helperArgs)
    Start-Sleep -Seconds 4
    $helper.Refresh()
    Check (-not $helper.HasExited) 'A helper keeps running while its agent runs, even when the site cannot be reached.'
    Stop-Process -Id $standInAgent.Id -Force
    $helper.WaitForExit(20000) | Out-Null
    Check ($helper.HasExited) 'A helper must stop by itself once its agent has gone, so none are left behind.'
}
finally {
    $env:BOOK_RUNNER_TOKEN = $savedToken
    foreach ($p in @($standInAgent, $helper)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
}

# The agent uses these rules where they matter.
Check ($runnerText -match 'Enter-BookRunnerSingleInstance -TakeOver:\(\[bool\]\$Token\)') 'Only the setup command, which carries a token, may replace a running agent.'
$afterSelfUpdate = [regex]::Matches($runnerText, 'Invoke-BookRunnerSelfUpdate -ProjectRoot \$ProjectRoot -Instance \$instance\) \{ return \}\s+Sync-LocalStudioServer')
Check ($afterSelfUpdate.Count -eq 2) 'The server must be brought up to date at start and at every hourly check, after the agent itself.'
Check ($runnerText -match '\[int\]\$UpdateCheckMinutes = 15') 'The update check needs its interval, or it asks GitHub every cycle; fifteen minutes gets a fix out the same morning.'

# Any update on disk is running within a cycle, however it got there. An update
# from Get latest updates in Settings left the agent on its old code, because
# its own check then found nothing new to download.
$versionRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-version-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $versionRoot 'book-studio') -Force | Out-Null
try {
    '{ "version": "2026.09.23.18" }' | Set-Content -LiteralPath (Join-Path $versionRoot 'book-studio/version.json')
    Check (Test-BookRunnerBehindInstall -ProjectRoot $versionRoot -RunningVersion '2026.09.23.17') 'An agent older than the files on disk must see it is behind.'
    Check (-not (Test-BookRunnerBehindInstall -ProjectRoot $versionRoot -RunningVersion '2026.09.23.18')) 'An agent on the installed release is not behind.'
    Check (-not (Test-BookRunnerBehindInstall -ProjectRoot $versionRoot -RunningVersion '2026.09.23.19')) 'Files older than the agent never make it restart.'
    Check (Test-BookRunnerBehindInstall -ProjectRoot $versionRoot -RunningVersion '2026.09.23.9') 'Release numbers compare as numbers: .18 is newer than .9.'
    Check (-not (Test-BookRunnerBehindInstall -ProjectRoot $versionRoot -RunningVersion '')) 'An agent that could not read its own release does not restart in a loop.'
}
finally { Remove-Item -LiteralPath $versionRoot -Recurse -Force -ErrorAction SilentlyContinue }
$behindAt = $runnerText.IndexOf('Test-BookRunnerBehindInstall -ProjectRoot $ProjectRoot -RunningVersion $script:agentVersion')
Check ($behindAt -gt 0 -and $runnerText.Substring($behindAt, 400) -match 'Restart-BookRunner -ProjectRoot \$ProjectRoot -Instance \$instance\s+return') 'An agent behind the files on disk must restart into them.'
Check ($runnerText.IndexOf('$script:agentVersion = Get-BookStudioInstalledVersion') -gt 0 -and $runnerText.IndexOf('$script:agentVersion = Get-BookStudioInstalledVersion') -lt $behindAt) 'The agent must remember the release it started as.' 

"PASS: $checks connection assertions (token remembered and replaced, kept in the user profile, start with Windows without an administrator, setup replaces an old agent and connects the folder with the books, only the agent's own old server is restarted, helpers never start a duplicate)."
