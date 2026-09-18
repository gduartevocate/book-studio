$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('BookStudioTests/recovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
$studio = Get-Module BookStudio
. (Join-Path $root 'lib/EbookCodexSandbox.ps1')
. (Join-Path $root 'lib/EbookPublicationTemplate.ps1')
$checks = 0
function Check([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message }; $script:checks++ }
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) "Unexpected failure (expected $Pattern): $_ $($_.ScriptStackTrace)"; return }
    throw "Expected rejection matching: $Pattern"
}

# Load the real functions without starting a generator or touching real books.
foreach ($file in @('book-studio-runner.ps1', 'ebook-generator.ps1')) {
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$parseErrors)
    Check (-not $parseErrors) "PowerShell syntax errors in $file"
    foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
}

$logPath = Join-Path $fixture 'generator.log'
$errorPath = Join-Path $fixture 'generator.err.log'
$qaError = 'Release artifact gate failed during repair. publication_template: Chapter 1: the Opening Scenario must introduce a named **Business Case:**.'
function Write-Failure([string]$Detail) {
    "[BOOKSTUDIO-ERROR] 2026-09-17T18:03:00 | Generator failed | | | $Detail" | Set-Content -LiteralPath $logPath -Encoding UTF8
    Get-RunnerGeneratorFailure -LogPath $logPath -ErrorLogPath $errorPath -ExitCode '1'
}
$failure = Write-Failure $qaError
Check ($failure.kind -eq 'qa' -and $failure.message -eq $qaError) 'The original publication error was replaced with a generic Codex failure.'
# A named content check must not be classified from words in a chapter title.
$failure = Write-Failure ($qaError + ' Chapter 2: Authentication and timeout handling.')
Check ($failure.kind -eq 'qa') 'QA details were incorrectly classified as an authentication/timeout error.'
foreach ($sample in @(
    @('Codex drafting failed: Your refresh token was already used.', 'authentication'),
    @('Codex drafting failed: 429 rate limit', 'quota'),
    @('Codex drafting timed out after 3600 seconds.', 'timeout'),
    @('Codex drafting failed: stream disconnected before completion', 'network'),
    @('Access to the export path is denied.', 'execution'),
    @('Codex drafting stopped without a usable final response for this run.', 'execution')
)) {
    $failure = Write-Failure $sample[0]
    Check ($failure.kind -eq $sample[1] -and $failure.message -eq $sample[0]) "Wrong failure classification or lost detail: $($sample[0])"
}
'' | Set-Content -LiteralPath $logPath
'The disk is full.' | Set-Content -LiteralPath $errorPath
$failure = Get-RunnerGeneratorFailure -LogPath $logPath -ErrorLogPath $errorPath -ExitCode '1'
Check ($failure.kind -eq 'execution' -and $failure.message -eq 'The disk is full.') 'Unstructured stderr was lost.'
'' | Set-Content -LiteralPath $errorPath
$failure = Get-RunnerGeneratorFailure -LogPath $logPath -ErrorLogPath $errorPath -ExitCode '17'
Check ($failure.message -match '17' -and $failure.message -notmatch 'Codex') 'Unknown generator failure was attributed to Codex.'

