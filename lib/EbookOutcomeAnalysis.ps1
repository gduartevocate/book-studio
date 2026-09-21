# The instructional designer's course-outcome analysis, done before any book
# is planned. A curriculum draft arrives from the academic team with approved
# course objectives and weekly learning objectives that were written for course
# delivery, not for a book. The designer keeps every course objective word for
# word and reworks only the learning objectives beneath them, then the book is
# generated from the reworked set.
#
# Nothing here calls Codex or writes a file. It builds the prompt, reads the
# reply, and refuses a reply that rewrote a course objective.

function Get-EbookOutcomeComparableText {
    # Course objectives are compared with runs of whitespace collapsed, because
    # a Word table cell and a chat reply disagree about line breaks and nothing
    # else. Wording, casing, and punctuation are compared exactly.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    return ((([string]$Text) -replace '\s+', ' ').Trim())
}

function Get-EbookOutcomeAnalysisFacts {
    # Everything the analysis needs from the parsed curriculum draft, with the
    # chapter list fixed to the draft's own weeks. The analyzer may renumber
    # learning objectives; it may not add, drop, or reorder chapters.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Course)

    $courseObjectives = @(
        foreach ($record in @($Course.courseObjectives)) {
            if (-not $record) { continue }
            $id = ([string]$record.objectiveId).Trim().ToUpperInvariant()
            if ($id -notmatch '^CO\d+$') { continue }
            [pscustomobject]@{ objectiveId = $id; objective = (Get-EbookOutcomeComparableText $record.objective) }
        }
    )
    $chapters = @(
        foreach ($week in @($Course.weeks | Sort-Object { [int]$_.number })) {
            $draftObjectives = @(
                foreach ($module in @($week.modules)) {
                    if (-not $module -or [string]::IsNullOrWhiteSpace([string]$module.objective)) { continue }
                    [pscustomobject]@{
                        objectiveId = ([string]$module.objectiveId).Trim()
                        objective = (Get-EbookOutcomeComparableText $module.objective)
                    }
                }
            )
            $mapped = @()
            if ($week.PSObject.Properties.Name -contains 'courseObjectiveIds') {
                $mapped = @(@($week.courseObjectiveIds) | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ -match '^CO\d+$' } | Select-Object -Unique)
            }
            [pscustomobject]@{
                number = [int]$week.number
                title = [string]$week.title
                courseObjectiveIds = @($mapped)
                draftObjectives = @($draftObjectives)
            }
        }
    )
    if ($chapters.Count -eq 0) { throw 'This course document has no weeks, so there is nothing to analyze. Upload the curriculum draft with its weekly grid, or choose "Ebook-ready course file" if the outcomes are already final.' }
    if ($courseObjectives.Count -eq 0) { throw 'This course document has no numbered course objectives (CO1, CO2, ...). The analysis keeps course objectives word for word, so it cannot run without them.' }

    return [pscustomobject]@{
        courseCode = [string]$Course.courseCode
        courseName = [string]$Course.courseName
        description = (Get-EbookOutcomeComparableText $Course.description)
        courseObjectives = @($courseObjectives)
        chapters = @($chapters)
    }
}

function New-EbookOutcomeAnalysisPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Facts,
        [AllowEmptyString()][string]$DesignerNotes = '',
        [AllowEmptyString()][string]$SourceExcerpt = ''
    )

    $objectiveLines = @(foreach ($record in @($Facts.courseObjectives)) { "$($record.objectiveId): $($record.objective)" })
    $chapterLines = New-Object System.Collections.ArrayList
    foreach ($chapter in @($Facts.chapters)) {
        [void]$chapterLines.Add("- Chapter $($chapter.number): $($chapter.title)")
        $mapped = if (@($chapter.courseObjectiveIds).Count) { (@($chapter.courseObjectiveIds) -join ', ') } else { '(the draft does not map course objectives to this week)' }
        [void]$chapterLines.Add("  - Course objectives the draft maps to this week: $mapped")
        if (@($chapter.draftObjectives).Count) {
            foreach ($record in @($chapter.draftObjectives)) {
                $label = if ([string]::IsNullOrWhiteSpace($record.objectiveId)) { 'draft objective' } else { $record.objectiveId }
                [void]$chapterLines.Add("  - Draft learning objective ($label): $($record.objective)")
            }
        }
        else {
            [void]$chapterLines.Add('  - Draft learning objectives: none stated for this week.')
        }
    }
    $notesBlock = if ([string]::IsNullOrWhiteSpace($DesignerNotes)) { '(none)' } else { $DesignerNotes }
    $excerptBlock = if ([string]::IsNullOrWhiteSpace($SourceExcerpt)) { '(the parsed structure above is the whole of it)' } else { $SourceExcerpt }
    $chapterCount = @($Facts.chapters).Count
    $chapterNumbers = (@($Facts.chapters | ForEach-Object { $_.number }) -join ', ')

    return @"
# Course Objective and Learning Objective Analysis

You are the instructional designer reviewing a curriculum draft for $($Facts.courseCode) $($Facts.courseName) before its ebook is written.

## The One Rule That Cannot Bend

The course objectives below were approved by the academic team. Reproduce each one **character for character** in your reply. Do not reword, shorten, re-punctuate, merge, split, add, or drop a course objective, even when you believe one is poorly written. If a course objective has a problem, say so in the analysis and leave its wording alone. A reply that changes course-objective wording is rejected in full.

You are reworking the **learning objectives** only.

## Course Objectives (verbatim, do not change)

$($objectiveLines -join "`r`n")

## Course Description

$($Facts.description)

## Chapters and the Draft's Weekly Objectives

The book has $chapterCount chapters, numbered $chapterNumbers, and that is fixed. Do not add, remove, merge, or renumber chapters.

$($chapterLines -join "`r`n")

## Designer Notes

$notesBlock

## What To Produce

1. Give every course objective two to four learning objectives, numbered ``LO<course objective number>.<sequence>`` so ``LO3.2`` is the second learning objective under ``CO3``. Every learning objective must sit under exactly one course objective.
2. Each learning objective states one observable, assessable performance, uses a measurable verb, and is written at or below the cognitive level of its course objective. Split a draft objective that bundles two performances. Rewrite one that says "understand", "learn about", or "be familiar with".
3. Cover the whole of each course objective across its learning objectives. Do not introduce content the course objective does not claim.
4. Assign outcomes to chapters. Start from the course objectives the draft maps to each week and change that mapping only when the draft is internally inconsistent; say so in the analysis when you do. Every chapter must receive at least one outcome, and every outcome must appear in at least one chapter. An outcome may appear in more than one chapter.
5. In the analysis, say what was wrong with the draft's learning objectives and what you changed. Name the draft objective and the replacement. Flag any course objective the draft leaves uncovered, any week whose mapping does not match its stated objectives, and any course objective whose own wording is unmeasurable.

## Curriculum Draft Text

$excerptBlock

## Required Reply Format

Reply with exactly these three blocks, in this order, with no other text before or after them. Use plain lines; no Markdown tables, headings, bold, or code fences.

ANALYSIS
- One finding per line.
END ANALYSIS

SUGGESTED OUTCOMES
CO1: <the course objective, character for character>
LO1.1: <learning objective>
LO1.2: <learning objective>
CO2: <the course objective, character for character>
LO2.1: <learning objective>
END SUGGESTED OUTCOMES

CHAPTER ASSIGNMENTS
Chapter 1: CO1, LO7.1
Chapter 2: CO2, CO3
END CHAPTER ASSIGNMENTS

In CHAPTER ASSIGNMENTS, naming ``CO3`` assigns every learning objective under ``CO3``. Name a single learning objective such as ``LO3.2`` to split a course objective across chapters.
"@
}

