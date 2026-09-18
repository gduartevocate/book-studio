[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$DatabasePath,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [ValidateSet("Blueprint", "Full")][string]$RunMode = "Full"
)

$ErrorActionPreference = "Stop"
. (Join-Path $ProjectRoot 'lib/EbookReadiness.ps1')
. (Join-Path $ProjectRoot 'lib/EbookPublicationTemplate.ps1')

$modulePath = Join-Path $ProjectRoot "lib\BookStudio.psm1"
Import-Module $modulePath -Force

function Set-JobFailure {
    param([string]$Message)

    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($job)
        $job.status = "Failed"
        $job.error = $Message
        $job.runnerProcessId = $null
        if ($job.PSObject.Properties.Name -contains "workflowStage") {
            $job.workflowStage = if ($RunMode -eq "Blueprint") { "format-review" } else { "generation-failed" }
        }
        if ($job.PSObject.Properties.Name -contains "workflowStatus") {
            $job.workflowStatus = if ($RunMode -eq "Blueprint") { "Format preview failed" } else { "Full generation failed" }
        }
    }
    Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase "Failed" -Detail $Message -Level Error -AddLog
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Failed: $Message"
}

function ConvertTo-RunnerArgumentLine {
    param([Parameter(Mandatory)][object[]]$Arguments)

    $quoted = foreach ($argument in $Arguments) {
        $value = [string]$argument
        if ($value -match '[\s"]') {
            '"' + ($value -replace '"', '\"') + '"'
        }
        else {
            $value
        }
    }

    return ($quoted -join " ")
}

function Read-NewRunnerLines {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ref]$SeenLineCount
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($SeenLineCount.Value -ge $lines.Count) {
        return @()
    }

    $newLines = @($lines | Select-Object -Skip $SeenLineCount.Value)
    $SeenLineCount.Value = $lines.Count
    return $newLines
}

