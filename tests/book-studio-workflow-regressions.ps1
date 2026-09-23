[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('BookStudioTests/'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
$studio=Get-Module BookStudio
$script:checks=0
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Pattern){$rejected=$false;try{& $Action | Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$rejected=$true};Check $rejected "Expected rejection: $Pattern"}
function Upload([string]$Name,[string]$Text){[pscustomobject]@{name=$Name;contentBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))}}
$spec=@'
Course Number
QA1000
Course Name
Office Workflow Fixture
Course Description
This fixture teaches office records and workflow coordination.
Course Objectives
CO1: Organize office records using clear naming rules.
CO2: Coordinate office workflow using task ownership.
Week 1 Office Records
1. Office records and clear naming rules
Week 2 Workflow Coordination
2. Office workflow, task ownership, and handoffs
'@
$first=Upload 'QA1000 blueprint.txt' $spec
$second=Upload 'QA1000 blueprint.txt' 'Office records use clear naming rules. Workflow coordination assigns task ownership. This is a separate reading, not the authoritative blueprint.'
Reject {New-BookStudioJob -ProjectRoot $fixture -DatabasePath (Join-Path $fixture 'db.json') -Request ([pscustomobject]@{files=@($first,$second)})} 'Select the authoritative'
foreach($bad in @((Upload 'scan.pdf' 'pdf'),(Upload 'empty.txt' ''),[pscustomobject]@{name='bad.txt';contentBase64='not-base64'})){
    Reject {& $studio {param($r) Test-BookStudioUploadRequest $r} ([pscustomobject]@{files=@($bad)})} 'Unsupported|nonempty|Invalid upload'
}
$db=Initialize-BookStudioDatabase -ProjectRoot $fixture
$job=New-BookStudioJob -ProjectRoot $fixture -DatabasePath $db -Request ([pscustomobject]@{title='Office Workflow Fixture';courseCode='QA1000';primaryFileIndex=0;courseDocumentKind='EbookReady';files=@($first,$second);specialInstructions='Use plain language and preserve all objectives.';useCodexDrafting=$false;useCodexImages=$false})
Check ($job.options.sourceMode -eq 'UploadedOnly' -and $job.options.skipResearch -and $job.options.skipOpenStaxFetch) 'New jobs did not default to uploaded-only mode.'
Check (($job.uploadedFiles.path | Select-Object -Unique).Count -eq 3) 'Duplicate filenames overwrote each other.'
Check ((Get-Content -LiteralPath $job.uploadedFiles[0].path -Raw -Encoding UTF8) -eq $spec) 'The blueprint was overwritten.'
Check ($job.intake.readFiles -eq 3 -and $job.intake.files[0].sha256) 'Accepted source coverage or hashes missing.'
Check ($job.specPath -eq $job.uploadedFiles[0].path) 'Explicit primary selection was not honored.'
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force
$ebook=Get-Module EbookGenerator
$context=Import-SourceContext -Path $job.sourceContextPath -CourseSpecPath $job.specPath -StrictCoverage -IncludedPaths $job.uploadedFiles.path
$context | Add-Member sourceMode UploadedOnly
Reject {Import-SourceContext -Path $job.sourceContextPath -StrictCoverage -IncludedPaths $job.uploadedFiles.path -MaxFiles 2} 'limit'
Reject {Import-SourceContext -Path $job.sourceContextPath -StrictCoverage -IncludedPaths $job.uploadedFiles.path -MaxTotalChars 10} 'truncation'
$empty=Join-Path $fixture 'blank.txt';'   ' | Set-Content -LiteralPath $empty
Reject {Import-SourceContext -Path $fixture -StrictCoverage -IncludedPaths @($empty)} 'readable'
$many=@(1..24 | ForEach-Object {Upload "reading$_.txt" "Office workflow reading $_ contains distinct evidence about task ownership and records."})
$manyJob=New-BookStudioJob -ProjectRoot $fixture -DatabasePath $db -Request ([pscustomobject]@{files=$many;primaryFileIndex=0;courseDocumentKind='EbookReady'})
Check $manyJob.options.useCodexImages 'Server-side job creation did not default real image generation on.'
Check ($manyJob.intake.readFiles -eq 24) 'The old 20-file silent cap remains.'

