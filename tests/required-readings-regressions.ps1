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
Check (@(ConvertFrom-EbookReadingList 'OpenStax title only').Count -eq 1) 'An explicit designer title without a week label was dropped.'
$headings = @(ConvertFrom-EbookReadingList "Week 1: Healthcare Systems, Care Delivery, and Organizational Structures`nhttps://example.org/health`n## Week 2 Technology`nhttps://example.org/technology`n## Reference section`nA real reading needing its URL")
Check ($headings.Count -eq 3 -and $headings[0].chapters[0] -eq 1 -and $headings[1].chapters[0] -eq 2 -and $headings[2].url -eq '') 'Titled headings became readings, assignments were lost, or title-only readings were dropped.'
$objectiveText="Week 1`n1. Describe healthcare settings.`n1.1 Compare settings.`nWeek2`n2. Analyze workflow.`n2.1 Identify handoffs."
Check (@(ConvertFrom-EbookReadingList $objectiveText -Origin Blueprint).Count -eq 0) 'Blueprint objectives became phantom readings.'
$blueprintText=$objectiveText+"`nRequired readings:`nWeek 1`nA title awaiting its URL`nWeek 2`n[Assigned](https://example.org/assigned)`nWeek 3 Workforce design`n3. Develop a workforce plan.`n3.1 Identify roles."
$blueprintReadings=@(ConvertFrom-EbookReadingList $blueprintText -Origin Blueprint)
Check ($blueprintReadings.Count -eq 2 -and $blueprintReadings[0].chapters[0] -eq 1 -and $blueprintReadings[1].chapters[0] -eq 2) 'Explicit reference section lost its titles/URLs or swallowed later objectives.'
$merged=@(Merge-EbookReadingLists $blueprintReadings @(ConvertFrom-EbookReadingList "Week 3:`n[Same source](https://example.org/assigned)`nDesigner title only"))
Check ($merged.Count -eq 3 -and ($merged[1].chapters -join ',') -eq '2,3' -and $merged[2].origin -eq 'Designer') 'Merging designer and blueprint sources lost a title or chapter assignment.'
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
$extracted=@(ConvertFrom-EbookReadingList (Get-EbookBlueprintReadingText $docx) -Origin Blueprint)
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
Set-Content -LiteralPath (Join-Path $fixture 'Test - E-Book.md') -Value $good -Encoding UTF8
SaveJson ([pscustomobject]@{status='FAIL';chapters=@([pscustomobject]@{chapterNumber=1;checks=@([pscustomobject]@{name='numbered_notes';status='FAIL';detail='Missing body citations.'})})}) 'quality-report.json'
$summary=& (Get-Module BookStudio) {param($f) Get-BookStudioQualitySummary $f} $fixture
Check (@($summary.findings | Where-Object name -eq 'numbered_notes').Count -eq 1) 'QA details were discarded.'
Check (@($summary.findings | Where-Object category -eq 'Required sources').Count -gt 0 -and -not $summary.publicationReady) 'Stale cached QA passed changed/missing source evidence.'
$prose="# Chapter 1: Test`n`n## Introduction`n`nWe check the form. We tell the team.`n`n"
$metrics1=& $module {param($m) Get-UmaWritingStyleGuideMetrics $m} $prose
$metrics2=& $module {param($m) Get-UmaWritingStyleGuideMetrics $m} ($prose+"### Scholarly Sources`n`n1. " + ('Extraordinarily complicated bibliographical attribution. '*30))
Check ($metrics1.fleschKincaidGrade -eq $metrics2.fleschKincaidGrade) 'Level-three bibliography polluted learner readability metrics.'
# Get-EbookReadingId stays internal to the module; reach it the same way
# the other module-scope checks in this file do.
function ReadingId([string]$Value) { return & $module { param($v) Get-EbookReadingId $v } $Value }
# A general reading list assigns every source to every chapter. Requiring each
# one in each chapter made a book with 30+ shared readings impossible to pass.
$sharedFolder = Join-Path $fixture 'shared-readings'
New-Item -ItemType Directory -Path (Join-Path $sharedFolder 'source-readings') -Force | Out-Null
$sharedUrls = @('https://example.org/alpha', 'https://example.org/beta', 'https://example.org/gamma')
$sharedReadings = @($sharedUrls | ForEach-Object { [pscustomobject]@{ id = (& $module { param($v) Get-EbookReadingId $v } $_); url = $_; title = $_; chapters = @(0); origin = 'Designer' } })
$pinned = [pscustomobject]@{ id = (& $module { param($v) Get-EbookReadingId $v } 'https://example.org/pinned'); url = 'https://example.org/pinned'; title = 'Pinned to chapter 2'; chapters = @(2); origin = 'Designer' }
$sharedPlan = [pscustomobject]@{ sourceMode = 'Assigned'; chapters = @(1, 2 | ForEach-Object { [pscustomobject]@{ number = $_; title = "Chapter $_"; focus = 'focus'; learningTargets = @('Target.') } }); requiredReadings = @($sharedReadings + $pinned) }
$sharedReport = [pscustomobject]@{ schemaVersion = 1; readings = @(@($sharedReadings + $pinned) | ForEach-Object { [pscustomobject]@{ id = $_.id; url = $_.url; title = $_.title; chapters = @($_.chapters); status = 'Read'; detail = ''; contentFile = "source-readings/$($_.id).txt"; contentSha256 = ''; resolvedUrl = $_.url } }) }
foreach ($record in $sharedReport.readings) {
    $path = Join-Path $sharedFolder $record.contentFile
    Set-Content -LiteralPath $path -Value ('Synthetic teaching text. ' * 40) -Encoding UTF8 -NoNewline
    $record.contentSha256 = (Get-FileHash -LiteralPath $path).Hash
}
$sharedReport | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $sharedFolder 'required-source-report.json') -Encoding UTF8
# Chapter 1 cites one shared reading; chapter 2 cites its pinned reading.
$sharedMarkdown = "# Chapter 1: Chapter 1`n`nTeaching that uses the source [1](#chapter-1-note-1).`n`n### Scholarly Sources`n`n1. [Alpha](https://example.org/alpha).`n`n# Chapter 2: Chapter 2`n`nTeaching that uses the source [1](#chapter-2-note-1).`n`n### Scholarly Sources`n`n1. [Pinned](https://example.org/pinned).`n"
$sharedReview = Get-EbookRequiredSourceReview $sharedPlan $sharedFolder $sharedMarkdown
Check ($sharedReview.status -eq 'PASS') "Shared readings were demanded in every chapter: $($sharedReview.issues -join ' ')"
# A reading pinned to a chapter is still mandatory there.
$missingPinned = $sharedMarkdown.Replace("1. [Pinned](https://example.org/pinned).", "1. [Alpha](https://example.org/alpha).")
Check ((Get-EbookRequiredSourceReview $sharedPlan $sharedFolder $missingPinned).status -eq 'FAIL') 'A reading pinned to a chapter was not required there.'
# A chapter that cites no assigned reading at all is still refused.
$noCitation = "# Chapter 1: Chapter 1`n`nTeaching with no source.`n`n# Chapter 2: Chapter 2`n`nTeaching that uses the source [1](#chapter-2-note-1).`n`n### Scholarly Sources`n`n1. [Pinned](https://example.org/pinned).`n"
$noCitationReview = Get-EbookRequiredSourceReview $sharedPlan $sharedFolder $noCitation
Check ($noCitationReview.status -eq 'FAIL' -and ($noCitationReview.issues -join ' ') -match 'cite at least one assigned reading') 'A chapter citing nothing was allowed.'

