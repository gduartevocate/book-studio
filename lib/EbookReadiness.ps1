. (Join-Path $PSScriptRoot 'EbookImages.ps1')

function Get-EbookEditorialPolicy {
    # One release threshold, shared by generation, audit, and regression tests.
    # Do not relax it to make a manuscript pass; revise the manuscript instead.
    [pscustomobject]@{ version = '2026-09-15.1'; maximumGrade = 8.0; maximumPassiveRate = 4.0 }
}

function Test-EbookEditorialThresholds {
    param([AllowNull()][object]$Grade, [AllowNull()][object]$PassiveRate)
    $policy = Get-EbookEditorialPolicy
    $issues = New-Object System.Collections.ArrayList
    foreach ($entry in @(
        @{ name = 'Flesch-Kincaid grade'; value = $Grade; maximum = $policy.maximumGrade },
        @{ name = 'Possible passive phrases per 1,000 words'; value = $PassiveRate; maximum = $policy.maximumPassiveRate }
    )) {
        $number = 0.0
        $valid = $null -ne $entry.value -and [double]::TryParse([string]$entry.value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)
        if (-not $valid -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            [void]$issues.Add("$($entry.name) is missing or invalid; fail closed.")
        } elseif ($entry.name -like 'Possible passive*' -and $number -lt 0) {
            [void]$issues.Add('Passive phrase rate cannot be negative.')
        } elseif ($number -gt $entry.maximum) {
            [void]$issues.Add("$($entry.name) is $number; maximum is $($entry.maximum). Revise the prose before delivery.")
        }
    }
    [pscustomobject]@{ status = $(if ($issues.Count) { 'FAIL' } else { 'PASS' }); policyVersion = $policy.version; issues = @($issues); detail = $(if ($issues.Count) { $issues -join ' ' } else { 'Grade-8 and active-voice release thresholds passed.' }) }
}

function Get-EbookDeliveryReadiness {
    param([object[]]$Checks, [AllowNull()][object]$Approvals, [string]$DocxSha256)
    # Editorial findings are review work, not broken-deliverable failures. Keep
    # artifact, export, release, and path-integrity checks as the technical
    # threshold so a usable whole-book draft can reach an instructional
    # designer without weakening publication controls.
    $reviewCategories = @(
        'Planning Gates', 'Planning Content', 'Feedback Hardening',
        'Content Policy', 'Quality Reports', 'Style Gates', 'Content Gates',
        'Research Gates', 'Agent Reports', 'Publishing Review',
        'Assigned Reading List', 'Manuscript Shape'
    )
    $technical = @($Checks | Where-Object {
        $_.category -notin $reviewCategories -and
        ($_.name -ne 'generation_gate' -or $_.status -notin @('PASS','WARNING'))
    })
    $bad = @($technical | Where-Object { $_.status -ne 'PASS' })
    $technicalStatus = if (-not $technical.Count -or @($bad | Where-Object status -ne 'WARNING').Count) { 'FAIL' } elseif ($bad.Count) { 'WARNING' } else { 'PASS' }
    $missing = New-Object System.Collections.ArrayList
    foreach ($kind in @('academic', 'permissions')) {
        $approval = if ($Approvals -and $Approvals.PSObject.Properties[$kind]) { $Approvals.$kind } else { $null }
        $date = [datetime]::MinValue
        $valid = $approval -and $approval.status -ceq 'Approved' -and
            -not [string]::IsNullOrWhiteSpace([string]$approval.reviewer) -and
            [datetime]::TryParse([string]$approval.reviewedAt, [ref]$date) -and $date -le (Get-Date) -and
            $DocxSha256 -match '^[A-Fa-f0-9]{64}$' -and $approval.docxSha256 -ceq $DocxSha256
        if (-not $valid) { [void]$missing.Add($kind) }
    }
    [pscustomobject]@{
        technicalStatus = $technicalStatus
        draftReadyForReview = ($technicalStatus -eq 'PASS')
        publicationReady = ($technicalStatus -eq 'PASS' -and $missing.Count -eq 0)
        pendingApprovals = @($missing)
        blockingTechnicalChecks = @($bad | ForEach-Object name)
        approvalRequirement = 'Human academic and permissions records must identify the reviewer, date, and exact delivered DOCX SHA256. Never infer approval from a build or a working source link.'
    }
}

function Get-EbookPackageQaStatus {
    param([Parameter(Mandatory)][string]$OutputFolder)
    try {
        if ((Get-EbookImageExportReview -OutputFolder $OutputFolder).status -ne 'PASS') { return 'FAIL' }
        $quality = Get-Content -LiteralPath (Join-Path $OutputFolder 'quality-report.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $editor = Get-Content -LiteralPath (Join-Path $OutputFolder 'publishing-editor-report.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $audit = Get-Content -LiteralPath (Join-Path $OutputFolder 'ebook-output-audit.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        if ($quality.status -ne 'PASS' -or $editor.status -ne 'PASS' -or $audit.status -notin @('PASS','WARNING') -or -not $audit.readiness.draftReadyForReview -or $audit.readiness.technicalStatus -ne 'PASS') { return 'FAIL' }
        if (-not (Get-EbookDeliveryReadiness -Checks $audit.checks -DocxSha256 $audit.docxSha256).draftReadyForReview) { return 'FAIL' }
        if ($audit.editorialPolicyVersion -ne (Get-EbookEditorialPolicy).version) { return 'FAIL' }
        $docx = @(Get-ChildItem -LiteralPath $OutputFolder -Filter '* - E-Book.docx' -File -ErrorAction Stop)
        $md = @(Get-ChildItem -LiteralPath $OutputFolder -Filter '* - E-Book.md' -File -ErrorAction Stop)
        if ($docx.Count -ne 1 -or $md.Count -ne 1 -or (Get-FileHash -LiteralPath $docx[0].FullName -Algorithm SHA256).Hash -ne $audit.docxSha256) { return 'FAIL' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $md[0].FullName -Raw -Encoding UTF8))) | ForEach-Object {$_.ToString('x2')}) } finally { $sha.Dispose() }
        if ($hash -ne $quality.manuscriptSha256 -or $hash -ne $editor.manuscriptSha256 -or $editor.editorialPolicyVersion -ne (Get-EbookEditorialPolicy).version) { return 'FAIL' }
        # A pending human-approval warning is not an editorial failure, but it
        # must remain visible; this function never grants publication approval.
        return 'PASS'
    } catch { return 'FAIL' }
}