function Get-EbookOutcomeAnalysisBlock {
    # Markers are matched on their own line, allowing for the Markdown
    # decoration a model adds without being asked (#, *, `, >).
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Name
    )
    $start = -1
    $end = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = (($Lines[$i] -replace '^[\s>#*`_]+', '') -replace '[\s*`_:]+$', '').Trim()
        if ($start -lt 0) {
            if ($line -eq $Name) { $start = $i + 1 }
            continue
        }
        if ($line -eq "END $Name") { $end = $i; break }
    }
    if ($start -lt 0) { return $null }
    if ($end -lt 0) { $end = $Lines.Count }
    # An empty block is not a missing block. Returning one blank line keeps the
    # two apart so the caller can say which one happened.
    if ($end -le $start) { return , ([string[]]@('')) }
    return , ([string[]]@($Lines[$start..($end - 1)]))
}

function ConvertFrom-EbookOutcomeAnalysisResponse {
    # Reads the three-block reply. A missing block is reported by name, because
    # a designer who is handed "the analysis failed" cannot tell whether to
    # rerun it, fix the draft, or write the outcomes by hand.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'The analysis reply was empty. Run the analysis again, or enter the outcomes yourself.' }
    $lines = [string[]]@($Text -split '\r?\n')

    $catalogLines = Get-EbookOutcomeAnalysisBlock -Lines $lines -Name 'SUGGESTED OUTCOMES'
    if ($null -eq $catalogLines) { throw 'The analysis reply has no SUGGESTED OUTCOMES block, so there are no outcomes to review. Run the analysis again, or enter the outcomes yourself.' }
    $catalogText = (@($catalogLines | ForEach-Object { ($_ -replace '^[\s>#*`_]+', '').TrimEnd() }) -join "`r`n").Trim()
    if ([string]::IsNullOrWhiteSpace($catalogText)) { throw 'The analysis reply has an empty SUGGESTED OUTCOMES block. Run the analysis again, or enter the outcomes yourself.' }

    $assignmentLines = Get-EbookOutcomeAnalysisBlock -Lines $lines -Name 'CHAPTER ASSIGNMENTS'
    if ($null -eq $assignmentLines) { throw 'The analysis reply has no CHAPTER ASSIGNMENTS block, so the suggested outcomes are not assigned to chapters. Run the analysis again, or assign them yourself.' }
    $assignments = New-Object System.Collections.ArrayList
    foreach ($raw in @($assignmentLines)) {
        $line = ($raw -replace '^[\s>#*`_-]+', '').Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^Chapter\s+(\d+)\s*[:.\-]\s*(.*)$') { throw "The analysis reply has an unreadable chapter assignment: $line. Each line must read 'Chapter 1: CO1, LO7.1'." }
        $number = [int]$Matches[1]
        if (@($assignments | Where-Object { $_.number -eq $number }).Count) { throw "The analysis reply assigns Chapter $number twice." }
        [void]$assignments.Add([pscustomobject]@{ number = $number; ids = ($Matches[2].Trim().TrimEnd('.')) })
    }
    if ($assignments.Count -eq 0) { throw 'The analysis reply has an empty CHAPTER ASSIGNMENTS block. Run the analysis again, or assign the outcomes yourself.' }

    $findings = @()
    $findingLines = Get-EbookOutcomeAnalysisBlock -Lines $lines -Name 'ANALYSIS'
    if ($null -ne $findingLines) {
        $findings = @(
            foreach ($raw in @($findingLines)) {
                $line = ($raw -replace '^[\s>#*`_]*[-*•]?\s*', '').Trim()
                if (-not [string]::IsNullOrWhiteSpace($line)) { $line }
            }
        )
    }

    return [pscustomobject]@{
        findings = @($findings)
        catalogText = $catalogText
        assignments = @($assignments.ToArray())
    }
}