# A source that can never be machine-read (video, interactive tool, dataset,
# sign-in page) is marked "(reference only)": cited, never taught from, and
# never a chapter's only reading.
$list = "Week 1:`n[Readable article](https://example.org/read)`n[Orientation video](https://example.org/video) (reference only)`nWeek 2:`n[Tool](https://example.org/tool) (Reference Only)"
$parsed = @(ConvertFrom-EbookReadingList -Text $list)
Check ($parsed.Count -eq 3) "Reference-only lines were dropped (got $($parsed.Count))."
Check (-not $parsed[0].referenceOnly -and $parsed[1].referenceOnly -and $parsed[2].referenceOnly) 'The reference-only marker was not recognized in both spellings.'
Check ($parsed[1].url -eq 'https://example.org/video' -and $parsed[1].title -eq 'Orientation video') 'The marker leaked into the reading title or URL.'
Check ((ConvertTo-EbookReadingListText $parsed) -match '\(reference only\)') 'Saving the list dropped the reference-only marker.'
Check (@(ConvertFrom-EbookReadingList -Text (ConvertTo-EbookReadingListText $parsed) | Where-Object referenceOnly).Count -eq 2) 'The marker did not survive a save and reload.'
Check (@(Merge-EbookReadingLists @() $parsed | Where-Object referenceOnly).Count -eq 2) 'Merging lost the reference-only marker.'

