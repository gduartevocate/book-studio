$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/EbookGenerator.psm1') -Force
$module = Get-Module EbookGenerator
& $module {
    $count = 0
    function Check([bool]$condition, [string]$message) { if (-not $condition) { throw $message }; $script:checksRun++ }
    $script:checksRun = 0
    $blocks = @(Get-ModulesFromWeekBlock @('Week 2 Functions','2. Compare functions.','3. Map processes.','2.1 Identify finance.','2.2 Explain dependencies.','3.1 Identify inputs.','3.2 Map handoffs.'))
    Check ($blocks.Count -eq 2 -and $blocks[0].subObjectives.Count -eq 2 -and $blocks[1].subObjectives.Count -eq 2) 'Lessons were assigned by proximity instead of parent ID.'
    Check ($blocks[0].subObjectives[0] -eq 'Identify finance.') 'CO2 received the wrong lesson.'
    $orphanRejected = $false
    try { Get-ModulesFromWeekBlock @('2. Compare functions.','3.1 Orphan lesson.') | Out-Null } catch { $orphanRejected = $true }
    Check $orphanRejected 'Orphan lesson was silently accepted.'
    $course = [pscustomobject]@{courseName='Business Office Operations';weeks=@([pscustomobject]@{number=1;modules=@([pscustomobject]@{objectiveId='7';objective='Recommend an improvement.'})})}
    $plan = [pscustomobject]@{chapters=@([pscustomobject]@{number=1;learningTargetRecords=@([pscustomobject]@{objectiveId='7';objective='Recommend an improvement.'})})}
    $md = "# Chapter 1: Business Office Operations`n`n### Learning Objectives`n`n1. Recommend an improvement.`n`n### Field Guide`n`n1. Identify a record.`n"
    Check ((Test-EbookObjectiveTraceability $course $plan $md).status -eq 'PASS') 'Nested learning objectives included field-guide items.'
    Check ((Test-EbookObjectiveTraceability $course $plan ($md -replace 'Recommend an improvement.', 'Teach leadership.')).status -eq 'FAIL') 'Wrong-course objective was accepted.'
    $course.weeks[0].modules[0].objectiveId = ''
    Check ((Test-EbookObjectiveTraceability $course $plan $md).status -eq 'FAIL') 'Missing source objective ID was accepted.'
    $html = ConvertTo-SimpleHtmlFromMarkdown -Markdown "| Role | Output |`n| --- | --- |`n| Clerk | Record |"
    Check ($html -match '<table>' -and $html -match '<th scope="col">Role</th>' -and $html -match '<td>Record</td>') 'HTML table was rendered as pipe text.'
    $rels = New-Object System.Collections.ArrayList
    $ids = New-Object System.Collections.ArrayList
    $xml = ConvertTo-WordDocumentXml -Markdown "# Chapter 1: Sample`n`n1. First block.`n2. Second item.`n`n### Another list`n`n1. New block.`n`nA source [1](#chapter-1-note-1).`n`n## Scholarly Sources`n`n1. A source.`n`n| Role | Output |`n| --- | --- |`n| Clerk | Record |" -HyperlinkRelationships $rels -RestartingNumberingIds $ids
    Check ($ids.Count -eq 3 -and @($ids | Select-Object -Unique).Count -eq 3) 'Ordered lists do not have separate numbering instances.'
    Check ($xml -match 'w:anchor="chapter_1_note_1"' -and $xml -match 'w:name="chapter_1_note_1"') 'Word note link lacks a matching internal bookmark.'
    Check ($rels.Count -eq 0) 'An internal note became an external relationship.'
    Check ($xml -match '<w:tblGrid>' -and $xml -match 'w:pStyle w:val="TableText"' -and $xml -match '<w:tblHeader/>' -and $xml -match '<w:cantSplit/>') 'Table layout lacks wrapping-safe style, grid, or row protection.'
    $styles = Get-WordStylesXml
    Check ($styles -match '(?s)styleId="TableText".*?w:right="0"') 'Table text inherits an overflowing negative right indent.'
    Check ((Get-WordNumberingXml) -notmatch 'w:ascii="Symbol"') 'Unicode bullet uses the incompatible Symbol font.'
    $chapter=[pscustomobject]@{number=1;title='Business Office Operations';focus='business office operations';learningTargets=@('Describe business operations.')}
    Check ((Get-SourceFidelitySignals -Course $course -Chapter $chapter -ChapterText 'Business office operations support an organization.').status -eq 'PASS') 'A non-leadership course was required to include GM1025 content.'
    $sourceJson = '[{"chapterNumber":1,"openStax":[{"url":"https://example.org/one"}],"researchCandidates":[]},{"chapterNumber":2,"openStax":[],"researchCandidates":[{"title":"Only chapter two","url":"https://example.org/two"}]}]'
    $nestedSources = @(ConvertFrom-Json $sourceJson)
    $one = Get-ChapterSources -Sources $nestedSources -ChapterNumber 1
    Check (@($one.researchCandidates).Count -eq 0 -and $one.chapterNumber -eq 1) 'A nested JSON array leaked another chapter''s research into chapter one.'
    $two = Get-ChapterSources -Sources $nestedSources -ChapterNumber 2
    Check (@($two.openStax).Count -eq 0 -and $two.chapterNumber -eq 2) 'A nested JSON array leaked another chapter''s OER into chapter two.'
    Check ($null -eq (Get-ChapterSources -Sources $nestedSources -ChapterNumber 3)) 'An absent source chapter matched another chapter.'
    $duplicateRejected = $false
    try { Get-ChapterSources -Sources @($one,$one) -ChapterNumber 1 | Out-Null } catch { $duplicateRejected = $true }
    Check $duplicateRejected 'Duplicate source chapters were accepted.'
    [xml]$notesXml = ConvertTo-WordDocumentXml -Markdown "# Chapter 1: Sample`n`n## Scholarly Sources`n`n1. First short source.`n2. Second short source.`n`n# Chapter 2: Next"
    $ns = New-Object Xml.XmlNamespaceManager($notesXml.NameTable)
    $ns.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    Check ($null -ne $notesXml.SelectSingleNode('//w:p[w:bookmarkStart/@w:name="chapter_1_note_1"]/w:pPr/w:keepNext',$ns)) 'Short bibliography notes can orphan across pages.'
    Check ($null -eq $notesXml.SelectSingleNode('//w:p[w:bookmarkStart/@w:name="chapter_1_note_2"]/w:pPr/w:keepNext',$ns)) 'The last bibliography note is incorrectly chained to the next chapter.'
    Write-Output "PASS: $script:checksRun publication regression assertions."
}
