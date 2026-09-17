function Get-BookStudioChatSessionId {
    param([object]$Job)
    if ($Job.chatSessionId) { return [string]$Job.chatSessionId }
    return 'legacy'
}

function Get-BookStudioCurrentChatRequests {
    param([object]$Job, [switch]$IncludeArchived)
    $sessionId=Get-BookStudioChatSessionId $Job
    return @($Job.aiRequests | Where-Object {
        $_ -and ($IncludeArchived -or (-not $_.chatArchivedAt -and
            $(if ($_.chatSessionId) { $_.chatSessionId -eq $sessionId } else { $sessionId -eq 'legacy' })))
    })
}

function Reset-BookStudioChat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePath, [Parameter(Mandatory)][string]$JobId, [string]$ExpectedSessionId)
    $newSessionId=[guid]::NewGuid().ToString('N')
    $now=(Get-Date).ToString('o')
    # No Codex call, file deletion, book rebuild, or connection requirement.
    # History stays recoverable for diagnostics but is excluded from new prompts.
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($job)
        if ($ExpectedSessionId -and $ExpectedSessionId -ne (Get-BookStudioChatSessionId $job)) { throw 'This conversation changed in another window. Refresh chat before clearing it.' }
        if (@($job.aiRequests | Where-Object { $_.status -in @('Running','Queued') }).Count) {
            throw 'A Codex request is still running. Wait for it to finish before starting a new chat.'
        }
        foreach ($request in @(Get-BookStudioCurrentChatRequests $job)) {
            Add-OrSet-BookStudioNoteProperty $request 'chatArchivedAt' $now
        }
        Add-OrSet-BookStudioNoteProperty $job 'chatSessionId' $newSessionId
        Add-OrSet-BookStudioNoteProperty $job 'chatStartedAt' $now
    } | Out-Null
    [pscustomobject]@{sessionId=$newSessionId;requests=@();message='New chat started. Previous conversation context is cleared; the book and diagnostic logs are unchanged.'}
}
