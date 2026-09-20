$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
$studio = Get-Module BookStudio
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('bookstudio-stale-requests-' + [guid]::NewGuid().ToString('N'))
$dbPath = Initialize-BookStudioDatabase -ProjectRoot $fixture
$checks = 0
function Check([bool]$ok, [string]$message) { if (-not $ok) { throw $message }; $script:checks++ }
function SaveRequest($request) {
    $db = Read-BookStudioDatabase $dbPath
    $db.jobs = @([pscustomobject]@{id='book';title='Revenue Cycle';status='Completed';updatedAt=(Get-Date).ToString('s');log=@();aiRequests=@($request)})
    Write-BookStudioDatabase $dbPath $db
}
function Blocker { & $studio {param($d) Get-BookStudioUpdateBlocker $d} $dbPath }
function Request { (Get-BookStudioJob $dbPath 'book').aiRequests[0] }
$exitPath = Join-Path $fixture 'exit.txt'
$responsePath = Join-Path $fixture 'response.md'
'Partial or final response.' | Set-Content -LiteralPath $responsePath -Encoding UTF8
$deadPid = [int]::MaxValue
SaveRequest ([pscustomobject]@{id='dead';status='Running';processId=$deadPid;allowEdits=$true;responsePath=$responsePath;chatArchivedAt='2026-01-01'})
Check (-not (Blocker)) 'Dead request still blocks updates.'
Check ((Request).status -eq 'Failed' -and (Request).postProcessStatus -match 'no automatic rebuild') 'Interrupted edit claimed success or scheduled an unexpected rebuild.'
Check ((Get-Content -LiteralPath $responsePath -Raw).Trim() -eq 'Partial or final response.') 'Recovery changed the response.'
Check (@((Get-BookStudioJob $dbPath 'book').log).Count -eq 1) 'Recovery was not logged.'
$null = Blocker
Check (@((Get-BookStudioJob $dbPath 'book').log).Count -eq 1) 'Repeated checks duplicate recovery logs.'
foreach ($exitText in @('0','1','not an exit code')) {
    Set-Content -LiteralPath $exitPath -Value $exitText -Encoding UTF8
    SaveRequest ([pscustomobject]@{id='exited';status='Running';processId=$deadPid;exitCodePath=$exitPath;responsePath=$responsePath})
    Check (-not (Blocker)) 'Finished request still blocks updates.'
    $expected = if ($exitText -eq '0') { 'Completed' } else { 'Failed' }
    Check ((Request).status -eq $expected) "Wrong completion state for exit code '$exitText'."
}
'0' | Set-Content -LiteralPath $exitPath
SaveRequest ([pscustomobject]@{id='no-response';status='Running';exitCodePath=$exitPath})
Check (-not (Blocker) -and (Request).status -eq 'Failed') 'Exit zero without a response falsely succeeded.'
$live = [pscustomobject]@{id='live';status='Running';processId=$PID;processStartedAt=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}
SaveRequest $live
Check ((Blocker) -match 'Stopping the web server does not stop Codex') 'Live runner no longer blocks updates.'
Check ((Request).status -eq 'Running') 'Live runner was marked failed.'
$live.processStartedAt = (Get-Date).AddDays(-3).ToUniversalTime().ToString('o')
SaveRequest $live
Check (-not (Blocker) -and (Request).status -eq 'Failed') 'Reused PID blocked updates.'
SaveRequest ([pscustomobject]@{id='legacy-reused';status='Running';processId=$PID;createdAt=(Get-Date).AddDays(-3).ToString('s')})
Check (-not (Blocker)) 'Legacy reused PID blocked updates.'
SaveRequest ([pscustomobject]@{id='missing-pid';status='Running'})
Check (-not (Blocker) -and (Request).status -eq 'Failed') 'Missing process ID blocked updates.'
SaveRequest ([pscustomobject]@{id='queued';status='Queued'})
Check ((Blocker) -match 'Codex request') 'Pending queued request was silently cleared.'
# The standalone recovery is usable on the installed version, leaves a backup,
# and only writes the database, not tracked app files or book content.
SaveRequest ([pscustomobject]@{id='bootstrap';status='Running';processId=$deadPid})
New-Item -ItemType Directory -Path (Join-Path $fixture 'lib') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'lib') -Destination $fixture -Recurse -Force
& (Join-Path $root 'Repair-BookStudioUpdate.ps1') -InstallPath $fixture
Check (@(Get-ChildItem -LiteralPath (Split-Path $dbPath -Parent) -Filter '*.before-update-recovery-*.bak').Count -eq 1) 'Standalone repair did not back up the database.'
Check ((Request).status -eq 'Failed') 'Standalone repair left the stale request running.'

