$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
$studio = Get-Module BookStudio
$git = (Get-Command git.exe -ErrorAction Stop).Source
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }
function Reject([scriptblock]$Action, [string]$Expected, [string]$Message) { try { & $Action | Out-Null } catch { if ($_.Exception.Message -match $Expected) { $script:checks++; return }; throw "FAIL: $Message (got: $($_.Exception.Message))" }; throw "FAIL: $Message (no error)" }

# A private local "update server" (bare repo), a publisher clone, and a
# designer install. No network, no GitHub, no real Book Studio server.
$fixture = Join-Path $env:LOCALAPPDATA ('BookStudioTests\update-' + [guid]::NewGuid().ToString('N'))
$remote = Join-Path $fixture 'remote.git'; $work = Join-Path $fixture 'work'; $install = Join-Path $fixture 'install'
New-Item -ItemType Directory -Path $fixture, $work | Out-Null
& $git init --quiet --bare -b main $remote
& $git -C $work init --quiet -b main
& $git -C $work config user.email 'tests@example.com'; & $git -C $work config user.name 'Book Studio Tests'
function Publish([string]$Version, [string]$Message) {
    New-Item -ItemType Directory -Path (Join-Path $work 'book-studio') -Force | Out-Null
    ([pscustomobject]@{ product = 'Book Studio ID'; version = $Version; buildDate = '2026-01-01'; channel = 'test' } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $work 'book-studio/version.json') -Encoding UTF8
    "Release $Version" | Set-Content -LiteralPath (Join-Path $work 'README.md') -Encoding UTF8
    & $git -C $work add -A; & $git -C $work commit --quiet -m $Message
    if (-not (& $git -C $work remote)) { & $git -C $work remote add origin $remote }
    & $git -C $work push --quiet -u origin main
}
Publish '2026.01.01.1' 'v1'
& $git clone --quiet $remote $install
& $git -C $install config user.email 'designer@example.com'; & $git -C $install config user.name 'Designer'

$status = & $studio { param($r) Get-BookStudioUpdateStatus -ProjectRoot $r } $install
Check ($status.gitAvailable -and $status.isRepository -and $status.installedVersion -eq '2026.01.01.1') 'A cloned install reports its version and repository.'
Check (-not $status.updateAvailable -and $status.message -match 'Check for updates') 'Without fetching, no update is claimed.'

Publish '2026.01.02.1' 'Add feature'
$status = & $studio { param($r) Get-BookStudioUpdateStatus -ProjectRoot $r -Fetch } $install
Check ($status.updateAvailable -and $status.behind -eq 1 -and $status.latestVersion -eq '2026.01.02.1') "A newer release is detected after fetch (behind=$($status.behind), latest=$($status.latestVersion))."
Check ((@($status.changes) -join ' ') -match 'Add feature' -and $status.canUpdate) 'Pending changes are listed and the update is allowed.'

Add-Content -LiteralPath (Join-Path $install 'README.md') -Value 'local edit'
$dirty = & $studio { param($r) Get-BookStudioUpdateStatus -ProjectRoot $r -Fetch } $install
Check ($dirty.dirty -and -not $dirty.canUpdate -and $dirty.message -match 'Local changes') 'Local edits block the update and are named.'
Reject { & $studio { param($r) Start-BookStudioUpdate -ProjectRoot $r -NoRestart -Wait } $install } 'Local changes' 'Start refuses a dirty folder.'
& $git -C $install checkout --quiet -- README.md

