$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force -DisableNameChecking
. (Join-Path $root 'lib/BookStudioIntake.ps1')
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# A synthetic course. No private course content is used; the shape mirrors a
# parsed curriculum draft: numbered course objectives, weeks that map course
# objectives, and weekly learning objectives written for delivery.
$course = [pscustomobject]@{
    courseCode = 'QA2010'
    courseName = 'Fixture Revenue Operations'
    description = 'A fixture course used only by this regression suite.'
    courseObjectives = @(
        [pscustomobject]@{ objectiveId = 'CO1'; objective = 'Describe the end-to-end revenue cycle from registration through collections.' },
        [pscustomobject]@{ objectiveId = 'CO2'; objective = 'Apply coding systems to basic scenarios.' },
        [pscustomobject]@{ objectiveId = 'CO3'; objective = 'Analyze billing errors that impact reimbursement.' }
    )
    weeks = @(
        [pscustomobject]@{ number = 1; title = 'Revenue Cycle Foundations'; courseObjectiveIds = @('CO1'); modules = @(
            [pscustomobject]@{ objectiveId = 'LO1'; title = 'Stages'; objective = 'Describe the major stages of the revenue cycle.'; subObjectives = @() }) },
        [pscustomobject]@{ number = 2; title = 'Coding System Fundamentals'; courseObjectiveIds = @('CO2', 'CO1'); modules = @(
            [pscustomobject]@{ objectiveId = 'LO2'; title = 'Codes'; objective = 'Understand coding classifications and apply appropriate codes.'; subObjectives = @() }) },
        [pscustomobject]@{ number = 3; title = 'Billing Error Analysis'; courseObjectiveIds = @('CO3'); modules = @(
            [pscustomobject]@{ objectiveId = 'LO3'; title = 'Errors'; objective = 'Analyze billing errors and recommend corrections.'; subObjectives = @() }) }
    )
    sourcePath = $null
}

$facts = Get-EbookOutcomeAnalysisFacts -Course $course
Check ($facts.courseCode -eq 'QA2010' -and @($facts.courseObjectives).Count -eq 3) 'Facts carry the course code and every numbered course objective.'
Check (@($facts.chapters).Count -eq 3 -and $facts.chapters[1].number -eq 2) 'Chapters follow the course weeks, in order.'
Check ((@($facts.chapters[1].courseObjectiveIds) -join ',') -eq 'CO2,CO1') "The week's own course-objective mapping is preserved (got '$(@($facts.chapters[1].courseObjectiveIds) -join ',')')."
Check (@($facts.chapters[0].draftObjectives).Count -eq 1 -and $facts.chapters[0].draftObjectives[0].objectiveId -eq 'LO1') 'The draft learning objectives are kept for reference.'

# A course document with no numbered course objectives cannot be analyzed, and
# must say so instead of producing an analysis with nothing to hold onto.
$noObjectives = [pscustomobject]@{ courseCode = 'QA2011'; courseName = 'x'; description = ''; courseObjectives = @(); weeks = @($course.weeks[0]); sourcePath = $null }
try { Get-EbookOutcomeAnalysisFacts -Course $noObjectives | Out-Null; throw 'FAIL: A course with no course objectives must be refused.' }
catch { Check ($_.Exception.Message -match 'no numbered course objectives') 'A course with no CO1/CO2 rows is refused by name.' }

$prompt = New-EbookOutcomeAnalysisPrompt -Facts $facts -DesignerNotes 'Fixture note.'
Check ($prompt -match 'character for character') 'The prompt states the verbatim rule for course objectives.'
Check ($prompt -match [regex]::Escape('CO1: Describe the end-to-end revenue cycle from registration through collections.')) 'The prompt quotes each course objective exactly as the course document states it.'
Check ($prompt -match 'Fixture note\.') 'Designer notes reach the prompt.'
Check ($prompt -match 'SUGGESTED OUTCOMES' -and $prompt -match 'CHAPTER ASSIGNMENTS') 'The prompt states the reply format the parser reads.'

