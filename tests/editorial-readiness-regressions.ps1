$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib/EbookReadiness.ps1')
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force
$module=Get-Module EbookGenerator
$script:checks=0
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};$script:checks++}
Check ((Test-EbookEditorialThresholds 8 4).status -eq 'PASS') 'Exact target boundary must pass.'
foreach($grade in @(8.1,8.8,9.9,10.7,12.2,12.5,13)) { Check ((Test-EbookEditorialThresholds $grade 0).status -eq 'FAIL') "Grade $grade must block, not warn." }
foreach($rate in @(4.1,5.8,6,10)) { Check ((Test-EbookEditorialThresholds 7 $rate).status -eq 'FAIL') "Passive rate $rate must block." }
foreach($bad in @($null,'','not measured','NaN','Infinity')) {
    Check ((Test-EbookEditorialThresholds $bad 0).status -eq 'FAIL') 'Invalid grade passed.'
    Check ((Test-EbookEditorialThresholds 7 $bad).status -eq 'FAIL') 'Invalid passive measurement passed.'
}
$count=& $module { @(Get-PassiveVoiceMatches 'The form was checked. The form was checked. The form was checked.').Count }
Check ($count -eq 3) 'Repeated passive constructions were deduplicated.'
$hash='A'*64
$pass=[pscustomobject]@{name='current_editorial';status='PASS'}
$human=[pscustomobject]@{name='generation_gate';status='WARNING'}
$warning=[pscustomobject]@{name='chapter_5_readability';status='WARNING'}
$ready=Get-EbookDeliveryReadiness -Checks @($pass,$human) -DocxSha256 $hash
Check ($ready.draftReadyForReview -and -not $ready.publicationReady -and $ready.pendingApprovals.Count -eq 2) 'A clean review draft must not imply publication approval.'
Check (-not (Get-EbookDeliveryReadiness -Checks @($pass,$warning)).draftReadyForReview) 'A technical warning was hidden by an overall completion state.'
Check (-not (Get-EbookDeliveryReadiness -Checks @()).draftReadyForReview) 'No checks passed as ready.'
Check (-not (Get-EbookDeliveryReadiness -Checks @([pscustomobject]@{name='export';status='UNKNOWN'})).draftReadyForReview) 'Unknown check status passed.'
function Approvals { [pscustomobject]@{academic=[pscustomobject]@{status='Approved';reviewer='Fixture academic reviewer';reviewedAt='2026-01-01';docxSha256=$hash};permissions=[pscustomobject]@{status='Approved';reviewer='Fixture permissions reviewer';reviewedAt='2026-01-01';docxSha256=$hash}} }
$approval=Approvals
Check ((Get-EbookDeliveryReadiness -Checks @($pass) -Approvals $approval -DocxSha256 $hash).publicationReady) 'Valid fixture approvals did not pass.'
$approval=Approvals;$approval.academic.docxSha256='B'*64
Check (-not (Get-EbookDeliveryReadiness -Checks @($pass) -Approvals $approval -DocxSha256 $hash).publicationReady) 'An approval for another Word version passed.'
$approval=Approvals;$approval.permissions.reviewer=''
Check (-not (Get-EbookDeliveryReadiness -Checks @($pass) -Approvals $approval -DocxSha256 $hash).publicationReady) 'Anonymous approval passed.'
$approval=Approvals;$approval.academic.reviewedAt='2999-01-01'
Check (-not (Get-EbookDeliveryReadiness -Checks @($pass) -Approvals $approval -DocxSha256 $hash).publicationReady) 'Future approval passed.'
Check (-not (Get-EbookDeliveryReadiness -Checks @($warning) -Approvals (Approvals) -DocxSha256 $hash).publicationReady) 'Human approval waived a technical finding.'
# Preserve actual defective excerpts as a portable fixture. A clean checkout
# must not need a developer's ignored historical dist/v5 package to run tests.
$old=Get-Content (Join-Path $PSScriptRoot 'fixtures/gm1025-pre-v6-editorial.md') -Raw -Encoding UTF8
$oldChapter=[regex]::Match($old,'(?ms)^# Chapter 5:.*').Value
$oldStyle=& $module {param($text) Get-UmaWritingStyleGuideMetrics $text} $oldChapter
Check ($oldStyle.status -eq 'FAIL' -and $oldStyle.fleschKincaidGrade -gt 8) 'The actual old high-reading-level excerpt still passed.'
Check (@((Test-EbookPublicationTemplate $old).issues -match 'embedded Markdown').Count -gt 0) 'The actual old merged heading was not identified.'
$wordIssues=& $module {
    [xml]$word=ConvertTo-WordDocumentXml -Markdown "# Chapter 1: Example`n`n### Balance### Balance and Feedback`n`nUse clear facts."
    [xml]$styles=Get-WordStylesXml
    @(Get-EbookWordTemplateIssues $styles $word)
}
Check (($wordIssues -join ' ') -match 'merged Markdown') 'Merged heading in actual Word XML passed.'
# Isolated generated fixtures; no source books or delivered artifacts are edited.
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ebook-readiness-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
Check ((Get-EbookPackageQaStatus $fixture) -eq 'FAIL') 'Missing QA reports passed.'
'{"status":"PASS"}' | Set-Content (Join-Path $fixture 'quality-report.json') -Encoding UTF8
Check ((Get-EbookPackageQaStatus $fixture) -eq 'FAIL') 'One available PASS hid missing reports.'
'not json' | Set-Content (Join-Path $fixture 'publishing-editor-report.json') -Encoding UTF8
Check ((Get-EbookPackageQaStatus $fixture) -eq 'FAIL') 'Malformed report passed.'
Write-Output "PASS: $script:checks editorial/readiness regression assertions. Fixture only: $fixture"
