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
    # The publication policy excludes prohibited learner SECTIONS and links to
    # the local study page. Matching those words anywhere in the prose failed a
    # whole book for one ordinary sentence, and named neither text nor chapter.
    $chapterShell = "# Chapter 1: Payer Systems`n`n## Introduction`n`nBODY`n"
    function ProhibitedIssue([string]$Body) {
        $result = Test-EbookPublicationTemplate -Markdown $chapterShell.Replace('BODY', $Body)
        return @($result.issues | Where-Object { $_ -match 'prohibited learner sections' })
    }
    foreach ($prose in @('Students review the chapter summary before class.', 'This is an interactive study of payer operations.', 'Think about it carefully before deciding.')) {
        Check ((ProhibitedIssue $prose).Count -eq 0) "Ordinary prose was rejected as a prohibited section: $prose"
    }
    foreach ($violation in @("## Knowledge Check`n`nAnswer these.", "### Reflection Activity`n`nWrite a paragraph.", "## Chapter Summary`n`nWe covered payers.")) {
        Check ((ProhibitedIssue $violation).Count -eq 1) "A prohibited section heading was allowed: $violation"
    }
    Check ((ProhibitedIssue '**Knowledge Check:** name three payers.').Count -eq 1) 'A prohibited bold label was allowed.'
    Check ((ProhibitedIssue 'See [the study page](interactive-study.html#chapter-1).').Count -eq 1) 'An interactive-study link was allowed.'
    $named = @(ProhibitedIssue "## Knowledge Check`n`nAnswer these.")[0]
    Check ($named -match "Chapter 1" -and $named -match "## Knowledge Check") "The refusal does not name the chapter and the offending text: $named"

    # Exporting gates the manuscript on the publication template and on the
    # prohibited-section rules, but only the rebuild path normalized the
    # manuscript first. Generation therefore judged text that had never been
    # through the step the gates assume, so a book could fail at export and
    # then pass an unchanged Rebuild Package. Both paths must normalize.
    $generation = (Get-Command New-EbookPackage).Definition
    foreach ($step in @('ConvertTo-EbookPublicationMarkdown', 'ConvertTo-EbookBusinessCaseLabel', 'Remove-ProhibitedKnowledgeCheckSections', 'Remove-ProhibitedLearnerSections')) {
        Check ($generation -match [regex]::Escape($step)) "Generation does not apply $step, so export gates text the rebuild path would have cleaned."
    }
    $dirty = @(
        '# Chapter 1: Payer Systems', '', '## Introduction', '',
        'Payers coordinate benefits and claims for members.', '',
        '## Knowledge Check', '', 'Name three payer types.', '',
        '## Reflection Activity', '', 'Write about a claim you have filed.', '',
        '## Chapter Summary', '', 'Payers connect members, providers, and plans.', ''
    ) -join "`r`n"
    $normalized = ConvertTo-EbookPublicationMarkdown -Markdown (ConvertTo-EbookBusinessCaseLabel -Markdown $dirty)
    $normalized = [string](Remove-ProhibitedKnowledgeCheckSections -Markdown $normalized).markdown
    $normalized = [string](Remove-ProhibitedLearnerSections -Markdown $normalized).markdown
    Check ((Get-ProhibitedKnowledgeCheckSignals -Markdown $normalized).status -eq 'PASS') 'The normalized manuscript still trips the knowledge-check export gate.'
    Check ((Get-ProhibitedLearnerSectionSignals -Markdown $normalized).status -eq 'PASS') 'The normalized manuscript still trips the learner-section export gate.'
    $normalizedTemplate = @(Test-EbookPublicationTemplate -Markdown $normalized).issues | Where-Object { $_ -match 'prohibited learner sections' }
    Check (@($normalizedTemplate).Count -eq 0) "The normalized manuscript still trips the publication template gate: $normalizedTemplate"
    Check ($normalized -match 'Payers coordinate benefits') 'Normalization discarded ordinary chapter prose.'

    # A real MI1000 objective reads "completing a structured knowledge check
    # with 80% accuracy". Rewriting the prohibited words wherever they appeared
    # changed the rendered objective, and objective traceability then refused
    # the book because it no longer matched the course document exactly.
    $objective = 'Demonstrate correct use of payer terminology by completing a structured knowledge check with ' + [char]0x2265 + ' 80% accuracy.'
    $withObjective = @(
        '# Chapter 1: Health Insurance and Payer Ecosystem', '',
        '### Learning Objectives', '',
        '1. Identify major U.S. payer types and basic plan structures.',
        "2. $objective", '',
        '### Section 1.1 - Understanding the context', '',
        'Members review the chapter summary before their annual enrollment meeting.', '',
        '## Knowledge Check', '', 'Name three payer types.', '',
        '**Reflection Activity:** write a paragraph.', ''
    ) -join "`r`n"
    $cleanedOnce = [string](Remove-ProhibitedKnowledgeCheckSections -Markdown $withObjective).markdown
    $cleaned = [string](Remove-ProhibitedLearnerSections -Markdown $cleanedOnce).markdown
    Check ($cleaned.Contains($objective)) 'Cleaning rewrote a course objective, which objective traceability compares word for word.'
    Check ($cleaned -match 'review the chapter summary before their annual') 'Cleaning rewrote ordinary prose that merely names a chapter summary.'
    Check (-not ($cleaned -match '(?im)^##\s+Knowledge Check')) 'A prohibited section heading survived cleaning.'
    Check (-not ($cleaned -match '(?i)Reflection Activity')) 'A prohibited label that opens a line survived cleaning.'
    Check ((Get-ProhibitedKnowledgeCheckSignals -Markdown $cleaned).status -eq 'PASS') 'The cleaned manuscript still trips the knowledge-check gate.'
    Check ((Get-ProhibitedLearnerSectionSignals -Markdown $cleaned).status -eq 'PASS') 'The cleaned manuscript still trips the learner-section gate.'
    # The gates must agree with the cleaners, or export refuses text the
    # cleaners deliberately kept.
    $objectiveOnly = @('### Learning Objectives', '', "1. $objective", '', '### Section 1.1 - Context', '', 'Members sit a short quiz test at the clinic.', '') -join "`r`n"
    Check ((Get-ProhibitedKnowledgeCheckSignals -Markdown $objectiveOnly).status -eq 'PASS') 'The knowledge-check gate flagged a course objective or ordinary prose.'
    Check ((Get-ProhibitedLearnerSectionSignals -Markdown "Members review the chapter summary each term.").status -eq 'PASS') 'The learner-section gate flagged ordinary prose.'
    Check ((Get-ProhibitedLearnerSectionSignals -Markdown "## Chapter Summary").count -ge 1) 'The learner-section gate stopped seeing a prohibited heading.'
    $records = @(
        [pscustomobject]@{ objectiveId = '1'; objective = 'Identify major U.S. payer types and basic plan structures.' },
        [pscustomobject]@{ objectiveId = '7'; objective = $objective }
    )
    $objectiveCourse = [pscustomobject]@{ courseName = 'Payer Systems'; weeks = @([pscustomobject]@{ number = 1; modules = $records }) }
    $objectivePlan = [pscustomobject]@{ chapters = @([pscustomobject]@{ number = 1; learningTargetRecords = $records }) }
    $trace = Test-EbookObjectiveTraceability $objectiveCourse $objectivePlan $cleaned
    Check ($trace.status -eq 'PASS') "A cleaned manuscript must keep objective traceability: $(@($trace.issues) -join ' ')"


