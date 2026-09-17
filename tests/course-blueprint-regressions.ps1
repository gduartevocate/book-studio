$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force -DisableNameChecking
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# Build a synthetic week-per-column Course Blueprint .docx. No private course
# content is used; the layout mirrors the real blueprint template, including a
# spanning header cell and "T" time columns between the week columns.
function New-Cell([string[]]$Lines, [int]$Span = 1) {
    $props = if ($Span -gt 1) { "<w:tcPr><w:gridSpan w:val=`"$Span`"/></w:tcPr>" } else { '' }
    $paragraphs = ($Lines | ForEach-Object { "<w:p><w:r><w:t xml:space=`"preserve`">$([System.Security.SecurityElement]::Escape($_))</w:t></w:r></w:p>" }) -join ''
    if (-not $Lines.Count) { $paragraphs = '<w:p/>' }
    return "<w:tc>$props$paragraphs</w:tc>"
}
function New-Row([string[]]$Cells) { return "<w:tr>$($Cells -join '')</w:tr>" }
function New-Table([string[]]$Rows) { return "<w:tbl>$($Rows -join '')</w:tbl>" }

$metaTable = New-Table @(
    (New-Row @((New-Cell @('Course Number:')), (New-Cell @('QA2010')))),
    (New-Row @((New-Cell @('Course Title:')), (New-Cell @('Fixture Revenue Operations & Coding')))),
    (New-Row @((New-Cell @('Initial Course SME')), (New-Cell @('Fixture SME'))))
)
$detailTable = New-Table @(
    (New-Row @((New-Cell @('Official Course Description')), (New-Cell @('This fixture course introduces revenue operations.', 'It is synthetic test data.')))),
    (New-Row @((New-Cell @('Semester Credits')), (New-Cell @('3.0 Semester Credits')))),
    (New-Row @((New-Cell @('Pre-requisites')), (New-Cell @('QA1000'))))
)
$objectiveTable = New-Table @(
    (New-Row @((New-Cell @('CO1.')), (New-Cell @('Describe the end-to-end revenue cycle.')))),
    (New-Row @((New-Cell @('CO2.')), (New-Cell @('Apply coding systems to basic scenarios.')))),
    (New-Row @((New-Cell @('CO3.')), (New-Cell @('Analyze billing errors that affect reimbursement.'))))
)
$weekTable = New-Table @(
    (New-Row @((New-Cell @('')), (New-Cell @('Week 1')), (New-Cell @('T')), (New-Cell @('Week 2')), (New-Cell @('T')), (New-Cell @('Week 3')), (New-Cell @('T')))),
    (New-Row @((New-Cell @('Weekly Topics')), (New-Cell @('Revenue Cycle Foundations')), (New-Cell @('')), (New-Cell @('Coding System Fundamentals')), (New-Cell @('')), (New-Cell @('Billing Error Analysis')), (New-Cell @('')))),
    (New-Row @((New-Cell @('Course Objectives (Add CO# after each bullet)')), (New-Cell @('CO1')), (New-Cell @('')), (New-Cell @('CO2, CO1')), (New-Cell @('')), (New-Cell @('CO3')), (New-Cell @('')))),
    (New-Row @((New-Cell @('Learning Objectives')), (New-Cell @('LO1: Describe the major stages of the revenue cycle,', 'LO2: Explain how each department contributes to revenue integrity.')), (New-Cell @('')), (New-Cell @('LO3: Differentiate ICD-10-CM, CPT, and HCPCS Level II codes.')), (New-Cell @('')), (New-Cell @('')), (New-Cell @('')))),
    (New-Row @((New-Cell @('Learn - readings; videos')), (New-Cell @('Read. [LO1] Resource: fixture reading')), (New-Cell @('5.0')), (New-Cell @('Watch a fixture video')), (New-Cell @('5.0')), (New-Cell @('Read a fixture guide')), (New-Cell @('5.0')))),
    (New-Row @((New-Cell @('Total Time')), (New-Cell @('Estimated weekly effort: 27.0') 6)))
)
$notesTable = New-Table @(
    (New-Row @((New-Cell @('')), (New-Cell @('Week 1')), (New-Cell @('Week 2')), (New-Cell @('Week 3')))),
    (New-Row @((New-Cell @('Instructor Notes')), (New-Cell @('')), (New-Cell @('')), (New-Cell @(''))))
)
$document = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Course Blueprint</w:t></w:r></w:p>$metaTable$detailTable<w:p><w:r><w:t>Course Objectives:</w:t></w:r></w:p>$objectiveTable$weekTable$notesTable</w:body></w:document>
"@
$contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'
$rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ebook-blueprint-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$docxPath = Join-Path $fixture 'QA2010 Curriculum Draft.docx'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($docxPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($part in @(@{ name = '[Content_Types].xml'; body = $contentTypes }, @{ name = '_rels/.rels'; body = $rels }, @{ name = 'word/document.xml'; body = $document })) {
        $entry = $archive.CreateEntry($part.name)
        $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.Write($part.body) } finally { $writer.Dispose() }
    }
}
finally { $archive.Dispose() }