$refPlan = [pscustomobject]@{chapters=@([pscustomobject]@{number=1}); requiredReadings=@(
    [pscustomobject]@{id=(ReadingId 'https://example.org/read');url='https://example.org/read';title='Readable article';chapters=@(1);origin='Designer';referenceOnly=$false},
    [pscustomobject]@{id=(ReadingId 'https://example.org/video');url='https://example.org/video';title='Orientation video';chapters=@(1);origin='Designer';referenceOnly=$true})}
$refFolder = Join-Path $fixture 'reference-only'
New-Item -ItemType Directory -Path $refFolder -Force | Out-Null
$fetched = [Collections.Generic.List[string]]::new()
$refReport = Update-EbookRequiredSourceEvidence $refPlan $refFolder { param($url, $folder) $fetched.Add($url); [pscustomobject]@{text=('Synthetic teaching text. ' * 60); resolvedUrl=$url; contentType='text/html'} }
Check ($refReport.status -eq 'PASS') "A reference-only reading blocked retrieval: $($refReport.issues -join ' ')"
Check (@($fetched).Count -eq 1 -and $fetched[0] -eq 'https://example.org/read') 'A reference-only reading was downloaded anyway.'
Check ((@($refReport.readings | Where-Object status -eq 'Reference only').Count -eq 1)) 'The report did not record the reference-only decision.'

# A site the designer cannot control (403, JavaScript-only, timeout) is skipped
# and reported instead of stopping the book.
$blockedPlan = [pscustomobject]@{sourceMode='Assigned'; chapters=@([pscustomobject]@{number=1;title='Systems';focus='systems';learningTargets=@('Describe the system.')}); requiredReadings=@(
    $refPlan.requiredReadings[0],
    [pscustomobject]@{id=(ReadingId 'https://example.gov/blocked');url='https://example.gov/blocked';title='Agency page';chapters=@(1);origin='Designer';referenceOnly=$false})}
