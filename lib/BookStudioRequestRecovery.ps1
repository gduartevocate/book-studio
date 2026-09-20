function Get-BookStudioAiRequestRunState {
    param([object]$Request)
    $exitCode = 0
    if ($Request.exitCodePath -and (Test-Path -LiteralPath $Request.exitCodePath -PathType Leaf)) {
        $text = [string](Get-Content -LiteralPath $Request.exitCodePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($text) -and [int]::TryParse($text.Trim(), [ref]$exitCode)) {
            return [pscustomobject]@{running=$false;hasExitCode=$true;exitCode=$exitCode;reason='The Codex runner recorded its exit code.'}
        }
    }
    if ($Request.processId) {
        $process = Get-Process -Id ([int]$Request.processId) -ErrorAction SilentlyContinue
        if ($process) {
            $sameProcess = $true
            try {
                if ($Request.processStartedAt) {
                    $sameProcess = $process.StartTime.ToUniversalTime() -eq ([datetime]$Request.processStartedAt).ToUniversalTime()
                } elseif ($Request.createdAt) {
                    # Legacy records have second-precision creation times. A much
                    # newer process with the same PID is not the original runner.
                    $sameProcess = $process.StartTime.ToUniversalTime() -le ([datetime]$Request.createdAt).ToUniversalTime().AddSeconds(5)
                }
            } catch { $sameProcess = $true } # Unknown identity must not clear active work.
            if ($sameProcess) { return [pscustomobject]@{running=$true;hasExitCode=$false;exitCode=$null;reason='The Codex runner is still active.'} }
        }
    }
    [pscustomobject]@{running=$false;hasExitCode=$false;exitCode=$null;reason='The Codex runner is no longer active and no valid exit code was recorded.'}
}

function Stop-BookStudioAiRequest {
    # A Codex run that hangs holds its book hostage: the book cannot be deleted
    # and every action reports Codex is still working. Let the designer end it.
    # Only the process this request recorded is stopped, never anything else.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$RequestId
    )

    $stopped = @{ value = $false; found = $false }
    Invoke-BookStudioDatabaseLock -DatabasePath $DatabasePath -ScriptBlock {
        $db = Read-BookStudioDatabase -DatabasePath $DatabasePath
        $job = @($db.jobs | Where-Object { $_.id -eq $JobId } | Select-Object -First 1)[0]
        if (-not $job) { throw "Book Studio job not found: $JobId" }
        $request = @($job.aiRequests | Where-Object { $_.id -eq $RequestId } | Select-Object -First 1)[0]
        if (-not $request) { throw "Codex request not found: $RequestId" }
        $stopped.found = $true
        if ($request.status -ne 'Running') { return }
        $state = Get-BookStudioAiRequestRunState $request
        if ($state.running -and $request.processId) {
            try { Stop-Process -Id ([int]$request.processId) -Force -ErrorAction Stop; $stopped.value = $true } catch { }
        }
        Add-OrSet-BookStudioNoteProperty $request 'status' 'Failed'
        Add-OrSet-BookStudioNoteProperty $request 'completedAt' (Get-Date).ToString('s')
        Add-OrSet-BookStudioNoteProperty $request 'statusDetail' 'Stopped by the instructional designer. Any edits Codex had already saved are still on disk; review them before retrying.'
        Add-OrSet-BookStudioNoteProperty $request 'failureKind' 'cancelled'
        if ($request.allowEdits -and -not $request.postProcessedAt) {
            Add-OrSet-BookStudioNoteProperty $request 'postProcessStatus' 'Stopped before a package rebuild. Review any saved edits and use Rebuild Package.'
            Add-OrSet-BookStudioNoteProperty $request 'postProcessedAt' (Get-Date).ToString('s')
        }
        Add-OrSet-BookStudioNoteProperty $job 'log' (@($job.log | Where-Object { $_ }) + [pscustomobject]@{ at = (Get-Date).ToString('s'); message = "Stopped Codex request $RequestId at the designer's request." })
        Add-OrSet-BookStudioNoteProperty $job 'updatedAt' (Get-Date).ToString('s')
        Write-BookStudioDatabase -DatabasePath $DatabasePath -Database $db
    }
    return [pscustomobject]@{ requestId = $RequestId; stoppedProcess = [bool]$stopped.value; found = [bool]$stopped.found }
}

function Repair-BookStudioStaleAiRequests {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath)
    $result = @{count=0}
    # Reconcile every book and archived conversation, not only the open chat.
    # This path never invokes Codex, kills a process, or rebuilds a manuscript.
    Invoke-BookStudioDatabaseLock -DatabasePath $DatabasePath -ScriptBlock {
        $db = Read-BookStudioDatabase -DatabasePath $DatabasePath
        foreach ($job in @($db.jobs)) {
            foreach ($request in @($job.aiRequests | Where-Object status -eq 'Running')) {
                $state = Get-BookStudioAiRequestRunState $request
                if ($state.running) { continue }
                $hasResponse = $false
                if ($request.responsePath -and (Test-Path -LiteralPath $request.responsePath -PathType Leaf)) {
                    $hasResponse = -not [string]::IsNullOrWhiteSpace([string](Get-Content -LiteralPath $request.responsePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue))
                }
                $status = if ($state.hasExitCode -and $state.exitCode -eq 0 -and $hasResponse) { 'Completed' } else { 'Failed' }
                $detail = if ($status -eq 'Completed') { 'Codex finished; recovered the saved completion result.' } else { 'Codex stopped without a confirmed successful response. Review its logs and any partial edits before retrying.' }
                Add-OrSet-BookStudioNoteProperty $request 'status' $status
                Add-OrSet-BookStudioNoteProperty $request 'completedAt' (Get-Date).ToString('s')
                Add-OrSet-BookStudioNoteProperty $request 'statusDetail' $detail
                Add-OrSet-BookStudioNoteProperty $request 'recoveryDetail' $state.reason
                if ($state.hasExitCode) { Add-OrSet-BookStudioNoteProperty $request 'exitCode' $state.exitCode }
                if ($request.allowEdits -and -not $request.postProcessedAt) {
                    Add-OrSet-BookStudioNoteProperty $request 'postProcessStatus' 'Recovered after interruption. Review any saved edits and use Rebuild Package; no automatic rebuild was started.'
                    Add-OrSet-BookStudioNoteProperty $request 'postProcessedAt' (Get-Date).ToString('s')
                }
                Add-OrSet-BookStudioNoteProperty $job 'log' (@($job.log | Where-Object { $_ }) + [pscustomobject]@{at=(Get-Date).ToString('s');message="Recovered Codex request $($request.id): $status. $detail"})
                Add-OrSet-BookStudioNoteProperty $job 'updatedAt' (Get-Date).ToString('s')
                $result.count++
            }
        }
        if ($result.count) { Write-BookStudioDatabase -DatabasePath $DatabasePath -Database $db }
    }
    return $result.count
}