$course = Import-CourseSpec -Path $docxPath
Check ($course.courseCode -eq 'QA2010') "Course code from the Course Number cell (got '$($course.courseCode)')."
Check ($course.courseName -eq 'Fixture Revenue Operations & Coding') "Course title from the Course Title cell (got '$($course.courseName)')."
Check ($course.sme -eq 'Fixture SME') 'SME from the metadata table.'
Check ($course.description -like 'This fixture course introduces revenue operations.*synthetic test data.') 'Description joins the multi-paragraph cell.'
Check ($course.credits -eq '3.0 Semester Credits' -and $course.prerequisites -eq 'QA1000') 'Credits and prerequisites from label rows.'
Check (@($course.courseObjectives).Count -eq 3 -and $course.courseObjectives[2].objectiveId -eq 'CO3') 'CO1./CO2./CO3. rows become course-objective records.'
Check ($course.sourceFormat -eq 'course-blueprint') 'Blueprint parser handled the document.'

$weeks = @($course.weeks)
Check ($weeks.Count -eq 3) "Three week columns become three chapter groups (got $($weeks.Count))."
Check (($weeks | ForEach-Object { $_.number }) -join ',' -eq '1,2,3') 'Week numbers follow the header columns.'
Check ($weeks[0].title -eq 'Revenue Cycle Foundations' -and $weeks[2].title -eq 'Billing Error Analysis') 'Weekly Topics row supplies chapter titles.'
Check (@($weeks[0].modules).Count -eq 2 -and $weeks[0].modules[0].objectiveId -eq 'LO1' -and $weeks[0].modules[1].objectiveId -eq 'LO2') 'Week 1 learning objectives keep their LO identifiers.'
Check ($weeks[0].modules[0].objective -eq 'Describe the major stages of the revenue cycle') 'Trailing punctuation is trimmed from objectives.'
Check ($weeks[0].modules[0].title -notmatch '^Describe') 'Module titles are derived from objective text.'
Check ((@($weeks[1].courseObjectiveIds) -join ',') -eq 'CO2,CO1') 'Mapped course-objective IDs are preserved per week.'
Check (@($weeks[2].modules).Count -eq 1 -and $weeks[2].modules[0].objectiveId -eq 'CO3' -and $weeks[2].modules[0].objective -eq 'Analyze billing errors that affect reimbursement.') 'A week with no learning objectives falls back to its mapped course objective.'
Check (@($weeks[0].activities).Count -eq 0) 'Learner-facing activities are not created from blueprint metadata.'
foreach ($week in $weeks) { foreach ($module in @($week.modules)) { Check (-not [string]::IsNullOrWhiteSpace([string]$module.objectiveId)) "Week $($week.number) modules have resolved objective IDs." } }

