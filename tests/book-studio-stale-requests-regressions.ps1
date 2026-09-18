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
"PASS: $checks stale-request checks. Fixtures: $fixture"
