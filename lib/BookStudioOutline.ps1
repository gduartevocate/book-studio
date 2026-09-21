function Get-BookStudioOutcomeReplacement {
    param([object]$Job,[object]$Request)
    Assert-BookStudioProductionIdle $Job
    if (-not $Job.outputFolder -or -not (Test-Path -LiteralPath (Join-Path $Job.outputFolder 'ebook-plan.json'))) { throw 'Create the outline first.' }
    if (@(Get-ChildItem -LiteralPath $Job.outputFolder -Filter '* - E-Book.md' -File).Count) { throw 'Outcome replacement is available before manuscript generation. Start a new revision/book to change official outcomes after drafting.' }
    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
    $planPath=Join-Path $Job.outputFolder 'ebook-plan.json'
    $plan=Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $catalog=@(ConvertFrom-EbookOutcomeCatalog ([string]$Request.text))
    $resolution=Resolve-EbookOutcomeAssignments -Catalog $catalog -Chapters @($plan.chapters) -Assignments @($Request.assignments)
    $chapters=@(foreach($chapter in $resolution.chapters){
        $planned=@($plan.chapters | Where-Object number -eq $chapter.number)
        [pscustomobject]@{number=$chapter.number;title=$chapter.title;previous=@(if($planned.Count){$planned[0].learningTargetRecords}else{@()});records=$chapter.records}
    })
    [pscustomobject]@{planHash=(Get-FileHash -LiteralPath $planPath).Hash;catalog=$catalog;chapters=$chapters;previousCount=@($plan.chapters | ForEach-Object {$_.learningTargetRecords}).Count;newCount=$resolution.newCount;uniqueOutcomes=$resolution.uniqueOutcomes}
}

