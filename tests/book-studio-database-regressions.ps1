$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$module=Join-Path $root 'lib/BookStudio.psm1'
Import-Module $module -Force -DisableNameChecking
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('studio-db-'+[guid]::NewGuid().ToString('N'))
$db=Initialize-BookStudioDatabase -ProjectRoot $fixture
$initial=Read-BookStudioDatabase $db
$initial.jobs=@([pscustomobject]@{id='stress';status='Completed';updatedAt=(Get-Date).ToString('s');log=@()})
Write-BookStudioDatabase $db $initial
$workers=@()
try {
    foreach($worker in 1..2){
        $workers+=Start-Job -ArgumentList $module,$db,$worker -ScriptBlock {
            param($module,$db,$worker)
            $ErrorActionPreference='Stop'
            Import-Module $module -Force -DisableNameChecking
            foreach($number in 1..50){
                Add-BookStudioLogEntry -DatabasePath $db -JobId stress -Message "$worker-$number"
            }
        }
    }
    $reads=0;$lastCount=0
    while(@($workers | Where-Object State -in @('Running','NotStarted')).Count){
        $snapshot=Read-BookStudioDatabase $db
        if ($snapshot.jobs.Count -ne 1 -or $snapshot.jobs[0].log.Count -lt $lastCount) {throw 'Concurrent read lost jobs or progress.'}
        $lastCount=$snapshot.jobs[0].log.Count;$reads++
        Start-Sleep -Milliseconds 10
    }
    $workers | Receive-Job -ErrorAction Stop
    $final=Read-BookStudioDatabase $db
    if($final.jobs[0].log.Count -ne 100 -or ($final.jobs[0].log.message | Select-Object -Unique).Count -ne 100){throw 'Concurrent writers lost updates.'}
    if(-not (Test-Path -LiteralPath "$db.bak")){throw 'Atomic write did not preserve the previous snapshot.'}
    # A persistent, closed lock file must not act as a stale crash lock.
    $null=Initialize-BookStudioDatabase -ProjectRoot $fixture
    if((Read-BookStudioDatabase $db).jobs[0].log.Count -ne 100){throw 'Reinitializing erased history.'}
    $bad=Join-Path $fixture 'corrupt.json';' ' | Set-Content -LiteralPath $bad
    $rejected=$false;try{Read-BookStudioDatabase $bad | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Empty database silently became empty job history.'}
    "PASS: 100 concurrent updates, $reads complete live snapshots, backup preservation, reusable crash lock, and fail-closed corrupt database."
} finally {
    $workers | Stop-Job -ErrorAction SilentlyContinue
    $workers | Remove-Job -Force -ErrorAction SilentlyContinue
}
