# The course-objective and learning-objective analysis stage.
#
# A curriculum draft is what the academic team hands over. Its course
# objectives are approved and final; its weekly learning objectives were
# written for course delivery and usually are not the objectives a book should
# be built on. This stage runs once, before anything is planned or drafted:
# Codex proposes reworked learning objectives, the designer edits and approves
# them, and the approved set becomes the book's official outcomes.
#
# A book whose course document is already ebook-ready never enters this stage.
#
# The approved outcomes are written as the same book-studio-outcomes.json
# amendment the post-preview outcome replacement writes, so one code path
# reads outcomes no matter which review produced them.

function Get-BookStudioOutcomeAnalysisFolder {
    param([Parameter(Mandatory)][object]$Job)
    return (Join-Path $Job.sourceContextPath 'outcome-analysis')
}

function Get-BookStudioCourseFactsPath {
    param([Parameter(Mandatory)][object]$Job)
    return (Join-Path $Job.sourceContextPath 'book-studio-course-facts.json')
}

function Save-BookStudioCourseFacts {
    # Written once, at intake, from the curriculum draft as uploaded. Every
    # later check compares against this file rather than re-reading the course
    # document, because after the first approval the document is read through
    # the amendment and would agree with itself.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UploadFolder,
        [Parameter(Mandatory)][string]$SpecPath
    )
    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
    $course = Import-CourseSpec -Path $SpecPath
    $facts = Get-EbookOutcomeAnalysisFacts -Course $course
    $path = Join-Path $UploadFolder 'book-studio-course-facts.json'
    $facts | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    return $facts
}

function Get-BookStudioCourseFacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Job)
    $path = Get-BookStudioCourseFactsPath -Job $Job
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'This book has no recorded course objectives to analyze. It was created before the outcome analysis existed, or its course document is already ebook-ready.'
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function New-BookStudioOutcomeAnalysisState {
    param([Parameter(Mandatory)][string]$FactsPath)
    return [pscustomobject]@{
        required = $true
        status = 'Not analyzed'
        statusDetail = 'Run the analysis, or write the outcomes yourself, before the book is planned.'
        factsPath = $FactsPath
        requestId = ''
        relativeFolder = ''
        startedAt = ''
        completedAt = ''
        findings = @()
        catalogText = ''
        assignments = @()
        errorDetail = ''
        approvedAt = ''
        reviewedBy = ''
        reason = ''
        documents = @()
    }
}

function Assert-BookStudioOutcomeAnalysisStage {
    param([Parameter(Mandatory)][object]$Job)
    if (-not $Job) { throw 'Book Studio job not found.' }
    if ([string]$Job.courseDocumentKind -ne 'CurriculumDraft') {
        throw 'This book was created from an ebook-ready course file, so its outcomes are already final and there is nothing to analyze.'
    }
    if ([string]$Job.workflowStage -ne 'outcomes-analysis') {
        throw "The outcome analysis runs once, before the book is planned. This book is at the '$($Job.workflowStage)' stage; use the outcome replacement in its format review to change outcomes now."
    }
}