function Test-EbookCourseObjectiveFidelity {
    # The gate behind the one rule. Returns one problem record per course
    # objective that was rewritten, dropped, or invented, each quoting both
    # texts so the designer can see exactly what changed without diffing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CourseObjectives,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Catalog
    )

    $problems = New-Object System.Collections.ArrayList
    $catalogObjectives = @($Catalog | Where-Object { ([string]$_.objectiveId) -match '^CO\d+$' })
    foreach ($official in @($CourseObjectives)) {
        $id = ([string]$official.objectiveId).ToUpperInvariant()
        $proposed = @($catalogObjectives | Where-Object { ([string]$_.objectiveId).ToUpperInvariant() -eq $id })
        if ($proposed.Count -eq 0) {
            [void]$problems.Add([pscustomobject]@{
                objectiveId = $id
                kind = 'missing'
                official = [string]$official.objective
                proposed = ''
                message = "$id is missing. The course document states: `"$($official.objective)`""
            })
            continue
        }
        $officialText = Get-EbookOutcomeComparableText $official.objective
        $proposedText = Get-EbookOutcomeComparableText $proposed[0].objective
        if ($officialText -cne $proposedText) {
            [void]$problems.Add([pscustomobject]@{
                objectiveId = $id
                kind = 'reworded'
                official = $officialText
                proposed = $proposedText
                message = "$id was reworded. The course document states: `"$officialText`" The suggestion states: `"$proposedText`""
            })
        }
    }
    foreach ($proposed in $catalogObjectives) {
        $id = ([string]$proposed.objectiveId).ToUpperInvariant()
        if (@($CourseObjectives | Where-Object { ([string]$_.objectiveId).ToUpperInvariant() -eq $id }).Count -eq 0) {
            [void]$problems.Add([pscustomobject]@{
                objectiveId = $id
                kind = 'added'
                official = ''
                proposed = (Get-EbookOutcomeComparableText $proposed.objective)
                message = "$id is not a course objective in the course document: `"$(Get-EbookOutcomeComparableText $proposed.objective)`""
            })
        }
    }
    # Not comma-wrapped: every caller wraps the result in @(), and wrapping an
    # empty result here would hand them one element that is an empty array.
    return $problems.ToArray()
}

function ConvertTo-EbookOutcomeSpecSheetMarkdown {
    # The reworked outcomes written back out in the ebook-ready course-file
    # layout, so the designer can hand the same document to the next build and
    # skip the analysis. Import-CourseSpec must read this back as the same
    # chapters and objectives; tests/outcome-analysis-regressions.ps1 checks it.
    #
    # The course description is written last, on purpose. Get-BetweenLabels
    # reads "Course Description" to the next Grading/Criteria label or to the
    # end of the file, so a description placed above the weeks would swallow
    # them.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Facts,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chapters
    )

    $byId = @{}
    foreach ($record in @($Catalog)) { $byId[([string]$record.objectiveId).ToUpperInvariant()] = $record }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('Spec Sheet')
    [void]$lines.Add('')
    [void]$lines.Add('Course Number')
    [void]$lines.Add([string]$Facts.courseCode)
    [void]$lines.Add('')
    [void]$lines.Add('Course Name')
    [void]$lines.Add([string]$Facts.courseName)
    [void]$lines.Add('')
    foreach ($chapter in @($Chapters | Sort-Object { [int]$_.number })) {
        [void]$lines.Add("Week $([int]$chapter.number) $([string]$chapter.title)")
        [void]$lines.Add('Course Objective')
        [void]$lines.Add('Lesson Objectives')
        $parents = New-Object System.Collections.ArrayList
        foreach ($record in @($chapter.records)) {
            $id = ([string]$record.objectiveId).ToUpperInvariant()
            $parentNumber = if ($id -match '^LO(\d+)\.') { $Matches[1] } elseif ($id -match '^CO(\d+)$') { $Matches[1] } else { '' }
            if ($parentNumber -and $parents -notcontains $parentNumber) { [void]$parents.Add($parentNumber) }
        }
        foreach ($parentNumber in @($parents | Sort-Object { [int]$_ })) {
            $parent = $byId["CO$parentNumber"]
            $text = if ($parent) { Get-EbookOutcomeComparableText $parent.objective } else { "Course objective $parentNumber" }
            [void]$lines.Add("$parentNumber. $text")
        }
        foreach ($parentNumber in @($parents | Sort-Object { [int]$_ })) {
            $lessons = @($chapter.records | Where-Object { ([string]$_.objectiveId).ToUpperInvariant() -match "^LO$parentNumber\.(\d+)$" })
            foreach ($lesson in @($lessons)) {
                $sequence = ([string]$lesson.objectiveId).ToUpperInvariant() -replace '^LO\d+\.', ''
                [void]$lines.Add("$parentNumber.$sequence $(Get-EbookOutcomeComparableText $lesson.objective)")
            }
        }
        [void]$lines.Add('')
    }
    if (-not [string]::IsNullOrWhiteSpace($Facts.description)) {
        [void]$lines.Add('Course Description')
        [void]$lines.Add([string]$Facts.description)
        [void]$lines.Add('')
    }
    return (($lines.ToArray()) -join "`r`n")
}

function ConvertTo-EbookOutcomeAnalysisMarkdown {
    # The designer-facing record of the review: what the draft said, what was
    # changed, why, and which chapter teaches each outcome.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Facts,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chapters,
        [AllowEmptyCollection()][AllowNull()][string[]]$Findings = @(),
        [AllowEmptyString()][string]$ReviewedBy = '',
        [AllowEmptyString()][string]$Reason = '',
        [AllowEmptyString()][string]$ConfirmedAt = ''
    )

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# $($Facts.courseCode) $($Facts.courseName) - Course Objectives and Learning Objectives")
    [void]$lines.Add('')
    [void]$lines.Add("Reviewed by $(if ([string]::IsNullOrWhiteSpace($ReviewedBy)) { 'the instructional designer' } else { $ReviewedBy }) on $(if ([string]::IsNullOrWhiteSpace($ConfirmedAt)) { (Get-Date).ToString('s') } else { $ConfirmedAt }).")
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        [void]$lines.Add('')
        [void]$lines.Add("Reason for the revision: $Reason")
    }
    [void]$lines.Add('')
    [void]$lines.Add('Course objectives are reproduced from the curriculum draft word for word. Only the learning objectives beneath them were reworked.')
    [void]$lines.Add('')
    [void]$lines.Add('## Analysis')
    [void]$lines.Add('')
    if (@($Findings).Count) {
        foreach ($finding in @($Findings)) { [void]$lines.Add("- $finding") }
    }
    else {
        [void]$lines.Add('- No analysis notes were recorded with this revision.')
    }
    [void]$lines.Add('')
    [void]$lines.Add('## Course Objectives and Learning Objectives')
    [void]$lines.Add('')
    foreach ($record in @($Catalog | Where-Object { ([string]$_.objectiveId) -match '^CO\d+$' })) {
        $number = ([string]$record.objectiveId) -replace '^CO', ''
        [void]$lines.Add("**$($record.objectiveId).** $(Get-EbookOutcomeComparableText $record.objective)")
        [void]$lines.Add('')
        $lessons = @($Catalog | Where-Object { ([string]$_.objectiveId) -match "^LO$number\.\d+$" })
        foreach ($lesson in @($lessons)) { [void]$lines.Add("- $($lesson.objectiveId): $(Get-EbookOutcomeComparableText $lesson.objective)") }
        if (@($lessons).Count -eq 0) { [void]$lines.Add('- No learning objectives were written under this course objective.') }
        [void]$lines.Add('')
    }
    [void]$lines.Add('## Chapter Assignments')
    [void]$lines.Add('')
    foreach ($chapter in @($Chapters | Sort-Object { [int]$_.number })) {
        [void]$lines.Add("### Chapter $($chapter.number): $($chapter.title)")
        [void]$lines.Add('')
        foreach ($record in @($chapter.records)) { [void]$lines.Add("- $($record.objectiveId): $(Get-EbookOutcomeComparableText $record.objective)") }
        [void]$lines.Add('')
    }
    return (($lines.ToArray()) -join "`r`n")
}
