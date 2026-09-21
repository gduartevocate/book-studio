$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/EbookGenerator.psm1') -Force -DisableNameChecking
$ebook = Get-Module EbookGenerator
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# A revenue cycle course used to fall through to business-operations, which
# framed a medical coding book as office operations: one identical focus on
# every chapter, and GM1000 section titles such as "What Are Business and
# Office Operations?" proposed for all five chapters of a coding book.
function New-Course([string]$Name, [string[]]$WeekTitles, [string[]]$Objectives = @()) {
    $weeks = @()
    for ($i = 0; $i -lt $WeekTitles.Count; $i++) {
        $modules = @(
            if ($i -lt $Objectives.Count -and $Objectives[$i]) {
                [pscustomobject]@{ objectiveId = "LO$($i + 1).1"; title = $Objectives[$i]; objective = $Objectives[$i]; subObjectives = @() }
            }
        )
        $weeks += [pscustomobject]@{ number = $i + 1; title = $WeekTitles[$i]; modules = $modules; activities = @(); chapterReferences = @() }
    }
    return [pscustomobject]@{ courseCode = 'QA9000'; courseName = $Name; description = 'Fixture course.'; courseObjectives = @(); weeks = $weeks; sourcePath = $null }
}

$rb = New-Course 'Healthcare Revenue Cycle Fundamentals & Medical Coding Systems' @(
    'Healthcare Revenue Cycle Operations & Revenue Integrity Foundations',
    'Medical Documentation Interpretation & Coding System Fundamentals',
    'Claims Processing, Payer Requirements & Reimbursement Methods',
    'Revenue Integrity Analysis, Billing Errors & Reimbursement Risk Management',
    'Integrated Revenue Cycle Assessment & Reimbursement Improvement Strategies'
) @(
    'Describe the major stages of the revenue cycle from patient scheduling through final payment.',
    'Apply ICD-10-CM, CPT, and HCPCS Level II codes to basic healthcare scenarios.',
    'Complete selected sections of CMS-1500 and UB-04 claim forms accurately.',
    'Analyze coding and billing errors that result in claim denials and underpayments.',
    'Develop an integrated revenue cycle analysis with improvement recommendations.'
)
Check ((& $ebook { param($c) Get-CourseDomain -Course $c } $rb) -eq 'healthcare-revenue-cycle') 'A revenue cycle and medical coding course must get its own domain.'

# Every chapter sharing one focus is the defect this domain exists to fix.
$focuses = @(foreach ($week in $rb.weeks) { & $ebook { param($c, $w) Get-ChapterFocus -Week $w -Course $c } $rb $week })
Check ((@($focuses | Select-Object -Unique).Count) -eq 5) "Each chapter needs its own focus (got $(@($focuses | Select-Object -Unique).Count) distinct of 5): $($focuses -join ' / ')"
Check ($focuses[0] -match 'stages') "Chapter 1 is the end-to-end cycle (got '$($focuses[0])')."
Check ($focuses[1] -match 'documentation|code assignment') "Chapter 2 is documentation and coding (got '$($focuses[1])')."
Check ($focuses[2] -match 'claim completion') "Chapter 3 is claim completion and payers (got '$($focuses[2])')."
Check ($focuses[3] -match 'error analysis|denial') "Chapter 4 is errors and denials (got '$($focuses[3])')."
Check ($focuses[4] -match 'integrated') "Chapter 5 is the integrated assessment (got '$($focuses[4])')."
Check (@($focuses | Where-Object { $_ -match 'office|business operations' }).Count -eq 0) 'No chapter may be framed as office operations.'

$frame = & $ebook { param($c) Get-CoursePracticeFrame -Course $c } $rb
Check ($frame.learnerWork -match 'documentation|coding|claim') "The practice frame must describe revenue cycle work (got '$($frame.learnerWork)')."
Check ($frame.bridgeNoun -eq 'revenue cycle accuracy') 'The bridge noun names this domain.'
Check ($frame.scenario -notmatch 'office operations') 'The scenario must not be the office-operations one.'

# Section titles came from GM1000 rather than this course's own objectives.
$plan = New-EbookPlan -Course $rb
foreach ($chapter in $plan.chapters) {
    $titles = @(& $ebook { param($c, $ch) Get-ProposedOutlineSectionTitles -Course $c -Chapter $ch } $rb $chapter)
    Check (@($titles | Where-Object { $_ -match 'Business and Office Operations|Office Operations Across|Organizational Structures and Office' }).Count -eq 0) "Chapter $($chapter.number) must not propose GM1000 office-operations sections."
    Check (@($titles | Where-Object { $_ -match 'office operations' }).Count -eq 0) "Chapter $($chapter.number) required sections must not cite office operations."
}

# The neighbouring domains must not be disturbed.
foreach ($case in @(
    @{ name = 'Introduction to Business & Office Operations'; weeks = @('The Office as an Operations System', 'Business Functions'); expect = 'business-operations' },
    @{ name = 'Healthcare Systems and Workforce Design'; weeks = @('Healthcare Delivery Systems', 'Workforce Planning'); expect = 'business-operations' },
    @{ name = 'Critical Thinking and Problem Solving'; weeks = @('Critical Thinking Habits', 'Evaluating Arguments'); expect = 'critical-thinking' },
    @{ name = 'Computer Applications'; weeks = @('Windows Operating System', 'Files and Folders'); expect = 'computer-applications' }
)) {
    $probe = New-Course $case.name $case.weeks
    $actual = & $ebook { param($c) Get-CourseDomain -Course $c } $probe
    Check ($actual -eq $case.expect) "'$($case.name)' must stay in $($case.expect) (got '$actual')."
}

# "Healthcare" alone is not this domain; a billing course named plainly is.
$plainHealthcare = New-Course 'Healthcare Delivery and Patient Care Foundations' @('Patient Care Settings', 'Care Teams')
Check ((& $ebook { param($c) Get-CourseDomain -Course $c } $plainHealthcare) -ne 'healthcare-revenue-cycle') 'A general healthcare course must not be treated as a revenue cycle course.'
$billing = New-Course 'Medical Billing and Reimbursement' @('Charge Capture', 'Payer Requirements')
Check ((& $ebook { param($c) Get-CourseDomain -Course $c } $billing) -eq 'healthcare-revenue-cycle') 'A medical billing course belongs to this domain.'

Write-Output "PASS: $checks healthcare revenue cycle domain assertions (domain detection, per-chapter focus, practice frame, section titles, neighbouring domains)."