function Update-ProgressFromRunnerLine {
    param([AllowNull()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return
    }

    if ($Line -match '^\[BOOKSTUDIO-PROGRESS\]\s*([^|]+)\|\s*([^|]+)\|\s*(.*)$') {
        $phase = $Matches[2].Trim()
        $detail = $Matches[3].Trim()
        Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase $phase -Detail $detail -AddLog
        return
    }

    if ($Line -match '^\[BOOKSTUDIO-CHAPTER\]\s*([^|]+)\|\s*([^|]+)\|\s*([^|]+)\|\s*([^|]+)\|\s*([^|]+)\|\s*(.*)$') {
        $chapterNumber = [int]($Matches[2].Trim())
        $chapterTitle = $Matches[3].Trim()
        $chapterPhase = $Matches[4].Trim()
        $chapterStatus = $Matches[5].Trim()
        $chapterDetail = $Matches[6].Trim()
        Set-BookStudioJobProgress `
            -DatabasePath $DatabasePath `
            -JobId $JobId `
            -Phase $chapterPhase `
            -Detail $chapterDetail `
            -ChapterNumber $chapterNumber `
            -ChapterTitle $chapterTitle `
            -ChapterStatus $chapterStatus `
            -AddLog
        return
    }

    if ($Line -match '^\[BOOKSTUDIO-ERROR\]\s*([^|]+)\|\s*([^|]+)\|\s*([^|]*)\|\s*([^|]*)\|\s*(.*)$') {
        $phase = $Matches[2].Trim()
        $chapterNumberText = $Matches[3].Trim()
        $chapterTitle = $Matches[4].Trim()
        $detail = $Matches[5].Trim()
        $chapterNumber = 0
        if ($chapterNumberText -match '^\d+$') { $chapterNumber = [int]$chapterNumberText }
        Set-BookStudioJobProgress `
            -DatabasePath $DatabasePath `
            -JobId $JobId `
            -Phase $phase `
            -Detail $detail `
            -ChapterNumber $chapterNumber `
            -ChapterTitle $chapterTitle `
            -ChapterStatus "Error" `
            -Level Error `
            -AddLog
        return
    }
}

function Get-RunnerArtifactSpecs {
    return @(
        @{ name = "E-book planning packet"; pattern = "* - E-Book Planning Packet.docx" },
        @{ name = "E-book outline"; pattern = "* - E-Book Outline.docx" },
        @{ name = "E-book planning packet Markdown"; fileName = "ebook-planning-packet.md" },
        @{ name = "E-book outline Markdown"; fileName = "ebook-outline.md" },
        @{ name = "Book format preview"; fileName = "book-format-preview.html" },
        @{ name = "Word document"; pattern = "* - E-Book.docx" },
        @{ name = "HTML ebook"; pattern = "* - E-Book.html" },
        @{ name = "Markdown ebook"; pattern = "* - E-Book.md" },
        @{ name = "Interactive study"; fileName = "interactive-study.html" },
        @{ name = "Quality report"; fileName = "quality-report.md" },
        @{ name = "Agent report"; fileName = "agent-report.md" },
        @{ name = "Publishing editor report"; fileName = "publishing-editor-report.md" },
        @{ name = "Export validation report"; fileName = "export-validation.md" },
        @{ name = "Output audit report"; fileName = "ebook-output-audit.md" },
        @{ name = "Codex drafting report"; fileName = "codex-drafting-report.md" },
        @{ name = "Codex drafting prompt"; fileName = "codex-drafting-prompt.md" },
        @{ name = "Codex drafting response"; fileName = "codex-drafting-response.md" },
        @{ name = "Manuscript preflight"; fileName = "manuscript-preflight.md" },
        @{ name = "Targeted format repair"; fileName = "codex-format-repair-report.md" },
        @{ name = "Targeted format repair log"; fileName = "codex-format-repair-error.log" },
        @{ name = "Codex drafting log"; fileName = "codex-drafting-error.log" },
        @{ name = "Codex image report"; fileName = "codex-image-report.md" },
        @{ name = "Codex image prompt"; fileName = "codex-image-prompt.md" },
        @{ name = "Codex image response"; fileName = "codex-image-response.md" },
        @{ name = "Chapter source manifest"; relativePath = "chapters\manifest.json" },
        @{ name = "Academic source registry"; fileName = "sources.md" }
    )
}

function Get-LatestRunnerOutputFolder {
    param([Parameter(Mandatory)][string]$OutputRoot)

    return @(
        Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    )[0]
}

function Get-RunnerArtifactsForOutputFolder {
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][string]$JobId
    )

    $artifacts = New-Object System.Collections.ArrayList
    foreach ($spec in @(Get-RunnerArtifactSpecs)) {
        $path = $null
        if ($spec.pattern) {
            $matchedFile = @(
                Get-ChildItem -LiteralPath $OutputFolder -File -Filter $spec.pattern -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
            )[0]
            if ($matchedFile) {
                $path = $matchedFile.FullName
            }
        }
        else {
            if ($spec.relativePath) {
                $path = Join-Path $OutputFolder $spec.relativePath
            }
            else {
                $path = Join-Path $OutputFolder $spec.fileName
            }
        }

        if ($path -and (Test-Path -LiteralPath $path)) {
            $file = Get-Item -LiteralPath $path
            [void]$artifacts.Add([pscustomobject]@{
                name = $spec.name
                fileName = $file.Name
                path = $file.FullName
                size = $file.Length
                url = "/api/jobs/$JobId/artifact?name=$([uri]::EscapeDataString($file.Name))"
            })
        }
    }

    return @($artifacts)
}

function Save-RunnerArtifactsIfAvailable {
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$LogPath
    )

    $outputFolder = Get-LatestRunnerOutputFolder -OutputRoot $OutputRoot
    if (-not $outputFolder) {
        return $null
    }

    $artifacts = Get-RunnerArtifactsForOutputFolder -OutputFolder $outputFolder.FullName -JobId $JobId
    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        $current.outputFolder = $outputFolder.FullName
        $current.logPath = $LogPath
        $current.artifacts = @($artifacts)
    }

    return $outputFolder
}

function Get-RunnerRecentText {
    param([string[]]$Paths)

    $parts = New-Object System.Collections.ArrayList
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            continue
        }
        try {
            $lines = @(Get-Content -LiteralPath $path -Tail 80 -ErrorAction SilentlyContinue)
            if ($lines.Count -gt 0) {
                [void]$parts.Add(($lines -join [Environment]::NewLine))
            }
        }
        catch {
        }
    }

    return ($parts -join [Environment]::NewLine)
}

function Test-RunnerCodexUsageLimitText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return ($Text -match '(?i)\busage limit\b' -or $Text -match '(?i)\btry again at\b')
}

function Get-RunnerGeneratorFailure {
    param([string]$LogPath, [string]$ErrorLogPath, [string]$ExitCode)

    # The generator's structured error is authoritative. A QA/export exception
    # is not evidence that Codex crashed or failed to return a response.
    $outputText = if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath -Raw -Encoding UTF8 } else { '' }
    $errors = [regex]::Matches([string]$outputText, '(?m)^\[BOOKSTUDIO-ERROR\]\s*[^|]*\|\s*[^|]*\|\s*[^|]*\|\s*[^|]*\|\s*([^\r\n]+)')
    $detail = if ($errors.Count) { $errors[$errors.Count - 1].Groups[1].Value.Trim() } else { '' }
    if (-not $detail -and (Test-Path -LiteralPath $ErrorLogPath)) {
        $detail = (@(Get-Content -LiteralPath $ErrorLogPath -Tail 12 -Encoding UTF8) -join ' ').Trim()
        if ($detail.Length -gt 2000) { $detail = $detail.Substring($detail.Length - 2000) }
    }
    if (-not $detail) { $detail = "Generator exited with code $ExitCode without recording a specific error." }

    $kind = 'execution'
    if ($errors.Count -and $detail -match '^(Release artifact gate failed during repair\.|Final export validation failed\.|E-book output audit status is (FAIL|WARN)\.)') {
        $kind = 'qa'
    }
    else {
        $classified = & (Get-Module BookStudio) { param($text) Get-BookStudioCodexFailure -Text $text } $detail
        $kind = $classified.kind
    }
    [pscustomobject]@{ kind = $kind; message = $detail }
}

function Get-RunnerCodexUsageLimitMessage {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "Codex reported a usage limit. Try again after the time shown in the log."
    }

    if ($Text -match '(?is)(hit your usage limit\.\s*Try again at\s*[^\r\n.]+\.?)') {
        return $Matches[1].Trim()
    }
    if ($Text -match '(?is)(Codex reported a usage limit[^\r\n.]*\.?)') {
        return $Matches[1].Trim()
    }
    if ($Text -match '(?is)(Try again at\s*[^\r\n.]+\.?)') {
        return "Codex reported a usage limit. $($Matches[1].Trim())"
    }

    return "Codex reported a usage limit. Try again after the time shown in the log."
}

function Backup-RunnerExistingOutputFolder {
    param([Parameter(Mandatory)][object]$Job)

    if (-not $Job.PSObject.Properties.Name.Contains("outputFolder") -or [string]::IsNullOrWhiteSpace($Job.outputFolder)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $Job.outputFolder -PathType Container)) {
        return $null
    }

    $sourceItem = Get-Item -LiteralPath $Job.outputFolder
    $bookStudioRoot = Split-Path -Parent $DatabasePath
    $backupRoot = Join-Path $bookStudioRoot "bk"
    $stamp = Get-Date -Format "HHmmss"
    $backupParent = Join-Path $backupRoot "$JobId-$stamp"
    $backupPath = Join-Path $backupParent "p"
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

    $backupFailed = $false
    Get-ChildItem -LiteralPath $sourceItem.FullName -Force | ForEach-Object {
        try {
            Copy-Item -LiteralPath $_.FullName -Destination $backupPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            $backupFailed = $true
            Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Could not back up $($_.Name) before retry; continuing without an automatic restore copy. $($_.Exception.Message)"
        }
    }
    if ($backupFailed) {
        Remove-Item -LiteralPath $backupParent -Recurse -Force -ErrorAction SilentlyContinue
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message 'The pre-retry backup was incomplete because the output contains unavailable OneDrive files. The retry will continue.'
        return $null
    }
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Backed up current package before retry: $backupPath"

    return [pscustomobject]@{
        sourcePath = $sourceItem.FullName
        backupPath = $backupPath
    }
}

function Restore-RunnerExistingOutputBackup {
    param([AllowNull()][object]$Backup)

    if (-not $Backup -or [string]::IsNullOrWhiteSpace($Backup.backupPath) -or -not (Test-Path -LiteralPath $Backup.backupPath -PathType Container)) {
        return $null
    }

    $targetPath = [string]$Backup.sourcePath
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        return $null
    }

    $targetParent = Split-Path -Parent $targetPath
    if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $targetPath) {
        Remove-Item -LiteralPath $targetPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    Get-ChildItem -LiteralPath $Backup.backupPath -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $targetPath -Recurse -Force
    }
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Restored package backup after Codex usage limit: $targetPath"

    return Get-Item -LiteralPath $targetPath
}

function Test-RunnerLogCompletedSuccessfully {
    param([Parameter(Mandatory)][string]$LogPath)

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return $false
    }

    $logText = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($logText)) {
        return $false
    }

    $completionMarker = if ($RunMode -eq "Blueprint") { "Ebook planning packet complete\." } else { "Ebook generator complete\." }
    return ($logText -match $completionMarker -and $logText -match "\[BOOKSTUDIO-PROGRESS\].*\|\s*Complete\s*\|")
}

function Test-RunnerAutoQaRepairEnabled {
    $value = [Environment]::GetEnvironmentVariable("BOOKSTUDIO_AUTO_QA_REPAIR", "Process")
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable("BOOKSTUDIO_AUTO_QA_REPAIR", "User") }
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable("BOOKSTUDIO_AUTO_QA_REPAIR", "Machine") }
    return ($value -notmatch '^(0|false|no|off)$')
}

function Get-RunnerReportStatus {
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][string]$FileName
    )

    $path = Join-Path $OutputFolder $FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ""
    }

    try {
        $report = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$report.status
    }
    catch {
        return "FAIL"
    }
}

function Get-RunnerQaStatus {
    param([Parameter(Mandatory)][string]$OutputFolder)
    return Get-EbookPackageQaStatus -OutputFolder $OutputFolder
}

function Get-RunnerTechnicalStatus {
    param([Parameter(Mandatory)][string]$OutputFolder)

    if ((Get-EbookImageExportReview -OutputFolder $OutputFolder).status -ne 'PASS') { return 'FAIL' }
    $auditPath = Join-Path $OutputFolder 'ebook-output-audit.json'
    if (-not (Test-Path -LiteralPath $auditPath -PathType Leaf)) {
        return 'FAIL'
    }
    try {
        $audit = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($audit.readiness -and [string]$audit.readiness.technicalStatus -eq 'PASS') {
            return 'PASS'
        }
    }
    catch {
    }
    return 'FAIL'
}

function Test-RunnerCodexDraftComplete {
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][datetime]$StartedAt
    )

    try {
        foreach ($name in @('codex-drafting-exit-code.txt', 'codex-drafting-response.md', 'codex-drafting-report.md', 'codex-drafting-error.log')) {
            $file = Get-Item -LiteralPath (Join-Path $OutputFolder $name) -ErrorAction Stop
            if ($file.LastWriteTime -lt $StartedAt -or $file.Length -eq 0) { return $false }
        }
        $exitText = (Get-Content -LiteralPath (Join-Path $OutputFolder 'codex-drafting-exit-code.txt') -Raw -Encoding UTF8).Trim()
        if ($exitText -ne '0') { return $false }
        $response = Get-Content -LiteralPath (Join-Path $OutputFolder 'codex-drafting-response.md') -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($response)) { return $false }
        $report = Get-Content -LiteralPath (Join-Path $OutputFolder 'codex-drafting-report.md') -Raw -Encoding UTF8
        if ($report -notmatch '(?m)^- Exit code: 0\s*$') { return $false }
        $draftLog = Get-Content -LiteralPath (Join-Path $OutputFolder 'codex-drafting-error.log') -Raw -Encoding UTF8
        $sandboxProblem = & (Get-Module BookStudio) { param($text) Get-EbookCodexSandboxFailure -Text $text -ExpectedSandbox 'workspace-write' } $draftLog
        if ($sandboxProblem) { return $false }

        $manuscripts = @(Get-ChildItem -LiteralPath $OutputFolder -Filter '* - E-Book.md' -File)
        if ($manuscripts.Count -ne 1 -or $manuscripts[0].LastWriteTime -lt $StartedAt) { return $false }
        $markdown = Get-Content -LiteralPath $manuscripts[0].FullName -Raw -Encoding UTF8
        $plan = Get-Content -LiteralPath (Join-Path $OutputFolder 'ebook-plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $actual = @([regex]::Matches([string]$markdown, '(?m)^# Chapter (\d+):[^\r\n]+') | ForEach-Object { [int]$_.Groups[1].Value })
        $expected = @($plan.chapters | Sort-Object { [int]$_.number } | ForEach-Object { [int]$_.number })
        if ($expected.Count -eq 0 -or ($actual -join ',') -ne ($expected -join ',')) { return $false }
        return $true
    }
    catch { return $false }
}

function Get-RunnerQaRepairDecision {
    param([string]$FailureKind, [string]$OutputFolder, [datetime]$StartedAt)

    if ($FailureKind -ne 'qa') {
        return [pscustomobject]@{ allowed = $false; reason = 'The generator failed outside a confirmed QA check. Review the original error and any partial output before retrying.' }
    }
    if (-not (Test-RunnerCodexDraftComplete -OutputFolder $OutputFolder -StartedAt $StartedAt)) {
        return [pscustomobject]@{ allowed = $false; reason = 'A completed drafting pass for this run could not be verified. Review the drafting log and partial manuscript before retrying.' }
    }
    return [pscustomobject]@{ allowed = $true; reason = '' }
}

function Confirm-RunnerCodexGenerationProof {
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][datetime]$StartedAt
    )

    if (-not (Test-RunnerCodexDraftComplete -OutputFolder $OutputFolder -StartedAt $StartedAt)) { return $false }

    $command = Resolve-BookStudioCodexCommand -ProjectRoot $ProjectRoot
    if (-not $command) {
        return $false
    }
    $connectionResult = [pscustomobject]@{
        status = 'PASS'
        checkedAt = (Get-Date).ToString('o')
        identity = ''
        kind = ''
        message = 'Codex completed the drafting pass successfully; the connection remains verified for this run.'
        exitCode = 0
        logPath = ''
    }
    & (Get-Module BookStudio) {
        param($root, $commandPath, $result)
        $result.identity = Get-BookStudioConnectionIdentity $commandPath
        Set-BookStudioConnectionResult -ProjectRoot $root -Result $result
    } $ProjectRoot $command.Source $connectionResult
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message 'Codex drafting completed successfully; refreshed the connection proof before QA repair.'
    return $true
}

function Get-RunnerQaRepairInstruction {
    param(
        [Parameter(Mandatory)][object]$Job,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $courseLabel = "$($Job.courseCode) $($Job.title)".Trim()
    if ([string]::IsNullOrWhiteSpace($courseLabel)) {
        $courseLabel = "this ebook package"
    }

    return @"
Fix the failed QA issues for $courseLabel.

This is an automatic Book Studio repair pass. Edit the learner-facing ebook package in place so the generated package can pass QA before it is shown as complete.

Context from the runner:
$FailureMessage

Required workflow:
1. Inspect quality-report.md, publishing-editor-report.md, agent-report.md, export-validation.md, ebook-output-audit.md, ebook-outline.md, ebook-planning-packet.md, sources.md, and the current E-Book Markdown when those files exist.
2. Identify every blocking QA/export/output-audit issue.
3. Revise the actual E-Book Markdown source; keep chapter Markdown/JSON files synchronized if you edit them. Target reported failures and preserve unaffected chapters, exact objectives, source details, and image references. Do not rewrite the entire book for a formatting defect.
4. Keep the work as a clean e-book. Do not add assignments, tests, quiz language, visible ADA descriptions, placeholder captions, or process notes for reviewers.
5. Preserve numbered scholarly source links and source integrity. Use plain Markdown source notes (1. Source details), restarting at 1 per chapter, with matching body links such as [1](#chapter-1-note-1). Do not add raw or escaped HTML a/span anchors; the exporter creates targets. Never remove sources to make a check pass or invent citations.
6. Fix content depth, missing sections, broken image references, weak visuals, obvious accessibility issues, and export problems that are visible from the reports.

Publication format contract (also applies to repairs):
$(Get-EbookTemplateInstructions)

After editing, summarize exactly which files changed and which QA issues you addressed.
"@
}

function Set-RunnerAiRequestPostProcess {
    # The runner rebuilds the package itself after its repair request, so the
    # request record must say what happened; otherwise the app keeps showing
    # "rebuild queued" and disables Fix QA with Codex indefinitely.
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Status
    )

    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        foreach ($request in @($current.aiRequests)) {
            if ($request.id -ne $RequestId) { continue }
            foreach ($pair in @(@{ name = "postProcessStatus"; value = $Status }, @{ name = "postProcessedAt"; value = (Get-Date).ToString("s") })) {
                if ($request.PSObject.Properties.Name -contains $pair.name) { $request.($pair.name) = $pair.value }
                else { $request | Add-Member -MemberType NoteProperty -Name $pair.name -Value $pair.value }
            }
        }
    }
}

function Wait-RunnerAiRequest {
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [int]$TimeoutSeconds = 3600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $requests = @(Get-BookStudioAiRequests -DatabasePath $DatabasePath -JobId $JobId)
        $request = @($requests | Where-Object { $_.id -eq $RequestId } | Select-Object -First 1)[0]
        if ($request -and $request.status -ne "Running") {
            return $request
        }
        Start-Sleep -Seconds 5
    }

    throw "Automatic QA repair timed out after $TimeoutSeconds seconds."
}

function Invoke-RunnerAutomaticQaRepair {
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][string]$FailureMessage,
        [Parameter(Mandatory)][string]$FailureKind,
        [Parameter(Mandatory)][datetime]$StartedAt
    )

    $decision = Get-RunnerQaRepairDecision -FailureKind $FailureKind -OutputFolder $OutputFolder -StartedAt $StartedAt
    if (-not $decision.allowed) {
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Automatic QA repair skipped. $($decision.reason)"
        return $false
    }

    if (Test-RunnerCodexUsageLimitText -Text $FailureMessage) {
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Automatic QA repair skipped because Codex reported a usage limit."
        return $false
    }

    if (-not (Test-RunnerAutoQaRepairEnabled)) {
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Automatic QA repair is disabled by BOOKSTUDIO_AUTO_QA_REPAIR."
        return $false
    }

    $codexCommand = Resolve-BookStudioCodexCommand -ProjectRoot $ProjectRoot
    if (-not $codexCommand) {
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Automatic QA repair skipped because Codex CLI is not available."
        return $false
    }

    $jobForRepair = Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    $technicalBefore = Get-RunnerTechnicalStatus -OutputFolder $OutputFolder
    if ($technicalBefore -eq "PASS") {
        return $false
    }
    if (-not (Confirm-RunnerCodexGenerationProof -OutputFolder $OutputFolder -StartedAt $StartedAt)) { return $false }

    Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase "Automatic QA repair" -Detail "QA did not pass. Starting one Codex repair pass before finalizing the job." -Percent 94 -AddLog
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Automatic QA repair started because technical readiness was $technicalBefore."

    $request = New-BookStudioAiRequest `
        -DatabasePath $DatabasePath `
        -JobId $JobId `
        -Instruction (Get-RunnerQaRepairInstruction -Job $jobForRepair -FailureMessage $FailureMessage) `
        -Scope "Package" `
        -ChapterId "" `
        -AllowEdits `
        -IncludeHistory:$false `
        -KeepJobActive `
        -ActiveProcessId $PID `
        -RequestKind 'QaRepair' `
        -ProjectRoot $ProjectRoot

    $timeoutText = [Environment]::GetEnvironmentVariable("BOOKSTUDIO_AUTO_QA_REPAIR_TIMEOUT_SECONDS", "Process")
    if (-not $timeoutText) { $timeoutText = [Environment]::GetEnvironmentVariable("BOOKSTUDIO_AUTO_QA_REPAIR_TIMEOUT_SECONDS", "User") }
    $timeoutSeconds = 3600
    if ($timeoutText -match '^\d+$') {
        $timeoutSeconds = [int]$timeoutText
    }

    $completedRequest = try { Wait-RunnerAiRequest -RequestId $request.id -TimeoutSeconds $timeoutSeconds } catch { Set-RunnerAiRequestPostProcess -RequestId $request.id -Status "Package rebuild skipped: $($_.Exception.Message)"; throw }
    if (-not $completedRequest -or $completedRequest.status -ne "Completed") {
        $detail = if ($completedRequest) { $completedRequest.statusDetail } else { "No request status was returned." }
        Set-RunnerAiRequestPostProcess -RequestId $request.id -Status "Package rebuild skipped: the automatic QA repair request did not complete. $detail"
        throw "Automatic QA repair did not complete successfully. $detail Repair log: $($request.errorPath). Partial edits may exist; review them before retrying."
    }
    if ($completedRequest.failureKind -eq 'sandbox') {
        Set-RunnerAiRequestPostProcess -RequestId $request.id -Status "Package rebuild skipped: $($completedRequest.statusDetail)"
        throw "Automatic QA repair could not edit the book. $($completedRequest.statusDetail)"
    }

    try {
        $rebuild = Invoke-BookStudioPackageRebuild -DatabasePath $DatabasePath -JobId $JobId -ProjectRoot $ProjectRoot
    }
    catch {
        Set-RunnerAiRequestPostProcess -RequestId $request.id -Status "Package rebuild failed after automatic QA repair: $($_.Exception.Message)"
        throw
    }
    Set-RunnerAiRequestPostProcess -RequestId $request.id -Status "Package rebuilt after automatic QA repair. Export validation: $($rebuild.repair.exportValidationStatus). Output audit: $($rebuild.audit.status)."
    $refreshed = Refresh-BookStudioJobArtifacts -DatabasePath $DatabasePath -JobId $JobId
    $qaAfter = Get-RunnerQaStatus -OutputFolder $OutputFolder
    $technicalAfter = Get-RunnerTechnicalStatus -OutputFolder $OutputFolder
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Automatic QA repair finished. Export validation: $($rebuild.repair.exportValidationStatus). Output audit: $($rebuild.audit.status). Technical readiness: $technicalAfter. Editorial QA status: $qaAfter."

    if ($technicalAfter -ne "PASS") {
        throw "Automatic QA repair ran, but QA still failed. See ebook-output-audit.md, quality-report.md, and publishing-editor-report.md."
    }

    return $true
}

try {
    $job = Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    if (-not $job) {
        throw "Job not found: $JobId"
    }

    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        $current.status = "Running"
        $current.error = ""
        if (-not ($current.PSObject.Properties.Name -contains "workflowStage")) {
            $current | Add-Member -MemberType NoteProperty -Name "workflowStage" -Value $(if ($RunMode -eq "Blueprint") { "format-review" } else { "generating" })
        }
        elseif ($RunMode -eq "Blueprint") {
            $current.workflowStage = "format-review"
        }
        else {
            $current.workflowStage = "generating"
        }
        if (-not ($current.PSObject.Properties.Name -contains "workflowStatus")) {
            $current | Add-Member -MemberType NoteProperty -Name "workflowStatus" -Value $(if ($RunMode -eq "Blueprint") { "Creating format preview" } else { "Generating full book" })
        }
        else {
            $current.workflowStatus = if ($RunMode -eq "Blueprint") { "Creating format preview" } else { "Generating full book" }
        }
    }
    $startPhase = if ($RunMode -eq "Blueprint") { "Preparing format review" } else { "Starting full generation" }
    $startDetail = if ($RunMode -eq "Blueprint") { "Preparing the layout and formatting preview for instructional-designer approval." } else { "Preparing the local ebook runner." }
    Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase $startPhase -Detail $startDetail -Percent 5 -AddLog
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Runner started."

    $generatorPath = Join-Path $ProjectRoot "ebook-generator.ps1"
    if (-not (Test-Path -LiteralPath $generatorPath)) {
        throw "Generator not found: $generatorPath"
    }

    $outputRoot = $job.outputRoot
    if (-not (Test-Path -LiteralPath $outputRoot)) {
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    }
    $preRunOutputBackup = Backup-RunnerExistingOutputFolder -Job $job

    $logPath = $job.logPath
    if ([string]::IsNullOrWhiteSpace($logPath)) {
        $logPath = Join-Path (Join-Path (Split-Path -Parent $DatabasePath) "logs") "$JobId.log"
    }

    $generatorArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $generatorPath,
        "-SpecPath", $job.specPath,
        "-SourceContextPath", $job.sourceContextPath,
        "-OutputDir", $outputRoot,
        "-MaxResearchPerChapter", ([int]$job.options.maxResearchPerChapter),
        "-MaxSourceContextFiles", ([int]$job.options.maxSourceContextFiles)
    )
    if($job.options.sourceMode){$generatorArgs+=@('-SourceMode',$job.options.sourceMode)}
    if($job.options.maxSourceContextChars){$generatorArgs+=@('-MaxSourceContextChars',[int]$job.options.maxSourceContextChars)}
    $reviewedOutlinePath = Join-Path $job.sourceContextPath 'book-studio-reviewed-outline.json'
    if (Test-Path -LiteralPath $reviewedOutlinePath -PathType Leaf) {
        $generatorArgs += @('-ReviewedOutlinePath', $reviewedOutlinePath)
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message 'Applying the saved instructional-designer outline to this run.'
    }
    if ($RunMode -eq "Blueprint") {
        $generatorArgs += "-BlueprintOnly"
    }
    else {
        $generatorArgs += @(
            "-ApproveOutline",
            "-ApprovedBy", "Book Studio",
            "-ApprovalNotes", "Format preview approved by the instructional designer in Book Studio."
        )
    }
    $useCodexDrafting = if ($job.options.PSObject.Properties.Name -contains "useCodexDrafting") { [bool]$job.options.useCodexDrafting } else { $true }
    $useCodexImages = if ($job.options.PSObject.Properties.Name -contains "useCodexImages") { [bool]$job.options.useCodexImages } else { $true }
    $resumeImages = $false
    $resumeFolder = Get-LatestRunnerOutputFolder -OutputRoot $outputRoot
    if ($RunMode -eq 'Full' -and $useCodexImages -and $resumeFolder -and (Test-Path -LiteralPath (Join-Path $resumeFolder.FullName 'image-production-run.json'))) {
        $imageRun = Get-Content -LiteralPath (Join-Path $resumeFolder.FullName 'image-production-run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($imageRun.status -eq 'Incomplete') {
            $resumeImages = $true
            $useCodexDrafting = $false
            $generatorArgs += @('-ResumeImageOutputFolder', $resumeFolder.FullName)
            Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message 'Retrying only image production and exports. Existing chapter text and verified images will be preserved.'
        }
    }
    if ($RunMode -eq "Full" -and ($useCodexDrafting -or $useCodexImages)) {
        $codexCommand = Resolve-BookStudioCodexCommand -ProjectRoot $ProjectRoot
        if (-not $codexCommand) {
            throw "Codex generation is enabled, but Codex CLI was not found. Use the Codex Assistant panel to save the codex.exe path, then retry the job."
        }
        $generatorArgs += @("-CodexCommandPath", $codexCommand.Source)
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Codex enabled: $($codexCommand.Source)"
    }
    if ($RunMode -eq "Full") {
        $generatorArgs += @("-UseCodexDrafting", $(if ($useCodexDrafting) { 1 } else { 0 }))
        if (-not $useCodexDrafting) {
            Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Codex AI drafting disabled for this job."
        }
        $generatorArgs += @("-UseCodexImages", $(if ($useCodexImages) { 1 } else { 0 }))
        if (-not $useCodexImages) {
            Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Image generation is disabled. This run can save a text scaffold but cannot finish a complete book; no placeholder artwork will be substituted."
        }
    }
    if ([bool]$job.options.skipResearch) {
        $generatorArgs += "-SkipResearch"
    }
    if ([bool]$job.options.skipOpenStaxFetch) {
        $generatorArgs += "-SkipOpenStaxFetch"
    }

    $runLabel = if ($RunMode -eq "Blueprint") { "format preview" } else { "ebook package" }
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Generating $runLabel."
    $runDetail = if ($RunMode -eq "Blueprint") { "The blueprint generator is building the format preview." } else { "The ebook generator is running. Live milestones will appear here." }
    Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase $(if ($RunMode -eq "Blueprint") { "Building format preview" } else { "Generating" }) -Detail $runDetail -Percent 10 -AddLog

    $errorLogPath = [System.IO.Path]::ChangeExtension($logPath, ".err.log")
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errorLogPath -Force -ErrorAction SilentlyContinue

    $generatorStartedAt = Get-Date
    $generatorProcess = Start-Process `
        -FilePath "powershell" `
        -ArgumentList (ConvertTo-RunnerArgumentLine -Arguments $generatorArgs) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $logPath `
        -RedirectStandardError $errorLogPath `
        -PassThru
    $generatorProcessHandle = $generatorProcess.Handle

    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        $current.runnerProcessId = $generatorProcess.Id
    }

    $seenOutputLines = 0
    $seenErrorLines = 0
    while (-not $generatorProcess.HasExited) {
        foreach ($line in @(Read-NewRunnerLines -Path $logPath -SeenLineCount ([ref]$seenOutputLines))) {
            Update-ProgressFromRunnerLine -Line $line
        }
        foreach ($line in @(Read-NewRunnerLines -Path $errorLogPath -SeenLineCount ([ref]$seenErrorLines))) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase "Generator message" -Detail $line -Level Warning -AddLog
            }
        }
        Save-RunnerArtifactsIfAvailable -OutputRoot $outputRoot -LogPath $logPath | Out-Null
        Start-Sleep -Seconds 2
        $generatorProcess.Refresh()
    }
    $generatorProcess.WaitForExit()
    $generatorProcess.Refresh()

    foreach ($line in @(Read-NewRunnerLines -Path $logPath -SeenLineCount ([ref]$seenOutputLines))) {
        Update-ProgressFromRunnerLine -Line $line
    }
    foreach ($line in @(Read-NewRunnerLines -Path $errorLogPath -SeenLineCount ([ref]$seenErrorLines))) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase "Generator message" -Detail $line -Level Warning -AddLog
        }
    }

    $exitCode = $generatorProcess.ExitCode
    if ($null -eq $exitCode -and (Test-RunnerLogCompletedSuccessfully -LogPath $logPath)) {
        $exitCode = 0
    }
    elseif ($null -eq $exitCode) {
        $exitCode = "unknown"
    }
    if ($exitCode -ne 0) {
        $availableOutputFolder = Save-RunnerArtifactsIfAvailable -OutputRoot $outputRoot -LogPath $logPath
        $failureText = Get-RunnerRecentText -Paths @($errorLogPath, $logPath)
        $failure = Get-RunnerGeneratorFailure -LogPath $logPath -ErrorLogPath $errorLogPath -ExitCode $exitCode
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Original generator failure: $($failure.message)"
        if ($failure.kind -eq 'authentication') {
            & (Get-Module BookStudio) {
                param($root,$message)
                $command=Resolve-BookStudioCodexCommand -ProjectRoot $root
                if($command){Set-BookStudioConnectionResult -ProjectRoot $root -Result ([pscustomobject]@{status='FAIL';checkedAt=(Get-Date).ToString('o');identity=(Get-BookStudioConnectionIdentity $command.Source);kind='authentication';message=$message})}
            } $ProjectRoot $failure.message
            throw "$($failure.message) Generation did not complete. See $logPath and $errorLogPath; review any partial output before retrying."
        }
        if (Test-RunnerCodexUsageLimitText -Text $failureText) {
            $usageLimitMessage = Get-RunnerCodexUsageLimitMessage -Text $failureText
            $restoredOutputFolder = Restore-RunnerExistingOutputBackup -Backup $preRunOutputBackup
            if ($restoredOutputFolder) {
                $restoredQaStatus = Get-RunnerQaStatus -OutputFolder $restoredOutputFolder.FullName
                if ($restoredQaStatus -eq "PASS") {
                    $restoredArtifacts = Get-RunnerArtifactsForOutputFolder -OutputFolder $restoredOutputFolder.FullName -JobId $JobId
                    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
                        param($current)
                        $current.status = "Completed"
                        $current.outputFolder = $restoredOutputFolder.FullName
                        $current.logPath = $logPath
                        $current.artifacts = @($restoredArtifacts)
                        $current.error = ""
                        $current.runnerProcessId = $null
                    }
                    Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase "Codex usage limit" -Detail "Retry stopped because Codex quota is exhausted; the previous package was restored. $usageLimitMessage" -Level Warning -Percent 100 -AddLog
                    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Retry stopped by Codex usage limit. Previous package restored. $usageLimitMessage"
                    exit 0
                }
            }

            if ($availableOutputFolder) {
                $availableQaStatus = Get-RunnerQaStatus -OutputFolder $availableOutputFolder.FullName
                if ($availableQaStatus -eq "PASS") {
                    $availableArtifacts = Get-RunnerArtifactsForOutputFolder -OutputFolder $availableOutputFolder.FullName -JobId $JobId
                    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
                        param($current)
                        $current.status = "Completed"
                        $current.outputFolder = $availableOutputFolder.FullName
                        $current.logPath = $logPath
                        $current.artifacts = @($availableArtifacts)
                        $current.error = ""
                        $current.runnerProcessId = $null
                    }
                    Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase "Codex usage limit" -Detail "Retry stopped because Codex quota is exhausted; the existing usable package was kept. $usageLimitMessage" -Level Warning -Percent 100 -AddLog
                    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Retry stopped by Codex usage limit. Existing usable package kept. $usageLimitMessage"
                    exit 0
                }
            }

            throw "Codex generation stopped because the Codex account is at its usage limit. $usageLimitMessage"
        }

        if ($RunMode -eq 'Full' -and $availableOutputFolder -and (Test-Path -LiteralPath (Join-Path $availableOutputFolder.FullName 'image-production-run.json'))) {
            $imageRun = Get-Content -LiteralPath (Join-Path $availableOutputFolder.FullName 'image-production-run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($imageRun.status -ne 'Complete') { throw "Original failure: $($failure.message) Images incomplete. $($imageRun.failure) Retry will resume images only; the manuscript and successful images are preserved. See $logPath and $errorLogPath." }
        }
        if ($RunMode -eq "Full" -and $availableOutputFolder -and $useCodexDrafting) {
            try {
                $repairApplied = if ((Get-RunnerTechnicalStatus -OutputFolder $availableOutputFolder.FullName) -ne 'PASS') {
                    Invoke-RunnerAutomaticQaRepair -OutputFolder $availableOutputFolder.FullName -FailureKind $failure.kind -StartedAt $generatorStartedAt -FailureMessage $failure.message
                } else { $false }
                if ($repairApplied) {
                    $exitCode = 0
                }
            }
            catch {
                $primaryFailure = if ($failure.message) { [string]$failure.message } else { "Review the generator output and error log." }
                throw "Generator exited with code $exitCode. Primary failure: $primaryFailure Automatic QA repair was attempted but did not resolve the job: $($_.Exception.Message) See $logPath."
            }
        }

        if ($exitCode -ne 0) {
            throw "Generator exited with code $exitCode. Original failure: $($failure.message) See $logPath and $errorLogPath. Review any partial output before retrying."
        }
    }

    if ($RunMode -eq "Full" -and $useCodexDrafting) {
        $completedOutputFolder = Get-LatestRunnerOutputFolder -OutputRoot $outputRoot
        if ($completedOutputFolder) {
            Confirm-RunnerCodexGenerationProof -OutputFolder $completedOutputFolder.FullName -StartedAt $generatorStartedAt | Out-Null
        }
    }

    Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase "Collecting artifacts" -Detail "Finding the generated Word, HTML, Markdown, reports, and source files." -Percent 92 -AddLog

    $outputFolder = Get-LatestRunnerOutputFolder -OutputRoot $outputRoot

    if (-not $outputFolder) {
        throw "Generator completed, but no output folder was found in $outputRoot."
    }

    New-BookStudioFormatPreview -Job $job -OutputFolder $outputFolder.FullName | Out-Null
    $artifacts = Get-RunnerArtifactsForOutputFolder -OutputFolder $outputFolder.FullName -JobId $JobId

    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        $current.status = "Running"
        $current.outputFolder = $outputFolder.FullName
        $current.logPath = $logPath
        $current.artifacts = @($artifacts)
        $current.error = ""
        $current.runnerProcessId = $null
        if (-not ($current.PSObject.Properties.Name -contains "workflowStage")) {
            $current | Add-Member -MemberType NoteProperty -Name "workflowStage" -Value $(if ($RunMode -eq "Blueprint") { "format-review" } else { "id-review" })
        }
        else {
            $current.workflowStage = if ($RunMode -eq "Blueprint") { "format-review" } else { "id-review" }
        }
        if (-not ($current.PSObject.Properties.Name -contains "workflowStatus")) {
            $current | Add-Member -MemberType NoteProperty -Name "workflowStatus" -Value $(if ($RunMode -eq "Blueprint") { "Format preview ready for review" } else { "Full book ready for instructional-designer review" })
        }
        else {
            $current.workflowStatus = if ($RunMode -eq "Blueprint") { "Format preview ready for review" } elseif ($qaStatus -eq "PASS") { "Full book ready for instructional-designer review" } else { "Full book ready; editorial review required" }
        }
    }

    $qaStatus = Get-RunnerQaStatus -OutputFolder $outputFolder.FullName
    if ($RunMode -eq 'Full') {
        $imageReview = Get-EbookImageProductionReview -OutputFolder $outputFolder.FullName
        if ($imageReview.status -ne 'PASS') { throw "Cannot complete this book: $($imageReview.detail)" }
    }
    $technicalStatus = Get-RunnerTechnicalStatus -OutputFolder $outputFolder.FullName
    if ($RunMode -eq "Full" -and $technicalStatus -ne "PASS" -and $useCodexDrafting) {
        try {
            Invoke-RunnerAutomaticQaRepair -OutputFolder $outputFolder.FullName -FailureKind 'qa' -StartedAt $generatorStartedAt -FailureMessage "Generator completed, but technical readiness is $technicalStatus. Inspect release-integrity.json and ebook-output-audit.md for the failed checks." | Out-Null
            New-BookStudioFormatPreview -Job $job -OutputFolder $outputFolder.FullName | Out-Null
            $artifacts = Get-RunnerArtifactsForOutputFolder -OutputFolder $outputFolder.FullName -JobId $JobId
            $qaStatus = Get-RunnerQaStatus -OutputFolder $outputFolder.FullName
            $technicalStatus = Get-RunnerTechnicalStatus -OutputFolder $outputFolder.FullName
        }
        catch {
            throw "Generator completed, but QA failed. Automatic QA repair was attempted but did not resolve the job: $($_.Exception.Message) Review the QA and export reports for the original failure."
        }
    }

    if ($RunMode -eq "Full" -and $technicalStatus -ne "PASS") {
        throw "Generator completed, but technical readiness still failed. See the repair status in the job log, ebook-output-audit.md, export-validation.md, and release-integrity.json."
    }

    if ($RunMode -eq "Full" -and $qaStatus -ne "PASS") {
        Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase "Editorial review required" -Detail "The complete book is available. Editorial QA findings are listed in the quality, publishing, and audit reports." -Level Warning -Percent 98 -AddLog
    }

    Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update {
        param($current)
        $current.status = "Completed"
        $current.outputFolder = $outputFolder.FullName
        $current.logPath = $logPath
        $current.artifacts = @($artifacts)
        $current.error = ""
        $current.runnerProcessId = $null
        if ($current.PSObject.Properties.Name -contains "workflowStage") {
            $current.workflowStage = if ($RunMode -eq "Blueprint") { "format-review" } else { "id-review" }
        }
        if ($current.PSObject.Properties.Name -contains "workflowStatus") {
            $current.workflowStatus = if ($RunMode -eq "Blueprint") { "Format preview ready for review" } elseif ($qaStatus -eq "PASS") { "Full book ready for instructional-designer review" } else { "Full book ready; editorial review required" }
        }
    }
    Set-BookStudioJobProgress -DatabasePath $DatabasePath -JobId $JobId -Phase "Complete" -Detail "Book package is ready for review." -Percent 100 -AddLog
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message "Completed ebook package."
}
catch {
    Set-JobFailure -Message $_.Exception.Message
    exit 1
}
