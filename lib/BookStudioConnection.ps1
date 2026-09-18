. (Join-Path $PSScriptRoot 'EbookCodexSandbox.ps1')

function Get-BookStudioCodexFailure {
    param([string]$Text,[int]$ExitCode=1,[string]$ExpectedSandbox='')
    $kind='execution';$message='Codex stopped without a usable final response. Open the full log for details.'
    $sandboxProblem=Get-EbookCodexSandboxFailure -Text $Text -ExpectedSandbox $ExpectedSandbox
    if($sandboxProblem){
        $kind='sandbox';$message=$sandboxProblem
    }elseif($Text -match '(?i)spend[ -]cap|spending limit|budget.*exceeded'){
        $kind='quota';$message='Codex reached the workspace spending limit. Ask a workspace owner to increase the spend cap, then Test connection. The repair was not completed; review any partial edits before retrying.'
    }elseif($Text -match '(?i)refresh.token|access token.*refresh|not logged|not signed|unauthorized|authentication|401\b'){
        $kind='authentication';$message='Codex sign-in needs attention. Sign out and sign in again using the executable and profile shown below, then Test connection. Your book was not automatically retried.'
    }elseif($Text -match '(?i)usage limit|rate.limit|quota|429\b'){
        $kind='quota';$message='Codex reported a usage or rate limit. Check the full log for the reset time. Do not repeat an edit request until you have reviewed its result.'
    }elseif($Text -match '(?i)timed? out|timeout'){
        $kind='timeout';$message='The Codex operation timed out. Check the full log and any partial edits, then Test connection before retrying.'
    }elseif($Text -match '(?i)stream disconnected|connection reset|connection closed before|error sending request|dns.*failed|failed to connect'){
        $kind='network';$message='The Codex connection was interrupted. Check the full log and any partial edits, then Test connection before retrying.'
    }elseif($Text -match '(?i)cannot find path|not found|no such file'){
        $kind='configuration';$message='Codex could not find a required executable or file. Check the configured path and full log.'
    }
    [pscustomobject]@{kind=$kind;message=$message;exitCode=$ExitCode}
}

function Get-BookStudioCodexProfile {
    $profile=[Environment]::GetEnvironmentVariable('CODEX_HOME','Process')
    if([string]::IsNullOrWhiteSpace($profile)){$profile=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'}
    [IO.Path]::GetFullPath($profile)
}

function Get-BookStudioConnectionIdentity {
    param([string]$CommandPath)
    $profile=Get-BookStudioCodexProfile
    $auth=Join-Path $profile 'auth.json'
    # Metadata only. Never read, return, copy, or log credential contents.
    $stamp=if(Test-Path -LiteralPath $auth){(Get-Item -LiteralPath $auth).LastWriteTimeUtc.Ticks}else{0}
    "$CommandPath|$profile|$stamp"
}

function Set-BookStudioConnectionResult {
    param([string]$ProjectRoot,[object]$Result)
    $folder=Join-Path $ProjectRoot '.bookstudio'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $folder 'codex-connection.json') -Encoding UTF8
}

function Get-BookStudioConnectionResult {
    param([string]$ProjectRoot,[string]$CommandPath)
    $path=Join-Path $ProjectRoot '.bookstudio/codex-connection.json'
    try{
        $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        if($record.identity -ne (Get-BookStudioConnectionIdentity $CommandPath)){return $null}
        if($record.status -eq 'PASS' -and [datetime]$record.checkedAt -lt (Get-Date).AddMinutes(-10)){return $null}
        return $record
    }catch{return $null}
}

function Test-BookStudioCodexConnection {
    param([Parameter(Mandatory)][string]$ProjectRoot,[ValidateRange(1,45)][int]$TimeoutSeconds=25)
    $command=Resolve-BookStudioCodexCommand -ProjectRoot $ProjectRoot
    if(-not $command){throw 'Codex is not installed or the configured executable cannot be found.'}
    if([IO.Path]::GetExtension($command.Source) -ne '.exe'){throw "Book Studio found the Codex shell wrapper $($command.Source), but it needs the native codex.exe and could not find one beside it. If Codex came from npm, look for codex.exe under ...\npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-*\vendor\*\bin\ and paste that full path into the Codex executable path box above, then Save path. Reinstalling Codex also restores it."}
    $folder=Join-Path $ProjectRoot ('.bookstudio/connection-checks/'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $response=Join-Path $folder 'response.txt';$errorPath=Join-Path $folder 'error.log';$stdout=Join-Path $folder 'stdout.log'
    # Probe with the same write sandbox generation and edits use, so a
    # downgraded (read-only) Codex is caught here rather than an hour into a book.
    $args=@('exec','--ephemeral','--skip-git-repo-check','--sandbox','workspace-write')+(Get-EbookCodexSandboxArgumentList)+@('-c','web_search=\"disabled\"','-C',('"'+$folder+'"'),'--output-last-message',('"'+$response+'"'),'"Reply exactly BOOKSTUDIO_CONNECTION_OK. Do not read, create, or change files and do not use tools."')
    $process=Start-Process -FilePath $command.Source -ArgumentList $args -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $errorPath
    # Retain the native handle before it exits; otherwise Windows PowerShell can
    # lose ExitCode for fast processes and falsely reject a captured response.
    $processHandle=$process.Handle
    $timedOut=-not $process.WaitForExit($TimeoutSeconds*1000)
    if($timedOut){$process.Kill();$process.WaitForExit()}
    $log=Get-Content -LiteralPath $errorPath -Raw -ErrorAction SilentlyContinue
    if($timedOut){$failure=Get-BookStudioCodexFailure 'Connection test timed out.'}
    else{$process.Refresh();$failure=Get-BookStudioCodexFailure -Text $log -ExitCode $process.ExitCode -ExpectedSandbox 'workspace-write'}
    $answer=if(Test-Path -LiteralPath $response){(Get-Content -LiteralPath $response -Raw -Encoding UTF8).Trim()}else{''}
    $sandboxMode=Get-EbookCodexSandboxMode -Text $log
    $responded=-not $timedOut -and $process.ExitCode -eq 0 -and $answer -eq 'BOOKSTUDIO_CONNECTION_OK'
    $pass=$responded -and $sandboxMode -eq 'workspace-write'
    if($responded -and -not $pass -and $failure.kind -ne 'sandbox'){
        $failure=[pscustomobject]@{kind='sandbox';message="Codex answered, but it did not confirm file-editing access (reported sandbox: '$sandboxMode'). Book Studio needs workspace-write to draft and repair books. Update Codex CLI with 'codex update' and test again.";exitCode=$process.ExitCode}
    }
    $result=[pscustomobject]@{status=$(if($pass){'PASS'}else{'FAIL'});checkedAt=(Get-Date).ToString('o');identity=(Get-BookStudioConnectionIdentity $command.Source);kind=$(if($pass){''}else{$failure.kind});message=$(if($pass){'Connection tested: a real Codex final response was received and file editing (workspace-write, non-admin sandbox) is available.'}else{$failure.message});exitCode=$process.ExitCode;logPath=$errorPath;sandbox=$sandboxMode}
    Set-BookStudioConnectionResult -ProjectRoot $ProjectRoot -Result $result
    Get-BookStudioCodexStatus -ProjectRoot $ProjectRoot
}