# A Codex run that hangs must not hold its book hostage: the designer can stop
# it, and a runner that already died is reconciled by the running app itself.
$stuckRoot = Join-Path $env:LOCALAPPDATA ('BookStudioTests\stuck-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stuckDb = Initialize-BookStudioDatabase -ProjectRoot $stuckRoot
$idle = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 300') -WindowStyle Hidden -PassThru
try {
    $stuckJob = [pscustomobject]@{ id = 'stuck01'; status = 'Completed'; title = 'Stuck book'; log = @(); aiRequests = @([pscustomobject]@{
                id = 'req1'; status = 'Running'; allowEdits = $true; processId = $idle.Id
                processStartedAt = $idle.StartTime.ToUniversalTime().ToString('o')
                createdAt = (Get-Date).ToString('s'); responsePath = ''; exitCodePath = ''; errorPath = ''
            })
    }
    $stuckDatabase = Read-BookStudioDatabase -DatabasePath $stuckDb
    $stuckDatabase.jobs = @($stuckJob)
    Write-BookStudioDatabase -DatabasePath $stuckDb -Database $stuckDatabase
    Check ((Repair-BookStudioStaleAiRequests -DatabasePath $stuckDb) -eq 0) 'Recovery cleared a Codex request whose runner is alive.'
    $blocked = $false
    try { Remove-BookStudioJob -DatabasePath $stuckDb -JobId 'stuck01' | Out-Null }
    catch { $blocked = $true; Check ($_.Exception.Message -match 'Stop Codex request') 'The deletion refusal does not say how to get unstuck.' }
    Check $blocked 'A book with a running Codex request was deleted anyway.'
    $stopResult = Stop-BookStudioAiRequest -DatabasePath $stuckDb -JobId 'stuck01' -RequestId 'req1'
    Check ($stopResult.stoppedProcess -and -not (Get-Process -Id $idle.Id -ErrorAction SilentlyContinue)) 'Stopping the request left its runner alive.'
    $stoppedRequest = (Get-BookStudioJob -DatabasePath $stuckDb -JobId 'stuck01').aiRequests[0]
    Check ($stoppedRequest.status -eq 'Failed' -and $stoppedRequest.failureKind -eq 'cancelled') 'The stopped request was not recorded as cancelled.'
    $null = Remove-BookStudioJob -DatabasePath $stuckDb -JobId 'stuck01'
    Check (-not (Get-BookStudioJob -DatabasePath $stuckDb -JobId 'stuck01')) 'The book could not be deleted after stopping Codex.'
}
finally { Stop-Process -Id $idle.Id -Force -ErrorAction SilentlyContinue }
$deadJob = [pscustomobject]@{ id = 'dead01'; status = 'Completed'; title = 'Dead runner'; log = @(); aiRequests = @([pscustomobject]@{ id = 'req2'; status = 'Running'; allowEdits = $false; processId = 999999; createdAt = (Get-Date).ToString('s'); responsePath = ''; exitCodePath = ''; errorPath = '' }) }
$stuckDatabase = Read-BookStudioDatabase -DatabasePath $stuckDb
$stuckDatabase.jobs = @($deadJob)
Write-BookStudioDatabase -DatabasePath $stuckDb -Database $stuckDatabase
Check ((Repair-BookStudioStaleAiRequests -DatabasePath $stuckDb) -eq 1) 'A dead Codex runner was left Running.'
$null = Remove-BookStudioJob -DatabasePath $stuckDb -JobId 'dead01'
Check (-not (Get-BookStudioJob -DatabasePath $stuckDb -JobId 'dead01')) 'A book with a dead Codex runner still could not be deleted.'
Remove-Item -LiteralPath $stuckRoot -Recurse -Force -ErrorAction SilentlyContinue
$serverModule = Get-Content -LiteralPath (Join-Path $root 'lib/BookStudio.psm1') -Raw -Encoding UTF8
Check (([regex]::Matches($serverModule, 'Repair-BookStudioStaleAiRequests -DatabasePath')).Count -ge 2) 'The running app does not reconcile stale Codex requests while serving books.'

"PASS: $checks stale-request checks. Fixtures: $fixture"
