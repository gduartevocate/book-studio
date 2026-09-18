function Assert-BookStudioProductionIdle {
    param([object]$Job)
    if (-not $Job) { throw 'Book not found.' }
    if (($Job.status -in @('Running','Queued') -and $Job.runnerProcessId) -or @($Job.aiRequests | Where-Object status -in @('Queued','Running')).Count) { throw 'Wait for this book to finish its current work before changing production settings.' }
}

function Get-BookStudioProductionPreferences {
    param([object]$Job)
    if (-not $Job) { throw 'Book not found.' }
    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
    $readings=@($Job.options.requiredReadings | Where-Object { $_ })
    if (-not $Job.options.PSObject.Properties['requiredReadings'] -and $Job.specPath -and (Test-Path -LiteralPath $Job.specPath)) {
        $readings=@(ConvertFrom-EbookReadingList -Text (Get-EbookBlueprintReadingText $Job.specPath) -Origin 'Blueprint')
    }
    $report=$null
    if ($Job.outputFolder -and (Test-Path -LiteralPath (Join-Path $Job.outputFolder 'required-source-report.json'))) {
        $report=Get-Content -LiteralPath (Join-Path $Job.outputFolder 'required-source-report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    [pscustomobject]@{sourceMode=$Job.options.sourceMode;requiredSources=(ConvertTo-EbookReadingListText $readings);readings=$readings;sourceReport=$report;imageSettings=$(if($Job.options.imageSettings){$Job.options.imageSettings}else{[pscustomobject]@{context='Generic';instructions=''}})}
}

function Set-BookStudioProductionPreferences {
    param([string]$DatabasePath,[string]$JobId,[object]$Request)
    $job=Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    Assert-BookStudioProductionIdle $job
    if ($Request.sourceMode -notin @('Assigned','UploadedOnly','Discovery')) { throw 'Choose a supported source policy.' }
    if ($Request.imageContext -notin @('Generic','Healthcare','Business','Custom')) { throw 'Choose a supported image setting.' }
    if (([string]$Request.requiredSources).Length -gt 40000 -or ([string]$Request.imageInstructions).Length -gt 4000) { throw 'Production preferences exceed the input limit.' }
    if ($Request.imageContext -eq 'Custom' -and [string]::IsNullOrWhiteSpace([string]$Request.imageInstructions)) { throw 'Describe the custom image setting.' }
    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
    $readings=@(ConvertFrom-EbookReadingList -Text ([string]$Request.requiredSources))
    if ($Request.sourceMode -eq 'Assigned' -and -not $readings.Count) { throw 'Add at least one required reading URL.' }
    $settings=[pscustomobject]@{context=$Request.imageContext;instructions=([string]$Request.imageInstructions).Trim()}
    $production=[pscustomobject]@{sourceMode=$Request.sourceMode;requiredReadings=$readings;imageSettings=$settings}
    if (-not $job.sourceContextPath -or -not (Test-Path -LiteralPath $job.sourceContextPath)) { throw 'Original course uploads are not available for this book.' }
    $planPath=if($job.outputFolder){Join-Path $job.outputFolder 'ebook-plan.json'}else{''}
    $plan=if($planPath -and (Test-Path -LiteralPath $planPath)){Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json}else{$null}
    if ($plan) {
        foreach ($reading in $readings) {
            if (@($reading.chapters | Where-Object { $_ -ne 0 -and $_ -notin @($plan.chapters.number) }).Count) { throw 'A required reading refers to a chapter outside this outline.' }
        }
        foreach ($key in @('sourceMode','requiredReadings','imageSettings')) { $plan | Add-Member -NotePropertyName $key -NotePropertyValue $production.$key -Force }
        $backup=Join-Path $job.outputFolder 'production-backups'
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        Copy-Item -LiteralPath $planPath -Destination (Join-Path $backup ((Get-Date -Format 'yyyyMMddHHmmssfff')+'-plan.json'))
        $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding UTF8
    }
    $production | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $job.sourceContextPath 'book-studio-production.json') -Encoding UTF8
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        foreach ($key in @('sourceMode','requiredReadings','imageSettings')) { $current.options | Add-Member -NotePropertyName $key -NotePropertyValue $production.$key -Force }
    }
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message 'Source list and image setting saved. Existing citations and image contents are unchanged; check sources, then revise the manuscript or regenerate images as needed.'
    Get-BookStudioProductionPreferences (Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId)
}

function Start-BookStudioSourcePreparation {
    param([string]$DatabasePath,[string]$JobId,[string]$ProjectRoot)
    $job=Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    Assert-BookStudioProductionIdle $job
    if ($job.options.sourceMode -ne 'Assigned' -or -not $job.outputFolder -or -not (Test-Path -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json'))) { throw 'Save required-reading mode and create the outline before checking sources.' }
    $scriptPath=Join-Path $ProjectRoot 'book-studio-source-runner.ps1'
    $priorStatus=$job.status
    $process=Start-Process -FilePath powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$scriptPath+'"'),'-ProjectRoot',('"'+$ProjectRoot+'"'),'-DatabasePath',('"'+$DatabasePath+'"'),'-JobId',$JobId,'-PriorStatus',$priorStatus) -WindowStyle Hidden -PassThru
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update { param($current) $current.status='Running'; $current.runnerProcessId=$process.Id }
    Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase 'Reading required sources' -Detail 'Retrieving the exact assigned URLs. No manuscript edits or AI calls.' -Percent 5 -AddLog
    [pscustomobject]@{status='Running';message='Source check started. Refresh the source list for per-reading results.'}
}

function Start-BookStudioSavedImageGeneration {
    param([string]$DatabasePath,[string]$JobId,[string]$ProjectRoot)
    $job=Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    Assert-BookStudioProductionIdle $job
    if (-not $job.outputFolder -or -not @(Get-ChildItem -LiteralPath $job.outputFolder -Filter '* - E-Book.md' -File).Count) { throw 'Generate the manuscript before requesting images.' }
    $null=Get-EbookImagePlan $job.outputFolder
    # Validate the normal connection/approval gate before persisting a retry request.
    $job.options | Add-Member -NotePropertyName useCodexImages -NotePropertyValue $true -Force
    Assert-BookStudioGenerationReady -Job $job -ProjectRoot $ProjectRoot
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        $current.options | Add-Member -NotePropertyName useCodexImages -NotePropertyValue $true -Force
        $current.options | Add-Member -NotePropertyName savedImageRetry -NotePropertyValue $true -Force
    }
    Start-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -ProjectRoot $ProjectRoot -RunMode Full
}

function Get-BookStudioQaFindings {
    param($Quality,$Publishing,$Audit)
    foreach ($chapter in @($Quality.chapters)) {
        foreach ($check in @($chapter.checks | Where-Object status -in @('FAIL','WARNING'))) {
            [pscustomobject]@{category='Quality';chapter=$chapter.chapterNumber;name=$check.name;status=$check.status;detail=$check.detail}
        }
    }
    foreach ($chapter in @($Publishing.chapters)) {
        foreach ($issue in @($chapter.priorityRevisions)) { if ($issue) { [pscustomobject]@{category='Publishing';chapter=$chapter.chapterNumber;name='Revision';status='FAIL';detail=[string]$issue} } }
    }
    foreach ($check in @($Audit.checks | Where-Object status -in @('FAIL','WARNING'))) {
        [pscustomobject]@{category='Audit';chapter=$null;name=$check.name;status=$check.status;detail=$check.detail}
    }
}