$blockedFolder = Join-Path $fixture 'blocked-source'
New-Item -ItemType Directory -Path $blockedFolder -Force | Out-Null
$blockedReport = Update-EbookRequiredSourceEvidence $blockedPlan $blockedFolder { param($url, $folder) if ($url -match 'blocked') { throw 'The remote server returned an error: (403) Forbidden.' }; [pscustomobject]@{text=('Synthetic teaching text. ' * 60); resolvedUrl=$url; contentType='text/html'} }
Check ($blockedReport.status -eq 'PASS') "An unreachable source still blocked generation: $($blockedReport.issues -join ' ')"
Check ($blockedReport.skippedCount -eq 1 -and ($blockedReport.skipped -join ' ') -match '403') 'The skipped source was not reported with its reason.'
Check ((@($blockedReport.readings | Where-Object status -eq 'Not retrieved').Count -eq 1)) 'An unreachable source was not recorded as Not retrieved.'
Check ((Get-Content -LiteralPath (Join-Path $blockedFolder 'required-source-report.md') -Raw) -match 'could not be read') 'The report does not list skipped readings for the designer.'
# The writer's brief must omit a skipped reading. It has no text file, so
# including it threw "Could not find file ... source-readings\...txt".
$blockedBrief = @(New-EbookRequiredSourceBrief -Plan $blockedPlan -OutputFolder $blockedFolder -SourceContext ([pscustomobject]@{chunks=@();files=@()}))
Check ($blockedBrief.Count -eq 1 -and @($blockedBrief[0].assignedSources).Count -eq 1) "The brief did not drop the skipped reading (got $(@($blockedBrief[0].assignedSources).Count) source(s))."
Check ($blockedBrief[0].assignedSources[0].url -eq 'https://example.org/read') 'The brief kept a reading whose text was never retrieved.'
Check (@($blockedBrief[0].researchCandidates | Where-Object { $_.url -match 'blocked' }).Count -eq 0) 'A skipped reading was offered to the writer as evidence.'

# A wrong list is still the designer's to fix.
$badPlan = [pscustomobject]@{chapters=@([pscustomobject]@{number=1}); requiredReadings=@(
    $refPlan.requiredReadings[0],
    [pscustomobject]@{id=(ReadingId 'title-only');url='';title='A title with no link';chapters=@(1);origin='Designer';referenceOnly=$false})}
$badFolder = Join-Path $fixture 'bad-list'
New-Item -ItemType Directory -Path $badFolder -Force | Out-Null
$badListReport = Update-EbookRequiredSourceEvidence $badPlan $badFolder { param($url, $folder) [pscustomobject]@{text=('Synthetic teaching text. ' * 60); resolvedUrl=$url; contentType='text/html'} }
Check ($badListReport.status -eq 'FAIL' -and ($badListReport.issues -join ' ') -match 'exact URL') 'A reading with no URL was accepted.'

# Every chapter still needs one source that was actually read.
$onlyRefPlan = [pscustomobject]@{chapters=@([pscustomobject]@{number=1}); requiredReadings=@($refPlan.requiredReadings[1])}
$onlyRefFolder = Join-Path $fixture 'reference-only-alone'
New-Item -ItemType Directory -Path $onlyRefFolder -Force | Out-Null
$aloneReport = Update-EbookRequiredSourceEvidence $onlyRefPlan $onlyRefFolder { param($url, $folder) throw 'must not fetch' }
Check ($aloneReport.status -eq 'FAIL' -and ($aloneReport.issues -join ' ') -match 'no reading that could be read') 'A chapter with nothing readable was allowed.'

