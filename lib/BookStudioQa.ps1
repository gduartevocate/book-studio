# Review existing content; never repair or regenerate learner-facing artifacts.
function Invoke-BookStudioQaReview {
    [CmdletBinding()]
    param([string]$DatabasePath, [string]$JobId, [string]$ProjectRoot)
    $job = Get-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId
    Assert-BookStudioProductionIdle $job
    if ($job.status -in @('Running','Queued')) { throw 'Wait for the current work to finish before running QA.' }
    if (-not $job.outputFolder -or -not (Test-Path -LiteralPath $job.outputFolder -PathType Container)) { throw 'Create the outline before running QA.' }
    Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message 'QA review started. Checking saved content without rewriting it.'
    try {
        Import-Module (Join-Path $ProjectRoot 'lib/EbookGenerator.psm1') -Scope Local
        & (Get-Module EbookGenerator) {
            param($folder)
            function Read-QaJson([string]$name) {
                Get-Content -LiteralPath (Join-Path $folder $name) -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            }
            $plan = Read-QaJson 'ebook-plan.json'
            if (-not @($plan.chapters).Count) { throw 'The saved outline has no chapters.' }
            $blueprint = Read-QaJson 'ebook-planning-packet.json'
            $planning = Get-PlanningPacketQualityReview -Course $blueprint.course -CourseConceptArc $blueprint.courseConceptArc -EbookOutline $blueprint.ebookOutline
            $planning | Add-Member -NotePropertyName planningSha256 -NotePropertyValue (Get-FileHash -LiteralPath (Join-Path $folder 'ebook-planning-packet.json')).Hash -Force
            $planning | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $folder 'outline-qa.json') -Encoding UTF8
            $manuscripts = @(Get-ChildItem -LiteralPath $folder -Filter '* - E-Book.md' -File)
            if ($manuscripts.Count -gt 1) { throw 'Multiple manuscripts found. Select one book package before running QA.' }
            $artifacts = @()
            foreach ($kind in @('Planning Packet','Outline')) {
                $files = @(Get-ChildItem -LiteralPath $folder -Filter "* - E-Book $kind.docx" -File)
                if ($files.Count -gt 1) { throw "Multiple $kind exports found." }
                $path = if ($files.Count) { $files[0].FullName } else { Join-Path $folder "$($plan.courseCode) - E-Book $kind.docx" }
                $artifacts += [pscustomobject]@{name="$kind Word document";path=$path;minimumWords=500;minimumTextRuns=60;minimumImages=0;requireHeadings=$false}
            }
            if ($manuscripts.Count) {
                $markdown = Get-Content -LiteralPath $manuscripts[0].FullName -Raw -Encoding UTF8
                $sources = @(Read-QaJson 'source-brief.json')
                $context = Read-QaJson 'source-context-index.json'
                $brand = Read-QaJson 'brand-profile.json'
                $engagement = Read-QaJson 'engagement-plan.json'
                $quality = New-EbookQualityReport -Course $blueprint.course -Plan $plan -Sources $sources -SourceContext $context -Markdown $markdown -BrandProfile $brand
                $publishing = New-PublishingEditorReport -Course $blueprint.course -Plan $plan -Sources $sources -SourceContext $context -QualityReport $quality -Markdown $markdown -EngagementPlan $engagement -BrandProfile $brand
                $agents = New-AgentReviewReport -Course $blueprint.course -Plan $plan -Sources $sources -SourceContext $context -QualityReport $quality -Markdown $markdown -BrandProfile $brand -EditorialReport $publishing -Blueprint $blueprint
                foreach ($item in @(
                    @{name='quality-report';report=$quality;text=(ConvertTo-QualityReportMarkdown $quality)},
                    @{name='publishing-editor-report';report=$publishing;text=(ConvertTo-PublishingEditorReportMarkdown $publishing)},
                    @{name='agent-report';report=$agents;text=(ConvertTo-AgentReportMarkdown $agents)}
                )) {
                    $item.report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $folder ($item.name+'.json')) -Encoding UTF8
                    $item.text | Set-Content -LiteralPath (Join-Path $folder ($item.name+'.md')) -Encoding UTF8
                }
                $assigned = Test-EbookAssignedSourcePackage -Course $blueprint.course -Plan $plan -Markdown $markdown -OutputFolder $folder
                if ($assigned.applicable) { $assigned | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $folder 'assigned-source-review.json') -Encoding UTF8 }
                $artifacts += [pscustomobject]@{name='E-book Word document';path=[IO.Path]::ChangeExtension($manuscripts[0].FullName,'.docx');minimumWords=1000;minimumTextRuns=120;minimumImages=@(Get-MarkdownImageReferences $markdown).Count;requireHeadings=$true}
            } elseif (@(Get-ChildItem -LiteralPath $folder -Filter '* - E-Book.docx' -File).Count) {
                throw 'The manuscript Markdown is missing. Restore it before running book QA.'
            }
            $validation = New-ExportValidationReport -Artifacts $artifacts
            $validation | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'export-validation.json') -Encoding UTF8
            ConvertTo-ExportValidationMarkdown $validation | Set-Content -LiteralPath (Join-Path $folder 'export-validation.md') -Encoding UTF8
        } $job.outputFolder
        if (@(Get-ChildItem -LiteralPath $job.outputFolder -Filter '* - E-Book.md' -File).Count) {
            & (Join-Path $ProjectRoot 'audit-ebook-output.ps1') -OutputFolder $job.outputFolder -CourseCode $job.courseCode | Out-Null
        }
        $summary = Get-BookStudioQualitySummary -OutputFolder $job.outputFolder
        $message = if ($summary.stage -eq 'outline') {
            "QA review finished. Outline: $($summary.outlineStatus). Sources: $($summary.sourceReadiness.status). Book QA waits for a manuscript. Use Check required sources to retrieve or retry reading URLs."
        } else { "QA review finished. Book QA: $($summary.status). Content unchanged; see QA findings and refreshed reports." }
        $receipt = [pscustomobject]@{status='Completed';checkedAt=(Get-Date).ToString('o');message=$message;qaSummary=$summary}
        $receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $job.outputFolder 'qa-review.json') -Encoding UTF8
        Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update { param($current) Add-OrSet-BookStudioNoteProperty -InputObject $current -Name qaReview -Value $receipt }
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message $message
        $null = Refresh-BookStudioJobArtifacts -DatabasePath $DatabasePath -JobId $JobId
        return $receipt
    } catch {
        $message = "QA review could not finish: $($_.Exception.Message)"
        $receipt = [pscustomobject]@{status='Failed';checkedAt=(Get-Date).ToString('o');message=$message}
        Update-BookStudioJob -DatabasePath $DatabasePath -JobId $JobId -Update { param($current) Add-OrSet-BookStudioNoteProperty -InputObject $current -Name qaReview -Value $receipt }
        Add-BookStudioLogEntry -DatabasePath $DatabasePath -JobId $JobId -Message $message
        throw
    }
}