# A curriculum draft is not planned until its learning objectives have been
# reviewed. Planning first builds a whole preview against the draft's delivery
# objectives, which then has to be thrown away and rebuilt.
$draftJob=New-BookStudioJob -ProjectRoot $fixture -DatabasePath $db -Request ([pscustomobject]@{title='Office Workflow Draft';courseCode='QA1000';primaryFileIndex=0;courseDocumentKind='CurriculumDraft';files=@($first,$second)})
Check ($draftJob.workflowStage -eq 'outcomes-analysis') "A curriculum draft waits for its outcome review (got '$($draftJob.workflowStage)')."
Check ($draftJob.courseDocumentKind -eq 'CurriculumDraft' -and $draftJob.outcomeAnalysis.status -eq 'Not analyzed') 'The outcome-analysis state is recorded on the job.'
# A parked book is not queued for a runner. Reported as Queued it claims to be
# generating, and its own deletion refuses because the app thinks it is busy.
Check ($draftJob.status -eq 'Review') "A book waiting for its outcome review must not report a runner status (got '$($draftJob.status)')."
$stuck=Update-BookStudioJob -DatabasePath $db -JobId $draftJob.id -Update { param($j) $j.status='Queued' }
Reject {Remove-BookStudioJob -DatabasePath $db -JobId $draftJob.id -DeleteFiles} 'still generating'
Check (Repair-BookStudioParkedJobs -DatabasePath $db) 'A book left parked as Queued was not repaired.'
Check ((Get-BookStudioJob -DatabasePath $db -JobId $draftJob.id).status -eq 'Review') 'The repair did not clear the runner status from a parked book.'
Check (-not (Repair-BookStudioParkedJobs -DatabasePath $db)) 'The parked-book repair reported work when there was none.'
$facts=Get-Content -LiteralPath (Join-Path $draftJob.sourceContextPath 'book-studio-course-facts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Check (@($facts.courseObjectives).Count -eq 2 -and $facts.courseObjectives[0].objectiveId -eq 'CO1') 'The draft course objectives are recorded at intake, before any amendment exists.'
Check ($facts.courseObjectives[0].objective -eq 'Organize office records using clear naming rules.') 'The recorded course objective keeps the course document wording.'
Check ($job.workflowStage -eq 'format-review' -and $job.courseDocumentKind -eq 'EbookReady') 'An ebook-ready course file still goes straight to the format preview.'
Set-Content -LiteralPath (Join-Path $fixture 'book-studio-runner.ps1') -Value '# fixture runner' -Encoding UTF8
Reject {Start-BookStudioJob -DatabasePath $db -JobId $draftJob.id -ProjectRoot $fixture -RunMode 'Blueprint'} 'approve this course'
Reject {& $studio {param($d,$i) Start-BookStudioOutcomeAnalysis -DatabasePath $d -JobId $i -ProjectRoot 'X:\missing'} $db $job.id} 'ebook-ready course file'

# Approving the reviewed outcomes, with no Codex anywhere in the path. The
# designer can always write the outcomes by hand, so the stage must complete
# without one.
$catalog=@'
CO1: Organize office records using clear naming rules.
LO1.1: Identify the record types an office keeps.
LO1.2: Name a record using the office naming convention.
CO2: Coordinate office workflow using task ownership.
LO2.1: Assign an owner to each workflow step.
'@
$assign=@([pscustomobject]@{number=1;ids='CO1'},[pscustomobject]@{number=2;ids='CO2'})
$preview=Get-BookStudioOutcomeAnalysisPreview -Job (Get-BookStudioJob -DatabasePath $db -JobId $draftJob.id) -Request ([pscustomobject]@{text=$catalog;assignments=$assign})
Check (@($preview.chapters).Count -eq 2 -and @($preview.chapters[0].records).Count -eq 2) 'The preview resolves each chapter from the reviewed outcomes.'
Check (@($preview.chapters[0].previous | ForEach-Object {$_.objective}) -join '|' -match 'Office records') 'The preview shows what the curriculum draft said for comparison.'
$reworded=$catalog -replace 'Organize office records using clear naming rules\.','Organize office records using clear file naming rules.'
Reject {Get-BookStudioOutcomeAnalysisPreview -Job (Get-BookStudioJob -DatabasePath $db -JobId $draftJob.id) -Request ([pscustomobject]@{text=$reworded;assignments=$assign})} 'CO1 was reworded'
Reject {Set-BookStudioOutcomeAnalysis -DatabasePath $db -JobId $draftJob.id -Request ([pscustomobject]@{text=$catalog;assignments=$assign;confirm=$false;reviewedBy='Fixture ID';reason='Reviewed'})} 'Confirm that you reviewed'
Reject {Set-BookStudioOutcomeAnalysis -DatabasePath $db -JobId $draftJob.id -Request ([pscustomobject]@{text=$catalog;assignments=$assign;confirm=$true;reviewedBy='';reason='Reviewed'})} 'Enter your name'
$approved=Set-BookStudioOutcomeAnalysis -DatabasePath $db -JobId $draftJob.id -Request ([pscustomobject]@{text=$catalog;assignments=$assign;confirm=$true;reviewedBy='Fixture ID';reason='Reviewed against the draft'})
Check ($approved.status -eq 'Approved' -and $approved.workflowStage -eq 'format-review') "Approval releases the book to planning (got '$($approved.status)'/'$($approved.workflowStage)')."
Check ((Get-BookStudioJob -DatabasePath $db -JobId $draftJob.id).status -eq 'Ready') 'Approval must leave the book ready to run, not claim a runner is queued.'
# A book whose runner never started is stranded: it reports generation in
# progress, so the client hides the button that would start it.
$null=Update-BookStudioJob -DatabasePath $db -JobId $draftJob.id -Update { param($j) $j.status='Queued' }
# Update-BookStudioJob always stamps updatedAt, so the record is aged directly.
$aged=Read-BookStudioDatabase -DatabasePath $db
(@($aged.jobs | Where-Object id -eq $draftJob.id)[0]).updatedAt=(Get-Date).AddMinutes(-5).ToString('s')
Write-BookStudioDatabase -DatabasePath $db -Database $aged
Check (Repair-BookStudioParkedJobs -DatabasePath $db) 'A book stranded as Queued with no runner was not repaired.'
Check ((Get-BookStudioJob -DatabasePath $db -JobId $draftJob.id).status -eq 'Ready') 'The repair did not clear the runner status from a stranded book.'
# A scaffold already written is the normal state at format review: the runner
# writes the folder, stops, and waits for a person to approve the format.
# Treating that as still generating left real books stuck for days, reported as
# generating, refusing their own deletion, with nothing a designer could do.
# On a copy, so the book this suite is still working with is left alone.
$parkedDb=Read-BookStudioDatabase -DatabasePath $db
$parkedCopy=(@($parkedDb.jobs | Where-Object id -eq $draftJob.id)[0]) | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$parkedCopy.id='parkedcopy'
$parkedCopy.status='Queued'
$parkedCopy.workflowStage='format-review'
$parkedCopy.runnerProcessId=$null
$parkedCopy.outputFolder=(Join-Path $fixture 'outputs/parkedcopy')
$parkedCopy.updatedAt=(Get-Date).AddMinutes(-5).ToString('s')
$parkedDb.jobs=@($parkedDb.jobs) + $parkedCopy
Write-BookStudioDatabase -DatabasePath $db -Database $parkedDb
Check (Repair-BookStudioParkedJobs -DatabasePath $db) 'A book parked at format review with its scaffold written was not repaired.'
Check ((Get-BookStudioJob -DatabasePath $db -JobId 'parkedcopy').status -eq 'Ready') 'A book with a written scaffold must stop reporting itself as generating.'
$null=Remove-BookStudioJob -DatabasePath $db -JobId 'parkedcopy'
Check (-not (Get-BookStudioJob -DatabasePath $db -JobId 'parkedcopy')) 'A book parked at format review must be deletable once it is no longer generating.'
# A book that was queued a moment ago is still starting; leave it alone.
$null=Update-BookStudioJob -DatabasePath $db -JobId $draftJob.id -Update { param($j) $j.status='Queued'; $j.updatedAt=(Get-Date).ToString('s') }
Check (-not (Repair-BookStudioParkedJobs -DatabasePath $db)) 'The repair raced a book that had only just been queued.'
Check ((Get-BookStudioJob -DatabasePath $db -JobId $draftJob.id).status -eq 'Queued') 'A book that was just queued must keep its status while its runner starts.'
$null=Update-BookStudioJob -DatabasePath $db -JobId $draftJob.id -Update { param($j) $j.status='Ready' }
$revisionPath=Join-Path $draftJob.sourceContextPath 'book-studio-outcomes.json'
Check (Test-Path -LiteralPath $revisionPath) 'The approved amendment was not written beside the upload.'
$revised=Import-CourseSpec -Path $draftJob.specPath
Check (@($revised.weeks[0].modules | ForEach-Object {$_.objectiveId}) -join ',' -eq 'LO1.1,LO1.2') "The generator reads the approved outcomes back for chapter 1 (got '$(@($revised.weeks[0].modules | ForEach-Object {$_.objectiveId}) -join ',')')."
Check ($revised.outcomeRevision.reviewedBy -eq 'Fixture ID' -and $revised.outcomeRevision.origin -eq 'curriculum-draft-analysis') 'The amendment records who approved it and which review produced it.'
$outcomeFolder=Join-Path $draftJob.sourceContextPath 'outcome-analysis'
Check (Test-Path -LiteralPath (Join-Path $outcomeFolder 'QA1000 - Course Outcomes.md')) 'The approved review record was not written.'
# The Word export is a documented deliverable, and its failure path is a
# fallback that records the error rather than losing the approval. Assert the
# file itself, or a missing Export-MarkdownToDocx passes as a graceful note.
$outcomeDocx=Join-Path $outcomeFolder 'QA1000 - Course Outcomes.docx'
Check (Test-Path -LiteralPath $outcomeDocx) "The approved review record was not exported to Word. Recorded documents: $(@($approved.documents | ForEach-Object {$_.name}) -join ' | ')"
Check ((Get-Item -LiteralPath $outcomeDocx).Length -gt 0 -and -not @($approved.documents | Where-Object {$_.name -like 'Word export unavailable*'}).Count) 'The Word export reported a failure instead of producing the document.'
$reusable=Join-Path $outcomeFolder 'QA1000 - Ebook Course File.md'
Check (Test-Path -LiteralPath $reusable) 'The reusable ebook-ready course file was not written.'
$reused=Import-CourseSpec -Path $reusable
Check (@($reused.weeks).Count -eq 2 -and $reused.weeks[1].modules[0].subObjectives -contains 'Assign an owner to each workflow step.') 'The generated course file does not read back as the approved outcomes.'
Reject {Set-BookStudioOutcomeAnalysis -DatabasePath $db -JobId $draftJob.id -Request ([pscustomobject]@{text=$catalog;assignments=$assign;confirm=$true;reviewedBy='Fixture ID';reason='Again'})} 'runs once, before the book is planned'

# Required readings and system research were mutually exclusive: a book could
# have the document's assigned readings, locked and cited, or the generator's
# own research, never both. Permitting research does not loosen the reading
# list; every gate on it still binds.
$upload=@{files=@(@{name='draft.docx';contentBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('fixture'))});courseDocumentKind='EbookReady'}
$upload.sourceMode='Assigned'; $upload.allowAdditionalResearch=$true
$validated=& $studio {param($r) Test-BookStudioUploadRequest $r} ([pscustomobject]$upload)
Check ($validated.allowAdditionalResearch) 'Research permission must survive intake validation.'
foreach($mode in @('UploadedOnly','Discovery')){
    $upload.sourceMode=$mode
    try { & $studio {param($r) Test-BookStudioUploadRequest $r} ([pscustomobject]$upload) | Out-Null; throw "FAIL: $mode must not accept research permission." }
    catch { Check ($_.Exception.Message -match 'required-readings source policy') "Research permission is refused for $mode." }
}
$upload.sourceMode='Assigned'; $upload.allowAdditionalResearch=$false
Check (-not (& $studio {param($r) Test-BookStudioUploadRequest $r} ([pscustomobject]$upload)).allowAdditionalResearch) 'Required readings alone remain the default.'

