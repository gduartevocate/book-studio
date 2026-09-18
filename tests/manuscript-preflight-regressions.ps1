[CmdletBinding()]
param([string]$SamplePackage)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('BookStudioTests/preflight-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force
$script:checks = 0
function Check([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message }; $script:checks++ }
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Check ($_.Exception.Message -match $Pattern) "Unexpected failure: $_"; return }
    throw "Expected rejection matching $Pattern"
}

# Synthetic course only: reproduces the reported layout without private content.
$chapters = foreach ($number in 1..5) {
    $closing = if ($number -eq 5) { 'Conclusion' } else { 'Looking Ahead' }
    @"
# Chapter ${number}: Records $number

### Introduction
Reliable records support informed decisions.
### Learning Objectives
1. Explain the record workflow.
## Section $number.1 - Understanding records
### Opening Scenario
**Business Case:** Morgan reviews an incomplete record before sending it to the authorized reviewer.
### Chapter Roadmap
Follow the record through each role.
## Section $number.2 - Tracking the workflow
Use the provided source [1](#chapter-$number-note-1).
## Section $number.3 - Applying the workflow
### Case Study Progression
Morgan verifies the record.
### Communication Toolbox
A handoff message names the record, responsible role, next action, and due time.
### Practical Field Guide
Verify the record before sending it.
## Section $number.4 - Integrating the workflow
Reliable records depend on careful observation and clear communication across roles. Use the source evidence to explain each decision, verify the result, and document the next action before handing work to another team.
### Key Takeaways
Records connect people and decisions.
### Vocabulary Review
Handoff: transferring responsibility for a record.
### $closing
Continue applying the workflow.
### Scholarly Sources
1. [Provided source $number](https://example.org/source/$number). (2026). Assigned reading.
"@
}
# Here-strings inherit this file's CRLF endings, while preflight standardizes
# on LF exactly as Update-EbookManuscriptPreflight does before comparing.
$canonical = ($chapters -join "`n`n") -replace "`r`n", "`n"
Check ((Test-EbookPublicationTemplate $canonical).status -eq 'PASS') 'Synthetic baseline violates the template.'
$baseline = Test-EbookManuscriptPreflight $canonical -ExpectedChapterNumbers @(1,2,3,4,5)
Check ($baseline.status -eq 'PASS' -and $baseline.markdown -ceq $canonical) 'Canonical manuscript was changed.'
foreach ($notesHeading in @('Notes', 'Numbered Notes', 'Numbered Scholarly Notes', 'Scholarly Sources / Numbered Notes')) {
    $notesResult = Test-EbookManuscriptPreflight ($canonical.Replace('### Scholarly Sources', "### $notesHeading"))
    Check ($notesResult.status -eq 'PASS' -and $notesResult.markdown -ceq $canonical) 'Template validation ran before source-heading normalization.'
}
foreach ($separator in @([string][char]0x2014, [string][char]0x2013, ':')) {
    $variant = $canonical.Replace(' - ', " $separator ").Replace('**Business Case:**', '**Business Case**:')
    $normalized = Test-EbookManuscriptPreflight $variant
    Check ($normalized.status -eq 'PASS' -and $normalized.markdown -ceq $canonical) 'Heading separator or colon placement was not normalized.'
}
$variant = [regex]::Replace($canonical, '(?m)^## Section (\d+\.\d+) - ', '## $1 ')
$variant = [regex]::Replace($variant, '(?m)^(## \d+\.4 )Integrating ', '$1')
$variant = [regex]::Replace($variant, '(?m)^(## \d+\.4 [^\r\n]+)\r?\n', '$1' + "`n`n### Synthesis`n")
$variant = $variant.Replace('### Communication Toolbox', '### Modeled Artifact').Replace('### Introduction', '## Introduction')
$variant = [regex]::Replace($variant, '(?m)^(### Scholarly Sources)\r?\n1\. (\[Provided source (\d+)\])', '$1' + "`n<a id=""chapter-" + '$3' + "-note-1""></a>`n`n1. " + '$2')
$normalized = Test-EbookManuscriptPreflight $variant -ExpectedChapterNumbers @(1,2,3,4,5)
Check ($normalized.status -eq 'PASS') ('Reported layout aliases still fail: ' + ($normalized.issues -join ' '))
Check ($normalized.markdown.Contains('### Communication Toolbox: Modeled Artifact')) 'Modeled artifact title or content was dropped.'
Check ($normalized.markdown.Contains('## Section 1.4 - Integrating: the workflow')) 'Integration title was not retained.'
Check ($normalized.markdown.Contains('Reliable records depend on careful observation and clear communication across roles.')) 'Synthesis prose was changed.'
Check ($normalized.markdown -notmatch '<a id=') 'Reported standalone citation anchors remain.'
Check ((Test-EbookManuscriptPreflight $normalized.markdown).markdown -ceq $normalized.markdown) 'Normalization is not idempotent.'
$normalizer = { param($text) & (Get-Module EbookGenerator) { param($inputText) ConvertTo-EbookPublicationMarkdown $inputText } $text }
$fenced = "# Chapter 1: Records`n" + '```markdown' + "`n## 1.2 Example`n### Opening Scenario`n**Business Case**: Morgan`n" + '```'
Check ((& $normalizer $fenced) -ceq $fenced) 'Fenced examples were rewritten.'
$ordinary = "# Chapter 1: Records`n### A quotation`n**Business Case**: Morgan`n### Modeled Artifact"
Check ((& $normalizer $ordinary) -ceq $ordinary) 'Unrelated prose or headings were rewritten.'
foreach ($bad in @(
    $canonical.Replace('### Communication Toolbox', '### Unrelated Topic'),
    $canonical.Replace('**Business Case:** Morgan', 'A person'),
    $canonical.Replace('Section 2.2 -', 'Section 9.2 -'),
    $canonical.Replace('### Practical Field Guide', '### Missing Guide'),
    $canonical.Replace('[1](#chapter-1-note-1)', '[2](#chapter-1-note-2)'),
    $canonical.Replace('1. [Provided source 1]', '32. [Provided source 1]'),
    ($canonical + "`n### Scholarly Sources`n1. Duplicate source."),
    ([regex]::Replace($canonical, '(?m)^Reliable records depend[^\r\n]+', 'Too short.'))
)) {
    Check ((Test-EbookManuscriptPreflight $bad -ExpectedChapterNumbers @(1,2,3,4,5)).status -eq 'FAIL') 'Normalization hid a genuine content/citation defect.'
}
Check ((Test-EbookManuscriptPreflight $canonical -ExpectedChapterNumbers @(1,2,3,4,5,6)).status -eq 'FAIL') 'Missing planned chapter accepted.'
$introSignals = & (Get-Module EbookGenerator) {
    $course = [pscustomobject]@{courseName='Records';description='Office records'}
    $chapter = [pscustomobject]@{number=2;title='Records'}
    $intro = "## Introduction`nRecords support decisions. Verify the record.`n### Learning Objectives`n" + ('These objective words must not inflate the introduction. ' * 20)
    @(Get-IntroductionCompletenessSignals $course $chapter $intro; Get-IntroductionCompletenessSignals $course $chapter ($intro.Replace('## Introduction', '### Introduction')))
}
Check ($introSignals[0].wordCount -eq $introSignals[1].wordCount -and $introSignals[0].wordCount -gt 0 -and $introSignals[0].wordCount -lt 15) 'Introduction heading depth or next-heading boundary is inconsistent.'
Check ($introSignals[0].status -eq 'FAIL' -and $introSignals[1].status -eq 'FAIL') 'Objective text padded a short introduction into a pass.'
$manuscript = Join-Path $fixture 'QA1000 - E-Book.md'
Set-Content -LiteralPath $manuscript -Value $variant -Encoding UTF8 -NoNewline
$beforeHash = (Get-FileHash -LiteralPath $manuscript).Hash
$null = Update-EbookManuscriptPreflight $manuscript -ExpectedChapterNumbers @(1,2,3,4,5)
$backups = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'manuscript-backups') -File)
Check ($backups.Count -eq 1 -and (Get-FileHash -LiteralPath $backups[0].FullName).Hash -eq $beforeHash) 'Original manuscript backup is not byte-exact.'
$null = Update-EbookManuscriptPreflight $manuscript -ExpectedChapterNumbers @(1,2,3,4,5)
Check (@(Get-ChildItem -LiteralPath (Join-Path $fixture 'manuscript-backups') -File).Count -eq 1) 'Idempotent preflight creates repeated backups.'
$report = Get-Content -LiteralPath (Join-Path $fixture 'manuscript-preflight.json') -Raw | ConvertFrom-Json
Check ($report.status -eq 'PASS' -and $report.manuscriptSha256 -eq (Get-FileHash -LiteralPath $manuscript).Hash) 'Preflight report does not describe the saved manuscript.'