function Save-BookStudioOutlineArtifacts {
    param([string]$DatabasePath,[object]$Job,[object]$Plan,[object]$Course,[object]$Revision,[string[]]$Changes,[string]$ExpectedPlanHash)
    # Build every review artifact before touching the live book. No AI calls.
    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
    $stageRoot=Join-Path ([IO.Path]::GetTempPath()) ('bs-outline-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stageRoot | Out-Null
    $chapters=@($Plan.chapters | Sort-Object number)
    for($i=0;$i -lt $chapters.Count;$i++){
        $chapter=$chapters[$i]
        $chapter.buildsOn=if($i -gt 0){$chapters[$i-1].title}else{'the course purpose and prior knowledge'}
        $chapter.setsUp=if($i+1 -lt $chapters.Count){$chapters[$i+1].title}else{'the final course synthesis'}
        $chapter.cohesionBridge="Connect $($chapter.buildsOn) to $($chapter.setsUp), developing $($chapter.focus)."
    }
    $Plan.narrativeSpine='The reviewed chapter sequence develops: '+(($chapters | ForEach-Object {$_.title}) -join '; ')+'.'
    $context=Import-SourceContext -Path $Job.sourceContextPath -CourseSpecPath $Job.specPath -MaxFiles 52 -MaxTotalChars 1000000 -IncludedPaths @($Job.uploadedFiles.path)
    $brand=Import-BrandProfile -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/uma-brand-profile.json')
    $package=New-EbookBlueprintPackage -Course $Course -Plan $Plan -SourceContext $context -BrandProfile $brand
    $result=Export-EbookBlueprintPackage -Package $package -OutputRoot $stageRoot
    $settings=Join-Path $Job.outputFolder 'book-format-settings.json'
    if(Test-Path -LiteralPath $settings){Copy-Item -LiteralPath $settings -Destination (Join-Path $result.outputFolder 'book-format-settings.json')}
    New-BookStudioFormatPreview -Job $Job -OutputFolder $result.outputFolder | Out-Null
    $planPath=Join-Path $Job.outputFolder 'ebook-plan.json'
    if((Get-FileHash -LiteralPath $planPath).Hash -ne $ExpectedPlanHash){throw 'The outline changed while building the preview. Reload and review your changes again.'}
    $backup=Join-Path $Job.outputFolder ('outline-backups/'+[guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $files=[Collections.Generic.List[object]]::new()
    foreach($file in Get-ChildItem -LiteralPath $result.outputFolder -File){
        $files.Add([pscustomobject]@{source=$file.FullName;target=(Join-Path $Job.outputFolder $file.Name);backup=(Join-Path $backup $file.Name);existed=$false})
    }
    $files.Add([pscustomobject]@{source=(Join-Path $result.outputFolder 'ebook-plan.json');target=(Join-Path $Job.sourceContextPath 'book-studio-reviewed-outline.json');backup=(Join-Path $backup 'reviewed-outline.json');existed=$false})
    if($Revision){
        $revisionStage=Join-Path $stageRoot 'outcomes.json'
        $Revision | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $revisionStage -Encoding UTF8
        $files.Add([pscustomobject]@{source=$revisionStage;target=(Join-Path $Job.sourceContextPath 'book-studio-outcomes.json');backup=(Join-Path $backup 'outcomes.json');existed=$false})
    }
    foreach($file in $files){$file.existed=Test-Path -LiteralPath $file.target;if($file.existed){Copy-Item -LiteralPath $file.target -Destination $file.backup -ErrorAction Stop}}
    # Fail before publishing if a review document is locked (for example in Word).
    foreach($file in $files){if($file.existed){$handle=[IO.File]::Open($file.target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read);$handle.Dispose()}}
    $written=[Collections.Generic.List[object]]::new()
    $at=(Get-Date).ToString('s')
    $summary=if($Revision){"Official outcomes replaced after review: $(@($Plan.chapters | ForEach-Object {$_.learningTargetRecords}).Count) chapter assignments."}else{"Saved $($Changes.Count) outline field change(s). Official outcomes unchanged."}
    $message="$summary Preview, Word/Markdown outlines, and planning packets refreshed at $at. Review approval cleared. No manuscript generated or rewritten."
    try {
        foreach($file in $files){$written.Add($file);Copy-Item -LiteralPath $file.source -Destination $file.target -Force -ErrorAction Stop}
        $receipt=[pscustomobject]@{at=$at;message=$message;changes=@($Changes);outcomesChanged=[bool]$Revision;backupFolder=$backup;planHash=(Get-FileHash -LiteralPath $planPath).Hash;previewHash=(Get-FileHash -LiteralPath (Join-Path $Job.outputFolder 'book-format-preview.html')).Hash}
        Update-BookStudioJob -DatabasePath $DatabasePath -JobId $Job.id -Update {
            param($current)
            if(-not $current.formatReview){Add-OrSet-BookStudioNoteProperty $current 'formatReview' ([pscustomobject]@{})}
            Add-OrSet-BookStudioNoteProperty $current.formatReview 'status' 'Needs revision'
            Add-OrSet-BookStudioNoteProperty $current.formatReview 'fingerprint' ''
            Add-OrSet-BookStudioNoteProperty $current.formatReview 'notesResolved' $false
            Add-OrSet-BookStudioNoteProperty $current 'workflowStage' 'format-review'
            Add-OrSet-BookStudioNoteProperty $current 'workflowStatus' 'Outline updated; review the regenerated preview'
            Add-OrSet-BookStudioNoteProperty $current 'reviewedOutlinePath' (Join-Path $Job.sourceContextPath 'book-studio-reviewed-outline.json')
            Add-OrSet-BookStudioNoteProperty $current 'outlineUpdate' $receipt
            $current.log=@($current.log)+[pscustomobject]@{at=$at;message=$message}
        }
    } catch {
        $failure=$_
        foreach($file in $written){if($file.existed){Copy-Item -LiteralPath $file.backup -Destination $file.target -Force -ErrorAction Stop}elseif(Test-Path -LiteralPath $file.target){Remove-Item -LiteralPath $file.target -Force -ErrorAction Stop}}
        throw $failure
    }
    return Get-BookStudioJob -DatabasePath $DatabasePath -JobId $Job.id
}

function Set-BookStudioOutcomeReplacement {
    param([string]$DatabasePath,[string]$JobId,[object]$Request)
    $job=Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    $preview=Get-BookStudioOutcomeReplacement $job $Request
    if($Request.confirm -isnot [bool] -or -not $Request.confirm -or -not ([string]$Request.reviewedBy).Trim() -or -not ([string]$Request.reason).Trim()){throw 'Confirm the reviewed replacement and provide your name and the source/reason for this revision.'}
    if(([string]$Request.reviewedBy).Length -gt 150 -or ([string]$Request.reason).Length -gt 1000){throw 'Reviewer name or revision reason exceeds the input limit.'}
    if($Request.planHash -ne $preview.planHash){throw 'The outline changed. Preview the outcome replacement again before confirming.'}
    $revision=[pscustomobject]@{schemaVersion=1;baseSourceSha256=(Get-FileHash -LiteralPath $job.specPath).Hash;confirmedAt=(Get-Date).ToString('o');reviewedBy=([string]$Request.reviewedBy).Trim();reason=([string]$Request.reason).Trim();catalog=$preview.catalog;chapters=@($preview.chapters | Select-Object number,records)}
    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
    $course=Set-EbookCourseOutcomeRevision (Import-CourseSpec $job.specPath) $revision
    $plan=Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $fresh=New-EbookPlan $course
    foreach($chapter in $plan.chapters){
        $updated=@($fresh.chapters | Where-Object number -eq $chapter.number)[0]
        foreach($field in @('learningTargets','learningTargetRecords','moduleSequence','assessmentHooks')){$chapter | Add-Member -NotePropertyName $field -NotePropertyValue $updated.$field -Force}
    }
    $plan | Add-Member -NotePropertyName outcomeRevision -NotePropertyValue $revision -Force
    $plan | Add-Member -NotePropertyName outlineEditedAt -NotePropertyValue (Get-Date).ToString('s') -Force
    Save-BookStudioOutlineArtifacts -DatabasePath $DatabasePath -Job $job -Plan $plan -Course $course -Revision $revision -Changes @('Official outcome catalog and chapter assignments') -ExpectedPlanHash $preview.planHash
}