# The house pattern the instructional designer actually writes: exactly two
# learning objectives per course objective, forming an enabling-to-terminal
# ladder. Without it the analyzer splits a course objective into parallel
# same-level objectives by topic, which is not what a designer produces.
Check ($prompt -match 'exactly two learning objectives') 'The prompt states the two-objective pattern.'
Check ($prompt -match 'enabling' -and $prompt -match 'terminal') 'The prompt describes the enabling-to-terminal ladder.'
Check ($prompt -match 'each assign one code set is wrong') 'The prompt rejects splitting a course objective into parallel topic objectives.'
Check ($prompt -match 'Never write a fourth') 'The prompt caps the objective count.'
# The terminal verb is the designer's judgment call, so the analyzer decides it
# per course objective and has to show its reasoning rather than apply a rule.
Check ($prompt -match 'hold its own verb or lift one level') 'The terminal verb is a decision, not a fixed rule.'
Check ($prompt -match 'Never lift more than one level') 'The lift is capped at one level.'
Check ($prompt -match 'state whether its terminal objective holds') 'The prompt requires each verb decision to be justified in the analysis.'

# The reply parser. Models decorate blocks with Markdown even when told not to,
# and a decorated reply that is otherwise correct must not be thrown away.
$reply = @'
Here is what I found.

**ANALYSIS**
- LO2 says "understand", which is not observable.
- CO3 has no measurable learning objective in the draft.
END ANALYSIS

## SUGGESTED OUTCOMES
CO1: Describe the end-to-end revenue cycle from registration through collections.
LO1.1: Describe the major stages of the revenue cycle.
LO1.2: Explain how each department contributes to revenue integrity.
CO2: Apply coding systems to basic scenarios.
LO2.1: Differentiate among the purposes of each code set.
CO3: Analyze billing errors that impact reimbursement.
LO3.1: Identify common billing errors that cause denials.
END SUGGESTED OUTCOMES

CHAPTER ASSIGNMENTS
Chapter 1: CO1
Chapter 2: CO2, LO1.2
Chapter 3: CO3
END CHAPTER ASSIGNMENTS
'@
$parsed = ConvertFrom-EbookOutcomeAnalysisResponse -Text $reply
Check (@($parsed.findings).Count -eq 2 -and $parsed.findings[0] -like 'LO2 says*') "Findings lose their bullet markers (got '$($parsed.findings[0])')."
Check ($parsed.catalogText -match '^CO1: Describe') 'The outcome catalog survives a Markdown heading around its marker.'
Check ($parsed.catalogText -notmatch 'ANALYSIS') 'Blocks do not bleed into one another.'
Check (@($parsed.assignments).Count -eq 3 -and $parsed.assignments[1].ids -eq 'CO2, LO1.2') "Chapter assignments keep their ID lists (got '$($parsed.assignments[1].ids)')."

foreach ($case in @(
    @{ text = "SUGGESTED OUTCOMES`r`nCO1: x`r`nEND SUGGESTED OUTCOMES"; expect = 'no CHAPTER ASSIGNMENTS block' },
    @{ text = "CHAPTER ASSIGNMENTS`r`nChapter 1: CO1`r`nEND CHAPTER ASSIGNMENTS"; expect = 'no SUGGESTED OUTCOMES block' },
    @{ text = ''; expect = 'empty' }
)) {
    try { ConvertFrom-EbookOutcomeAnalysisResponse -Text $case.text | Out-Null; throw "FAIL: An unusable reply must be refused ($($case.expect))." }
    catch { Check ($_.Exception.Message -match [regex]::Escape($case.expect)) "An unusable reply names what is missing: $($case.expect)." }
}
try { ConvertFrom-EbookOutcomeAnalysisResponse -Text "SUGGESTED OUTCOMES`r`nCO1: x`r`nEND SUGGESTED OUTCOMES`r`nCHAPTER ASSIGNMENTS`r`nWeek one gets CO1`r`nEND CHAPTER ASSIGNMENTS" | Out-Null; throw 'FAIL: An unreadable assignment line must be refused.' }
catch { Check ($_.Exception.Message -match 'Week one gets CO1') 'An unreadable assignment line is quoted back.' }

# The gate the whole stage exists to hold: course objectives are the academic
# team's words. A rewrite is reported with both texts, because a designer who
# is told only "a course objective changed" cannot find which one.
$catalog = @(ConvertFrom-EbookOutcomeCatalog $parsed.catalogText)
Check (@(Test-EbookCourseObjectiveFidelity -CourseObjectives @($facts.courseObjectives) -Catalog $catalog).Count -eq 0) 'An untouched course objective passes the fidelity gate.'

$reworded = @(ConvertFrom-EbookOutcomeCatalog ($parsed.catalogText -replace 'CO2: Apply coding systems to basic scenarios\.', 'CO2: Apply coding systems to basic healthcare scenarios.'))
$problems = @(Test-EbookCourseObjectiveFidelity -CourseObjectives @($facts.courseObjectives) -Catalog $reworded)
Check ($problems.Count -eq 1 -and $problems[0].objectiveId -eq 'CO2' -and $problems[0].kind -eq 'reworded') 'A reworded course objective is caught by ID.'
Check ($problems[0].message -match 'Apply coding systems to basic scenarios\.' -and $problems[0].message -match 'basic healthcare scenarios') 'The refusal quotes both the official and the suggested wording.'