# The runner reads these two, so permitting research must clear them or the
# setting is saved and ignored.
$researchJob=New-BookStudioJob -ProjectRoot $fixture -DatabasePath $db -Request ([pscustomobject]@{title='Research Fixture';courseCode='QA1000';primaryFileIndex=0;courseDocumentKind='EbookReady';sourceMode='Assigned';allowAdditionalResearch=$true;skipResearch=$true;skipOpenStaxFetch=$true;requiredSources="All chapters:`nhttps://example.org/reading";files=@($first,$second)})
Check ($researchJob.options.allowAdditionalResearch) 'The job must record that research is permitted.'
Check ((-not $researchJob.options.skipResearch) -and (-not $researchJob.options.skipOpenStaxFetch)) 'Permitting research must override the skip flags the client sends for non-discovery policies.'
$plainJob=New-BookStudioJob -ProjectRoot $fixture -DatabasePath $db -Request ([pscustomobject]@{title='Uploaded Fixture';courseCode='QA1000';primaryFileIndex=0;courseDocumentKind='EbookReady';sourceMode='UploadedOnly';files=@($first,$second)})
Check ($plainJob.options.skipResearch -and $plainJob.options.skipOpenStaxFetch) 'Uploaded-only books must still skip research.'

# The drafter is told both halves: cite every assigned reading, and anything
# researched is added on top rather than in place of them.
$studioSource=Get-Content -LiteralPath (Join-Path $root 'lib/BookStudio.psm1') -Raw -Encoding UTF8
Check ($studioSource -match 'ADDITIONAL RESEARCH:') 'The drafting prompt must state the additional-research boundary.'
Check ($studioSource -match 'never in place of them') 'The boundary must keep assigned readings mandatory.'
Check ($studioSource -match '\$allowResearch=\[bool\]\$job\.options\.allowAdditionalResearch') 'Network access must follow the research permission.'
Check ($studioSource -match 'if\(\(-not \$allowResearch\) -and \$job\.options\.sourceMode -in @\(.UploadedOnly.,.Assigned.\)\)') 'A book permitted to research must not be network-blocked.'