# A week-per-column blueprint keeps its reading list in one grid row, one cell
# per week. Read in document order that row flattens into a single run with no
# week markers left in it, so every reading in the course was assigned to
# whichever week was last seen: 40 real URLs all landed in chapter 5.
function New-GridCell([string[]]$Lines) {
    $paragraphs = ($Lines | ForEach-Object { "<w:p><w:r><w:t xml:space=`"preserve`">$([System.Security.SecurityElement]::Escape($_))</w:t></w:r></w:p>" }) -join ''
    if (-not $Lines.Count) { $paragraphs = '<w:p/>' }
    return "<w:tc>$paragraphs</w:tc>"
}
$gridRows = @(
    "<w:tr>$((New-GridCell @('')) + (New-GridCell @('Week 1')) + (New-GridCell @('T')) + (New-GridCell @('Week 2')) + (New-GridCell @('T')) + (New-GridCell @('Week 3')) + (New-GridCell @('T')))</w:tr>",
    "<w:tr>$((New-GridCell @('Weekly Topics')) + (New-GridCell @('Intake')) + (New-GridCell @('')) + (New-GridCell @('Coding')) + (New-GridCell @('')) + (New-GridCell @('Claims')) + (New-GridCell @('')))</w:tr>",
    "<w:tr>$((New-GridCell @('Textbook/ebook/ Resource list')) + (New-GridCell @('One: https://example.org/one')) + (New-GridCell @('')) + (New-GridCell @('Two: https://example.org/two')) + (New-GridCell @('')) + (New-GridCell @('Three: https://example.org/three')) + (New-GridCell @('')))</w:tr>",
    "<w:tr>$((New-GridCell @('Learn - readings; videos')) + (New-GridCell @('Read the intake guide. Resource: https://example.org/one')) + (New-GridCell @('')) + (New-GridCell @('Annotate a record. Resource: https://example.org/two')) + (New-GridCell @('')) + (New-GridCell @('Walk a claim form. Resource: https://example.org/three')) + (New-GridCell @('')))</w:tr>"
)
$gridXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Course Blueprint</w:t></w:r></w:p><w:tbl>' + ($gridRows -join '') + '</w:tbl></w:body></w:document>'
$gridTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
$gridRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
$gridPath = Join-Path $fixture 'QA3010 Curriculum Draft.docx'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$gridArchive = [System.IO.Compression.ZipFile]::Open($gridPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($part in @(@{ name = '[Content_Types].xml'; body = $gridTypes }, @{ name = '_rels/.rels'; body = $gridRels }, @{ name = 'word/document.xml'; body = $gridXml })) {
        $entry = $gridArchive.CreateEntry($part.name)
        $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.Write($part.body) } finally { $writer.Dispose() }
    }
}
finally { $gridArchive.Dispose() }

$gridReadings = @(ConvertFrom-EbookReadingList -Text (Get-EbookBlueprintReadingText -Path $gridPath) -Origin 'Blueprint')
Check (@($gridReadings | Where-Object url).Count -eq 3) "The week grid must yield its three readings (got $(@($gridReadings | Where-Object url).Count))."
foreach ($pair in @(@{ url = 'https://example.org/one'; week = 1 }, @{ url = 'https://example.org/two'; week = 2 }, @{ url = 'https://example.org/three'; week = 3 })) {
    $record = @($gridReadings | Where-Object { $_.url -eq $pair.url })
    Check ($record.Count -eq 1) "One record per reading URL ($($pair.url))."
    Check ((@($record[0].chapters) -join ',') -eq ([string]$pair.week)) "$($pair.url) belongs to week $($pair.week) only (got '$(@($record[0].chapters) -join ',')')."
}
# Activity rows cite the same readings; their prose is not a reading of its own.
Check (@($gridReadings | Where-Object { -not $_.url }).Count -eq 0) "An activity description must not become a title-only reading (got $((@($gridReadings | Where-Object { -not $_.url }) | ForEach-Object { $_.title }) -join ' | '))."

# Designers have no administrator rights, so "install Poppler" was not a step
# any of them could take, and 13 of RB1010's 40 assigned readings were CMS and
# AHIMA PDFs refused for want of it. Git for Windows ships pdftotext, and every
# designer has Git because that is how Book Studio is cloned and updated.
$converter = & $module { Get-EbookPdfTextConverter }
if ($converter) {
    Check (Test-Path -LiteralPath $converter -PathType Leaf) "The resolved pdftotext path must exist (got '$converter')."
}
if (Get-Command git.exe, git -ErrorAction SilentlyContinue) {
    Check ([bool]$converter) 'Git for Windows is installed, so pdftotext must be found without asking the designer to install anything.'
}
$readingsSource = Get-Content -LiteralPath (Join-Path $root 'lib/EbookRequiredReadings.ps1') -Raw -Encoding UTF8
Check ($readingsSource -notmatch 'Install the Poppler pdftotext utility') 'The refusal must not tell a designer without administrator rights to install Poppler.'
Check ($readingsSource -match 'mingw64') 'The converter lookup must check the Git for Windows installation.'

# Reading the document again, for a book whose saved list was taken by an older
# version. RB1000 carried eighteen entries, four of them fragments with no URL,
# while the same document read today yields every source linked. The designer
# could see "4 required readings have no URLs" and had no way to act on it.
$refreshFixture = Join-Path ([IO.Path]::GetTempPath()) ('readings-refresh-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $refreshFixture | Out-Null
try {
    Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking
    $refreshDb = Initialize-BookStudioDatabase -ProjectRoot $refreshFixture
    $courseText = @(
        'RB9100 Fixture Readings Course',
        'Week 1 Foundations',
        'Course Objective',
        '1. Explain the basics.',
        'Lesson Objectives',
        '1.1 Identify the basics.',
        'Week 1',
        '[A linked source](https://example.org/one)',
        '[Another linked source](https://example.org/two)'
    ) -join [Environment]::NewLine
    $refreshJob = New-BookStudioJob -DatabasePath $refreshDb -ProjectRoot $root -Request ([pscustomobject]@{
        title = 'Readings fixture'; courseCode = 'RB9100'; courseDocumentKind = 'EbookReady'
        sourceMode = 'Assigned'; readingLevel = 8
        files = @(@{ name = 'course.txt'; contentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($courseText)) })
    })
    # A saved list as an older version left it: two fragments with no URL, and
    # one entry a designer added that is not in the document at all.
    $null = Update-BookStudioJob -DatabasePath $refreshDb -JobId $refreshJob.id -Update {
        param($current)
        $current.options | Add-Member -NotePropertyName 'requiredReadings' -NotePropertyValue @(
            [pscustomobject]@{ title = 'A linked source'; url = 'https://example.org/one'; origin = 'Blueprint' },
            [pscustomobject]@{ title = 'A fragment with no link'; url = ''; origin = 'Designer' },
            [pscustomobject]@{ title = 'Another fragment'; url = ''; origin = 'Designer' },
            [pscustomobject]@{ title = 'Something the designer added'; url = 'https://example.org/added'; origin = 'Designer' }
        ) -Force
    }
    $refreshed = Update-BookStudioBlueprintReadings -DatabasePath $refreshDb -JobId $refreshJob.id
    Check ($refreshed.withoutUrlAfter -eq 0) "Reading the document again must leave nothing without a URL (got $($refreshed.withoutUrlAfter))."
    Check (@($refreshed.dropped).Count -eq 2) "Both fragments must be dropped (dropped $(@($refreshed.dropped).Count))."
    Check ((@($refreshed.dropped) -join '; ') -match 'fragment') 'The dropped entries are named, so nothing disappears silently.'
    $urls = @($refreshed.readings | ForEach-Object { [string]$_.url })
    Check ($urls -contains 'https://example.org/one' -and $urls -contains 'https://example.org/two') 'Every source in the document is present afterwards.'
    Check ($urls -contains 'https://example.org/added') 'A source the designer added, which the document does not list, is kept.'
    $saved = Get-Content -LiteralPath (Join-Path $refreshJob.sourceContextPath 'book-studio-production.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check (@($saved.requiredReadings).Count -eq @($refreshed.readings).Count) 'The list is written back to the book, not only returned.'
    $logged = @((Get-BookStudioJob -DatabasePath $refreshDb -JobId $refreshJob.id).log | Where-Object { $_.message -match 'Readings read again' })
    Check ($logged.Count -eq 1 -and $logged[0].message -match 'no URL') 'The book records what was read again and what was dropped.'
}
finally { Remove-Item -LiteralPath $refreshFixture -Recurse -Force -ErrorAction SilentlyContinue }

"PASS: $script:checks required-source and QA regression checks. Fixtures: $fixture"