$output = Join-Path $fixture 'package'
New-Item -ItemType Directory -Path $output | Out-Null
$startedAt = (Get-Date).AddMinutes(-1)
$manuscript = Join-Path $output 'QA1000 - E-Book.md'
function Reset-DraftEvidence {
    '0' | Set-Content -LiteralPath (Join-Path $output 'codex-drafting-exit-code.txt')
    'Updated both chapters.' | Set-Content -LiteralPath (Join-Path $output 'codex-drafting-response.md')
    '- Exit code: 0' | Set-Content -LiteralPath (Join-Path $output 'codex-drafting-report.md')
    'sandbox: workspace-write' | Set-Content -LiteralPath (Join-Path $output 'codex-drafting-error.log')
    '{"chapters":[{"number":1},{"number":2}]}' | Set-Content -LiteralPath (Join-Path $output 'ebook-plan.json')
    "# Chapter 1: Records`nText.`n# Chapter 2: Workflow`nText." | Set-Content -LiteralPath $manuscript
}
Reset-DraftEvidence
Check (Test-RunnerCodexDraftComplete -OutputFolder $output -StartedAt $startedAt) 'Current completed draft was rejected.'
Check ((Get-RunnerQaRepairDecision -FailureKind 'qa' -OutputFolder $output -StartedAt $startedAt).allowed) 'QA-only failure should be repairable.'
foreach ($kind in @('execution','authentication','quota','sandbox','timeout','network','configuration')) {
    Check (-not (Get-RunnerQaRepairDecision -FailureKind $kind -OutputFolder $output -StartedAt $startedAt).allowed) "Automatic repair allowed for $kind"
}
foreach ($name in @('codex-drafting-exit-code.txt','codex-drafting-response.md','codex-drafting-report.md','codex-drafting-error.log','QA1000 - E-Book.md')) {
    Reset-DraftEvidence
    (Get-Item -LiteralPath (Join-Path $output $name)).LastWriteTime = $startedAt.AddDays(-1)
    Check (-not (Test-RunnerCodexDraftComplete -OutputFolder $output -StartedAt $startedAt)) "Stale $name accepted as evidence for this run."
}
foreach ($case in @(
    @('codex-drafting-response.md', '   '),
    @('codex-drafting-exit-code.txt', ''),
    @('codex-drafting-exit-code.txt', '1'),
    @('codex-drafting-report.md', ''),
    @('codex-drafting-error.log', 'sandbox: read-only'),
    @('QA1000 - E-Book.md', '# Chapter 1: Only half a book'),
    @('ebook-plan.json', '{bad json')
)) {
    Reset-DraftEvidence
    $case[1] | Set-Content -LiteralPath (Join-Path $output $case[0])
    Check (-not (Get-RunnerQaRepairDecision -FailureKind 'qa' -OutputFolder $output -StartedAt $startedAt).allowed) "Invalid evidence accepted: $($case[0])"
}