$chapter1=[pscustomobject]@{number=1;title='Office Records';focus='Office records naming';learningTargets=@('Organize office records using clear naming rules.');learningTargetRecords=@([pscustomobject]@{objectiveId='';objective='Organize office records using clear naming rules.'})}
$plan=[pscustomobject]@{sourceMode='UploadedOnly';chapters=@($chapter1)}
# Any source-discovery or web call is a test failure, not a stubbed success.
$sources=& $ebook {
    param($p,$ctx)
    function Find-OpenStaxPages {throw 'Unexpected external discovery'}
    function Get-OpenStaxPageContent {throw 'Unexpected external fetch'}
    function Invoke-WebRequest {throw 'Unexpected web request'}
    function Invoke-RestMethod {throw 'Unexpected REST request'}
    Resolve-EbookSources -Plan $p -SourceContext $ctx -SourceMapPath 'deliberately-absent.json' -SourceMode UploadedOnly
} $plan $context
Check (@($sources).Count -eq 1 -and @($sources[0].openStax).Count -eq 0 -and @($sources[0].researchCandidates).Count -eq 0) 'Uploaded-only source resolution used external sources.'
Check (@($sources[0].sourceContext | Where-Object {$_.sourceFile -match 'book-studio-brief'}).Count -eq 0) 'Production notes were treated as academic citation evidence.'
Check (@($sources[0].sourceContext | Where-Object sourceFile -eq $job.specPath).Count -eq 0) 'Blueprint was treated as academic evidence.'
Reject { & $ebook { param($p,$ctx) $ctx.files=@($ctx.files | Where-Object isCourseSpec); $ctx.chunks=@($ctx.chunks | Where-Object sourceFile -eq $ctx.files[0].path); Resolve-EbookSources -Plan $p -SourceContext $ctx -SourceMapPath 'absent.json' -SourceMode UploadedOnly } $plan ($context | ConvertTo-Json -Depth 15 | ConvertFrom-Json) } 'No uploaded teaching content'
Check (& $ebook {param($p,$s,$c) Test-EbookUploadedSourceEvidence $p $s $c} $plan $sources[0] $context) 'Valid uploaded evidence failed.'
Check ((& $ebook {param($chapter,$chapterSources) Get-SourceFitSignals -Chapter $chapter -ChapterSources $chapterSources} $chapter1 $sources[0]).status -eq 'WARNING') 'Uploaded-only source policy incorrectly blocked on external source-fit coverage.'
$badSources=$sources[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$badSources.sourceContext[0].excerpt+=' invented evidence'
Check (-not (& $ebook {param($p,$s,$c) Test-EbookUploadedSourceEvidence $p $s $c} $plan $badSources $context)) 'Invented chunk evidence passed.'
Check ((& $ebook {param($p,$s,$c) Get-EbookUploadedSourceReview -Plan $p -Sources $s -SourceContext $c -Markdown '[outside](https://example.org)'} $plan $sources $context).status -eq 'FAIL') 'External citation passed uploaded-only gate.'
$registry=& $ebook {param($s) New-SourceRegistry -Sources $s} $sources
$citations=& $ebook {param($s,$r) Get-ChapterCitationModel -ChapterSources $s -SourceRegistry $r} $sources[0] $registry
Check ($citations.sourceContext.Count -ge 1 -and @($citations.sourceContext | Where-Object {$_.url}).Count -eq 0) 'Provided-document citations are missing or invented URLs.'
'changed after intake' | Add-Content -LiteralPath $job.uploadedFiles[1].path
Check (-not (& $ebook {param($p,$s,$c) Test-EbookUploadedSourceEvidence $p $s $c} $plan $sources[0] $context)) 'Changed uploaded files passed the source hash gate.'

$output=Join-Path $fixture 'format';New-Item -ItemType Directory -Path $output | Out-Null
$plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $output 'ebook-plan.json') -Encoding UTF8
Update-BookStudioJob -DatabasePath $db -JobId $job.id -Update {param($j) $j.outputFolder=$output;$j.status='Completed'}
$job=Get-BookStudioJob -DatabasePath $db -JobId $job.id
$null=New-BookStudioFormatPreview -Job $job -OutputFolder $output
Check ((Get-Content -LiteralPath (Join-Path $output 'book-format-preview.html') -Raw) -match 'Objective mapping ID requires verification') 'A valid objective with a missing mapping ID incorrectly blocked the format preview.'
$before=& $studio {param($j) Get-BookStudioFormatState $j} $job
$null=Set-BookStudioFormatReview -DatabasePath $db -JobId $job.id -ProjectRoot $fixture -Action request-changes -Layout large-text -Notes 'Check the larger text layout.'
$job=Get-BookStudioJob -DatabasePath $db -JobId $job.id
$after=& $studio {param($j) Get-BookStudioFormatState $j} $job
Check ($before.fingerprint -ne $after.fingerprint -and $after.layout -eq 'large-text') 'Format edits did not change the preview/fingerprint.'
Check ((Get-Content -LiteralPath (Join-Path $output 'book-format-preview.html') -Raw) -match 'font-size: 14pt') 'Larger layout was not applied to HTML.'
Reject {Set-BookStudioFormatReview -DatabasePath $db -JobId $job.id -ProjectRoot $fixture -Action approve -Layout large-text -PreviewFingerprint $before.fingerprint -NotesResolved $true} 'preview changed'
Reject {Set-BookStudioFormatReview -DatabasePath $db -JobId $job.id -ProjectRoot $fixture -Action approve -Layout large-text -PreviewFingerprint $after.fingerprint} 'additional format requests'
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force
$ebook=Get-Module EbookGenerator
$word=Join-Path $output 'layout.docx'
& $ebook {param($p,$o) Export-MarkdownToDocx -Markdown "# Chapter 1: Layout fixture`n`nUse clear records." -Path $p -AssetRoot $o} $word $output
Check ((& $ebook {param($p) Get-EbookDocxArtifactIssues -Path $p} $word).status -eq 'PASS') 'Word export did not match the per-book format contract.'
$job.formatReview.status='Approved';$job.formatReview.fingerprint=$after.fingerprint
& $studio {param($j,$r) Assert-BookStudioGenerationReady $j $r} $job $fixture
Check $true 'Valid preview approval rejected.'
'<!-- changed -->' | Add-Content -LiteralPath (Join-Path $output 'book-format-preview.html')
Reject {& $studio {param($j,$r) Assert-BookStudioGenerationReady $j $r} $job $fixture} 'outdated approval'

