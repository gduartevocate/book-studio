$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
$module=Get-Module EbookGenerator
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('book-readings-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$script:checks=0
function Check([bool]$Ok,[string]$Message){if(-not $Ok){throw $Message};$script:checks++;Write-Verbose "Passed $script:checks : $Message"}
function Reject([scriptblock]$Action,[string]$Pattern){$caught=$false;try{& $Action | Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$caught=$true};Check $caught "Expected rejection: $Pattern"}
function SaveJson($Value,$Name){$Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $fixture $Name) -Encoding UTF8}
$list=@'
Week1
[First](https://example.org/one/)-
Week 2:
[Second](https://example.org/two_(test)) - Chapter 7 controls
[First again](https://example.org/one/)
All chapters:
https://example.org/shared
'@
$readings=@(ConvertFrom-EbookReadingList $list)
Check ($readings.Count -eq 3 -and $readings[0].url -eq 'https://example.org/one/' -and ($readings[0].chapters -join ',') -eq '1,2') 'Markdown punctuation or deduplication lost the URL/assignment.'
Check ($readings[1].url -eq 'https://example.org/two_(test)' -and $readings[1].title -match 'Chapter 7 controls') 'Parenthesized URL or chapter guidance lost.'
$roundtrip=@(ConvertFrom-EbookReadingList (ConvertTo-EbookReadingListText $readings))
Check (($readings | ConvertTo-Json -Depth 10 -Compress) -eq ($roundtrip | ConvertTo-Json -Depth 10 -Compress)) 'Saving extracted readings changes the assignments.'
Check (@(ConvertFrom-EbookReadingList "Week 1:`nOpenStax title only")[0].url -eq '') 'A title alone was treated as a retrieved URL.'
Reject {ConvertFrom-EbookReadingList 'https://username:secret@example.org/path'} 'Invalid reading'
foreach($url in @('file:///C:/secret','http://127.0.0.1','https://10.1.2.3','http://[::1]','http://192.168.1.1','https://example.org:8443/x')) {
    Reject { & $module {param($u) Assert-EbookPublicReadingUrl $u} $url } 'public HTTP|Local/private'
}
Reject { & $module {param($f) Read-EbookRequiredSourceUrl 'https://openstax.org/details/books/principles-financial-accounting' $f} $fixture } 'landing page'
# A real DOCX ZIP fixture: hyperlinks live in relationships, not displayed text.
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$docx=Join-Path $fixture 'blueprint.docx'
$zip=[IO.Compression.ZipFile]::Open($docx,[IO.Compression.ZipArchiveMode]::Create)
try {
    $parts=@{
        'word/document.xml'='<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:r><w:t>Week1</w:t></w:r></w:p><w:p><w:hyperlink r:id="r1"><w:r><w:t>Reading</w:t></w:r></w:hyperlink><w:r><w:t> - </w:t></w:r><w:hyperlink r:id="r2"><w:r><w:t>Reading</w:t></w:r></w:hyperlink></w:p><w:p><w:r><w:t>Week 2</w:t></w:r></w:p><w:p><w:fldSimple w:instr="HYPERLINK &quot;https://example.org/field&quot;"><w:r><w:t>Field reading</w:t></w:r></w:fldSimple></w:p></w:body></w:document>'
        'word/_rels/document.xml.rels'='<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.org/one" TargetMode="External"/><Relationship Id="r2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.org/two" TargetMode="External"/></Relationships>'
    }
    foreach($name in $parts.Keys){$writer=[IO.StreamWriter]::new($zip.CreateEntry($name).Open());try{$writer.Write($parts[$name])}finally{$writer.Dispose()}}
} finally {$zip.Dispose()}
$extracted=@(ConvertFrom-EbookReadingList (Get-EbookBlueprintReadingText $docx))
Check ($extracted.Count -eq 3 -and $extracted[0].url -eq 'https://example.org/one' -and $extracted[1].url -eq 'https://example.org/two' -and $extracted[2].chapters[0] -eq 2) 'Word hyperlinks/fields with identical labels lost their targets.'
$plan=[pscustomobject]@{sourceMode='Assigned';requiredReadings=@(ConvertFrom-EbookReadingList "All chapters:`n[Required reading](https://example.org/article)");chapters=@([pscustomobject]@{number=1;title='Records';focus='records';learningTargets=@('Keep clear records.')})}
SaveJson $plan 'ebook-plan.json'
$report=Update-EbookRequiredSourceEvidence $plan $fixture -ReadSource {param($Url,$WorkFolder) [pscustomobject]@{text=('Verified synthetic teaching text. '*40);resolvedUrl=$Url;contentType='text/plain'}}
Check ($report.status -eq 'PASS' -and $report.readings[0].contentSha256) 'Retrieved text lacks evidence/hash.'
$good="# Chapter 1: Records`n`nApply the reading [1](#chapter-1-note-1).`n`n### Scholarly Sources`n`n1. [Required reading](https://example.org/article).`n"
Check ((Get-EbookRequiredSourceReview $plan $fixture $good).status -eq 'PASS') 'Assigned reading with verified text and body citation failed.'
Check ((Get-EbookRequiredSourceReview $plan $fixture ($good.Replace(' [1](#chapter-1-note-1)',''))).status -eq 'FAIL') 'Bibliography-only usage falsely passed.'
Check ((Get-EbookRequiredSourceReview $plan $fixture ($good+"2. Course blueprint, provided course document.`n")).status -eq 'FAIL') 'Blueprint as scholarly evidence passed.'
Check ((Get-EbookRequiredSourceReview $plan $fixture ($good+"2. [Unassigned](https://example.org/unassigned)`n")).status -eq 'FAIL') 'An unassigned source passed.'
$plan.requiredReadings[0].chapters=@(2)
Check ((Get-EbookRequiredSourceReview $plan $fixture $good).status -eq 'FAIL') 'Reading assigned to another chapter passed.'
$plan.requiredReadings[0].chapters=@(0)
$brief=@(New-EbookRequiredSourceBrief -Plan $plan -OutputFolder $fixture -SourceContext ([pscustomobject]@{chunks=@();files=@()}))
$registry=& $module {param($s) New-SourceRegistry $s} $brief
Check ($registry.items.Count -eq 1 -and $registry.items[0].url -eq 'https://example.org/article' -and $registry.items[0].type -ne 'Provided document') 'Registry substituted a blueprint.'
Check ($brief[0].researchCandidates[0].preview -match 'synthetic teaching text') 'Writer received titles instead of retrieved source text.'
$many=$brief[0] | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$many.researchCandidates=@(1..7 | ForEach-Object {[pscustomobject]@{title="Reading $_";url="https://example.org/$_"}})
$model=& $module {param($s) Get-ChapterCitationModel $s $null} $many
Check ($model.research.Count -eq 7) 'Required readings were silently capped at five.'
'tampered' | Add-Content -LiteralPath (Join-Path $fixture $report.readings[0].contentFile)
Check ((Get-EbookRequiredSourceReview $plan $fixture $good -EvidenceOnly).status -eq 'FAIL') 'Changed source snapshot passed.'
$plan.requiredReadings[0].id='../../outside'
Check ((Get-EbookRequiredSourceReview $plan $fixture $good -EvidenceOnly).status -eq 'FAIL') 'Unsafe source path accepted.'
$badReport=Update-EbookRequiredSourceEvidence $plan $fixture
Check ($badReport.status -eq 'FAIL' -and $badReport.readings[0].detail -match 'identifier') 'Invalid reading id reached the download step.'
# Actual QA findings must be visible, including source requirements changed after export.
SaveJson ([pscustomobject]@{status='FAIL';chapters=@([pscustomobject]@{chapterNumber=1;checks=@([pscustomobject]@{name='numbered_notes';status='FAIL';detail='Missing body citations.'})})}) 'quality-report.json'
$summary=& (Get-Module BookStudio) {param($f) Get-BookStudioQualitySummary $f} $fixture
Check (@($summary.findings | Where-Object name -eq 'numbered_notes').Count -eq 1) 'QA details were discarded.'
Check (@($summary.findings | Where-Object category -eq 'Required sources').Count -gt 0 -and -not $summary.publicationReady) 'Stale cached QA passed changed/missing source evidence.'
$prose="# Chapter 1: Test`n`n## Introduction`n`nWe check the form. We tell the team.`n`n"
$metrics1=& $module {param($m) Get-UmaWritingStyleGuideMetrics $m} $prose
$metrics2=& $module {param($m) Get-UmaWritingStyleGuideMetrics $m} ($prose+"### Scholarly Sources`n`n1. " + ('Extraordinarily complicated bibliographical attribution. '*30))
Check ($metrics1.fleschKincaidGrade -eq $metrics2.fleschKincaidGrade) 'Level-three bibliography polluted learner readability metrics.'
"PASS: $script:checks required-source and QA regression checks. Fixtures: $fixture"