$dropped = @($catalog | Where-Object { $_.objectiveId -ne 'CO3' })
Check (@(Test-EbookCourseObjectiveFidelity -CourseObjectives @($facts.courseObjectives) -Catalog $dropped | Where-Object { $_.kind -eq 'missing' }).Count -eq 1) 'A dropped course objective is caught.'
$invented = @($catalog) + @([pscustomobject]@{ objectiveId = 'CO9'; objective = 'Invent a new course objective.' })
Check (@(Test-EbookCourseObjectiveFidelity -CourseObjectives @($facts.courseObjectives) -Catalog $invented | Where-Object { $_.kind -eq 'added' }).Count -eq 1) 'An invented course objective is caught.'

# A course objective that only differs by how a Word cell wrapped it is the
# same objective. Only wording, casing, and punctuation count as a change.
$rewrapped = @($catalog | ForEach-Object { [pscustomobject]@{ objectiveId = $_.objectiveId; objective = ($_.objective -replace ' ', "`r`n") } })
Check (@(Test-EbookCourseObjectiveFidelity -CourseObjectives @($facts.courseObjectives) -Catalog $rewrapped).Count -eq 0) 'Re-wrapped whitespace is not treated as a rewrite.'
$recased = @($catalog | ForEach-Object { [pscustomobject]@{ objectiveId = $_.objectiveId; objective = $_.objective.ToUpperInvariant() } })
Check (@(Test-EbookCourseObjectiveFidelity -CourseObjectives @($facts.courseObjectives) -Catalog $recased).Count -eq 3) 'A change of casing is a rewrite.'

# Assignment resolution is shared with the post-preview outcome replacement.
# Both reviews must accept and refuse exactly the same thing.
$chapters = @($facts.chapters | ForEach-Object { [pscustomobject]@{ number = $_.number; title = $_.title } })
$resolution = Resolve-EbookOutcomeAssignments -Catalog $catalog -Chapters $chapters -Assignments @($parsed.assignments)
Check (@($resolution.chapters).Count -eq 3) 'Every chapter is resolved.'
Check ((@($resolution.chapters[0].records | ForEach-Object { $_.objectiveId }) -join ',') -eq 'LO1.1,LO1.2') "Naming CO1 assigns its learning objectives, not the course objective itself (got '$(@($resolution.chapters[0].records | ForEach-Object { $_.objectiveId }) -join ',')')."
Check ((@($resolution.chapters[1].records | ForEach-Object { $_.objectiveId }) -join ',') -eq 'LO2.1,LO1.2') 'A single learning objective can be taught in a second chapter.'
Check ($resolution.uniqueOutcomes -eq 4) "Course objectives with children are not counted as outcomes of their own (got $($resolution.uniqueOutcomes))."

try { Resolve-EbookOutcomeAssignments -Catalog $catalog -Chapters $chapters -Assignments @(@($parsed.assignments)[0], @($parsed.assignments)[1]) | Out-Null; throw 'FAIL: A missing chapter assignment must be refused.' }
catch { Check ($_.Exception.Message -match '3 chapter\(s\) and 2 assignment\(s\)') 'A missing chapter assignment says how many were expected and supplied.' }
$unassigned = @([pscustomobject]@{ number = 1; ids = 'CO1' }, [pscustomobject]@{ number = 2; ids = 'CO2' }, [pscustomobject]@{ number = 3; ids = 'LO1.1' })
try { Resolve-EbookOutcomeAssignments -Catalog $catalog -Chapters $chapters -Assignments $unassigned | Out-Null; throw 'FAIL: An unassigned outcome must be refused.' }
catch { Check ($_.Exception.Message -match 'Unassigned: LO3\.1') 'An outcome no chapter teaches is named.' }
try { Resolve-EbookOutcomeAssignments -Catalog $catalog -Chapters $chapters -Assignments @([pscustomobject]@{ number = 1; ids = 'CO1' }, [pscustomobject]@{ number = 2; ids = 'CO7' }, [pscustomobject]@{ number = 3; ids = 'CO3' }) | Out-Null; throw 'FAIL: An unknown outcome ID must be refused.' }
catch { Check ($_.Exception.Message -match 'Unknown outcome CO7 in Chapter 2') 'An unknown outcome ID names the chapter it came from.' }