$wrapped="Error: Your access token could not be refreshed because your refresh token was already used. Please log`nout and sign in again."
Check ((& $studio {param($t) Get-BookStudioCodexFailure $t} $wrapped).kind -eq 'authentication') 'Refresh-token failure not classified.'
$errorLog=Join-Path $fixture 'wrapped.log';$wrapped | Set-Content -LiteralPath $errorLog
Check ((& $studio {param($p) Get-BookStudioAiLogPreview -Path $p} $errorLog) -match 'out and sign in again') 'Wrapped recovery text was lost.'
Check ((& $studio {Get-BookStudioCodexFailure '429 rate limit'}).kind -eq 'quota') 'Quota classification missing.'
Check ((& $studio {Get-BookStudioCodexFailure 'Connection timed out'}).kind -eq 'timeout') 'Timeout classification missing.'
$command='C:\fixture\codex.exe'
$identity=& $studio {param($c) Get-BookStudioConnectionIdentity $c} $command
$record=[pscustomobject]@{status='PASS';checkedAt=(Get-Date).ToString('o');identity=$identity}
& $studio {param($r,$v) Set-BookStudioConnectionResult $r $v} $fixture $record
Check ((& $studio {param($r,$c) Get-BookStudioConnectionResult $r $c} $fixture $command).status -eq 'PASS') 'Current probe proof rejected.'
Check (-not (& $studio {param($r) Get-BookStudioConnectionResult $r 'different.exe'} $fixture)) 'Connection proof transferred to another executable.'
$record.checkedAt=(Get-Date).AddMinutes(-11).ToString('o')
& $studio {param($r,$v) Set-BookStudioConnectionResult $r $v} $fixture $record
Check (-not (& $studio {param($r,$c) Get-BookStudioConnectionResult $r $c} $fixture $command)) 'Expired probe still reported connected.'