# Exercise real orchestration, replacing only AI/network effects.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ebook-generator.ps1'), [ref]$tokens, [ref]$errors)
Check (-not $errors) 'Generator syntax error.'
foreach ($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) { . ([scriptblock]::Create($function.Extent.Text)) }
$realDraft = ${function:Invoke-EbookCodexDraftingPass}
$realProgress = ${function:Write-EbookProgress}
function Write-EbookProgress { param($Phase,$Detail) }
$SourceMode = 'Discovery'
$script:repairs = 0; $script:images = 0; $script:repairBehavior = 'success'
function Invoke-EbookCodexDraftingPass {
    param($CodexCommand,$Course,$Result,$TimeoutSeconds,$RepairIssues)
    $script:repairs++
    Check ($RepairIssues.Count -gt 0 -and ($RepairIssues -join ' ') -match 'Communication Toolbox') 'Repair did not receive exact findings.'
    Check ($SourceMode -eq 'UploadedOnly') 'Resume repair escaped the saved source boundary.'
    if ($script:repairBehavior -eq 'error') { throw 'fixture stream disconnected' }
    if ($script:repairBehavior -eq 'success') { Set-Content -LiteralPath $Result.markdownPath -Value $canonical -Encoding UTF8 -NoNewline }
}
function Invoke-EbookCodexImagePass {
    param($CodexCommand,$Course,$Result,$TimeoutSeconds)
    Check ((Test-EbookManuscriptPreflight (Get-Content -LiteralPath $Result.markdownPath -Raw)).status -eq 'PASS') 'Images started before manuscript passed.'
    $script:images++
    [pscustomobject]@{ changedCount=5; reportPath='fixture' }
}
$plan = [pscustomobject]@{sourceMode='UploadedOnly';chapters=@(1..5 | ForEach-Object { @{number=$_} })}
$plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fixture 'ebook-plan.json') -Encoding UTF8
$course = [pscustomobject]@{courseCode='QA1000';courseName='Fixture'}
$result = [pscustomobject]@{outputFolder=$fixture;markdownPath=$manuscript}
$argsForImages = @{CodexCommand='fixture.exe';Course=$course;Result=$result}
Set-Content -LiteralPath $manuscript -Value $variant -Encoding UTF8 -NoNewline
$null = Invoke-EbookValidatedImagePass @argsForImages
Check ($script:repairs -eq 0 -and $script:images -eq 1) 'Safe normalization needlessly invoked AI.'
$broken = $canonical.Replace('### Communication Toolbox', '### Unrelated Topic')
Set-Content -LiteralPath $manuscript -Value $broken -Encoding UTF8 -NoNewline
$null = Invoke-EbookValidatedImagePass @argsForImages
Check ($script:repairs -eq 1 -and $script:images -eq 2) 'Targeted repair did not run exactly once before images.'
Check (Test-Path -LiteralPath (Join-Path $fixture 'manuscript-preflight-before-repair.json')) 'Original repair findings were lost.'
foreach ($behavior in @('nochange','error')) {
    Set-Content -LiteralPath $manuscript -Value $broken -Encoding UTF8 -NoNewline
    $script:repairBehavior = $behavior
    $beforeRepairs = $script:repairs
    Reject { Invoke-EbookValidatedImagePass @argsForImages } 'Manuscript preflight'
    Check ($script:repairs -eq ($beforeRepairs + 1) -and $script:images -eq 2) 'Failed repair repeated itself or started images.'
}
$beforeRepairs = $script:repairs
Reject { Invoke-EbookValidatedImagePass @argsForImages -AllowRepair:$false } 'Manuscript preflight failed'
Check ($script:repairs -eq $beforeRepairs -and $script:images -eq 2) 'Disabled AI still made an AI call.'
$exportPath = Join-Path $fixture 'QA1000 - E-Book.docx'
'Existing export fixture; must not be replaced by a failing rebuild.' | Set-Content -LiteralPath $exportPath -Encoding UTF8
$exportHash = (Get-FileHash -LiteralPath $exportPath).Hash
Reject { Repair-EbookPackageOutputs -OutputFolder $fixture -CourseCode 'QA1000' } 'Manuscript preflight.*Existing exports were not replaced'
Check ((Get-FileHash -LiteralPath $exportPath).Hash -eq $exportHash) 'Failed manuscript preflight changed an existing export.'
# Both entry points must use the shared guard; only the guard may call images.
$imageCalls = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-EbookCodexImagePass'}, $true))
$guardCalls = @($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-EbookValidatedImagePass'}, $true))
Check ($imageCalls.Count -eq 1 -and $guardCalls.Count -eq 2) 'Fresh or resume generation bypasses the shared preflight.'

# Real repair prompt and isolated response files; no subprocess/AI is launched.
${function:Invoke-EbookCodexDraftingPass} = $realDraft
. (Join-Path $root 'lib/EbookCodexSandbox.ps1')
$SourceMode = 'UploadedOnly'
$originalDraftEvidence = 'Original drafting evidence must not be overwritten.'
Set-Content -LiteralPath (Join-Path $fixture 'codex-drafting-response.md') -Value $originalDraftEvidence -Encoding UTF8
function Start-Process {
    param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru)
    Check ($WindowStyle -eq 'Hidden') 'Repair launches a visible helper window.'
    Set-Content -LiteralPath $manuscript -Value $canonical -Encoding UTF8 -NoNewline
    'sandbox: workspace-write' | Set-Content -LiteralPath (Join-Path $fixture 'codex-format-repair-error.log')
    '0' | Set-Content -LiteralPath (Join-Path $fixture 'codex-format-repair-exit-code.txt')
    'Repaired the reported headings.' | Set-Content -LiteralPath (Join-Path $fixture 'codex-format-repair-response.md')
    [pscustomobject]@{HasExited=$true}
}
$null = Invoke-EbookCodexDraftingPass -CodexCommand 'fixture.exe' -Course $course -Result $result -RepairIssues @('Chapter 1: missing Communication Toolbox.')
$prompt = Get-Content -LiteralPath (Join-Path $fixture 'codex-format-repair-prompt.md') -Raw -Encoding UTF8
Check ($prompt.Contains('Chapter 1: missing Communication Toolbox.') -and $prompt.Contains('Do not rewrite the whole book') -and $prompt.Contains('SOURCE BOUNDARY')) 'Repair prompt lacks targeted findings or preservation/source constraints.'
Check ((Get-Content -LiteralPath (Join-Path $fixture 'codex-drafting-response.md') -Raw).Trim() -eq $originalDraftEvidence) 'Targeted repair overwrote original drafting evidence.'
Check (Test-Path -LiteralPath (Join-Path $fixture 'codex-format-repair-report.md')) 'Targeted repair lacks its own report.'

