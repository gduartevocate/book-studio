$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

# Changing the setup of a book that already exists.
#
# Until this existed, a designer who had uploaded the wrong document, or typed
# the title wrongly, or picked the wrong kind of course file, could only delete
# the book and start again -- losing its history and re-uploading everything.
# These checks are about the things that made deletion the safer option: work in
# flight, an approval that no longer applies, and losing the only source file.

Import-Module (Join-Path $root 'lib/BookStudio.psm1') -Force -DisableNameChecking

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('studio-setup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $dbPath = Initialize-BookStudioDatabase -ProjectRoot $fixture
    # Carries both shapes on purpose: the week structure the blueprint reads,
    # and the CO/LO identity the outcome review keeps word for word, because
    # this book is switched between the two kinds of document below.
    $draft = @(
        'RB9000 Fixture Revenue Course',
        'Course Objectives',
        'CO1: Explain the stages of the revenue cycle.',
        'CO2: Describe how services are documented.',
        'Week 1 Revenue Cycle Foundations',
        'Course Objective',
        'CO1: Explain the stages of the revenue cycle.',
        'Lesson Objectives',
        'LO1.1: Identify the stages of the revenue cycle.',
        'Week 2 Revenue Documentation',
        'Course Objective',
        'CO2: Describe how services are documented.',
        'Lesson Objectives',
        'LO2.1: Describe how services are documented.'
    ) -join [Environment]::NewLine
    $asFile = { param($text) @{ name = 'course.txt'; contentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) } }

    $job = New-BookStudioJob -DatabasePath $dbPath -ProjectRoot $root -Request ([pscustomobject]@{
        title = 'First name'; courseCode = 'RB9000'; courseDocumentKind = 'EbookReady'
        sourceMode = 'UploadedOnly'; readingLevel = 8
        files = @((& $asFile $draft))
    })
    Check ($job.title -eq 'First name') 'The fixture book was created.'

    # 1. What the setup screen shows: what was chosen, and the documents behind
    #    it. A designer cannot correct what they cannot see.
    $summary = Get-BookStudioSetupSummary -Job $job
    Check ($summary.title -eq 'First name' -and $summary.courseCode -eq 'RB9000') 'The setup shows the name and course code.'
    Check ($summary.courseDocumentKind -eq 'EbookReady') 'The setup shows which kind of document this is.'
    Check ($summary.readingLevel -eq 8 -and $summary.sourceMode -eq 'UploadedOnly') 'The setup shows the production choices.'
    Check (@($summary.documents).Count -eq 1 -and $summary.documents[0].name -eq 'course.txt') 'The setup names the document that was uploaded.'

    # 2. Renaming is not a reason to rebuild anything.
    $renamed = Set-BookStudioJobSetup -DatabasePath $dbPath -JobId $job.id -ProjectRoot $root -Request ([pscustomobject]@{
        title = 'Corrected name'; courseCode = 'RB9001'
    })
    Check ($renamed.title -eq 'Corrected name' -and $renamed.courseCode -eq 'RB9001') 'A book can be renamed without being recreated.'
    Check ($renamed.id -eq $job.id) 'It is the same book, with the same id and history.'
    Check (@($renamed.log | Where-Object { $_.message -match "renamed to 'Corrected name'" }).Count -eq 1) 'The rename is recorded in the book, not applied silently.'
    Check ($renamed.workflowStage -eq $job.workflowStage) 'Renaming does not move the book to another stage.'

    # 3. A different document is a different book in every way that matters, so
    #    an approval of the old format preview cannot carry over.
    # Set through the record rather than the approval endpoint, which needs a
    # built preview; what matters here is that an approval exists to be cleared.
    $null = Update-BookStudioJob -DatabasePath $dbPath -JobId $job.id -Update {
        param($current)
        $current.formatReview.status = 'Approved'
        $current.formatReview.reviewedBy = 'A designer'
        $current.workflowStage = 'generating'
    }
    $approved = Get-BookStudioJob -DatabasePath $dbPath -JobId $job.id
    Check ($approved.formatReview.status -eq 'Approved') 'The fixture approval is in place.'

    $secondDraft = $draft.Replace('Revenue Cycle Foundations', 'Revenue Cycle Basics')
    $replaced = Set-BookStudioJobSetup -DatabasePath $dbPath -JobId $job.id -ProjectRoot $root -Request ([pscustomobject]@{
        courseDocumentKind = 'EbookReady'; sourceMode = 'UploadedOnly'; readingLevel = 8
        files = @((& $asFile $secondDraft))
    })
    Check ($replaced.formatReview.status -eq 'Not reviewed') 'Replacing the document clears an approval of the preview built from the old one.'
    Check ($replaced.workflowStage -eq 'format-review') 'The book returns to the stage that builds the preview.'
    Check ($replaced.status -eq 'Ready') 'And it is not left reporting itself as generating.'
    Check ((Get-Content -LiteralPath $replaced.specPath -Raw) -match 'Revenue Cycle Basics') 'The new document is what the book now reads.'
    Check (@($replaced.uploadedFiles | Where-Object { $_.role -eq 'spec' }).Count -eq 1) 'Exactly one document is the course source.'
    Check (Test-Path -LiteralPath (Join-Path $replaced.sourceContextPath 'intake-report.json')) 'Intake ran again for the new document.'

    # 4. Changing the kind of document changes what happens next: a curriculum
    #    draft has its objectives reviewed before anything is planned.
    # This fixture is a plain text file, which cannot carry the numbered course
    # objectives the outcome review keeps word for word. Calling it a curriculum
    # draft therefore has to be refused, and the refusal must leave the book
    # exactly as it was: a failed correction that half-applies is worse than one
    # that is refused. The curriculum-draft grid itself is covered by
    # book-studio-workflow-regressions.
    try {
        Set-BookStudioJobSetup -DatabasePath $dbPath -JobId $job.id -ProjectRoot $root -Request ([pscustomobject]@{
            courseDocumentKind = 'CurriculumDraft'
        }) | Out-Null
        throw 'FAIL: A document with no numbered course objectives cannot be treated as a curriculum draft.'
    }
    catch {
        Check ($_.Exception.Message -match 'numbered course objectives') 'Calling an unsuitable document a curriculum draft is refused, in terms of the document.'
    }
    $afterRefusal = Get-BookStudioJob -DatabasePath $dbPath -JobId $job.id
    Check ($afterRefusal.courseDocumentKind -eq 'EbookReady') 'A refused change leaves the kind of document as it was.'
    Check ($afterRefusal.workflowStage -eq 'format-review') 'And leaves the book where it was.'

    # 5. Never while it is generating: the folder being written and the document
    #    being described would stop matching.
    $running = Update-BookStudioJob -DatabasePath $dbPath -JobId $job.id -Update { param($current) $current.status = 'Running' }
    try {
        Set-BookStudioJobSetup -DatabasePath $dbPath -JobId $job.id -ProjectRoot $root -Request ([pscustomobject]@{ title = 'While running' }) | Out-Null
        throw 'FAIL: Changing the setup during generation must be refused.'
    }
    catch {
        Check ($_.Exception.Message -match 'generating') 'Changing the setup while the book generates is refused.'
        Check ($_.Exception.Message -match 'Stop Book Studio') 'The refusal says how to get unstuck.'
    }
    $null = Update-BookStudioJob -DatabasePath $dbPath -JobId $job.id -Update { param($current) $current.status = 'Ready' }

    # 6. Nor while Codex is working for this book.
    # A book only grows an aiRequests list once Codex has been asked for
    # something, so the property is added here rather than assigned.
    $null = Update-BookStudioJob -DatabasePath $dbPath -JobId $job.id -Update {
        param($current)
        $running = @([pscustomobject]@{ id = 'ai-1'; status = 'Running' })
        if ($current.PSObject.Properties.Name -contains 'aiRequests') { $current.aiRequests = $running }
        else { $current | Add-Member -MemberType NoteProperty -Name 'aiRequests' -Value $running }
    }
    try {
        Set-BookStudioJobSetup -DatabasePath $dbPath -JobId $job.id -ProjectRoot $root -Request ([pscustomobject]@{ title = 'While Codex runs' }) | Out-Null
        throw 'FAIL: Changing the setup during a Codex request must be refused.'
    }
    catch { Check ($_.Exception.Message -match 'Codex request') 'Changing the setup while Codex runs for it is refused.' }
    $null = Update-BookStudioJob -DatabasePath $dbPath -JobId $job.id -Update { param($current) $current.aiRequests = @() }

    # 7. A rejected replacement must not leave the book with no source at all.
    $before = (Get-BookStudioJob -DatabasePath $dbPath -JobId $job.id).specPath
    try {
        Set-BookStudioJobSetup -DatabasePath $dbPath -JobId $job.id -ProjectRoot $root -Request ([pscustomobject]@{
            files = @(@{ name = 'notes.pdf'; contentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not a course')) })
        }) | Out-Null
        throw 'FAIL: An unsupported document must be refused.'
    }
    catch { Check ($_.Exception.Message -match 'Unsupported source') 'An unsupported document is refused by the same rule as at intake.' }
    $after = Get-BookStudioJob -DatabasePath $dbPath -JobId $job.id
    Check ($after.specPath -eq $before -and (Test-Path -LiteralPath $after.specPath)) 'A refused replacement leaves the book with the document it had.'
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

"PASS: $checks setup-change assertions (rename without rebuilding, replace the document, correct the document kind, refusals while work is in flight)."
