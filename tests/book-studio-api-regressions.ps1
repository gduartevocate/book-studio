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
function Post([string]$Path,[object]$Body){Invoke-RestMethod -Uri ($base+$Path) -Method Post -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 15) -TimeoutSec 10}
function Reject([scriptblock]$Action,[int]$Status){$caught=$false;try{& $Action | Out-Null}catch{$caught=$true;Check ([int]$_.Exception.Response.StatusCode -eq $Status) "Wrong HTTP status: $_"};Check $caught 'Expected HTTP rejection.'}
try{
    $ready=$false
    for($i=0;$i -lt 20;$i++){try{$page=Invoke-WebRequest -UseBasicParsing -Uri $base -TimeoutSec 2;$ready=$true;break}catch{Start-Sleep -Milliseconds 300}}
    Check $ready 'Isolated app server did not start.'
    Check ($page.Content -match 'primarySourceSelect' -and $page.Content -match 'UploadedOnly' -and $page.Content -match 'testCodexConnection') 'New intake or connection controls missing from served UI.'
    $health=Invoke-RestMethod "$base/api/health"
    Check ($health.status -eq 'ok' -and $health.service -eq 'book-studio') 'Book Studio health endpoint did not respond.'
    Check (@((Invoke-RestMethod "$base/api/jobs").jobs).Count -eq 0) 'Isolated database was not empty.'
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
    $job=Post '/api/jobs' @{title='Office Workflow Fixture';courseCode='QA1000';files=@($file,$reading);primaryFileIndex=0;sourceMode='UploadedOnly';useCodexDrafting=$false;useCodexImages=$false}
    Check ($job.intake.readFiles -eq 2 -and $job.options.sourceMode -eq 'UploadedOnly') 'API intake contract missing.'
    $productionScript=Invoke-WebRequest -UseBasicParsing -Uri "$base/production.js"
    Check ($productionScript.Content -match 'appendProductionPreferences') 'Production preferences script is not served.'
    Reject {Post "/api/jobs/$($job.id)/run" @{mode='Full'}} 400
    $null=Post "/api/jobs/$($job.id)/run" @{mode='Blueprint'}
    $deadline=(Get-Date).AddSeconds(45)
    do{
        Start-Sleep -Milliseconds 500
        $job=@((Invoke-RestMethod "$base/api/jobs").jobs | Where-Object id -eq $job.id)[0]
    }while($job.status -in @('Running','Queued') -and (Get-Date) -lt $deadline)
    Check ($job.status -eq 'Completed' -and $job.workflowStage -eq 'format-review') "Blueprint workflow failed: $($job.error) (fixture: $fixture)"
    Check ($job.formatState.fingerprint -and -not $job.formatState.needsRefresh) 'Preview manifest/fingerprint missing from API.'
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
    $editedGuidance='Use a clinic front-desk example and keep the tone practical.'
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
    $bare=Post '/api/jobs' @{title='Bare week regression';files=@($bareFile);primaryFileIndex=0;sourceMode='Assigned';useCodexDrafting=$false;useCodexImages=$false}
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
    [pscustomobject]@{status='PASS';assertions=$script:checks;fixture=$fixture;scope='Real HTTP intake, blueprint, approval, local full scaffold and Word export; no AI drafting. Fixture correctly remains uncleared for review.'} | ConvertTo-Json
}finally{
    # Stop only the isolated server process created by this test.
    if(-not $server.HasExited){$server.Kill();$server.WaitForExit()}
}