if ($SamplePackage) {
    # Optional local integration on a COPY. Never distribute private course data.
    $sampleRoot = (Resolve-Path -LiteralPath $SamplePackage).Path
    $originalHashes = @(Get-ChildItem -LiteralPath $sampleRoot -Recurse -File | Get-FileHash | Select-Object Path,Hash) | ConvertTo-Json -Depth 3
    $copy = Join-Path $fixture 'sample-copy'
    Copy-Item -LiteralPath $sampleRoot -Destination $copy -Recurse
    $samplePlan = Get-Content -LiteralPath (Join-Path $copy 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $rebuild = Repair-EbookPackageOutputs -OutputFolder $copy -CourseCode $samplePlan.courseCode
    Check ($rebuild.releaseIntegrityStatus -eq 'PASS') 'Real sample failed rebuilt release integrity.'
    Check ($rebuild.exportValidationStatus -eq 'PASS') 'Real sample failed Word export validation.'
    $afterHashes = @(Get-ChildItem -LiteralPath $sampleRoot -Recurse -File | Get-FileHash | Select-Object Path,Hash) | ConvertTo-Json -Depth 3
    Check ($originalHashes -ceq $afterHashes) 'Original sample package was changed.'
    Write-Output "Rebuilt sample copy: $copy"
}
Write-Output "PASS: $script:checks manuscript preflight regression assertions."
Write-Output "Fixtures: $fixture"