# Exercise the actual repair entry point. Only external effects are replaced.
$ProjectRoot = $fixture; $DatabasePath = Join-Path $fixture 'unused.json'; $JobId = 'fixture'
$script:repairStarts = 0; $script:rebuilds = 0; $script:repairFailed = $false
$script:events = [Collections.Generic.List[string]]::new()
function Add-BookStudioLogEntry { param($DatabasePath,$JobId,$Message) $script:events.Add($Message) }
function Set-BookStudioJobProgress { param($DatabasePath,$JobId,$Phase,$Detail,$Percent,[switch]$AddLog) }
function Test-RunnerAutoQaRepairEnabled { return $true }
function Resolve-BookStudioCodexCommand { param($ProjectRoot) [pscustomobject]@{ Source = 'fixture.exe' } }
function Get-BookStudioJob { param($DatabasePath,$JobId) [pscustomobject]@{ courseCode='QA1000'; title='Fixture' } }
function Get-RunnerTechnicalStatus { param($OutputFolder) if ($script:rebuilds) { 'PASS' } else { 'FAIL' } }
function Get-RunnerQaStatus { param($OutputFolder) 'PASS' }
function New-BookStudioAiRequest {
    param($DatabasePath,$JobId,$Instruction,$Scope,$ChapterId,[switch]$AllowEdits,[switch]$IncludeHistory,[switch]$KeepJobActive,$ActiveProcessId,$RequestKind,$ProjectRoot)
    $script:repairStarts++
    Check ($Instruction.Contains($qaError)) 'Repair did not receive the original failure.'
    Check ($Instruction.Contains("'### Opening Scenario'") -and $Instruction.Contains("'**Business Case:** '")) 'Repair prompt is missing the exact publication format.'
    Check (-not $IncludeHistory -and $RequestKind -eq 'QaRepair') 'Automatic repair inherited unrelated chat or lost its request type.'
    [pscustomobject]@{ id='repair-fixture'; errorPath='fixture-repair-error.log' }
}
function Wait-RunnerAiRequest { param($RequestId) if ($script:repairFailed) { [pscustomobject]@{status='Failed';statusDetail='stream disconnected'} } else { [pscustomobject]@{status='Completed'} } }
function Set-RunnerAiRequestPostProcess { param($RequestId,$Status) $script:events.Add($Status) }
function Invoke-BookStudioPackageRebuild { param($DatabasePath,$JobId,$ProjectRoot) $script:rebuilds++; [pscustomobject]@{repair=@{exportValidationStatus='PASS'};audit=@{status='PASS'}} }
function Refresh-BookStudioJobArtifacts { param($DatabasePath,$JobId,$ProjectRoot) }
Reset-DraftEvidence
$null = Invoke-RunnerAutomaticQaRepair -OutputFolder $output -FailureMessage $qaError -FailureKind 'execution' -StartedAt $startedAt
Check ($script:repairStarts -eq 0) 'An execution failure launched automatic repair.'
' ' | Set-Content -LiteralPath (Join-Path $output 'codex-drafting-response.md')
$null = Invoke-RunnerAutomaticQaRepair -OutputFolder $output -FailureMessage $qaError -FailureKind 'qa' -StartedAt $startedAt
Check ($script:repairStarts -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $fixture '.bookstudio/codex-connection.json'))) 'Missing final response launched repair or falsely refreshed connection proof.'
Reset-DraftEvidence
Check (Invoke-RunnerAutomaticQaRepair -OutputFolder $output -FailureMessage $qaError -FailureKind 'qa' -StartedAt $startedAt) 'A completed draft with QA findings could not be repaired.'
Check ($script:repairStarts -eq 1 -and $script:rebuilds -eq 1) 'Repair must launch once and rebuild once.'
$script:rebuilds=0; $script:repairFailed=$true
Reject { Invoke-RunnerAutomaticQaRepair -OutputFolder $output -FailureMessage $qaError -FailureKind 'qa' -StartedAt $startedAt } 'stream disconnected.*fixture-repair-error.log'
Check ($script:rebuilds -eq 0 -and ($script:events -join ' ') -match 'rebuild skipped') 'A failed repair proceeded to rebuilding.'

# A fake process exercises real drafting completion checks without invoking AI.
$SourceMode = 'UploadedOnly'
$script:draftScenario = 'success'
function Start-Process {
    param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
    Add-Content -LiteralPath $manuscript -Value 'Revised learner-facing explanation.'
    'sandbox: workspace-write' | Set-Content -LiteralPath (Join-Path $output 'codex-drafting-error.log')
    if ($script:draftScenario -ne 'staleExit') { '0' | Set-Content -LiteralPath (Join-Path $output 'codex-drafting-exit-code.txt') }
    if ($script:draftScenario -eq 'blankExit') { Set-Content -LiteralPath (Join-Path $output 'codex-drafting-exit-code.txt') -Value '' -NoNewline }
    if ($script:draftScenario -ne 'staleResponse') { 'Draft updated.' | Set-Content -LiteralPath (Join-Path $output 'codex-drafting-response.md') }
    if ($script:draftScenario -eq 'emptyResponse') { '   ' | Set-Content -LiteralPath (Join-Path $output 'codex-drafting-response.md') }
    [pscustomobject]@{ HasExited=$true; ExitCode=0 }
}
foreach ($scenario in @('staleExit','blankExit','staleResponse','emptyResponse','success')) {
    Reset-DraftEvidence
    foreach ($name in @('codex-drafting-exit-code.txt','codex-drafting-response.md','codex-drafting-report.md')) {
        (Get-Item -LiteralPath (Join-Path $output $name)).LastWriteTime = (Get-Date).AddDays(-1)
    }
    $script:draftScenario=$scenario
    $invoke = { Invoke-EbookCodexDraftingPass -CodexCommand 'fixture.exe' -Course ([pscustomobject]@{courseCode='QA1000';courseName='Fixture'}) -Result ([pscustomobject]@{outputFolder=$output;markdownPath=$manuscript}) }
    if ($scenario -eq 'success') {
        $result = & $invoke
        Check ($result.exitCode -eq 0 -and (Test-RunnerCodexDraftComplete -OutputFolder $output -StartedAt $startedAt)) 'Valid drafting result was rejected.'
    } else {
        $pattern = if ($scenario -match 'Exit') { 'valid exit result' } else { 'usable final response' }
        Reject $invoke $pattern
        Check ((Get-Item -LiteralPath (Join-Path $output 'codex-drafting-report.md')).LastWriteTime -lt $startedAt) 'Interrupted drafting wrote a successful report.'
        Check ((Get-Content -LiteralPath $manuscript -Raw) -match 'Revised learner-facing') 'Partial manuscript edits were lost.'
    }
}

