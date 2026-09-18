$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force -DisableNameChecking
$studio=Get-Module BookStudio
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('bs-outcome-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$checks=0
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Pattern){$caught=$false;try{& $Action | Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$caught=$true};Check $caught "Expected: $Pattern"}
$text="CO1: Organize records.`nLO1.1: Identify records.`nLO1.2: Explain`nrecord ownership.`nCO2: Coordinate handoffs.`nLO2.1: Identify handoffs."
$records=@(ConvertFrom-EbookOutcomeCatalog $text)
Check ($records.Count -eq 5 -and $records[2].objective -eq 'Explain record ownership.') 'Wrapped outcome wording was not preserved.'
Reject {ConvertFrom-EbookOutcomeCatalog ($text+"`nCO1: Duplicate.")} 'Duplicate'
Reject {ConvertFrom-EbookOutcomeCatalog 'LO6.1: Missing parent.'} 'no parent'
Reject {ConvertFrom-EbookOutcomeCatalog 'CO1 missing punctuation'} 'Unrecognized'
Reject {ConvertFrom-EbookOutcomeCatalog ''} 'Paste'
$spec=Join-Path $fixture 'QA1015 Content.txt'
"Week 1 Records`n1. Describe records.`n1.1 Identify records.`nWeek 2 Handoffs`n2. Explain handoffs.`n2.1 Identify handoffs." | Set-Content -LiteralPath $spec -Encoding UTF8
$originalHash=(Get-FileHash -LiteralPath $spec).Hash
$course=Import-CourseSpec $spec
$plan=New-EbookPlan $course
$plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $fixture 'ebook-plan.json') -Encoding UTF8
$job=[pscustomobject]@{outputFolder=$fixture;specPath=$spec;status='Completed';aiRequests=@()}
$request=[pscustomobject]@{text=$text;assignments=@([pscustomobject]@{number=1;ids='CO1'},[pscustomobject]@{number=2;ids='LO1.2, CO2'})}
$preview=& $studio {param($j,$r) Get-BookStudioOutcomeReplacement $j $r} $job $request
Check ($preview.uniqueOutcomes -eq 3 -and $preview.newCount -eq 4) 'Shared outcomes were collapsed or counted incorrectly.'
Check (($preview.chapters[1].records.objectiveId -join ',') -eq 'LO1.2,LO2.1') 'Specific LO/group assignments were lost.'
$request.assignments[0].ids='LO1.1'
Check ((& $studio {param($j,$r) Get-BookStudioOutcomeReplacement $j $r} $job $request).newCount -eq 3) 'Split CO across chapters failed.'
$request.assignments[1].ids='LO2.1'
Reject {& $studio {param($j,$r) Get-BookStudioOutcomeReplacement $j $r} $job $request} 'Unassigned: LO1.2'
$request.assignments[1].ids='CO9'
Reject {& $studio {param($j,$r) Get-BookStudioOutcomeReplacement $j $r} $job $request} 'Unknown outcome'
$request.assignments[1].ids='CO2, LO1.2'
$request.assignments[1].number=1
Reject {& $studio {param($j,$r) Get-BookStudioOutcomeReplacement $j $r} $job $request} 'Missing or duplicate'
$request.assignments[1].number=2
$revision=[pscustomobject]@{schemaVersion=1;reviewedBy='Fixture ID';confirmedAt=(Get-Date).ToString('o');reason='Fixture revision';baseSourceSha256=$originalHash;catalog=$preview.catalog;chapters=$preview.chapters}
$revision | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $fixture 'book-studio-outcomes.json') -Encoding UTF8
$effective=Import-CourseSpec $spec
$fresh=New-EbookPlan $effective
Check ($fresh.chapters[0].learningTargetRecords[0].objectiveId -eq 'LO1.1' -and $effective.outcomeRevision.reviewedBy -eq 'Fixture ID') 'Accepted amendment not used during fresh parsing/planning.'
Check ((Get-FileHash -LiteralPath $spec).Hash -eq $originalHash) 'Original source was modified.'
Check ($effective.weeks[0].courseObjectiveIds[0] -eq 'CO1') 'Parent course mapping lost.'
$sourceRecords=& (Get-Module EbookGenerator) {param($c) Get-EbookObjectiveRecordsFromCourse $c} $effective
Check (@($sourceRecords | Where-Object objectiveId -eq 'LO1.2').Count -eq 2) 'Source traceability lost the shared outcome.'
$revision.baseSourceSha256='stale'
Reject {Set-EbookCourseOutcomeRevision $course $revision} 'original blueprint changed'
Write-Output "PASS: $checks outcome revision, identity, assignment, and source-integrity assertions. Fixture: $fixture"