# A designer was told "Run Test connection successfully" moments after doing
# it: the proof lasts ten minutes, and the agent's background check shares the
# record, so a slow check on the laptop replaced their pass with a timeout.
# Steps now test for themselves when there is no recent pass, and a timeout
# never replaces one. Codex itself is never called: the process is a stand-in.
$fresh=[pscustomobject]@{status='PASS';checkedAt=(Get-Date).ToString('o');identity=$identity;message='ok'}
& $studio {param($r,$v) Set-BookStudioConnectionResult $r $v} $fixture $fresh
$afterTimeout=& $studio {
    param($r,$c)
    function Resolve-BookStudioCodexCommand { [pscustomobject]@{Source=$c} }
    function Get-BookStudioCodexStatus { 'status' }
    # Stands in for a Codex that does not answer within the limit.
    function Start-Process { [Diagnostics.Process]::Start((New-Object Diagnostics.ProcessStartInfo -Property @{FileName='powershell.exe';Arguments='-NoProfile -Command Start-Sleep -Seconds 20';WindowStyle='Hidden';UseShellExecute=$false;RedirectStandardError=$false})) }
    $null=Test-BookStudioCodexConnection -ProjectRoot $r -TimeoutSeconds 1
    Get-BookStudioConnectionResult $r $c
} $fixture $command
Check ($afterTimeout.status -eq 'PASS' -and $afterTimeout.message -eq 'ok') 'A connection test that timed out replaced a recent pass.'
$stale=[pscustomobject]@{status='FAIL';kind='timeout';checkedAt=(Get-Date).ToString('o');identity=$identity;message='timed out'}
& $studio {param($r,$v) Set-BookStudioConnectionResult $r $v} $fixture $stale
$afterSecondTimeout=& $studio {
    param($r,$c)
    function Resolve-BookStudioCodexCommand { [pscustomobject]@{Source=$c} }
    function Get-BookStudioCodexStatus { 'status' }
    function Start-Process { [Diagnostics.Process]::Start((New-Object Diagnostics.ProcessStartInfo -Property @{FileName='powershell.exe';Arguments='-NoProfile -Command Start-Sleep -Seconds 20';WindowStyle='Hidden';UseShellExecute=$false})) }
    $null=Test-BookStudioCodexConnection -ProjectRoot $r -TimeoutSeconds 1
    Get-BookStudioConnectionResult $r $c
} $fixture $command
Check ($afterSecondTimeout.status -eq 'FAIL' -and $afterSecondTimeout.kind -eq 'timeout') 'Without a pass to protect, a timeout must still be recorded.'