function Start-BookStudioOutcomeAnalysis {
    # Starts Codex against the upload folder, read-only and offline. The
    # curriculum draft is the only thing being read; there is no package yet.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$JobId,
        [AllowEmptyString()][string]$Notes = '',
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $job = Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    Assert-BookStudioOutcomeAnalysisStage -Job $job
    if (([string]$Notes).Length -gt 4000) { throw 'Analysis notes exceed the 4,000-character limit.' }
    if ([string]$job.outcomeAnalysis.status -eq 'Analyzing') { throw 'The outcome analysis is already running for this book. Wait for it to finish.' }
    if ([string]$job.outcomeAnalysis.status -eq 'Approved') { throw 'These outcomes were already approved. Start a new book to analyze the curriculum draft again.' }

    $facts = Get-BookStudioCourseFacts -Job $job
    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local

    $codexCommand = Resolve-BookStudioCodexCommand -ProjectRoot $ProjectRoot
    if (-not $codexCommand) {
        throw 'The optional Codex assistant is not available on this computer, so the analysis cannot run. Write the outcomes yourself in the editor below and approve them, or install Codex CLI and sign in.'
    }
    $connection = Get-BookStudioConnectionResult -ProjectRoot $ProjectRoot -CommandPath $codexCommand.Source
    if (-not $connection -or $connection.status -ne 'PASS') {
        throw 'Test the Codex connection successfully before running the analysis. You can also write the outcomes yourself in the editor below and approve them.'
    }

    $requestId = 'outcomes-{0}-{1}' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $requestFolder = Join-Path (Get-BookStudioOutcomeAnalysisFolder -Job $job) $requestId
    Assert-BookStudioPathLength -Path (Join-Path $requestFolder 'exit-code.txt') -What 'this outcome analysis' -ProjectRoot $ProjectRoot
    New-Item -ItemType Directory -Path $requestFolder -Force | Out-Null

    $promptPath = Join-Path $requestFolder 'prompt.md'
    $responsePath = Join-Path $requestFolder 'response.md'
    $errorPath = Join-Path $requestFolder 'error.log'
    $exitCodePath = Join-Path $requestFolder 'exit-code.txt'
    $runScriptPath = Join-Path $requestFolder 'run.ps1'

    $excerpt = ''
    try { $excerpt = Get-DocxText -Path $job.specPath } catch { $excerpt = '' }
    if ($excerpt.Length -gt 60000) { $excerpt = $excerpt.Substring(0, 60000) + "`r`n(The curriculum draft was truncated here. The parsed structure above is complete.)" }
    $prompt = New-EbookOutcomeAnalysisPrompt -Facts $facts -DesignerNotes $Notes -SourceExcerpt $excerpt
    Set-Content -LiteralPath $promptPath -Value $prompt -Encoding UTF8

    $sandboxFlags = Get-EbookCodexSandboxConfigArgument
    $script = @"
`$ErrorActionPreference = "Continue"
`$prompt = Get-Content -LiteralPath '$($promptPath.Replace("'", "''"))' -Raw -Encoding UTF8
`$prompt | & '$($codexCommand.Source.Replace("'", "''"))' exec -C '$($requestFolder.Replace("'", "''"))' --skip-git-repo-check --sandbox 'read-only' $sandboxFlags -c 'web_search="disabled"' --output-last-message '$($responsePath.Replace("'", "''"))' - *> '$($errorPath.Replace("'", "''"))'
`$LASTEXITCODE | Set-Content -LiteralPath '$($exitCodePath.Replace("'", "''"))' -Encoding UTF8
"@
    Set-Content -LiteralPath $runScriptPath -Value $script -Encoding UTF8

    $process = Start-Process -FilePath 'powershell' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$runScriptPath`""
    ) -WindowStyle Hidden -PassThru

    $startedAt = (Get-Date).ToString('o')
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        $state = $current.outcomeAnalysis
        Add-OrSet-BookStudioNoteProperty $state 'status' 'Analyzing'
        Add-OrSet-BookStudioNoteProperty $state 'statusDetail' 'Codex is reading the curriculum draft and reworking its learning objectives.'
        Add-OrSet-BookStudioNoteProperty $state 'requestId' $requestId
        Add-OrSet-BookStudioNoteProperty $state 'relativeFolder' "outcome-analysis/$requestId"
        Add-OrSet-BookStudioNoteProperty $state 'startedAt' $startedAt
        Add-OrSet-BookStudioNoteProperty $state 'completedAt' ''
        Add-OrSet-BookStudioNoteProperty $state 'errorDetail' ''
        Add-OrSet-BookStudioNoteProperty $state 'processId' $process.Id
        Add-OrSet-BookStudioNoteProperty $state 'promptPath' $promptPath
        Add-OrSet-BookStudioNoteProperty $state 'responsePath' $responsePath
        Add-OrSet-BookStudioNoteProperty $state 'errorPath' $errorPath
        Add-OrSet-BookStudioNoteProperty $state 'exitCodePath' $exitCodePath
        Add-OrSet-BookStudioNoteProperty $current 'workflowStatus' 'Analyzing course objectives and learning objectives'
        $current.log = @($current.log) + [pscustomobject]@{ at = (Get-Date).ToString('s'); message = "Started the course-outcome analysis: $requestId." }
    } | Out-Null

    return Get-BookStudioOutcomeAnalysis -DatabasePath $DatabasePath -JobId $JobId
}

function Update-BookStudioOutcomeAnalysisResult {
    # Reads a finished Codex run once and records the suggestion. A reply that
    # rewrote a course objective is kept and shown with the offending text, not
    # discarded: the designer can fix that line in the editor, and the approval
    # gate refuses it until they do.
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][object]$Job
    )
    $state = $Job.outcomeAnalysis
    if ([string]$state.status -ne 'Analyzing') { return $Job }
    $exitCodePath = [string]$state.exitCodePath
    if ([string]::IsNullOrWhiteSpace($exitCodePath) -or -not (Test-Path -LiteralPath $exitCodePath -PathType Leaf)) {
        $processId = 0
        if ($state.PSObject.Properties.Name -contains 'processId') { $processId = [int]$state.processId }
        $alive = $false
        if ($processId -gt 0) { $alive = [bool](Get-Process -Id $processId -ErrorAction SilentlyContinue) }
        if ($alive) { return $Job }
        # The runner died without writing an exit code. Report it rather than
        # leaving the book analyzing forever.
        $detail = 'The analysis stopped before it produced a reply. Run it again, or write the outcomes yourself.'
        return (Set-BookStudioOutcomeAnalysisFailure -DatabasePath $DatabasePath -JobId $Job.id -Detail $detail)
    }

    $exitCode = 0
    try { $exitCode = [int]((Get-Content -LiteralPath $exitCodePath -Raw -ErrorAction Stop).Trim()) } catch { $exitCode = 1 }
    $errorText = Get-BookStudioTextFilePreview -Path ([string]$state.errorPath) -MaxCharacters 8000 -Tail
    if ($exitCode -ne 0) {
        $failure = Get-BookStudioCodexFailure -Text $errorText -ExitCode $exitCode -ExpectedSandbox 'read-only'
        return (Set-BookStudioOutcomeAnalysisFailure -DatabasePath $DatabasePath -JobId $Job.id -Detail "The analysis did not finish. $($failure.message)")
    }

    $responseText = ''
    try { $responseText = Get-Content -LiteralPath ([string]$state.responsePath) -Raw -Encoding UTF8 -ErrorAction Stop } catch { $responseText = '' }
    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
    $parsed = $null
    try { $parsed = ConvertFrom-EbookOutcomeAnalysisResponse -Text $responseText }
    catch { return (Set-BookStudioOutcomeAnalysisFailure -DatabasePath $DatabasePath -JobId $Job.id -Detail $_.Exception.Message) }

    $completedAt = (Get-Date).ToString('o')
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $Job.id -Update {
        param($current)
        $target = $current.outcomeAnalysis
        Add-OrSet-BookStudioNoteProperty $target 'status' 'Suggested'
        Add-OrSet-BookStudioNoteProperty $target 'statusDetail' 'Review the analysis, edit the outcomes, and approve them to plan the book.'
        Add-OrSet-BookStudioNoteProperty $target 'findings' @($parsed.findings)
        Add-OrSet-BookStudioNoteProperty $target 'catalogText' ([string]$parsed.catalogText)
        Add-OrSet-BookStudioNoteProperty $target 'assignments' @($parsed.assignments)
        Add-OrSet-BookStudioNoteProperty $target 'completedAt' $completedAt
        Add-OrSet-BookStudioNoteProperty $target 'errorDetail' ''
        Add-OrSet-BookStudioNoteProperty $current 'workflowStatus' 'Course outcomes suggested; designer review required'
        $current.log = @($current.log) + [pscustomobject]@{ at = (Get-Date).ToString('s'); message = 'The course-outcome analysis finished. Nothing was applied; the designer reviews and approves it.' }
    } | Out-Null
    return Get-BookStudioJob -DatabasePath $DatabasePath -JobId $Job.id
}

function Set-BookStudioOutcomeAnalysisFailure {
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Detail
    )
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        $target = $current.outcomeAnalysis
        Add-OrSet-BookStudioNoteProperty $target 'status' 'Failed'
        Add-OrSet-BookStudioNoteProperty $target 'statusDetail' $Detail
        Add-OrSet-BookStudioNoteProperty $target 'errorDetail' $Detail
        Add-OrSet-BookStudioNoteProperty $target 'completedAt' (Get-Date).ToString('o')
        Add-OrSet-BookStudioNoteProperty $current 'workflowStatus' 'Course-outcome analysis needs attention'
        $current.log = @($current.log) + [pscustomobject]@{ at = (Get-Date).ToString('s'); message = "Course-outcome analysis: $Detail" }
    } | Out-Null
    return Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
}

function Get-BookStudioOutcomeAnalysis {
    # The whole editor in one payload: the draft's own objectives for
    # reference, the current suggestion, and any course objective whose wording
    # no longer matches the draft.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$JobId
    )
    $job = Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    if (-not $job) { throw "Book Studio job not found: $JobId" }
    if ([string]$job.courseDocumentKind -ne 'CurriculumDraft') {
        throw 'This book was created from an ebook-ready course file, so its outcomes are already final and there is nothing to analyze.'
    }
    $job = Update-BookStudioOutcomeAnalysisResult -DatabasePath $DatabasePath -Job $job
    $facts = Get-BookStudioCourseFacts -Job $job
    $state = $job.outcomeAnalysis

    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
    $fidelity = @()
    $catalogError = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$state.catalogText)) {
        try {
            $catalog = @(ConvertFrom-EbookOutcomeCatalog ([string]$state.catalogText))
            $fidelity = @(Test-EbookCourseObjectiveFidelity -CourseObjectives @($facts.courseObjectives) -Catalog $catalog)
        }
        catch { $catalogError = $_.Exception.Message }
    }

    return [pscustomobject]@{
        jobId = $job.id
        courseDocumentKind = [string]$job.courseDocumentKind
        workflowStage = [string]$job.workflowStage
        status = [string]$state.status
        statusDetail = [string]$state.statusDetail
        startedAt = [string]$state.startedAt
        completedAt = [string]$state.completedAt
        errorDetail = [string]$state.errorDetail
        approvedAt = [string]$state.approvedAt
        reviewedBy = [string]$state.reviewedBy
        reason = [string]$state.reason
        findings = @($state.findings)
        catalogText = [string]$state.catalogText
        assignments = @($state.assignments)
        catalogError = $catalogError
        objectiveFidelity = @($fidelity)
        courseObjectives = @($facts.courseObjectives)
        chapters = @($facts.chapters)
        documents = @($state.documents)
        promptUrl = $(if ($state.relativeFolder) { "/api/jobs/$($job.id)/outcome-analysis/file?name=prompt.md" } else { '' })
        responseUrl = $(if ($state.relativeFolder) { "/api/jobs/$($job.id)/outcome-analysis/file?name=response.md" } else { '' })
        errorUrl = $(if ($state.relativeFolder) { "/api/jobs/$($job.id)/outcome-analysis/file?name=error.log" } else { '' })
    }
}

function Get-BookStudioOutcomeAnalysisPreview {
    # Validates exactly what approval will apply, and changes nothing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Job,
        [Parameter(Mandatory)][object]$Request
    )
    Assert-BookStudioOutcomeAnalysisStage -Job $Job
    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
    $facts = Get-BookStudioCourseFacts -Job $Job
    $catalog = @(ConvertFrom-EbookOutcomeCatalog ([string]$Request.text))
    $problems = @(Test-EbookCourseObjectiveFidelity -CourseObjectives @($facts.courseObjectives) -Catalog $catalog)
    if ($problems.Count) {
        throw ("Course objectives come from the academic team and are reproduced word for word. Fix these before approving, then check again. " + (@($problems | ForEach-Object { $_.message }) -join ' '))
    }
    $chapters = @(foreach ($chapter in @($facts.chapters | Sort-Object { [int]$_.number })) { [pscustomobject]@{ number = [int]$chapter.number; title = [string]$chapter.title } })
    $resolution = Resolve-EbookOutcomeAssignments -Catalog $catalog -Chapters $chapters -Assignments @($Request.assignments)
    $resolved = @(foreach ($chapter in @($resolution.chapters)) {
        $draft = @($facts.chapters | Where-Object { [int]$_.number -eq [int]$chapter.number })
        [pscustomobject]@{
            number = $chapter.number
            title = $chapter.title
            previous = @(if ($draft.Count) { $draft[0].draftObjectives } else { @() })
            records = @($chapter.records)
        }
    })
    return [pscustomobject]@{
        facts = $facts
        catalog = @($catalog)
        chapters = @($resolved)
        uniqueOutcomes = $resolution.uniqueOutcomes
        newCount = $resolution.newCount
        previousCount = @($facts.chapters | ForEach-Object { $_.draftObjectives }).Count
    }
}

function Set-BookStudioOutcomeAnalysis {
    # Approves the reviewed outcomes: writes the amendment the generator reads,
    # writes the designer-facing record and the reusable ebook-ready course
    # file, and releases the book to planning.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][object]$Request
    )
    $job = Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    $preview = Get-BookStudioOutcomeAnalysisPreview -Job $job -Request $Request
    if ($Request.confirm -isnot [bool] -or -not $Request.confirm) { throw 'Confirm that you reviewed the course objectives and their learning objectives before approving.' }
    $reviewedBy = ([string]$Request.reviewedBy).Trim()
    $reason = ([string]$Request.reason).Trim()
    if (-not $reviewedBy -or -not $reason) { throw 'Enter your name and the source or reason for these outcomes before approving.' }
    if ($reviewedBy.Length -gt 150 -or $reason.Length -gt 1000) { throw 'Reviewer name or reason exceeds the input limit.' }

    Import-Module (Join-Path $PSScriptRoot 'EbookGenerator.psm1') -Scope Local
    $confirmedAt = (Get-Date).ToString('o')
    $revision = [pscustomobject]@{
        schemaVersion = 1
        baseSourceSha256 = (Get-FileHash -LiteralPath $job.specPath).Hash
        confirmedAt = $confirmedAt
        reviewedBy = $reviewedBy
        reason = $reason
        origin = 'curriculum-draft-analysis'
        catalog = @($preview.catalog)
        chapters = @($preview.chapters | Select-Object number, records)
    }
    # Prove the amendment reads back before it is published, so the book is
    # never released to planning with an amendment the generator will refuse.
    $null = Set-EbookCourseOutcomeRevision -Course (Import-CourseSpec -Path $job.specPath) -Revision $revision

    $findings = @(@($job.outcomeAnalysis.findings) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $reviewMarkdown = ConvertTo-EbookOutcomeAnalysisMarkdown -Facts $preview.facts -Catalog @($preview.catalog) -Chapters @($preview.chapters) -Findings $findings -ReviewedBy $reviewedBy -Reason $reason -ConfirmedAt $confirmedAt
    $specSheetMarkdown = ConvertTo-EbookOutcomeSpecSheetMarkdown -Facts $preview.facts -Catalog @($preview.catalog) -Chapters @($preview.chapters)

    $courseCode = if ([string]::IsNullOrWhiteSpace([string]$preview.facts.courseCode)) { 'Course' } else { [string]$preview.facts.courseCode }
    $folder = Get-BookStudioOutcomeAnalysisFolder -Job $job
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $reviewMarkdownPath = Join-Path $folder "$courseCode - Course Outcomes.md"
    $reviewDocxPath = Join-Path $folder "$courseCode - Course Outcomes.docx"
    $specSheetPath = Join-Path $folder "$courseCode - Ebook Course File.md"
    $revisionPath = Join-Path $job.sourceContextPath 'book-studio-outcomes.json'

    Set-Content -LiteralPath $reviewMarkdownPath -Value $reviewMarkdown -Encoding UTF8
    Set-Content -LiteralPath $specSheetPath -Value $specSheetMarkdown -Encoding UTF8
    $documents = New-Object System.Collections.ArrayList
    [void]$documents.Add([pscustomobject]@{ name = 'Course objectives and learning objectives'; fileName = [IO.Path]::GetFileName($reviewMarkdownPath) })
    [void]$documents.Add([pscustomobject]@{ name = 'Ebook-ready course file (reusable)'; fileName = [IO.Path]::GetFileName($specSheetPath) })
    try {
        Export-MarkdownToDocx -Markdown $reviewMarkdown -Path $reviewDocxPath -Title "$courseCode Course Outcomes" | Out-Null
        [void]$documents.Add([pscustomobject]@{ name = 'Course objectives and learning objectives (Word)'; fileName = [IO.Path]::GetFileName($reviewDocxPath) })
    }
    catch {
        # A Word export that fails must not lose an approved review. The
        # Markdown record and the amendment are what the book depends on.
        [void]$documents.Add([pscustomobject]@{ name = "Word export unavailable: $($_.Exception.Message)"; fileName = '' })
    }

    # Published last: until this file exists, the book still plans from the
    # curriculum draft's own objectives.
    $revision | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $revisionPath -Encoding UTF8

    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        $state = $current.outcomeAnalysis
        Add-OrSet-BookStudioNoteProperty $state 'status' 'Approved'
        Add-OrSet-BookStudioNoteProperty $state 'statusDetail' "Approved by $reviewedBy. The book is planned from these outcomes."
        Add-OrSet-BookStudioNoteProperty $state 'catalogText' ([string]$Request.text)
        Add-OrSet-BookStudioNoteProperty $state 'assignments' @($Request.assignments)
        Add-OrSet-BookStudioNoteProperty $state 'approvedAt' $confirmedAt
        Add-OrSet-BookStudioNoteProperty $state 'reviewedBy' $reviewedBy
        Add-OrSet-BookStudioNoteProperty $state 'reason' $reason
        Add-OrSet-BookStudioNoteProperty $state 'documents' @($documents.ToArray())
        Add-OrSet-BookStudioNoteProperty $current 'workflowStage' 'format-review'
        Add-OrSet-BookStudioNoteProperty $current 'workflowStatus' 'Preparing format preview'
        $current.log = @($current.log) + [pscustomobject]@{
            at = (Get-Date).ToString('s')
            message = "$reviewedBy approved $($preview.uniqueOutcomes) course/learning outcome(s) across $(@($preview.chapters).Count) chapter(s). Course objectives were reproduced word for word. No manuscript was generated."
        }
    } | Out-Null

    return Get-BookStudioOutcomeAnalysis -DatabasePath $DatabasePath -JobId $JobId
}

function Get-BookStudioOutcomeAnalysisFilePath {
    # Serves only the named files this stage writes, from this job's folder.
    param(
        [Parameter(Mandatory)][object]$Job,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Name -match '[\\/]' -or $Name -match '\.\.') { throw 'Unknown outcome-analysis file.' }
    $folder = Get-BookStudioOutcomeAnalysisFolder -Job $Job
    if ($Name -in @('prompt.md', 'response.md', 'error.log')) {
        $relative = [string]$Job.outcomeAnalysis.relativeFolder
        if ([string]::IsNullOrWhiteSpace($relative)) { throw 'This book has no analysis run to download.' }
        $path = Join-Path $Job.sourceContextPath (($relative -replace '/', [IO.Path]::DirectorySeparatorChar))
        $path = Join-Path $path $Name
    }
    else {
        $known = @(@($Job.outcomeAnalysis.documents) | ForEach-Object { [string]$_.fileName } | Where-Object { $_ })
        if ($known -notcontains $Name) { throw 'Unknown outcome-analysis file.' }
        $path = Join-Path $folder $Name
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "That file has not been written yet: $Name" }
    return $path
}
