$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('studio-delete-' + [guid]::NewGuid().ToString('N'))
$dbPath = Initialize-BookStudioDatabase -ProjectRoot $fixture
$storage = Split-Path $dbPath -Parent
$script:checks = 0
function Check([bool]$ok, [string]$message) { if (-not $ok) { throw $message }; $script:checks++ }
function SaveJobs($jobs) {
    $db = Read-BookStudioDatabase $dbPath
    $db.jobs = @($jobs)
    Write-BookStudioDatabase $dbPath $db
}
function RejectDelete([string]$id, [string]$pattern) {
    $caught = $false
    try { Remove-BookStudioJob -DatabasePath $dbPath -JobId $id -DeleteFiles | Out-Null }
    catch { $caught = $true; Check ($_.Exception.Message -match $pattern) "Unexpected rejection: $_" }
    Check $caught "Unsafe deletion accepted: $id"
}
function CreateFixtureFile([string]$relative) {
    $path = Join-Path $storage $relative
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    'disposable test content' | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}
$neighbor = CreateFixtureFile 'outputs/neighbor/keep.txt'
foreach ($stage in @('preview','failed','archived','completed')) {
    $id = "delete-$stage"
    $output = CreateFixtureFile "outputs/$id/book.txt"
    $upload = CreateFixtureFile "uploads/$id/spec.txt"
    $log = CreateFixtureFile "logs/$id.log"
    $errorLog = CreateFixtureFile "logs/$id.err.log"
    # A corrupt/shared outputRoot must never widen the deletion scope.
    SaveJobs @(@{id=$id;status=$(if($stage -eq 'failed'){'Failed'}else{'Completed'});workflowStage='format-review';lifecycleStatus=$stage;outputRoot=(Join-Path $storage 'outputs')}, @{id='neighbor';status='Completed';outputFolder=(Split-Path $neighbor -Parent)})
    $result = Remove-BookStudioJob -DatabasePath $dbPath -JobId $id -DeleteFiles
    Check ($result.deleted -and $result.removedPaths.Count -eq 4) "$stage deletion failed"
    Check (-not (Test-Path $output) -and -not (Test-Path $upload) -and -not (Test-Path $log) -and -not (Test-Path $errorLog)) 'Managed files were left behind'
    Check ((Test-Path $neighbor) -and @((Read-BookStudioDatabase $dbPath).jobs).Count -eq 1) 'Neighbor was damaged'
}
$busyFile = CreateFixtureFile 'outputs/busy/keep.txt'
foreach ($state in @(@{status='Running'}, @{status='Queued'}, @{status='Completed';aiRequests=@(@{status='Running'})}, @{status='Failed';aiRequests=@(@{status='Queued'})})) {
    $state.id = 'busy'
    SaveJobs @($state)
    RejectDelete 'busy' 'Wait for generation'
    Check ((Test-Path $busyFile) -and (Get-BookStudioJob $dbPath busy)) 'Busy book was changed'
}
RejectDelete '..' 'Invalid book ID'
RejectDelete '../outputs' 'Invalid book ID'
SaveJobs @(@{id='busy';status='Completed'}, @{id='shared';status='Completed';outputFolder=(Split-Path $busyFile -Parent)})
RejectDelete 'busy' 'Another book'
Check (Test-Path $busyFile) 'Shared output was removed'
$external = Join-Path $fixture 'original.txt'
'original outside managed storage' | Set-Content -LiteralPath $external
SaveJobs @(@{id='imported';status='Completed';outputRoot=$fixture;outputFolder=$fixture;specPath=$external})
$null = Remove-BookStudioJob -DatabasePath $dbPath -JobId imported -DeleteFiles
Check (Test-Path $external) 'External original was deleted'
New-Item -ItemType Junction -Path (Join-Path $storage 'outputs/linked') -Target $fixture | Out-Null
SaveJobs @(@{id='linked';status='Completed'})
RejectDelete 'linked' 'linked folders'
Check (Test-Path $external) 'Deletion followed a junction'
SaveJobs @(@{id='busy';status='Completed'})
$null = Remove-BookStudioJob -DatabasePath $dbPath -JobId busy
Check ((Test-Path $busyFile) -and -not (Get-BookStudioJob $dbPath busy)) 'Record-only deletion removed files'
SaveJobs @(@{id='busy';status='Completed'})
$handle = [IO.File]::Open($busyFile, 'Open', 'Read', 'None')
try { RejectDelete 'busy' 'being used|access|process'; Check ($null -ne (Get-BookStudioJob $dbPath busy)) 'Cleanup failure hid the book' }
finally { $handle.Dispose() }
RejectDelete 'missing' 'not found'
Write-Output "PASS: $script:checks deletion checks; only disposable fixtures touched: $fixture"