# With no recent pass the step tests for itself, once, and goes ahead on a pass.
$working=& $studio {
    param($r,$c,$id)
    $script:tests=0
    function Test-BookStudioCodexConnection { param($ProjectRoot,$TimeoutSeconds) $script:tests++; Set-BookStudioConnectionResult $ProjectRoot ([pscustomobject]@{status='PASS';checkedAt=(Get-Date).ToString('o');identity=$id;message='tested now'}) }
    $got=Get-BookStudioWorkingConnection -ProjectRoot $r -CommandPath $c
    $again=Get-BookStudioWorkingConnection -ProjectRoot $r -CommandPath $c
    [pscustomobject]@{first=$got;tests=$script:tests;again=$again}
} $fixture $command $identity
Check ($working.first.status -eq 'PASS' -and $working.first.message -eq 'tested now') 'A step with no recent pass must test the connection itself and go ahead.'
Check ($working.tests -eq 1 -and $working.again.status -eq 'PASS') 'A recent pass must be used as it is, not tested again.'
# And when the test fails, the step says why, not "run Test connection".
$quota=[pscustomobject]@{status='FAIL';kind='quota';checkedAt=(Get-Date).ToString('o');identity=$identity;message='Codex reported a usage or rate limit.'}
$refusal=& $studio {param($v) Get-BookStudioConnectionRefusal -Connection $v -Action 'AI generation'} $quota
Check ($refusal -match 'usage or rate limit' -and $refusal -notmatch 'Run Test connection') 'A refusal must give the reason from the test that just ran.'
foreach($file in @('lib/BookStudioFormat.ps1','lib/BookStudioOutcomeAnalysis.ps1','lib/BookStudio.psm1')){
    $text=Get-Content -LiteralPath (Join-Path $root $file) -Raw -Encoding UTF8
    Check ($text -notmatch 'Run Test connection successfully|Test the Codex connection successfully') "$file still sends the designer to test the connection by hand."
    Check ($text -notmatch 'Get-BookStudioConnectionResult -ProjectRoot \$ProjectRoot -CommandPath \$(command|codexCommand)\.Source\s*\r?\n\s*if ?\(') "$file still gates on the stored result without testing."
}
Check ((Get-Content -LiteralPath (Join-Path $root 'cloud-book-runner.ps1') -Raw) -match 'Test-BookStudioCodexConnection -ProjectRoot \$ProjectRoot -TimeoutSeconds 45') 'The agent''s background check must allow the longest test time.'
Remove-Item -LiteralPath (Join-Path $fixture '.bookstudio/codex-connection.json') -Force -ErrorAction SilentlyContinue
$configured=Join-Path $fixture 'override.exe';Copy-Item -LiteralPath (Join-Path $PSHOME 'powershell.exe') -Destination $configured
$configured | Set-Content -LiteralPath (Join-Path $fixture 'codex-path.txt') -Encoding UTF8
Check ((Resolve-BookStudioCodexCommand -ProjectRoot $fixture).Source -eq $configured) 'Saved executable override did not take precedence.'