# Objective traceability reads the Learning Objectives list as a numbered list
# restarting at 1 per chapter, but nothing told the drafting pass that. Codex
# rendered RB1010's objectives as bullets, the gate reported "Markdown has 0
# rendered objective(s); source has 4" for every chapter, and a book whose
# objectives were word-perfect was refused over the list marker.
$objFixture = Join-Path ([IO.Path]::GetTempPath()) ('objective-numbering-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $objFixture | Out-Null
try {
    $objPath = Join-Path $objFixture 'book.md'
    $objective1 = "Describe the major stages of the revenue cycle from patient scheduling through final payment."
    $objective2 = "Explain how each department contributes to revenue integrity and the patient's financial experience."
    $objective3 = "Apply ICD-10-CM, CPT, and HCPCS Level II codes to basic healthcare scenarios."
    @(
        '# Chapter 1: Revenue Cycle', '', '### Learning Objectives', '',
        'By the end of this chapter, you should be able to:', '',
        "- $objective1", "- $objective2", '',
        '## Section 1.1 - Intake', '',
        '# Chapter 2: Coding', '', '### Learning Objectives', '',
        "7. $objective3", '',
        '## Section 2.1 - Codes'
    ) -join "`r`n" | Set-Content -LiteralPath $objPath -Encoding UTF8

    Check (Update-EbookObjectiveListNumbering -MarkdownPath $objPath) 'A bulleted objective list must be renumbered.'
    $fixed = Get-Content -LiteralPath $objPath -Raw -Encoding UTF8
    $records = @(& $module { param($t) Get-EbookObjectiveRecordsFromMarkdown -Markdown $t } $fixed)
    Check ($records.Count -eq 3) "The gate must now see every objective (got $($records.Count) of 3)."
    Check ((@($records | Where-Object chapterNumber -eq 1 | ForEach-Object { $_.objectiveId }) -join ',') -eq '1,2') 'Chapter 1 numbering starts at 1.'
    Check ((@($records | Where-Object chapterNumber -eq 2 | ForEach-Object { $_.objectiveId }) -join ',') -eq '1') 'Chapter 2 numbering restarts at 1 instead of continuing.'
    # Traceability compares wording character for character, so only the marker may change.
    foreach ($text in @($objective1, $objective2, $objective3)) {
        Check (@($records | Where-Object { $_.objective -ceq $text }).Count -eq 1) "Objective wording must survive renumbering unchanged: $text"
    }
    Check ($fixed -notmatch '(?m)^- ') 'No objective may be left as a bullet.'
    Check (-not (Update-EbookObjectiveListNumbering -MarkdownPath $objPath)) 'Renumbering an already-numbered list must report no change.'

    # The drafter has to be told, or the cleaner runs on every single book.
    $instructions = Get-EbookTemplateInstructions
    Check ($instructions -match 'numbered list that restarts at 1') 'The drafting instruction must state the objective list format the gate requires.'
    Check ($instructions -match 'Do not convert it to bullets') 'The drafting instruction must forbid the exact drift that occurred.'
}
finally { Remove-Item -LiteralPath $objFixture -Recurse -Force -ErrorAction SilentlyContinue }


# The reading level is chosen per course, defaults to grade 8, and has to reach
# every place that enforces or teaches it. RB1010 measured 11.8 against a
# hardcoded 8 in all five chapters, and the drafting pass was never told the
# target it was being judged against.
$range = Get-EbookReadingLevelRange
Check ($range.default -eq 8) 'Grade 8 stays the default.'
Check ($range.minimum -eq 6 -and $range.maximum -eq 16) 'The selectable range is grade 6 to 16.'

# A bad value must fall back to the default, never to "no threshold".
foreach ($bad in @($null, '', 'abc', 4, 99, [double]::NaN)) {
    Check ((Test-EbookReadingLevel -Value $bad) -eq 8) "An unusable reading level falls back to grade 8, not to no limit: '$bad'"
}
Check ((Test-EbookReadingLevel -Value 12) -eq 12) 'A valid level is honoured.'
Check ((Get-EbookEditorialPolicy -MaximumGrade 12).maximumGrade -eq 12) 'The policy carries the chosen level.'
Check ((Get-EbookEditorialPolicy).maximumGrade -eq 8) 'The policy still defaults to grade 8.'
Check ((Get-EbookEditorialPolicy -MaximumGrade 12).version -eq (Get-EbookEditorialPolicy).version) 'Changing the level must not change the policy version, which is compared for staleness.'

# The same manuscript passes or fails on the course's own setting.
Check ((Test-EbookEditorialThresholds -Grade 11.8 -PassiveRate 0 -MaximumGrade 8).status -eq 'FAIL') 'Grade 11.8 fails a grade-8 course.'
Check ((Test-EbookEditorialThresholds -Grade 11.8 -PassiveRate 0 -MaximumGrade 12).status -eq 'PASS') 'Grade 11.8 passes a grade-12 course.'
Check ((Test-EbookEditorialThresholds -Grade 11.8 -PassiveRate 0).status -eq 'FAIL') 'With no level supplied the grade-8 default still applies.'
# Raising the reading level must not loosen anything else.
Check ((Test-EbookEditorialThresholds -Grade 6 -PassiveRate 9 -MaximumGrade 16).status -eq 'FAIL') 'The passive-voice threshold is not course-specific and still binds.'

# The plan is the one place every consumer reads it from.
Check ((Get-EbookPlanReadingLevel -Plan ([pscustomobject]@{readingLevel=12})) -eq 12) 'The plan carries the level.'
Check ((Get-EbookPlanReadingLevel -Plan ([pscustomobject]@{})) -eq 8) 'A plan without a level uses the default.'
Check ((Get-EbookPlanReadingLevel -Plan $null) -eq 8) 'A missing plan uses the default.'

# The style check enforces the course's level, and reports which one applied.
$prose = ('# Chapter 1: Test' + "`r`n`r`n" + ('A clerk checks the claim. The payer reads the codes. A denial costs time. The team fixes it fast. ') + ('The billing department reviews each submitted claim against the clinical documentation before adjudication. ' * 4))
$measured = (Get-UmaWritingStyleGuideMetrics -Markdown $prose).fleschKincaidGrade
$below = [Math]::Max(6, [Math]::Floor($measured) - 1)
$above = [Math]::Min(16, [Math]::Ceiling($measured) + 1)
Check ($measured -gt 8) "The readability fixture must sit above the default to be meaningful (measured $measured)."
$strict = Get-UmaWritingStyleGuideMetrics -Markdown $prose -MaximumGrade $below
Check ($strict.readingLevel -eq $below) 'The style check reports the level it enforced.'
Check (@($strict.issues | Where-Object { $_ -match 'Flesch-Kincaid' }).Count -eq 1) "Prose at grade $measured fails a grade-$below course."
if ($above -ge $measured) {
    $lenient = Get-UmaWritingStyleGuideMetrics -Markdown $prose -MaximumGrade $above
    Check (@($lenient.issues | Where-Object { $_ -match 'Flesch-Kincaid' }).Count -eq 0) "The same prose passes a grade-$above course."
}

# The drafting pass has to be told the target, or it writes to no target at all.
Check ((Get-EbookTemplateInstructions) -match 'Flesch-Kincaid grade 8') 'The drafting instruction states the default target.'
Check ((Get-EbookTemplateInstructions -ReadingLevel 12) -match 'Flesch-Kincaid grade 12') "The drafting instruction states the course's chosen target."
Check ((Get-EbookTemplateInstructions) -match 'the quality gate measures it') 'The drafting instruction says the target is enforced, not advisory.'

    Write-Output "PASS: $script:checksRun publication regression assertions."
}
