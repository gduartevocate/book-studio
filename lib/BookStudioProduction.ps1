function Get-BookStudioPreviewQualitySummary {
    param([string]$OutputFolder)
    $outlineStatus = 'Not checked'
    $outlineDetail = 'Create or regenerate the outline preview.'
    $sourceStatus = 'Not checked'
    $sourceDetail = 'Source readiness is checked separately before drafting.'
    $sourceIssues = @()
    $outlineIssues = @()
    $validation = Join-Path $OutputFolder 'export-validation.json'
    if (Test-Path -LiteralPath $validation) {
        try {
            $report = Get-Content -LiteralPath $validation -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            $outlineStatus = if ($report.status -eq 'PASS') { 'Ready for review' } else { 'Needs attention' }
            $outlineDetail = if ($report.status -eq 'PASS') { 'Planning exports passed validation. Review the outline and format before approval.' } else { 'Planning export validation did not pass. Open Export validation report.' }
        } catch { $outlineStatus = 'Needs attention'; $outlineDetail = 'The planning export validation report could not be read.' }
    }
    $planPath = Join-Path $OutputFolder 'ebook-plan.json'
    if (Test-Path -LiteralPath $planPath) {
        try {
            $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if (-not @($plan.chapters | Where-Object { $_ }).Count) { throw 'The saved outline has no chapters.' }
            $planningPath = Join-Path $OutputFolder 'ebook-planning-packet.json'
            $planning = Get-Content -LiteralPath $planningPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            $gates = $planning.planningQualityGates
            $reviewPath = Join-Path $OutputFolder 'outline-qa.json'
            if (Test-Path -LiteralPath $reviewPath) {
                $review = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                if ($review.planningSha256 -eq (Get-FileHash -LiteralPath $planningPath).Hash) { $gates = $review }
            }
            $outlineIssues = @($gates.checks | Where-Object status -eq 'FAIL' | ForEach-Object detail)
            if ($gates.status -eq 'FAIL') { $outlineStatus = 'Needs attention'; $outlineDetail = 'The outline has planning findings. Review the planning packet before approval.' }
            if ($plan.sourceMode -eq 'Assigned') {
                $readings = @($plan.requiredReadings | Where-Object { $_ })
                if (-not $readings.Count) { $sourceIssues += 'Add the required article/chapter URLs. The blueprint is not a scholarly source.' }
                foreach ($reading in @($readings | Where-Object { -not $_.url })) {
                    $sourceIssues += "Missing URL: $($reading.title). Add the reading URL, or remove this entry if it is only a heading."
                }
                foreach ($chapter in $plan.chapters) {
                    if (-not @($readings | Where-Object { 0 -in $_.chapters -or $chapter.number -in $_.chapters }).Count) {
                        $sourceIssues += "Chapter $($chapter.number) has no assigned readings."
                    }
                }
                $evidencePath = Join-Path $OutputFolder 'required-source-report.json'
                if (Test-Path -LiteralPath $evidencePath) {
                    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
                    $review = Get-EbookRequiredSourceReview -Plan $plan -OutputFolder $OutputFolder -Markdown '' -EvidenceOnly
                    $sourceIssues += @($review.issues)
                    $sourceStatus = if ($sourceIssues.Count) { 'Needs attention' } else { 'Ready' }
                    $sourceDetail = 'Source text and chapter assignments checked; manuscript citations are not evaluated until a manuscript exists.'
                } else {
                    $sourceStatus = if ($sourceIssues.Count) { 'Needs attention' } else { 'Not checked' }
                    $sourceDetail = 'Open Sources and image setting, save the reading list, then Check required sources. Retrieval has not been checked for this outline.'
                }
            }
            elseif ($plan.sourceMode -eq 'UploadedOnly') { $sourceStatus = 'Pending drafting checks'; $sourceDetail = 'Uploaded teaching evidence is validated before drafting; no external readings are selected.' }
            else { $sourceStatus = 'Pending discovery'; $sourceDetail = 'External sources will be discovered and reviewed during generation.' }
        } catch { $outlineStatus = 'Needs attention'; $outlineDetail = 'The saved plan or planning packet could not be read.'; $outlineIssues += $_.Exception.Message }
    } else { $outlineStatus = 'Needs attention'; $outlineDetail = 'The saved plan is missing. Recreate the outline preview.' }
    [pscustomobject]@{
        status='Preview'; stage='outline'; outlineStatus=$outlineStatus; summary=$outlineDetail; outlineIssues=$outlineIssues
        sourceReadiness=[pscustomobject]@{status=$sourceStatus;detail=$sourceDetail;issues=@($sourceIssues | Select-Object -Unique)}
        manuscriptStatus='Not generated'; findings=@(); qualityStatus=''; publishingStatus=''; auditStatus=''
        draftReadyForReview=$false; publicationReady=$false
    }
}

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
    [pscustomobject]@{sourceMode=$Job.options.sourceMode;readingLevel=$(if($Job.options.readingLevel){[int]$Job.options.readingLevel}else{8});allowAdditionalResearch=[bool]$Job.options.allowAdditionalResearch;requiredSources=(ConvertTo-EbookReadingListText $readings);readings=$readings;sourceReport=$report;imageSettings=$(if($Job.options.imageSettings){$Job.options.imageSettings}else{[pscustomobject]@{context='Generic';instructions=''}})}
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
    # Assigned readings stay locked, taught and cited; this only permits sources
    # on top of them, so it is meaningless without an assigned list.
    $allowAdditionalResearch = [bool]$Request.allowAdditionalResearch
    if ($allowAdditionalResearch -and $Request.sourceMode -ne 'Assigned') { throw 'Additional research alongside required readings applies only to the required-readings source policy.' }
    $readingLevel = 8
    if ($null -ne $Request.readingLevel -and [string]$Request.readingLevel -ne '') {
        if (-not [int]::TryParse([string]$Request.readingLevel, [ref]$readingLevel) -or $readingLevel -lt 6 -or $readingLevel -gt 16) { throw 'Choose a reading level between grade 6 and grade 16.' }
    }
    $settings=[pscustomobject]@{context=$Request.imageContext;instructions=([string]$Request.imageInstructions).Trim()}
    $production=[pscustomobject]@{sourceMode=$Request.sourceMode;readingLevel=$readingLevel;requiredReadings=$readings;imageSettings=$settings;allowAdditionalResearch=$allowAdditionalResearch}
    if (-not $job.sourceContextPath -or -not (Test-Path -LiteralPath $job.sourceContextPath)) { throw 'Original course uploads are not available for this book.' }
    $planPath=if($job.outputFolder){Join-Path $job.outputFolder 'ebook-plan.json'}else{''}
    $plan=if($planPath -and (Test-Path -LiteralPath $planPath)){Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json}else{$null}
    if ($plan) {
        foreach ($reading in $readings) {
            if (@($reading.chapters | Where-Object { $_ -ne 0 -and $_ -notin @($plan.chapters.number) }).Count) { throw 'A required reading refers to a chapter outside this outline.' }
        }
        foreach ($key in @('sourceMode','readingLevel','requiredReadings','imageSettings','allowAdditionalResearch')) { $plan | Add-Member -NotePropertyName $key -NotePropertyValue $production.$key -Force }
        $backup=Join-Path $job.outputFolder 'production-backups'
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        Copy-Item -LiteralPath $planPath -Destination (Join-Path $backup ((Get-Date -Format 'yyyyMMddHHmmssfff')+'-plan.json'))
        $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding UTF8
    }
    $production | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $job.sourceContextPath 'book-studio-production.json') -Encoding UTF8
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        foreach ($key in @('sourceMode','readingLevel','requiredReadings','imageSettings','allowAdditionalResearch')) { $current.options | Add-Member -NotePropertyName $key -NotePropertyValue $production.$key -Force }
        # The runner reads skipResearch and skipOpenStaxFetch from the job, so
        # permitting research here has no effect unless these follow it.
        if ($allowAdditionalResearch) {
            $current.options | Add-Member -NotePropertyName skipResearch -NotePropertyValue $false -Force
            $current.options | Add-Member -NotePropertyName skipOpenStaxFetch -NotePropertyValue $false -Force
        }
        elseif ($production.sourceMode -eq 'UploadedOnly') {
            $current.options | Add-Member -NotePropertyName skipResearch -NotePropertyValue $true -Force
            $current.options | Add-Member -NotePropertyName skipOpenStaxFetch -NotePropertyValue $true -Force
        }
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
