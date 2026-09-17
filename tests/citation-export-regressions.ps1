[CmdletBinding()]
param([string]$OutputFolder)
$ErrorActionPreference = 'Stop'
if (-not $OutputFolder) { $OutputFolder = Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/citation-export-tests' }
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$OutputFolder = (Resolve-Path -LiteralPath $OutputFolder).Path
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/EbookGenerator.psm1') -Force
& (Get-Module EbookGenerator) {
    param($testFolder)
    $script:citationChecks = 0
    function Check([bool]$ok, [string]$message) { if (-not $ok) { throw $message }; $script:citationChecks++ }
    $steps = (1..31 | ForEach-Object { "$_. Prior list item." }) -join "`n"
    $notes = (1..5 | ForEach-Object { '<span id="chapter-2-note-' + $_ + '"></span>' + "`n$_. [Source $_](https://example.org/source/$_)" }) -join "`n`n"
    $legacy = "# Chapter 2: Example`n`n$steps`n`nSee [1](#chapter-2-note-1) and [5](#chapter-2-note-5).`n`n## Scholarly Sources / Numbered Notes`n`n$notes`n`n# Chapter 3: Next`n`nSee [1](#chapter-3-note-1).`n`n### Numbered Scholarly Notes`n`n1. [Next source](https://example.org/next)"
    $canonical = ConvertTo-EbookCitationMarkdown $legacy
    Check ($canonical -notmatch '<span|/ Numbered Notes') 'Legacy markup was not normalized.'
    $ids = New-Object Collections.ArrayList
    [xml]$word = ConvertTo-WordDocumentXml $legacy -RestartingNumberingIds $ids
    [xml]$numbering = Get-WordNumberingXml -RestartingNumberingIds ([int[]]$ids.ToArray())
    $html = ConvertTo-SimpleHtmlFromMarkdown $legacy
    Check (@(Get-EbookWordCitationIssues $word $numbering).Count -eq 0) 'Valid legacy notes fail the Word artifact gate.'
    Check (@(Get-EbookHtmlCitationIssues $html).Count -eq 0) 'Valid legacy notes fail the HTML artifact gate.'
    Check ($word.OuterXml -notmatch '&lt;span' -and $html -notmatch '&lt;span') 'The screenshot markup is still printed.'
    Check ($ids.Count -eq 3) 'Blank lines split bibliography entries into separate numbering instances.'
    Check ([regex]::Matches($word.OuterXml, '<w:bookmarkStart').Count -eq 6) 'A source note lost its bookmark.'
    Check ([regex]::Matches($html, '<li id="chapter-').Count -eq 6) 'A source note lost its HTML target.'
    Check ((ConvertTo-EbookCitationMarkdown ($legacy.Replace('#chapter-2-note-1','#chapter_2_note_1'))) -eq $canonical) 'A Word-style underscore fragment became a broken HTML link.'
    foreach ($heading in @('Notes','Numbered Notes','Numbered Scholarly Notes','Scholarly Sources / Numbered Notes')) {
        Check ((ConvertTo-EbookCitationMarkdown ($legacy.Replace('Scholarly Sources / Numbered Notes',$heading))) -eq $canonical) "Unsupported notes heading: $heading"
    }
    Check ((ConvertTo-EbookCitationMarkdown ($legacy.Replace('id="chapter-2-note-1"', "id='chapter-2-note-1'"))) -eq $canonical) 'Single-quoted legacy anchor failed.'
    $inlineAnchor = $legacy.Replace('<span id="chapter-2-note-1"></span>' + "`n1. ", '1. <a id="chapter-2-note-1"></a>')
    Check ((ConvertTo-EbookCitationMarkdown $inlineAnchor) -notmatch '<a\s+id=') 'Safe inline legacy anchor was not normalized.'
    $badInputs = @(
        $legacy.Replace('id="chapter-2-note-1"','id="chapter-9-note-1"'),
        $legacy.Replace('id="chapter-2-note-1"','id="chapter-2-note-2"'),
        $legacy.Replace('1. [Source 1]','32. [Source 1]'),
        $canonical.Replace('2. [Source 2]','3. [Source 2]'),
        $legacy.Replace('<span id="chapter-2-note-1"></span>','&lt;span id="chapter-2-note-1"&gt;&lt;/span&gt;'),
        $legacy.Replace('<span id="chapter-2-note-1"></span>','&amp;lt;span id="chapter-2-note-1"&amp;gt;&amp;lt;/span&amp;gt;'),
        $legacy.Replace('<span id="chapter-2-note-1"></span>','<span class="broken" id="chapter-2-note-1"></span>'),
        $inlineAnchor.Replace('<a id="chapter-2-note-1"></a>', '<a id="chapter-2-note-2"></a>'),
        $legacy.Replace('[1](#chapter-2-note-1)','[99](#chapter-2-note-99)'),
        ($canonical + "`n`n## Notes`n`n1. Duplicate source."),
        ($canonical + "`n`n<span id=""chapter-3-note-2""></span>")
    )
    foreach ($bad in $badInputs) {
        $rejected = $false
        try { $null = ConvertTo-WordDocumentXml $bad } catch { $rejected = $_.Exception.Message -match 'Citation preflight' }
        Check $rejected 'Word accepted malformed legacy markup, numbering, or a dangling citation.'
        $rejected = $false
        try { $null = ConvertTo-SimpleHtmlFromMarkdown $bad } catch { $rejected = $_.Exception.Message -match 'Citation preflight' }
        Check $rejected 'HTML accepted malformed legacy markup, numbering, or a dangling citation.'
    }
    $badStart = [xml]($numbering.OuterXml.Replace('w:startOverride w:val="1"','w:startOverride w:val="32"'))
    Check (@(Get-EbookWordCitationIssues $word $badStart).Count -gt 0) 'The Word gate accepted source numbering starting at 32.'
    $badBookmark = [xml]($word.OuterXml.Replace('w:name="chapter_2_note_1"','w:name="missing"'))
    Check (@(Get-EbookWordCitationIssues $badBookmark $numbering).Count -gt 0) 'The Word gate accepted a missing bookmark.'
    $badWord = [xml]($word.OuterXml.Replace('>Source 1</w:t>','>&lt;sp</w:t></w:r><w:r><w:t>an id="chapter-2-note-1"&gt;&lt;/span&gt;</w:t>'))
    Check (@(Get-EbookWordCitationIssues $badWord $numbering).Count -gt 0) 'The Word gate missed a visible tag split across runs.'
    $reused = [xml]($word.OuterXml.Replace('w:numId w:val="4"','w:numId w:val="3"'))
    Check (@(Get-EbookWordCitationIssues $reused $numbering).Count -gt 0) 'The Word gate accepted a bibliography continuing the prior 31 items.'
    $restarted = [xml]($word.OuterXml.Replace('w:numId w:val="4"','w:numId w:val="5"'))
    Check (@(Get-EbookWordCitationIssues $restarted $numbering).Count -gt 0) 'The Word gate accepted a numbering instance shared across chapters.'
    Check ((Get-EbookHtmlArtifactIssues ($html.Replace('<h2>Scholarly Sources</h2>', '<h2>Scholarly Sources</h2><p>&lt;span id="chapter-2-note-1"&gt;&lt;/span&gt;</p>'))).status -eq 'FAIL') 'Shared HTML gate missed printed tags.'
    Check ((Get-EbookHtmlArtifactIssues ($html.Replace('id="chapter-2-note-1"','id="missing"'))).status -eq 'FAIL') 'Shared HTML gate accepted a broken citation.'
    Check ((Get-EbookHtmlArtifactIssues ($html.Replace('<ol>','<ol start="32">'))).status -eq 'FAIL') 'Shared HTML gate accepted numbering starting at 32.'
    Check ((Get-EbookHtmlArtifactIssues ($html.Replace('<li id="chapter-2-note-2">','</ol><ol><li id="chapter-2-note-2">'))).status -eq 'FAIL') 'HTML notes were allowed to restart at every blank line.'
    Check ((Get-EbookMarkdownArtifactIssues $badInputs[2]).status -eq 'FAIL') 'Shared Markdown gate accepted a note starting at 32.'
    $goodPath = Export-MarkdownToDocx $legacy -Path (Join-Path $testFolder 'citation-fixture.docx')
    Check ((Get-EbookDocxArtifactIssues $goodPath).status -eq 'PASS') 'Exported fixture failed the shared DOCX gate.'
    $hash = (Get-FileHash -LiteralPath $goodPath).Hash
    $rejected = $false
    try { $null = Export-MarkdownToDocx $badInputs[2] -Path $goodPath } catch { $rejected = $true }
    Check ($rejected -and (Get-FileHash -LiteralPath $goodPath).Hash -eq $hash) 'Preflight failure changed the existing Word file.'
    $missingPath = Join-Path $testFolder ('rejected-' + [guid]::NewGuid().ToString('N') + '.docx')
    try { $null = Export-MarkdownToDocx $badInputs[2] -Path $missingPath } catch { }
    Check (-not (Test-Path -LiteralPath $missingPath)) 'Preflight failure left a partial Word file.'
    $badPath = Join-Path $testFolder 'intentionally-invalid-fixture.docx'
    Copy-Item -LiteralPath $goodPath -Destination $badPath -Force
    $zip = [IO.Compression.ZipFile]::Open($badPath,[IO.Compression.ZipArchiveMode]::Update)
    try { $zip.GetEntry('word/document.xml').Delete(); Add-ZipEntryString $zip 'word/document.xml' $badWord.OuterXml } finally { $zip.Dispose() }
    Check ((Get-EbookDocxArtifactIssues $badPath).status -eq 'FAIL') 'The shared release gate accepted a corrupted on-disk Word file.'
    Check ((Get-DocxPackageValidationResult $badPath -ArtifactName 'Corrupt fixture' -MinimumWords 0 -MinimumTextRuns 1).status -eq 'FAIL') 'Export validation ignored printed markup in the actual DOCX.'
    Write-Output "PASS: $script:citationChecks citation export regression assertions."
    Write-Output "Visual regression fixture: $goodPath"
} $OutputFolder