# The approved outcomes are written back out as an ebook-ready course file so
# the next book can skip this stage. That claim is only true if the generator
# reads the file back as the same chapters and objectives.
$specSheet = ConvertTo-EbookOutcomeSpecSheetMarkdown -Facts $facts -Catalog $catalog -Chapters @($resolution.chapters)
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ebook-outcome-analysis-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $specPath = Join-Path $fixture 'QA2010 Ebook Course File.md'
    Set-Content -LiteralPath $specPath -Value $specSheet -Encoding UTF8
    $roundTrip = Import-CourseSpec -Path $specPath
    Check ($roundTrip.courseCode -eq 'QA2010') "The generated course file reports its own course code (got '$($roundTrip.courseCode)')."
    Check ($roundTrip.courseName -eq 'Fixture Revenue Operations') 'The generated course file reports its course name.'
    Check (@($roundTrip.weeks).Count -eq 3) "The generated course file reads back as 3 chapters (got $(@($roundTrip.weeks).Count))."
    Check ($roundTrip.weeks[0].title -eq 'Revenue Cycle Foundations' -and $roundTrip.weeks[2].title -eq 'Billing Error Analysis') 'Chapter titles survive the round trip.'
    Check ($roundTrip.description -eq 'A fixture course used only by this regression suite.') "The course description survives the round trip without swallowing the weeks (got '$($roundTrip.description)')."
    $chapterTwo = @($roundTrip.weeks | Where-Object { $_.number -eq 2 })[0]
    $parents = @($chapterTwo.modules | ForEach-Object { $_.objectiveId }) -join ','
    Check ($parents -eq '1,2') "A chapter that teaches two course objectives reads back with both (got '$parents')."
    $lessons = @($chapterTwo.modules | ForEach-Object { $_.subObjectives }) -join ' | '
    Check ($lessons -match 'Differentiate among the purposes of each code set\.' -and $lessons -match 'Explain how each department contributes to revenue integrity\.') "Both learning objectives reach the chapter that teaches them (got '$lessons')."
    $chapterOne = @($roundTrip.weeks | Where-Object { $_.number -eq 1 })[0]
    Check ($chapterOne.modules[0].objective -eq 'Describe the end-to-end revenue cycle from registration through collections.') 'The course objective reads back word for word from the generated course file.'

    $reviewDocument = ConvertTo-EbookOutcomeAnalysisMarkdown -Facts $facts -Catalog $catalog -Chapters @($resolution.chapters) -Findings @($parsed.findings) -ReviewedBy 'Fixture Designer' -Reason 'Fixture review' -ConfirmedAt '2026-09-21T00:00:00'
    Check ($reviewDocument -match 'Fixture Designer' -and $reviewDocument -match 'Fixture review') 'The review record names who approved it and why.'
    Check ($reviewDocument -match [regex]::Escape('LO2 says "understand", which is not observable.')) 'The review record keeps the analysis findings.'
    Check ($reviewDocument -match '### Chapter 2: Coding System Fundamentals') 'The review record lists what each chapter teaches.'
}
finally { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }

# Intake. Whether the document still needs this review is the designer's call,
# so it must be stated rather than guessed, and a wrong value must not reach
# the job database.
$upload = @{ files = @(@{ name = 'draft.docx'; contentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('fixture')) }) }
try { Test-BookStudioUploadRequest -Request ([pscustomobject]$upload) | Out-Null; throw 'FAIL: An upload with no document kind must be refused.' }
catch { Check ($_.Exception.Message -match 'curriculum draft') 'An upload that does not say which kind of document it is, is refused.' }
$upload.courseDocumentKind = 'Something'
try { Test-BookStudioUploadRequest -Request ([pscustomobject]$upload) | Out-Null; throw 'FAIL: An unknown document kind must be refused.' }
catch { Check ($_.Exception.Message -match 'Unknown course document kind') 'An unknown document kind is refused.' }
$upload.courseDocumentKind = 'CurriculumDraft'
Check ((Test-BookStudioUploadRequest -Request ([pscustomobject]$upload)).courseDocumentKind -eq 'CurriculumDraft') 'A stated document kind reaches the validated request.'
$upload.courseDocumentKind = 'EbookReady'
Check ((Test-BookStudioUploadRequest -Request ([pscustomobject]$upload)).courseDocumentKind -eq 'EbookReady') 'An ebook-ready document is accepted without analysis.'

Write-Output "PASS: $checks course-outcome analysis assertions (facts, prompt, reply parsing, course-objective fidelity, chapter assignment, ebook-ready round trip, intake)."