function Test-EbookReviewEvidence {
    param([object]$Render,[object]$Independent,[object]$Visual,[object]$Links,[string]$DocxSha256,[string]$PdfSha256,[string]$ManifestSha256,[string[]]$ExpectedUrls,[string]$CourseCode,[int[]]$ChapterNumbers)
    $issues=New-Object System.Collections.ArrayList
    foreach($hash in @($DocxSha256,$PdfSha256,$ManifestSha256)) {
        if($hash -notmatch '^[A-Fa-f0-9]{64}$'){[void]$issues.Add('A required artifact SHA256 is invalid.')}
    }
    $pageCount=0
    $renderDate=[datetime]::MinValue
    if (-not $Render -or -not [int]::TryParse([string]$Render.pages,[ref]$pageCount) -or $pageCount -lt 1 -or -not [datetime]::TryParse([string]$Render.generatedAt,[ref]$renderDate) -or $renderDate -gt (Get-Date) -or $Render.docxSha256 -ne $DocxSha256 -or $Render.pdfSha256 -ne $PdfSha256) { [void]$issues.Add('Current Word/PDF render evidence is missing, invalid, or stale.') }
    if (-not $Independent -or $Independent.courseCode -ne $CourseCode -or $Independent.status -ne 'PASS' -or $Independent.editorialPolicyVersion -ne (Get-EbookEditorialPolicy).version -or $Independent.docxSha256 -ne $DocxSha256 -or $Independent.pdfSha256 -ne $PdfSha256 -or -not @($Independent.checks).Count -or @($Independent.checks | Where-Object status -ne 'PASS').Count) { [void]$issues.Add('Independent output review is missing, stale, incomplete, or failed.') }
    $requiredChecks=@('curriculum_objective_trace','assigned_source_trace','current_release_integrity','word_prose_round_trip','word_table_text_round_trip','no_prohibited_learner_content','html_no_prohibited_visible_content','matching_word_html_tables','word_source_destinations','html_source_destinations','current_word_render_hash','current_pdf_render_hash','pdf_source_destinations','pdf_no_prohibited_content','business_case_labels_in_word_and_pdf','pdf_has_all_chapter_bibliographies')
    foreach($n in $ChapterNumbers) {
        $requiredChecks+=@("word_chapter_${n}_exact_objectives","chapter_${n}_developed_vocabulary","chapter_${n}_substantive_integration","word_chapter_${n}_editorial_thresholds","pdf_chapter_${n}_note_numbering","pdf_chapter_${n}_objective_numbering")
    }
    if(-not $ChapterNumbers.Count -or @($requiredChecks | Where-Object {$_ -notin @($Independent.checks.name)}).Count){[void]$issues.Add('Independent review is missing required whole-book or chapter checks.')}
    $seen = @($Visual.thumbnailPages | Sort-Object -Unique)
    $expectedPages = if ($pageCount -ge 1) { @(1..$pageCount) } else { @() }
    $reviewedAt=[datetime]::MinValue
    if (-not $Visual -or $Visual.status -ne 'PASS' -or [string]::IsNullOrWhiteSpace($Visual.reviewer) -or -not [datetime]::TryParse([string]$Visual.reviewedAt,[ref]$reviewedAt) -or $reviewedAt -gt (Get-Date) -or $reviewedAt -lt $renderDate -or $Visual.docxSha256 -ne $DocxSha256 -or $Visual.pdfSha256 -ne $PdfSha256 -or ($seen -join ',') -ne ($expectedPages -join ',') -or @($Visual.enlargedPages | Sort-Object -Unique).Count -lt [Math]::Min(8,$expectedPages.Count) -or @($Visual.enlargedPages | Where-Object {$_ -notin $expectedPages}).Count) { [void]$issues.Add('Recorded inspection of every current page and enlarged samples is required; rendering alone is not visual review.') }
    $linkDate=[datetime]::MinValue
    $actualUrls=@($Links.results.url | Sort-Object -Unique)
    $wantedUrls=@($ExpectedUrls | Sort-Object -Unique)
    if (-not $Links -or $Links.courseCode -ne $CourseCode -or $Links.status -ne 'PASS' -or $Links.manifestSha256 -ne $ManifestSha256 -or -not $wantedUrls.Count -or ($actualUrls -join '|') -ne ($wantedUrls -join '|') -or @($Links.results | Where-Object status -ne 'PASS').Count -or -not [datetime]::TryParse([string]$Links.generatedAt,[ref]$linkDate) -or $linkDate -lt (Get-Date).AddDays(-7) -or $linkDate -gt (Get-Date)) { [void]$issues.Add('All assigned URLs require a matching, successful availability review within seven days.') }
    [pscustomobject]@{status=$(if($issues.Count){'FAIL'}else{'PASS'});issues=@($issues);detail=$(if($issues.Count){$issues -join ' '}else{'Current rendered artifacts, independent review, recorded visual inspection, and assigned-link evidence match.'})}
}
