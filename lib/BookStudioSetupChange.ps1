# Going back to the setup of a book that already exists.
#
# Until now the only way to change anything decided at intake -- the title, the
# course document, whether it is a curriculum draft, the reading level, the
# source policy -- was to delete the book and start again. Designers were
# deleting real work to correct a typo, and re-uploading documents they had
# already uploaded.
#
# This reopens the same book: it keeps its id, its history and its uploads, and
# re-runs exactly the parts of intake that the change affects.

function Assert-BookStudioSetupChangeAllowed {
    param([Parameter(Mandatory)][object]$Job)

    # The same measure the deletion gate uses: work actually in flight, not a
    # status that went stale. Changing the setup under a running generator would
    # leave the book describing one document while its folder holds another.
    $runnerAlive = $false
    if ($Job.runnerProcessId) {
        $runnerAlive = [bool](Get-Process -Id ([int]$Job.runnerProcessId) -ErrorAction SilentlyContinue)
    }
    if ($Job.status -eq 'Running' -or $runnerAlive) {
        throw 'This book is generating. Wait for it to finish, or stop it with Stop Book Studio, before changing its setup.'
    }
    $busyRequest = @($Job.aiRequests | Where-Object { $_.status -in @('Queued', 'Running') } | Select-Object -First 1)[0]
    if ($busyRequest) {
        throw 'A Codex request for this book is still running. Stop it beside the book, then change the setup.'
    }
}

function Get-BookStudioSetupSummary {
    param([Parameter(Mandatory)][object]$Job)

    $production = $null
    $productionPath = Join-Path ([string]$Job.sourceContextPath) 'book-studio-production.json'
    if (Test-Path -LiteralPath $productionPath) {
        try { $production = Get-Content -LiteralPath $productionPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $production = $null }
    }
    [pscustomobject]@{
        title = [string]$Job.title
        courseCode = [string]$Job.courseCode
        courseDocumentKind = [string]$Job.courseDocumentKind
        specialInstructions = [string]$Job.specialInstructions
        readingLevel = $(if ($production -and $production.readingLevel) { [int]$production.readingLevel } else { 8 })
        sourceMode = $(if ($production -and $production.sourceMode) { [string]$production.sourceMode } else { 'UploadedOnly' })
        imageContext = $(if ($production -and $production.imageSettings) { [string]$production.imageSettings.context } else { 'Generic' })
        imageInstructions = $(if ($production -and $production.imageSettings) { [string]$production.imageSettings.instructions } else { '' })
        documents = @(@($Job.uploadedFiles) | Where-Object { $_.role -ne 'brief' } | ForEach-Object {
            [pscustomobject]@{ name = [string]$_.originalName; role = [string]$_.role; size = [int]$_.size }
        })
        canChange = $true
    }
}

# What changing the setup means for where the book stands. A new document, or a
# different kind of document, invalidates a format preview built from the old
# one, so the book returns to the stage that produces it. Renaming does not.
function Get-BookStudioSetupStageReset {
    param(
        [Parameter(Mandatory)][object]$Job,
        [Parameter(Mandatory)][bool]$DocumentsChanged,
        [Parameter(Mandatory)][bool]$KindChanged
    )

    if (-not $DocumentsChanged -and -not $KindChanged) {
        return [pscustomobject]@{ stage = [string]$Job.workflowStage; status = [string]$Job.status; clearedApproval = $false }
    }
    $kind = [string]$Job.courseDocumentKind
    if ($kind -eq 'CurriculumDraft') {
        return [pscustomobject]@{ stage = 'outcomes-analysis'; status = 'Review'; clearedApproval = $true }
    }
    return [pscustomobject]@{ stage = 'format-review'; status = 'Ready'; clearedApproval = $true }
}