# The stricter repair entry requirements must not relax publication QA.
$bad = "# Chapter 1: Fixture`n### Opening Scenario`n**Business Case**: Maya manages clinic records."
$good = $bad.Replace('**Business Case**:', '**Business Case:**')
Check ((Test-EbookPublicationTemplate -Markdown $bad).detail -match 'must introduce a named') 'Incorrect Business Case label unexpectedly passed.'
Check ((Test-EbookPublicationTemplate -Markdown $good).detail -notmatch 'must introduce a named') 'The documented label format fails the actual validator.'

# Read actual request completion through the real database/API implementation.
# Each directory is unique, so no old response can satisfy a new request.
$requestDb = Initialize-BookStudioDatabase -ProjectRoot (Join-Path $fixture 'requests')
foreach ($case in @(
    @('blank','0','   ','sandbox: workspace-write','Failed'),
    @('missingExit',$null,'A partial response.','sandbox: workspace-write','Failed'),
    @('emptyExit','','A partial response.','sandbox: workspace-write','Failed'),
    @('nonzero','7','A partial response.','sandbox: workspace-write','Failed'),
    @('readOnly','0','I cannot edit.','sandbox: read-only','Failed'),
    @('network','1','','ERROR: stream disconnected before completion','Failed'),
    @('complete','0','Updated the draft.','sandbox: workspace-write','Completed')
)) {
    $folder = Join-Path $fixture $case[0]
    New-Item -ItemType Directory -Path $folder | Out-Null
    $responseFile=Join-Path $folder 'response.md'; $exitFile=Join-Path $folder 'exit.txt'; $requestLog=Join-Path $folder 'error.log'
    Set-Content -LiteralPath $responseFile -Value $case[2]
    Set-Content -LiteralPath $requestLog -Value $case[3]
    if ($null -ne $case[1]) { Set-Content -LiteralPath $exitFile -Value $case[1] -NoNewline }
    $request = [pscustomobject]@{id='test-request';status='Running';responsePath=$responseFile;errorPath=$requestLog;exitCodePath=$exitFile;exitCode=$null;processId=$null;createdAt=(Get-Date).ToString('s');completedAt='';allowEdits=$true}
    $database = Read-BookStudioDatabase $requestDb
    $database.jobs = @([pscustomobject]@{id='request-job';status='Completed';updatedAt=(Get-Date).ToString('s');aiRequests=@($request)})
    Write-BookStudioDatabase -DatabasePath $requestDb -Database $database
    $result = @(Get-BookStudioAiRequests -DatabasePath $requestDb -JobId 'request-job')[0]
    Check ($result.status -eq $case[4]) "Wrong request outcome: $($case[0])"
    if ($case[4] -eq 'Failed') { Check (-not $result.postProcessedAt) "Failed request queued a rebuild: $($case[0])" }
    if ($case[0] -eq 'nonzero') { Check ($result.statusDetail -match 'returned a response.*7') 'A captured response was falsely described as missing.' }
    if ($case[0] -eq 'network') { Check ($result.failureKind -eq 'network') 'Actual request lost its network failure classification.' }
    if ($case[0] -eq 'complete') { Check ($result.postProcessStatus -match 'rebuild queued') 'A valid completed edit did not queue exports.' }
}
Write-Output "PASS: $checks recovery assertions; no live Codex calls or production books changed. Fixture: $fixture"