# npm installs Codex as shell wrappers. Book Studio starts Codex directly, so a
# wrapper must resolve to the native binary npm vendored inside the package.
$npmRoot=Join-Path $fixture 'npm'
$vendorBin=Join-Path $npmRoot 'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin'
New-Item -ItemType Directory -Path $vendorBin -Force | Out-Null
$nativeCodex=Join-Path $vendorBin 'codex.exe'
Copy-Item -LiteralPath (Join-Path $PSHOME 'powershell.exe') -Destination $nativeCodex
foreach($wrapperName in @('codex','codex.cmd','codex.ps1')){
    $wrapper=Join-Path $npmRoot $wrapperName
    'wrapper that launches node' | Set-Content -LiteralPath $wrapper -Encoding UTF8
    Check ((& $studio {param($p) Resolve-BookStudioNativeCodexExecutable -Path $p} $wrapper) -eq $nativeCodex) "The npm wrapper $wrapperName did not resolve to the native codex.exe."
    $wrapper | Set-Content -LiteralPath (Join-Path $fixture 'codex-path.txt') -Encoding UTF8
    $resolvedCommand=Resolve-BookStudioCodexCommand -ProjectRoot $fixture
    Check ($resolvedCommand.Source -eq $nativeCodex -and $resolvedCommand.Discovery -match 'npm wrapper') "A configured $wrapperName was not replaced by the native executable."
}
# A wrapper inside the package (.../@openai/codex/bin) resolves the same way.
$packageBin=Join-Path $npmRoot 'node_modules\@openai\codex\bin'
New-Item -ItemType Directory -Path $packageBin -Force | Out-Null
$packageWrapper=Join-Path $packageBin 'codex.js'
'#!/usr/bin/env node' | Set-Content -LiteralPath $packageWrapper -Encoding UTF8
Check ((& $studio {param($p) Resolve-BookStudioNativeCodexExecutable -Path $p} $packageWrapper) -eq $nativeCodex) 'A wrapper inside the Codex package did not resolve to the native executable.'
# Without a vendored binary the wrapper is still returned, so the app can explain itself.
$lonelyWrapper=Join-Path $fixture 'lonely-codex.cmd'
'wrapper with no package' | Set-Content -LiteralPath $lonelyWrapper -Encoding UTF8
Check ($null -eq (& $studio {param($p) Resolve-BookStudioNativeCodexExecutable -Path $p} $lonelyWrapper)) 'A wrapper with no vendored binary must not resolve.'
$lonelyWrapper | Set-Content -LiteralPath (Join-Path $fixture 'codex-path.txt') -Encoding UTF8
$lonelyResult=Resolve-BookStudioCodexCommand -ProjectRoot $fixture
# Either the wrapper itself (nothing native anywhere) or a native executable
# found elsewhere on this machine; never nothing at all.
Check ($lonelyResult -and ($lonelyResult.Source -eq $lonelyWrapper -or [IO.Path]::GetExtension($lonelyResult.Source) -eq '.exe')) 'A wrapper with no vendored binary must still resolve to a usable Codex command.'
$configured | Set-Content -LiteralPath (Join-Path $fixture 'codex-path.txt') -Encoding UTF8
[pscustomobject]@{status='PASS';assertions=$script:checks;fixture=$fixture;liveCodex='Not invoked';productionBooksChanged=$false} | ConvertTo-Json