$database = Join-Path $install '.bookstudio/book-studio-db.json'
New-Item -ItemType Directory -Path (Split-Path $database -Parent) -Force | Out-Null
'{"schemaVersion":1,"createdAt":"2026-01-01T00:00:00","updatedAt":"2026-01-01T00:00:00","jobs":[{"id":"busy","title":"Busy Book","status":"Running","aiRequests":[]}]}' | Set-Content -LiteralPath $database -Encoding UTF8
Reject { & $studio { param($r, $d) Start-BookStudioUpdate -ProjectRoot $r -DatabasePath $d -NoRestart -Wait } $install $database } 'still generating' 'A running job blocks the update.'
$liveDb = [pscustomobject]@{schemaVersion=1;jobs=@([pscustomobject]@{id='busy';title='Busy Book';status='Completed';aiRequests=@([pscustomobject]@{id='r1';status='Running';processId=$PID;processStartedAt=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')})})}
$liveDb | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $database -Encoding UTF8
Reject { & $studio { param($r, $d) Start-BookStudioUpdate -ProjectRoot $r -DatabasePath $d -NoRestart -Wait } $install $database } 'Codex request' 'A running Codex request blocks the update.'
'{"schemaVersion":1,"createdAt":"2026-01-01T00:00:00","updatedAt":"2026-01-01T00:00:00","jobs":[{"id":"busy","title":"Busy Book","status":"Completed","aiRequests":[{"id":"r1","status":"Completed"}]}]}' | Set-Content -LiteralPath $database -Encoding UTF8

$record = & $studio { param($r, $d) Start-BookStudioUpdate -ProjectRoot $r -DatabasePath $d -NoRestart -Wait } $install $database
Check ($record.status -eq 'Completed' -and $record.fromVersion -eq '2026.01.01.1' -and $record.toVersion -eq '2026.01.02.1') "The update applies and records versions (status=$($record.status))."
Check ((& $studio { param($r) Get-BookStudioInstalledVersion -ProjectRoot $r } $install) -eq '2026.01.02.1') 'The installed version.json is the new release.'
$progress = & $studio { param($r) Get-BookStudioUpdateProgress -ProjectRoot $r } $install
Check ($progress.status -eq 'Completed' -and $progress.installedVersion -eq '2026.01.02.1' -and @($progress.logTail).Count -gt 0) 'Progress reports completion with a log.'
# The API serializes this record; it must never carry provider-attached strings
# that send ConvertTo-Json into an endless object graph. Run it under a timeout.
$serialize = Start-Job -ArgumentList (Join-Path $root 'lib/BookStudio.psm1'), $install { param($module, $r) Import-Module $module -Force -DisableNameChecking; $m = Get-Module BookStudio; $sw = [Diagnostics.Stopwatch]::StartNew(); $json = & $m { param($p) ConvertTo-BookStudioJson (Get-BookStudioUpdateProgress -ProjectRoot $p) } $r; [pscustomobject]@{ ms = $sw.ElapsedMilliseconds; length = $json.Length; ok = ($json -match '"logTail"') } }
if (-not (Wait-Job $serialize -Timeout 60)) { Stop-Job $serialize; Remove-Job $serialize -Force; throw 'FAIL: Serializing the update progress record did not finish within 60 seconds.' }
$serialized = Receive-Job $serialize; Remove-Job $serialize -Force
Check ($serialized.ok -and $serialized.length -lt 20000) "Progress record serializes quickly and compactly ($($serialized.ms) ms, $($serialized.length) chars)."
Check ((Get-Content -LiteralPath $database -Raw) -match 'Busy Book') 'Book data survives the update.'
Reject { & $studio { param($r) Start-BookStudioUpdate -ProjectRoot $r -NoRestart -Wait } $install } 'already up to date' 'An up-to-date install refuses to update again.'

$plain = Join-Path $fixture 'plain'
New-Item -ItemType Directory -Path (Join-Path $plain 'book-studio') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $install 'book-studio/version.json') -Destination (Join-Path $plain 'book-studio/version.json')
$plainStatus = & $studio { param($r) Get-BookStudioUpdateStatus -ProjectRoot $r } $plain
Check (-not $plainStatus.isRepository -and $plainStatus.message -match 'git clone') 'A ZIP install explains that it cannot self-update.'

# Static guards: the app wires every update control, and the launcher checks.
$index = Get-Content -LiteralPath (Join-Path $root 'book-studio/index.html') -Raw -Encoding UTF8
foreach ($id in @('updateBadge', 'checkUpdates', 'applyUpdate', 'updatesStatus', 'updatesChanges', 'updatesProgress', 'updatesLog')) { Check ($index -match ('id="' + $id + '"')) "index.html defines $id." }
$launcher = Get-Content -LiteralPath (Join-Path $root 'Start-BookStudioCompanion.ps1') -Raw -Encoding UTF8
Check ($launcher -match 'Get-BookStudioUpdateStatus') 'The launcher announces available updates.'

$fixtureResolved = [IO.Path]::GetFullPath($fixture)
$testRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'BookStudioTests')) + [IO.Path]::DirectorySeparatorChar
if (-not $fixtureResolved.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path.' }
Remove-Item -LiteralPath $fixtureResolved -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "PASS: $checks update assertions (detection, blocking, fast-forward apply, progress, data preservation, ZIP installs)."
