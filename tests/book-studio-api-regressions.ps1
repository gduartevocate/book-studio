[CmdletBinding()]
param([string]$CourseSpecPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('BookStudioTests/api-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
foreach($folder in @('lib','config','book-studio')){Copy-Item -LiteralPath (Join-Path $root $folder) -Destination (Join-Path $fixture $folder) -Recurse}
foreach($file in @('book-studio.ps1','book-studio-runner.ps1','book-studio-source-runner.ps1','ebook-generator.ps1','audit-ebook-output.ps1')){Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $fixture $file)}
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
$base="http://localhost:$port"
$server=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $fixture 'book-studio.ps1')+'"'),'-Port',$port) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $fixture 'server.log') -RedirectStandardError (Join-Path $fixture 'server-error.log')
$script:checks=0
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};$script:checks++}
function Post([string]$Path,[object]$Body){Invoke-RestMethod -Uri ($base+$Path) -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 15))) -TimeoutSec 30}
function Reject([scriptblock]$Action,[int]$Status){$caught=$false;try{& $Action | Out-Null}catch{$caught=$true;Check ([int]$_.Exception.Response.StatusCode -eq $Status) "Wrong HTTP status: $_"};Check $caught 'Expected HTTP rejection.'}
try{
    $ready=$false
    for($i=0;$i -lt 20;$i++){try{$page=Invoke-WebRequest -UseBasicParsing -Uri $base -TimeoutSec 2;$ready=$true;break}catch{Start-Sleep -Milliseconds 300}}
    Check $ready 'Isolated app server did not start.'
    Check ($page.Content -match 'primarySourceSelect' -and $page.Content -match 'UploadedOnly' -and $page.Content -match 'testCodexConnection') 'New intake or connection controls missing from served UI.'
    $health=Invoke-RestMethod "$base/api/health"
    Check ($health.status -eq 'ok' -and $health.service -eq 'book-studio') 'Book Studio health endpoint did not respond.'
    Check (@((Invoke-RestMethod "$base/api/jobs").jobs).Count -eq 0) 'Isolated database was not empty.'
    # The health check names the folder this server runs from and how many
    # books are in it. Two installs on one PC answer identically otherwise, and
    # the cloud agent restarted whichever one held the port -- including a
    # designer's own, with her books in it.
    Check ([string]::Equals([string]$health.installPath, [IO.Path]::GetFullPath($fixture).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) "The health check must name the folder the server runs from; got '$($health.installPath)'."
    Check ($health.bookCount -eq 0 -and "$($health.bookCount)" -eq '0') "An empty install must report 0 books, not nothing; got '$($health.bookCount)'."
    Check ([string]$health.databasePath -like '*.bookstudio\book-studio-db.json') "The health check must name the database the server uses; got '$($health.databasePath)'."

    # A second server for a port that is already taken must stop before it
    # touches any book database. The agent's page helpers started one whenever
    # the running server was too busy to answer a probe; it could not listen,
    # but it had already opened and repaired the database of its own folder.
    $duplicateRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('BookStudioTests/api-duplicate-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $duplicateRoot -Force | Out-Null
    foreach($folder in @('lib','config','book-studio')){Copy-Item -LiteralPath (Join-Path $root $folder) -Destination (Join-Path $duplicateRoot $folder) -Recurse}
    Copy-Item -LiteralPath (Join-Path $root 'book-studio.ps1') -Destination (Join-Path $duplicateRoot 'book-studio.ps1')
    $duplicate=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $duplicateRoot 'book-studio.ps1')+'"'),'-Port',$port) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $duplicateRoot 'server.log') -RedirectStandardError (Join-Path $duplicateRoot 'server-error.log')
    $duplicateExited=$duplicate.WaitForExit(60000)
    if(-not $duplicateExited){$duplicate.Kill();$duplicate.WaitForExit()}
    Check $duplicateExited 'A second Book Studio for a port already in use must give up, not keep running.'
    Check (-not (Test-Path -LiteralPath (Join-Path $duplicateRoot '.bookstudio'))) 'A second Book Studio that could not listen must not have created or opened a book database.'
    Check ((Invoke-RestMethod "$base/api/health" -TimeoutSec 10).installPath -eq $health.installPath) 'The first server must be unaffected by the second.'
    Remove-Item -LiteralPath $duplicateRoot -Recurse -Force -ErrorAction SilentlyContinue
    Reject {Invoke-WebRequest -UseBasicParsing -Uri "$base/api/jobs" -Method Post -ContentType 'application/json' -Headers @{Origin='https://example.org'} -Body '{}'} 403
    Reject {Invoke-WebRequest -UseBasicParsing -Uri "$base/api/jobs" -Method Post -ContentType 'text/plain' -Body '{}'} 400
    Reject {Post '/api/jobs' @{files=@(@{name='scan.pdf';contentBase64='UERG'})}} 400
    $spec=@'