# Word automatic list numbers are not text. The reader must render them so a
# spec sheet parses the way it looks ("1." from a numbered list, none for bullets).
$numberingXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl><w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1.%2"/></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="&#8226;"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num><w:num w:numId="3"><w:abstractNumId w:val="0"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="7"/></w:lvlOverride></w:num></w:numbering>'
function New-NumberedParagraph([string]$Text, [int]$NumId, [int]$Level = 0) { return "<w:p><w:pPr><w:numPr><w:ilvl w:val=`"$Level`"/><w:numId w:val=`"$NumId`"/></w:numPr></w:pPr><w:r><w:t xml:space=`"preserve`">$([System.Security.SecurityElement]::Escape($Text))</w:t></w:r></w:p>" }
$numberedBody = (New-NumberedParagraph 'Explain the stages of the revenue cycle.' 1) + (New-NumberedParagraph 'Identify the stages.' 1 1) + (New-NumberedParagraph 'Describe each stage.' 1 1) + (New-NumberedParagraph 'Explain the role of professionals.' 1) + (New-NumberedParagraph 'A bulleted resource' 2) + (New-NumberedParagraph 'Evaluate account lifecycle activities.' 3) + '<w:p><w:r><w:t>Plain paragraph.</w:t></w:r></w:p>'
$numberedDoc = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + $numberedBody + '</w:body></w:document>'
$numberedTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/></Types>'
$numberedPath = Join-Path $fixture 'numbered.docx'
$archive = [System.IO.Compression.ZipFile]::Open($numberedPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($part in @(@{ name = '[Content_Types].xml'; body = $numberedTypes }, @{ name = '_rels/.rels'; body = $rels }, @{ name = 'word/document.xml'; body = $numberedDoc }, @{ name = 'word/numbering.xml'; body = $numberingXml })) {
        $entry = $archive.CreateEntry($part.name)
        $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.Write($part.body) } finally { $writer.Dispose() }
    }
}
finally { $archive.Dispose() }
$ebook = Get-Module EbookGenerator
$lines = @((& $ebook { param($p) Get-DocxText -Path $p } $numberedPath) -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
Check ($lines[0] -eq '1. Explain the stages of the revenue cycle.' -and $lines[3] -eq '2. Explain the role of professionals.') "Decimal list numbers are rendered in document order (got '$($lines[0])' / '$($lines[3])')."
Check ($lines[1] -eq '1.1 Identify the stages.' -and $lines[2] -eq '1.2 Describe each stage.') "Nested levels render with their parent number (got '$($lines[1])' / '$($lines[2])')."
Check ($lines[4] -eq 'A bulleted resource') 'Bulleted lists get no prefix.'
Check ($lines[5] -eq '7. Evaluate account lifecycle activities.') "A list start override is honored (got '$($lines[5])')."
Check ($lines[6] -eq 'Plain paragraph.') 'Unnumbered paragraphs are unchanged.'
$locked = [System.IO.File]::Open($numberedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
try { Check (@((& $ebook { param($p) Get-DocxText -Path $p } $numberedPath) -split "\r?\n").Count -gt 1) 'A document held open for writing (as Word does) can still be read.' }
finally { $locked.Dispose() }

# Spec-sheet weeks whose course objectives lost their numbers while the lesson
# objectives kept theirs (RB1000 style) must still parse, by inferring parents.
$ebook = Get-Module EbookGenerator
$block = @(
    'Week 1 Revenue Cycle Foundations', 'Course Objective', 'Lesson Objectives',
    'Explain the stages of the revenue cycle and how they contribute to organizational financial performance.',
    '7. Explain the role of revenue cycle professionals in supporting financial sustainability.',
    '1.1 Identify the stages of the revenue cycle.',
    '1.2 Describe the stages of the revenue cycle and the purpose of each stage.',
    '7.1 Identify roles within the revenue cycle.'
)
$modules = @(& $ebook { param($b) Get-ModulesFromWeekBlock -Block $b } $block)
Check ($modules.Count -eq 2 -and $modules[0].objectiveId -eq '1' -and $modules[1].objectiveId -eq '7') "An unnumbered course objective is paired with its lessons' parent number (got $(($modules | ForEach-Object { $_.objectiveId }) -join ','))."
Check ($modules[0].objective -like 'Explain the stages of the revenue cycle*' -and @($modules[0].subObjectives).Count -eq 2 -and @($modules[1].subObjectives).Count -eq 1) 'Lessons attach to the inferred and the numbered parents.'
$orphan = @('Week 2 Revenue Documentation', 'Course Objective', 'Lesson Objectives', '2.1 Describe how services are documented.')
try { & $ebook { param($b) Get-ModulesFromWeekBlock -Block $b } $orphan | Out-Null; throw 'FAIL: An orphan lesson with no candidate parent must be rejected.' }
catch { Check ($_.Exception.Message -match 'Week 2 Revenue Documentation' -and $_.Exception.Message -match "Number that course objective") 'An orphan lesson explains which week and objective to fix.' }

# The line-based spec-sheet format must keep parsing exactly as before.
$specSheet = Join-Path $root 'Source/GM1000 Introduction to Business & Office Operations Spec Sheet.docx'
if (Test-Path -LiteralPath $specSheet) {
    $gm1000 = Import-CourseSpec -Path $specSheet
    Check ($gm1000.courseCode -eq 'GM1000' -and @($gm1000.weeks).Count -eq 5) "GM1000 spec sheet still parses as 5 weeks (got $(@($gm1000.weeks).Count))."
    Check (-not ($gm1000.PSObject.Properties.Name -contains 'sourceFormat')) 'GM1000 spec sheet still uses the spec-sheet parser, not the blueprint parser.'
}

Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "PASS: $checks course blueprint parsing assertions (week-per-column grid, spanning cells, metadata, CO/LO identity, spec-sheet compatibility)."