Course Number
QA1000
Course Name
Office Workflow Fixture
Course Description
Office records and workflow coordination.
Course Objectives
CO1: Organize office records using clear naming rules.
CO2: Coordinate office workflow using task ownership.
Week 1 Office Records
1. Office records and clear naming rules
Week 2 Workflow Coordination
2. Office workflow, task ownership, and handoffs
'@
    $file=@{name='QA1000 Blueprint.txt';contentBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($spec))}
    $reading=@{name='Office reading.txt';contentBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('Office records use clear naming rules. Workflow coordination defines task ownership and handoffs.'))}
    $job=Post '/api/jobs' @{title='Office Workflow Fixture';courseCode='QA1000';files=@($file,$reading);primaryFileIndex=0;courseDocumentKind='EbookReady';sourceMode='UploadedOnly';useCodexDrafting=$false;useCodexImages=$false}
    Check ($job.intake.readFiles -eq 2 -and $job.options.sourceMode -eq 'UploadedOnly') 'API intake contract missing.'
    $productionScript=Invoke-WebRequest -UseBasicParsing -Uri "$base/production.js"
    Check ($productionScript.Content -match 'appendProductionPreferences') 'Production preferences script is not served.'
    $analysisScript=Invoke-WebRequest -UseBasicParsing -Uri "$base/outcome-analysis.js"
    Check ($analysisScript.Content -match 'drawOutcomeAnalysisPanel') 'The outcome analysis script is not served.'
    Check ($page.Content -match 'courseDocumentKind') 'The course-document-kind control is missing from the served UI.'

    # The curriculum-draft route, over real HTTP, with no Codex anywhere.
    $draft=Post '/api/jobs' @{title='Office Workflow Draft';courseCode='QA1000';files=@($file,$reading);primaryFileIndex=0;courseDocumentKind='CurriculumDraft';sourceMode='UploadedOnly';useCodexDrafting=$false;useCodexImages=$false}
    Check ($draft.workflowStage -eq 'outcomes-analysis') "A curriculum draft stops for its outcome review (got '$($draft.workflowStage)')."
    # The count follows the books: an empty folder and one with books must not
    # look the same from outside.
    Check ((Invoke-RestMethod "$base/api/health" -TimeoutSec 10).bookCount -eq 2) 'The health check must count the books this server holds.'
    Reject {Post "/api/jobs/$($draft.id)/run" @{mode='Blueprint'}} 400
    $analysis=Invoke-RestMethod "$base/api/jobs/$($draft.id)/outcome-analysis"
    Check (@($analysis.courseObjectives).Count -eq 2 -and @($analysis.chapters).Count -eq 2) 'The outcome review did not return the course objectives and chapters.'
    Check ($analysis.status -eq 'Not analyzed' -and -not $analysis.catalogText) 'A new book must start with no suggested outcomes.'
    Reject {Invoke-RestMethod "$base/api/jobs/$($job.id)/outcome-analysis"} 400
    $catalog="CO1: Organize office records using clear naming rules.`nLO1.1: Identify the record types an office keeps.`nCO2: Coordinate office workflow using task ownership.`nLO2.1: Assign an owner to each workflow step."
    $assign=@(@{number=1;ids='CO1'},@{number=2;ids='CO2'})
    Reject {Post "/api/jobs/$($draft.id)/outcome-analysis/preview" @{text=($catalog -replace 'clear naming','clear file naming');assignments=$assign}} 400
    Reject {Post "/api/jobs/$($draft.id)/outcome-analysis/preview" @{text=$catalog;assignments=@(@{number=1;ids='CO1'},@{number=2;ids='LO1.1'})}} 400
    $checked=Post "/api/jobs/$($draft.id)/outcome-analysis/preview" @{text=$catalog;assignments=$assign}
    Check (@($checked.chapters).Count -eq 2 -and $checked.uniqueOutcomes -eq 2) 'The outcome preview did not resolve both chapters.'
    Reject {Invoke-RestMethod "$base/api/jobs/$($draft.id)/outcome-analysis/file?name=../book-studio-db.json"} 400
    $approved=Post "/api/jobs/$($draft.id)/outcome-analysis/apply" @{text=$catalog;assignments=$assign;confirm=$true;reviewedBy='Fixture ID';reason='Reviewed against the draft'}
    Check ($approved.status -eq 'Approved' -and $approved.workflowStage -eq 'format-review') 'Approval did not release the book to planning.'
    $reusable=Invoke-WebRequest -UseBasicParsing -Uri "$base/api/jobs/$($draft.id)/outcome-analysis/file?name=QA1000%20-%20Ebook%20Course%20File.md"
    Check ([string]$reusable.Content -match '1\.1 Identify the record types an office keeps\.') 'The reusable ebook-ready course file was not served.'
    Reject {Post "/api/jobs/$($job.id)/run" @{mode='Full'}} 400
    $null=Post "/api/jobs/$($job.id)/run" @{mode='Blueprint'}
    $deadline=(Get-Date).AddSeconds(45)
    do{
        Start-Sleep -Milliseconds 500
        $job=@((Invoke-RestMethod "$base/api/jobs").jobs | Where-Object id -eq $job.id)[0]
    }while($job.status -in @('Running','Queued') -and (Get-Date) -lt $deadline)
    Check ($job.status -eq 'Completed' -and $job.workflowStage -eq 'format-review') "Blueprint workflow failed: $($job.error) (fixture: $fixture)"
    Check ($job.formatState.fingerprint -and -not $job.formatState.needsRefresh) 'Preview manifest/fingerprint missing from API.'
    $qa = Post "/api/jobs/$($job.id)/run-qa" @{}
    Check ($qa.status -eq 'Completed' -and $qa.qaSummary.stage -eq 'outline' -and $qa.qaSummary.status -ne 'FAIL') 'Outline QA rerun failed or ran manuscript gates.'
    $reviewedJob = Invoke-RestMethod "$base/api/jobs/$($job.id)"
    Check ($reviewedJob.qaReview.checkedAt -and $reviewedJob.qaReview.message -match 'Outline:') 'QA rerun receipt did not persist.'
    $preview=Invoke-WebRequest -UseBasicParsing -Uri "$base/api/jobs/$($job.id)/asset?path=book-format-preview.html"
    Check ($preview.Content -match 'Organize office records using clear naming rules' -and $preview.Content -notmatch 'Knowledge Check|Chapter Summary') 'Real preview lost blueprint objectives or included excluded sections.'
    $generatedPlan=Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $plannedChapters=@($generatedPlan.chapters | Sort-Object number)
    $settings=Invoke-RestMethod "$base/api/jobs/$($job.id)/production-settings"
    Check ($settings.imageSettings.context -eq 'Generic') 'New image context default missing.'
    $settings=Post "/api/jobs/$($job.id)/production-settings" @{sourceMode='UploadedOnly';requiredSources='';imageContext='Business';imageInstructions='Use office teams, no scrubs.'}
    Check ($settings.imageSettings.context -eq 'Business') 'Saved image setting was lost.'
    $savedPlan=Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($savedPlan.imageSettings.instructions -eq 'Use office teams, no scrubs.') 'Image direction did not reach the book plan.'
    Reject {Post "/api/jobs/$($job.id)/production-settings" @{sourceMode='Assigned';requiredSources='';imageContext='Generic'}} 400
    Reject {Post "/api/jobs/$($job.id)/check-sources" @{}} 400
    Reject {Post "/api/jobs/$($job.id)/generate-images" @{}} 400
    $lastPlannedChapter=$plannedChapters[-1]
    Check ($plannedChapters.Count -gt 1 -and $preview.Content -match [regex]::Escape([string]$lastPlannedChapter.title) -and $preview.Content -match 'Complete Planned Book') 'Format preview did not include the complete planned book.'
    $outline=Invoke-RestMethod "$base/api/jobs/$($job.id)/outline"
    Check (@($outline.chapters).Count -eq $plannedChapters.Count -and $outline.editableFields -contains 'chapter title' -and $outline.editableFields -contains 'chapter focus' -and $outline.fixedFields -contains 'source learning objectives') 'Outline editor API did not expose the planned chapters and editing contract.'
    $beforeOutlineFingerprint=$job.formatState.fingerprint
    $editedTitle="Edited Chapter 1: Records That Work"
    $editedFocus="repeatable naming, filing, and retrieval of office records"
    $outline.chapters[0].title=$editedTitle
    $outline.chapters[0].focus=$editedFocus
    $editedGuidance='Use a clinic front-desk example and keep the tone practical. Preserve the patient'+[char]0x2019+'s perspective.'
    $outline.chapters[0] | Add-Member -NotePropertyName guidance -NotePropertyValue $editedGuidance -Force
    Check ($outline.editableFields -contains 'writer guidance' -and $outline.chapters[0].PSObject.Properties['guidance']) 'Outline editor API did not expose writer guidance.'
    $null=Post "/api/jobs/$($job.id)/outline" @{chapters=@($outline.chapters)}
    $job=@((Invoke-RestMethod "$base/api/jobs").jobs | Where-Object id -eq $job.id)[0]
    $updatedOutline=Invoke-RestMethod "$base/api/jobs/$($job.id)/outline"
    $updatedPreview=(Invoke-WebRequest -UseBasicParsing -Uri "$base/api/jobs/$($job.id)/asset?path=book-format-preview.html").Content
    $updatedPlan=Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($beforeOutlineFingerprint -ne $job.formatState.fingerprint -and $updatedOutline.chapters[0].title -eq $editedTitle -and $updatedOutline.chapters[0].focus -eq $editedFocus -and $updatedPreview -match [regex]::Escape($editedTitle) -and $updatedPreview -match [regex]::Escape($editedFocus) -and $updatedPreview -match [regex]::Escape([string]$outline.chapters[0].objectives[0])) 'Saved outline edits did not regenerate the complete preview.'
    Check ((Get-Content -LiteralPath (Join-Path $job.sourceContextPath 'book-studio-reviewed-outline.json') -Raw -Encoding UTF8) -match [regex]::Escape($editedTitle) -and $updatedPlan.chapters[0].title -eq $editedTitle) 'Saved outline edits were not persisted for the full-generation runner.'
    Check ($updatedOutline.chapters[0].guidance -eq $editedGuidance -and $updatedPlan.chapters[0].guidance -eq $editedGuidance) 'Writer guidance was not saved with the outline.'
    Check ($job.formatReview.status -eq 'Needs revision' -and [string]::IsNullOrWhiteSpace([string]$job.formatReview.fingerprint)) 'Outline editing did not clear the previous format approval.'
    Check ($job.outlineUpdate.message -match 'Word/Markdown' -and $updatedOutline.lastUpdate.planHash) 'Persisted save receipt is missing.'
    Check ((Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-outline.md') -Raw -Encoding UTF8).Contains($editedTitle)) 'Markdown outline is stale after saving.'
    Import-Module (Join-Path $fixture 'lib/EbookGenerator.psm1') -Force -DisableNameChecking
    $outlineWord=Get-ChildItem -LiteralPath $job.outputFolder -Filter '* - E-Book Outline.docx' | Select-Object -First 1
    Check ((& (Get-Module EbookGenerator) {param($p) Get-DocxText $p} $outlineWord.FullName).Contains($editedTitle)) 'Word outline is stale after saving.'
    Check ($updatedPlan.chapters[0].guidance -ceq $editedGuidance) 'Browser-style UTF-8 JSON corrupted punctuation.'
    Reject {Post "/api/jobs/$($job.id)/outline" @{chapters=@($outline.chapters);planHash='stale'}} 400
    $beforeLockedSave=(Get-FileHash -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json')).Hash
    $locked=[IO.File]::Open($outlineWord.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { Reject {Post "/api/jobs/$($job.id)/outline" @{chapters=@($outline.chapters);planHash=$beforeLockedSave}} 400 }
    finally { $locked.Dispose() }
    Check ((Get-FileHash -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json')).Hash -eq $beforeLockedSave) 'A locked Word export left a partially updated plan.'

    $originalSpecHash=(Get-FileHash -LiteralPath $job.specPath).Hash
    $outcomes=@{text="CO1: Organize reliable records.`nLO1.1: Identify record owners.`nLO1.2: Apply a naming convention.`nCO2: Coordinate reliable handoffs.`nLO2.1: Identify handoff risks.`nLO2.2: Explain follow-up responsibilities.";assignments=@(@{number=1;ids='CO1'},@{number=2;ids='CO2'})}
    $beforeOutcomeHash=(Get-FileHash -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json')).Hash
    $replacement=Post "/api/jobs/$($job.id)/outcomes/preview" $outcomes
    Check ($replacement.previousCount -eq @($updatedPlan.chapters | ForEach-Object {$_.learningTargetRecords}).Count -and $replacement.newCount -eq 4 -and $replacement.uniqueOutcomes -eq 4) 'Outcome replacement comparison is incorrect.'
    Check ((Get-FileHash -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json')).Hash -eq $beforeOutcomeHash) 'Preview changed the book.'
    Reject {Post "/api/jobs/$($job.id)/outcomes/apply" $outcomes} 400
    $outcomes.confirm=$true;$outcomes.reviewedBy='Fixture ID';$outcomes.reason='Revised approved outcomes';$outcomes.planHash='stale'
    Reject {Post "/api/jobs/$($job.id)/outcomes/apply" $outcomes} 400
    $outcomes.planHash=$replacement.planHash
    $null=Post "/api/jobs/$($job.id)/outcomes/apply" $outcomes
    $job=@((Invoke-RestMethod "$base/api/jobs").jobs | Where-Object id -eq $job.id)[0]
    $amendedPlan=Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($job.outlineUpdate.outcomesChanged -and ($amendedPlan.chapters[0].learningTargetRecords.objectiveId -join ',') -eq 'LO1.1,LO1.2') 'Outcome replacement lost official IDs.'
    Check ((Get-FileHash -LiteralPath $job.specPath).Hash -eq $originalSpecHash -and (Test-Path -LiteralPath (Join-Path $job.sourceContextPath 'book-studio-outcomes.json'))) 'Original blueprint changed or amendment missing.'
    $amendedCourse=Import-CourseSpec $job.specPath
    $regenerated=New-EbookPlan $amendedCourse
    $regenerated=Merge-EbookReviewedOutline $regenerated (Join-Path $job.sourceContextPath 'book-studio-reviewed-outline.json')
    Check ($regenerated.chapters[0].learningTargetRecords[0].objectiveId -eq 'LO1.1' -and $regenerated.chapters[0].title -eq $editedTitle) 'Regeneration discarded the accepted outcomes or edited title.'
    $packet=Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-planning-packet.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($packet.course.weeks[0].modules[0].objectiveId -eq 'LO1.1' -and $packet.course.outcomeRevision.reviewedBy -eq 'Fixture ID') 'Planning packet lacks effective source/provenance.'
    Check ((Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-outline.md') -Raw -Encoding UTF8).Contains('Identify record owners.') -and (& (Get-Module EbookGenerator) {param($p) Get-DocxText $p} $outlineWord.FullName).Contains('Identify record owners.')) 'Outcome replacement left stale Markdown or Word.'
    $editedTitleForFullGeneration=$editedTitle
    $old=$job.formatState.fingerprint
    $null=Post "/api/jobs/$($job.id)/format-review" @{action='request-changes';layout='large-text';notes='Check larger text.'}
    $job=@((Invoke-RestMethod "$base/api/jobs").jobs | Where-Object id -eq $job.id)[0]
    Check ($old -ne $job.formatState.fingerprint -and $job.formatState.layout -eq 'large-text') 'API layout update did not update preview.'
    Reject {Post "/api/jobs/$($job.id)/format-review" @{action='approve';layout='large-text';previewFingerprint=$old;notesResolved=$true}} 400
    Check ((Invoke-WebRequest -UseBasicParsing -Uri "$base/api/jobs/$($job.id)/asset?path=book-format-preview.html").Content -match 'font-size: 14pt') 'Served preview ignores the selected layout.'
    $null=Post "/api/jobs/$($job.id)/format-review" @{action='approve';layout='large-text';previewFingerprint=$job.formatState.fingerprint;notesResolved=$true}
    $deadline=(Get-Date).AddSeconds(45)
    do{
        Start-Sleep -Milliseconds 500
        $job=@((Invoke-RestMethod "$base/api/jobs").jobs | Where-Object id -eq $job.id)[0]
    }while($job.status -in @('Running','Queued') -and (Get-Date) -lt $deadline)
    Check ($job.status -notin @('Running','Queued')) "Local scaffold generation exceeded test limit (fixture: $fixture)."
    $sourceBrief=Get-Content -LiteralPath (Join-Path $job.outputFolder 'source-brief.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $generatedPlan=Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($generatedPlan.sourceMode -eq 'UploadedOnly' -and @($sourceBrief | Where-Object {$_.sourcePolicy.mode -ne 'UploadedOnly' -or @($_.openStax).Count -or @($_.researchCandidates).Count}).Count -eq 0) 'Source mode was lost in real full generation.'
    Check ($generatedPlan.chapters[0].title -eq $editedTitleForFullGeneration -and $generatedPlan.chapters[0].focus -eq $editedFocus) 'Full generation did not apply the saved instructional-designer outline.'
    Check ($generatedPlan.chapters[0].learningTargetRecords[0].objectiveId -eq 'LO1.1' -and $generatedPlan.chapters[0].learningTargets[0] -eq 'Identify record owners.') 'Full generation reverted to obsolete source objectives.'
    Check ($generatedPlan.chapters[0].guidance -eq $editedGuidance -and (Get-Content -LiteralPath (Join-Path $job.outputFolder 'ebook-outline.md') -Raw -Encoding UTF8) -match ('Designer guidance: ' + [regex]::Escape($editedGuidance))) 'Writer guidance did not reach the generated plan and outline.'
    Check (-not $job.qaSummary.draftReadyForReview) 'An unreviewed short-source scaffold was incorrectly marked ready.'
    Import-Module (Join-Path $fixture 'lib/EbookGenerator.psm1') -Force
    $word=Get-ChildItem -LiteralPath $job.outputFolder -Filter '* - E-Book.docx' | Select-Object -First 1
    Check ($null -ne $word) 'Full workflow did not export a Word document.'
    Check ((& (Get-Module EbookGenerator) {param($p) Get-EbookDocxArtifactIssues $p} $word.FullName).status -eq 'PASS') 'Full-workflow Word does not satisfy the selected layout/export contract.'
    Check ($generatedPlan.imageSettings.context -eq 'Business') 'Saved image setting was dropped during full generation.'
    $beforeBook=(Get-FileHash -LiteralPath $word.FullName).Hash
    $null=Post "/api/jobs/$($job.id)/production-settings" @{sourceMode='Assigned';requiredSources="All chapters:`n[Blocked fixture](http://127.0.0.1/reading)";imageContext='Business';imageInstructions='Use office teams.'}
    $start=Post "/api/jobs/$($job.id)/check-sources" @{}
    Check ($start.status -eq 'Running') 'Source check did not start asynchronously.'
    $deadline=(Get-Date).AddSeconds(20)
    do { Start-Sleep -Milliseconds 300; $job=@((Invoke-RestMethod "$base/api/jobs").jobs | Where-Object id -eq $job.id)[0] } while($job.status -in @('Running','Queued') -and (Get-Date) -lt $deadline)
    $settings=Invoke-RestMethod "$base/api/jobs/$($job.id)/production-settings"
    Check ($job.status -notin @('Running','Queued') -and $settings.sourceReport.status -eq 'FAIL' -and $settings.sourceReport.readings[0].detail -match 'Local/private') "Source runner did not expose blocked retrieval: $($job.progress.detail)"
    Check ((Get-FileHash -LiteralPath $word.FullName).Hash -eq $beforeBook) 'Checking sources modified the manuscript export.'
    Check (@($job.qaSummary.findings | Where-Object category -eq 'Required sources').Count -gt 0) 'Source failures are missing from current QA.'
    # Objective-only content must create a preview, not phantom assigned readings.
    # Optionally exercise a supplied real Word document without publishing it.
    $bareFile=if($CourseSpecPath){
        @{name=[IO.Path]::GetFileName($CourseSpecPath);contentBase64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($CourseSpecPath))}
    }else{
        @{name='QA1015 Content.txt';contentBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Week 1`n1. Describe records.`n1.1 Identify records.`nWeek 2`n2. Analyze handoffs.`n2.1 Identify handoffs."))}
    }
    $bare=Post '/api/jobs' @{title='Bare week regression';files=@($bareFile);primaryFileIndex=0;courseDocumentKind='EbookReady';sourceMode='Assigned';useCodexDrafting=$false;useCodexImages=$false}
    Check (@($bare.options.requiredReadings).Count -eq 0) 'Objective-only intake created phantom required readings.'
    $null=Post "/api/jobs/$($bare.id)/run" @{mode='Blueprint'}
    $deadline=(Get-Date).AddSeconds(45)
    do { Start-Sleep -Milliseconds 500; $bare=@((Invoke-RestMethod "$base/api/jobs").jobs | Where-Object id -eq $bare.id)[0] } while($bare.status -in @('Running','Queued') -and (Get-Date) -lt $deadline)
    Check ($bare.status -eq 'Completed' -and $bare.formatState.fingerprint) "Bare week preview failed: $($bare.error)"
    $barePlan=Get-Content -LiteralPath (Join-Path $bare.outputFolder 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($barePlan.chapters.Count -ge 2 -and @($barePlan.requiredReadings).Count -eq 0) 'Preview lost bare week chapters or reintroduced phantom sources.'
    $rejected=$false
    try { $null=Post "/api/jobs/$($bare.id)/format-review" @{action='approve';previewFingerprint=$bare.formatState.fingerprint;notesResolved=$true} }
    catch { if($_.ErrorDetails.Message -notmatch 'No required readings are assigned'){throw};$rejected=$true }
    Check $rejected 'Missing sources were not caught before full generation.'
    # Delete only the synthetic preview fixture through the real HTTP route.
    $deleted = Post "/api/jobs/$($bare.id)/delete" @{deleteFiles=$true}
    Check ($deleted.deleted -and -not (Test-Path -LiteralPath $bare.outputFolder)) 'Preview deletion did not remove managed output.'
    Check (@((Invoke-RestMethod "$base/api/jobs").jobs | Where-Object id -eq $bare.id).Count -eq 0) 'Deleted preview is still in the library.'
    Check (Test-Path -LiteralPath $word.FullName) 'Deleting a preview damaged another book.'
    Reject {Post "/api/jobs/$($bare.id)/delete" @{deleteFiles=$true}} 400
    [pscustomobject]@{status='PASS';assertions=$script:checks;fixture=$fixture;scope='Real HTTP intake, blueprint, approval, local full scaffold and Word export; no AI drafting. Fixture correctly remains uncleared for review.'} | ConvertTo-Json
}finally{
    # Stop only the isolated server process created by this test.
    if(-not $server.HasExited){$server.Kill();$server.WaitForExit()}
}
