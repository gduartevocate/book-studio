[CmdletBinding()]
param(
    [string]$OutputFolder = ".\dist\GM1000-Introduction-to-Business-Office-Operations",
    [string]$CourseCode = "",
    [switch]$FailOnFinding,
    [switch]$RequireDraftReady,
    [switch]$RequirePublicationReady
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'lib/EbookReadiness.ps1')

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

function Read-DocxText {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry("word/document.xml")
        if (-not $entry) { return "" }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { [xml]$documentXml = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $ns = New-Object System.Xml.XmlNamespaceManager($documentXml.NameTable)
        $ns.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
        $paragraphs = foreach ($paragraph in $documentXml.SelectNodes("//w:body//w:p", $ns)) {
            (($paragraph.SelectNodes(".//w:t", $ns) | ForEach-Object { $_.InnerText }) -join "")
        }
        return (($paragraphs -join "`n") -replace "\s+", " ").Trim()
    }
    finally {
        $zip.Dispose()
    }
}

function Get-TextSha256 {
    param([AllowNull()][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }))
    }
    finally {
        $sha.Dispose()
    }
}

function Get-OutputProseSignals {
    param([AllowNull()][string]$Text)

    $value = [string]$Text
    # Citation URLs contain normal periods followed by lowercase URL paths.
    # Exclude each chapter's source-note block from sentence-boundary checks;
    # source presence is validated separately by the source and release gates.
    $value = [regex]::Replace($value, "(?is)(?:#{1,6}\s*)?Scholarly Sources\b.*?(?=(?:#{1,6}\s*)?Chapter\s+\d+[:\s]|\z)", " ")
    $value = $value -replace "\s+", " "
    [pscustomobject]@{
        lowercaseAfterPeriod = [regex]::Matches($value, "(?<=[a-z])\.\s+(?=[a-z])").Count
        conjunctionAfterPeriod = [regex]::Matches($value, "(?i)\.\s+(?:and|or|but|while|because|so|when|instead|rather)\b").Count
        encodingSignals = [regex]::Matches($value, "(?:[\u00C2\u00C3\u00E2][\u0080-\u00BF]|\u0393\u00C7|\u00E2\u20AC)").Count
        wordCount = [regex]::Matches($value, "\b[A-Za-z][A-Za-z'-]*\b").Count
    }
}

function Test-OutputFilePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        if ($fullPath.Length -ge 240) {
            return [System.IO.File]::Exists("\\?\$fullPath")
        }
        return [System.IO.File]::Exists($fullPath)
    }
    catch {
        return Test-Path -LiteralPath $Path -PathType Leaf
    }
}

function Add-AuditCheck {
    param(
        [System.Collections.ArrayList]$Checks,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Detail,
        [string]$Evidence = ""
    )

    [void]$Checks.Add([pscustomobject]@{
        category = $Category
        name = $Name
        status = $Status
        detail = $Detail
        evidence = $Evidence
    })
}

function Get-CheckStatus {
    param([bool]$Condition)

    if ($Condition) { return "PASS" }
    return "FAIL"
}

function Get-ReportGateStatus {
    param([AllowNull()][string]$Status)

    switch -Regex ([string]$Status) {
        "^PASS$" { return "PASS" }
        "^WARNING$" { return "WARNING" }
        default { return "FAIL" }
    }
}

function Get-ReadabilityGateStatus {
    param([double]$Grade)

    return (Test-EbookEditorialThresholds -Grade $Grade -PassiveRate 0).status
}

function Get-FirstFile {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Pattern
    )

    return @(
        Get-ChildItem -LiteralPath $Folder -File -Filter $Pattern -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    )[0]
}

function ConvertTo-AuditMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# E-Book Output Audit")
    [void]$lines.Add("")
    [void]$lines.Add("Course: $($Report.courseCode)")
    [void]$lines.Add("")
    [void]$lines.Add("Output folder: $($Report.outputFolder)")
    [void]$lines.Add("")
    [void]$lines.Add("Status: $($Report.status)")
    [void]$lines.Add("Technical readiness: $($Report.readiness.technicalStatus); draft ready for review: $($Report.readiness.draftReadyForReview); publication approved: $($Report.readiness.publicationReady).")
    [void]$lines.Add("Pending human approvals: $($Report.readiness.pendingApprovals -join ', ').")
    [void]$lines.Add("")
    [void]$lines.Add("Summary: $($Report.summary.pass) pass, $($Report.summary.warning) warning, $($Report.summary.fail) fail.")
    [void]$lines.Add("")

    foreach ($category in @($Report.checks | Select-Object -ExpandProperty category -Unique)) {
        [void]$lines.Add("## $category")
        [void]$lines.Add("")
        foreach ($check in @($Report.checks | Where-Object { $_.category -eq $category })) {
            [void]$lines.Add("- $($check.status): $($check.name) - $($check.detail)")
            if (-not [string]::IsNullOrWhiteSpace($check.evidence)) {
                [void]$lines.Add("  Evidence: $($check.evidence)")
            }
        }
        [void]$lines.Add("")
    }

    return ($lines -join "`r`n")
}

$resolvedOutputFolder = (Resolve-Path -LiteralPath $OutputFolder).ProviderPath
$checks = New-Object System.Collections.ArrayList

$paths = [ordered]@{
    planningJson = Join-Path $resolvedOutputFolder "ebook-planning-packet.json"
    planningMarkdown = Join-Path $resolvedOutputFolder "ebook-planning-packet.md"
    outlineMarkdown = Join-Path $resolvedOutputFolder "ebook-outline.md"
    qualityJson = Join-Path $resolvedOutputFolder "quality-report.json"
    agentJson = Join-Path $resolvedOutputFolder "agent-report.json"
    publishingJson = Join-Path $resolvedOutputFolder "publishing-editor-report.json"
    exportJson = Join-Path $resolvedOutputFolder "export-validation.json"
    releaseIntegrityJson = Join-Path $resolvedOutputFolder "release-integrity.json"
    sourceContextJson = Join-Path $resolvedOutputFolder "source-context-index.json"
    ebookMarkdown = ""
    ebookDocx = ""
    planningDocx = ""
    outlineDocx = ""
}

$ebookDocxFile = Get-FirstFile -Folder $resolvedOutputFolder -Pattern "* - E-Book.docx"
$planningDocxFile = Get-FirstFile -Folder $resolvedOutputFolder -Pattern "* - E-Book Planning Packet.docx"
$outlineDocxFile = Get-FirstFile -Folder $resolvedOutputFolder -Pattern "* - E-Book Outline.docx"
$ebookMarkdownFile = Get-FirstFile -Folder $resolvedOutputFolder -Pattern "* - E-Book.md"
if ($ebookDocxFile) { $paths.ebookDocx = $ebookDocxFile.FullName }
if ($planningDocxFile) { $paths.planningDocx = $planningDocxFile.FullName }
if ($outlineDocxFile) { $paths.outlineDocx = $outlineDocxFile.FullName }
if ($ebookMarkdownFile) { $paths.ebookMarkdown = $ebookMarkdownFile.FullName }

foreach ($key in $paths.Keys) {
    $path = $paths[$key]
    $isPresent = -not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)
    Add-AuditCheck -Checks $checks -Category "Artifact Presence" -Name $key -Status (Get-CheckStatus $isPresent) -Detail $(if ($isPresent) { "Found." } else { "Missing required artifact." }) -Evidence $path
}

$planning = Read-JsonFile -Path $paths.planningJson
$quality = Read-JsonFile -Path $paths.qualityJson
$agent = Read-JsonFile -Path $paths.agentJson
$publishing = Read-JsonFile -Path $paths.publishingJson
$exportValidation = Read-JsonFile -Path $paths.exportJson
$releaseIntegrity = Read-JsonFile -Path $paths.releaseIntegrityJson
$sourceContext = Read-JsonFile -Path $paths.sourceContextJson
$planningMarkdown = Read-TextFile -Path $paths.planningMarkdown
$outlineMarkdown = Read-TextFile -Path $paths.outlineMarkdown
$ebookMarkdown = Read-TextFile -Path $paths.ebookMarkdown
$ebookDocxText = Read-DocxText -Path $paths.ebookDocx
$markdownOutputSignals = Get-OutputProseSignals -Text $ebookMarkdown
$docxOutputSignals = Get-OutputProseSignals -Text $ebookDocxText

if ([string]::IsNullOrWhiteSpace($CourseCode) -and $planning -and $planning.course.courseCode) {
    $CourseCode = $planning.course.courseCode
}
if ([string]::IsNullOrWhiteSpace($CourseCode) -and (Split-Path $resolvedOutputFolder -Leaf) -match "^([A-Z]{2,4}\d{3,4})-") {
    $CourseCode = $Matches[1]
}

if ($planning) {
    $generationGateReady = $planning.generationGate.status -eq "Approved for Draft" -and [bool]$planning.generationGate.canGenerateDraft
    Add-AuditCheck -Checks $checks -Category "Planning Gates" -Name "generation_gate" -Status $(if ($generationGateReady) { "PASS" } else { "WARNING" }) -Detail "Generation gate is $($planning.generationGate.status); canGenerateDraft=$($planning.generationGate.canGenerateDraft). Academic approval remains a human release decision."
    Add-AuditCheck -Checks $checks -Category "Planning Gates" -Name "planning_quality_gates" -Status (Get-ReportGateStatus $planning.planningQualityGates.status) -Detail "Planning quality gate status is $($planning.planningQualityGates.status)."
    foreach ($gateName in @("course_arc_structure", "concept_reinforcement_map", "student_performance_thread", "outline_specificity")) {
        $gate = @($planning.planningQualityGates.checks | Where-Object { $_.name -eq $gateName })[0]
        $gateStatus = if ($gate) { Get-ReportGateStatus $gate.status } else { "FAIL" }
        Add-AuditCheck -Checks $checks -Category "Planning Gates" -Name $gateName -Status $gateStatus -Detail $(if ($gate) { $gate.detail } else { "Gate not found." })
    }

    $conceptMapCount = @($planning.courseConceptArc.conceptIntroductionReinforcementMap).Count
    $moduleCount = @($planning.courseConceptArc.modules).Count
    $threadStepCount = @($planning.courseConceptArc.studentPerformanceThread.moduleSteps).Count
    Add-AuditCheck -Checks $checks -Category "Planning Content" -Name "concept_map_count" -Status (Get-CheckStatus ($conceptMapCount -ge 5)) -Detail "$conceptMapCount concept map row(s)."
    Add-AuditCheck -Checks $checks -Category "Planning Content" -Name "performance_thread_steps" -Status (Get-CheckStatus ($moduleCount -gt 0 -and $threadStepCount -eq $moduleCount)) -Detail "$threadStepCount performance thread step(s) for $moduleCount module(s)."
}
else {
    Add-AuditCheck -Checks $checks -Category "Planning Gates" -Name "planning_packet_json" -Status "FAIL" -Detail "Planning packet JSON could not be read."
}

Add-AuditCheck -Checks $checks -Category "Feedback Hardening" -Name "planning_packet_terminology" -Status (Get-CheckStatus ($planningMarkdown -match "E-Book Planning Packet" -and $planningMarkdown -notmatch "(?i)\bblueprint\b")) -Detail "Planning packet uses planning-packet terminology and avoids blueprint wording."
Add-AuditCheck -Checks $checks -Category "Feedback Hardening" -Name "concept_map_visible" -Status (Get-CheckStatus ($planningMarkdown -match "Key Concept Introduction and Reinforcement Map")) -Detail "Planning packet includes the concept introduction/reinforcement map."
Add-AuditCheck -Checks $checks -Category "Feedback Hardening" -Name "performance_thread_visible" -Status (Get-CheckStatus ($planningMarkdown -match "Recommended Student Performance Thread")) -Detail "Planning packet includes the recommended student performance thread."
Add-AuditCheck -Checks $checks -Category "Feedback Hardening" -Name "healthcare_context" -Status (Get-CheckStatus (($planningMarkdown + "`n" + $outlineMarkdown + "`n" + $ebookMarkdown) -match "(?i)allied healthcare|healthcare clinic|clinic|patient|medical front office|patient records|insurance")) -Detail "Output includes entry-level allied healthcare/front-office examples."
Add-AuditCheck -Checks $checks -Category "Feedback Hardening" -Name "no_student_support_fallback" -Status (Get-CheckStatus ($ebookMarkdown -notmatch "(?i)student support office")) -Detail "Student-support-office fallback example is absent from manuscript."
# Match learner-facing labels/sections, not ordinary instructional prose such
# as "test assumptions" or "examine the evidence".
$knowledgeCheckPattern = "(?im)^\s*(?:#{1,6}\s+|\*\*)?(?:Knowledge Checks?|Check Your Reasoning|Check Your Understanding|Self-Assessment|Quiz|Test|Exam)\b"
$knowledgeCheckMatches = @([regex]::Matches($ebookMarkdown, $knowledgeCheckPattern) | ForEach-Object { $_.Value.Trim() })
$reflectionOrChallengePattern = "(?i)\bReflection Activity\b|\bWorkplace Challenge\b|\bThis Week.?s Challenge\b"
$reflectionOrChallengeMatches = @([regex]::Matches($ebookMarkdown, $reflectionOrChallengePattern) | ForEach-Object { $_.Value.Trim() })
$chapterSummaryPattern = "(?i)\bChapter Summary\b"
$chapterSummaryMatches = @([regex]::Matches($ebookMarkdown, $chapterSummaryPattern) | ForEach-Object { $_.Value.Trim() })
Add-AuditCheck -Checks $checks -Category "Content Policy" -Name "markdown_no_knowledge_checks" -Status (Get-CheckStatus ($knowledgeCheckMatches.Count -eq 0)) -Detail $(if ($knowledgeCheckMatches.Count -eq 0) { "No prohibited knowledge-check labels or sections found in the Markdown manuscript." } else { "Prohibited knowledge-check labels/references remain: $($knowledgeCheckMatches -join '; ')" })
Add-AuditCheck -Checks $checks -Category "Content Policy" -Name "markdown_no_reflection_or_workplace_challenge" -Status (Get-CheckStatus ($reflectionOrChallengeMatches.Count -eq 0)) -Detail $(if ($reflectionOrChallengeMatches.Count -eq 0) { "No Reflection Activity, Workplace Challenge, or weekly challenge labels found in the Markdown manuscript." } else { "Prohibited learner-activity labels/references remain: $($reflectionOrChallengeMatches -join '; ')" })
Add-AuditCheck -Checks $checks -Category "Content Policy" -Name "markdown_no_redundant_chapter_summary" -Status (Get-CheckStatus ($chapterSummaryMatches.Count -eq 0)) -Detail $(if ($chapterSummaryMatches.Count -eq 0) { "No redundant Chapter Summary label found in the Markdown manuscript." } else { "Redundant Chapter Summary labels/references remain: $($chapterSummaryMatches -join '; ')" })
$genericPlaceholderPattern = "(?i)\bTODO\b|\bTBD\b|insert (?:a|an|the) (?:example|explanation|citation)|\[(?:insert|add|replace)\b[^\]]{0,100}\]"
# The planning packet intentionally documents the editorial requirements that
# an outline must satisfy (for example, “Concept explanation tied to the
# learning objectives”). Those instructions are not manuscript placeholders.
# Apply the placeholder gate to learner-facing copy and only the narrow,
# unambiguous placeholder patterns to the outline.
$manuscriptPlaceholderText = $ebookMarkdown
$outlinePlaceholderText = $outlineMarkdown
$hasGenericPlaceholder = ($manuscriptPlaceholderText -match $genericPlaceholderPattern) -or ($outlinePlaceholderText -match $genericPlaceholderPattern)
Add-AuditCheck -Checks $checks -Category "Feedback Hardening" -Name "no_generic_outline_placeholders" -Status (Get-CheckStatus (-not $hasGenericPlaceholder)) -Detail "No generic placeholder outline language detected in learner-facing copy or the detailed outline."

if ($quality) {
    Add-AuditCheck -Checks $checks -Category "Quality Reports" -Name "quality_report_status" -Status (Get-ReportGateStatus $quality.status) -Detail "Quality report status is $($quality.status)."
    $actualManuscriptHash = Get-TextSha256 -Text $ebookMarkdown
    $qualityHashMatches = $quality.manuscriptSha256 -and ([string]$quality.manuscriptSha256 -eq $actualManuscriptHash)
    Add-AuditCheck -Checks $checks -Category "Quality Reports" -Name "quality_report_freshness" -Status (Get-CheckStatus $qualityHashMatches) -Detail $(if ($qualityHashMatches) { "Quality report hash matches the current Markdown manuscript." } else { "Quality report is stale or missing manuscriptSha256; regenerate reports after the final manuscript mutation." }) -Evidence "Expected $actualManuscriptHash; reported $($quality.manuscriptSha256)"
    foreach ($chapter in @($quality.chapters)) {
        Add-AuditCheck -Checks $checks -Category "Quality Reports" -Name "chapter_$($chapter.chapterNumber)_status" -Status (Get-ReportGateStatus $chapter.status) -Detail "Chapter $($chapter.chapterNumber) status is $($chapter.status)."
        $style = @($chapter.checks | Where-Object { $_.name -eq "uma_ai_style_guide" })[0]
        $research = @($chapter.checks | Where-Object { $_.name -eq "research_candidates" })[0]
        $prose = @($chapter.checks | Where-Object { $_.name -eq "prose_integrity" })[0]
        $intro = @($chapter.checks | Where-Object { $_.name -eq "introduction_completeness" })[0]
        $fidelity = @($chapter.checks | Where-Object { $_.name -eq "source_fidelity" })[0]
        Add-AuditCheck -Checks $checks -Category "Style Gates" -Name "chapter_$($chapter.chapterNumber)_uma_style" -Status $(if ($style) { Get-ReportGateStatus $style.status } else { "FAIL" }) -Detail $(if ($style) { $style.detail } else { "UMA style check missing." })
        if ($style -and $style.metrics) {
            Add-AuditCheck -Checks $checks -Category "Style Gates" -Name "chapter_$($chapter.chapterNumber)_readability" -Status (Get-ReadabilityGateStatus ([double]$style.metrics.fleschKincaidGrade)) -Detail "Flesch-Kincaid grade $($style.metrics.fleschKincaidGrade)."
            $passiveRate = [double]$style.metrics.passiveVoiceRatePerThousand
            $passiveStatus = (Test-EbookEditorialThresholds -Grade 0 -PassiveRate $style.metrics.passiveVoiceRatePerThousand).status
            Add-AuditCheck -Checks $checks -Category "Style Gates" -Name "chapter_$($chapter.chapterNumber)_passive_voice" -Status $passiveStatus -Detail "Possible passive phrase rate $($style.metrics.passiveVoiceRatePerThousand) per 1,000 words; maximum 4, counted by occurrence."
        }
        Add-AuditCheck -Checks $checks -Category "Content Gates" -Name "chapter_$($chapter.chapterNumber)_prose_integrity" -Status $(if ($prose) { Get-ReportGateStatus $prose.status } else { "FAIL" }) -Detail $(if ($prose) { $prose.detail } else { "Prose integrity check missing." })
        Add-AuditCheck -Checks $checks -Category "Content Gates" -Name "chapter_$($chapter.chapterNumber)_introduction_completeness" -Status $(if ($intro) { Get-ReportGateStatus $intro.status } else { "FAIL" }) -Detail $(if ($intro) { $intro.detail } else { "Introduction completeness check missing." })
        Add-AuditCheck -Checks $checks -Category "Content Gates" -Name "chapter_$($chapter.chapterNumber)_source_fidelity" -Status $(if ($fidelity) { Get-ReportGateStatus $fidelity.status } else { "FAIL" }) -Detail $(if ($fidelity) { $fidelity.detail } else { "Source fidelity check missing." })
        Add-AuditCheck -Checks $checks -Category "Research Gates" -Name "chapter_$($chapter.chapterNumber)_research_candidates" -Status $(if ($research) { Get-ReportGateStatus $research.status } else { "FAIL" }) -Detail $(if ($research) { $research.detail } else { "Research check missing." })
    }
}
else {
    Add-AuditCheck -Checks $checks -Category "Quality Reports" -Name "quality_report_json" -Status "FAIL" -Detail "Quality report JSON could not be read."
}

$markdownProsePass = $markdownOutputSignals.lowercaseAfterPeriod -eq 0 -and $markdownOutputSignals.conjunctionAfterPeriod -le 20 -and $markdownOutputSignals.encodingSignals -eq 0
Add-AuditCheck -Checks $checks -Category "Content Gates" -Name "markdown_round_trip_prose" -Status (Get-CheckStatus $markdownProsePass) -Detail "Markdown output has $($markdownOutputSignals.lowercaseAfterPeriod) lowercase-after-period signal(s), $($markdownOutputSignals.conjunctionAfterPeriod) conjunction-after-period signal(s), and $($markdownOutputSignals.encodingSignals) encoding signal(s); conjunction transitions are tolerated through 20 because valid sentences commonly begin with When, Instead, or And."
$docxPresent = -not [string]::IsNullOrWhiteSpace($paths.ebookDocx) -and -not [string]::IsNullOrWhiteSpace($ebookDocxText)
$docxProsePass = $docxPresent -and $docxOutputSignals.lowercaseAfterPeriod -eq 0 -and $docxOutputSignals.conjunctionAfterPeriod -le 20 -and $docxOutputSignals.encodingSignals -eq 0
Add-AuditCheck -Checks $checks -Category "Content Gates" -Name "docx_round_trip_prose" -Status (Get-CheckStatus $docxProsePass) -Detail $(if ($docxPresent) { "DOCX text has $($docxOutputSignals.lowercaseAfterPeriod) lowercase-after-period signal(s), $($docxOutputSignals.conjunctionAfterPeriod) conjunction-after-period signal(s), and $($docxOutputSignals.encodingSignals) encoding signal(s); conjunction transitions are tolerated through 20 because valid sentences commonly begin with When, Instead, or And." } else { "Final e-book DOCX text could not be extracted." })
$docxKnowledgeCheckPass = $docxPresent -and $ebookDocxText -notmatch $knowledgeCheckPattern
Add-AuditCheck -Checks $checks -Category "Content Policy" -Name "docx_no_knowledge_checks" -Status (Get-CheckStatus $docxKnowledgeCheckPass) -Detail $(if ($docxKnowledgeCheckPass) { "No prohibited knowledge-check labels found in the extracted DOCX text." } else { "Prohibited knowledge-check labels remain in the extracted DOCX text." })
$docxReflectionOrChallengePass = $docxPresent -and $ebookDocxText -notmatch $reflectionOrChallengePattern
$docxChapterSummaryPass = $docxPresent -and $ebookDocxText -notmatch "(?i)\bChapter Summary\b"
Add-AuditCheck -Checks $checks -Category "Content Policy" -Name "docx_no_reflection_or_workplace_challenge" -Status (Get-CheckStatus $docxReflectionOrChallengePass) -Detail $(if ($docxReflectionOrChallengePass) { "No Reflection Activity, Workplace Challenge, or weekly challenge labels found in the extracted DOCX text." } else { "Prohibited learner-activity labels remain in the extracted DOCX text." })
Add-AuditCheck -Checks $checks -Category "Content Policy" -Name "docx_no_redundant_chapter_summary" -Status (Get-CheckStatus $docxChapterSummaryPass) -Detail $(if ($docxChapterSummaryPass) { "No redundant Chapter Summary label found in the extracted DOCX text." } else { "Redundant Chapter Summary label remains in the extracted DOCX text." })
$wordParityPass = $docxPresent -and $markdownOutputSignals.wordCount -gt 0 -and [Math]::Abs($docxOutputSignals.wordCount - $markdownOutputSignals.wordCount) / [double]$markdownOutputSignals.wordCount -le 0.15
Add-AuditCheck -Checks $checks -Category "Content Gates" -Name "markdown_docx_word_parity" -Status (Get-CheckStatus $wordParityPass) -Detail "Markdown word count is $($markdownOutputSignals.wordCount); DOCX extracted word count is $($docxOutputSignals.wordCount); allowed variance is 15%."

if ($agent) {
    Add-AuditCheck -Checks $checks -Category "Agent Reports" -Name "agent_report_status" -Status (Get-ReportGateStatus $agent.status) -Detail "Agent report status is $($agent.status)."
    foreach ($agentName in @(
        "Course Arc Structure Agent",
        "Concept Reinforcement Map Agent",
        "Student Performance Thread Agent",
        "Outline Specificity Agent",
        "UMA Writing Style Agent",
        "Prose Integrity Agent",
        "Introduction Completeness Agent",
        "Publishing Editor Agent",
        "Export Agent"
    )) {
        $agentResult = @($agent.agents | Where-Object { $_.name -eq $agentName })[0]
        Add-AuditCheck -Checks $checks -Category "Agent Reports" -Name ($agentName -replace "\s+", "_") -Status $(if ($agentResult) { Get-ReportGateStatus $agentResult.status } else { "FAIL" }) -Detail $(if ($agentResult) { "$agentName status is $($agentResult.status)." } else { "$agentName missing." })
    }
}
else {
    Add-AuditCheck -Checks $checks -Category "Agent Reports" -Name "agent_report_json" -Status "FAIL" -Detail "Agent report JSON could not be read."
}

if ($publishing) {
    $publishingFresh = $publishing.manuscriptSha256 -eq (Get-TextSha256 -Text $ebookMarkdown) -and $publishing.editorialPolicyVersion -eq (Get-EbookEditorialPolicy).version
    Add-AuditCheck -Checks $checks -Category 'Publishing Review' -Name 'publishing_editor_freshness' -Status (Get-CheckStatus $publishingFresh) -Detail 'Publishing review must match the current manuscript SHA256 and editorial policy.'
    Add-AuditCheck -Checks $checks -Category "Publishing Review" -Name "publishing_editor_status" -Status (Get-ReportGateStatus $publishing.status) -Detail "Publishing editor status is $($publishing.status). $($publishing.decision)"
}
else {
    Add-AuditCheck -Checks $checks -Category "Publishing Review" -Name "publishing_editor_json" -Status "FAIL" -Detail "Publishing editor report JSON could not be read."
}

if ($exportValidation) {
    Add-AuditCheck -Checks $checks -Category "Export Validation" -Name "export_validation_status" -Status (Get-CheckStatus ($exportValidation.status -eq "PASS")) -Detail "Export validation status is $($exportValidation.status)."
    foreach ($artifact in @($exportValidation.artifacts)) {
        Add-AuditCheck -Checks $checks -Category "Export Validation" -Name "$($artifact.artifactName)_status" -Status (Get-CheckStatus ($artifact.status -eq "PASS" -and [int]$artifact.blankNumberedParagraphs -eq 0 -and [int]$artifact.zeroSizedImages -eq 0)) -Detail "$($artifact.artifactName): $($artifact.wordCountApprox) words, $($artifact.textRunCount) text runs, $($artifact.blankNumberedParagraphs) blank numbered paragraphs, $($artifact.imageRefs) image refs, $($artifact.zeroSizedImages) zero-sized images."
    }
}
else {
    Add-AuditCheck -Checks $checks -Category "Export Validation" -Name "export_validation_json" -Status "FAIL" -Detail "Export validation JSON could not be read."
}

if ($releaseIntegrity) {
    Add-AuditCheck -Checks $checks -Category "Release Integrity" -Name "release_integrity_status" -Status (Get-ReportGateStatus $releaseIntegrity.status) -Detail "Release integrity status is $($releaseIntegrity.status)."
    foreach ($check in @($releaseIntegrity.checks)) {
        Add-AuditCheck -Checks $checks -Category "Release Integrity" -Name $check.name -Status (Get-ReportGateStatus $check.status) -Detail $check.detail
    }
}
else {
    Add-AuditCheck -Checks $checks -Category "Release Integrity" -Name "release_integrity_json" -Status "FAIL" -Detail "Release integrity report is missing; final artifact checks were not recorded."
}

$assignedPlanPath = Join-Path $resolvedOutputFolder 'ebook-plan.json'
$assignedPlan = Read-JsonFile -Path $assignedPlanPath
Import-Module (Join-Path $PSScriptRoot 'lib/EbookGenerator.psm1') -Force
if ($planning.course -and $assignedPlan) {
    $currentHtml = Get-FirstFile -Folder $resolvedOutputFolder -Pattern '* - E-Book.html'
    $currentRelease = Test-EbookReleaseArtifacts -Course $planning.course -Plan $assignedPlan -Markdown $ebookMarkdown -HtmlPath $currentHtml.FullName -DocxPath $paths.ebookDocx -OutputFolder $resolvedOutputFolder
    foreach ($check in @($currentRelease.checks)) {
        Add-AuditCheck -Checks $checks -Category 'Current Artifact Verification' -Name ("recomputed_" + $check.name) -Status $check.status -Detail $check.detail
    }
}
else {
    Add-AuditCheck -Checks $checks -Category 'Current Artifact Verification' -Name 'current_release_recheck' -Status 'FAIL' -Detail 'Course and plan are required to recheck the actual exports; a cached PASS is insufficient.'
}
if ($assignedPlan.assignedReadingListRequired -or (Test-Path -LiteralPath (Join-Path $resolvedOutputFolder 'assigned-reading-list.json'))) {
    Import-Module (Join-Path $PSScriptRoot 'lib/EbookGenerator.psm1') -Force
    $assignedReview = Test-EbookAssignedSourcePackage -Course $planning.course -Plan $assignedPlan -Markdown (Read-TextFile -Path $paths.ebookMarkdown) -OutputFolder $resolvedOutputFolder
    Add-AuditCheck -Checks $checks -Category 'Assigned Reading List' -Name 'recomputed_weekly_source_contract' -Status $assignedReview.status -Detail $assignedReview.detail
}

if ($sourceContext) {
    $fileNames = @($sourceContext.files | ForEach-Object { "$($_.name) $($_.path)" })
    $otherCourseMatches = New-Object System.Collections.ArrayList
    foreach ($item in $fileNames) {
        foreach ($match in [regex]::Matches($item, "\b[A-Z]{2,4}\d{3,4}\b")) {
            if (-not [string]::IsNullOrWhiteSpace($CourseCode) -and $match.Value -ne $CourseCode) {
                [void]$otherCourseMatches.Add($match.Value)
            }
        }
    }
    Add-AuditCheck -Checks $checks -Category "Source Context" -Name "course_context_filter" -Status (Get-CheckStatus ($otherCourseMatches.Count -eq 0)) -Detail "$(@($sourceContext.files).Count) source file(s), $(@($sourceContext.chunks).Count) source chunk(s); other course codes found: $(if ($otherCourseMatches.Count -eq 0) { 'none' } else { ($otherCourseMatches | Select-Object -Unique) -join ', ' })."
}
else {
    Add-AuditCheck -Checks $checks -Category "Source Context" -Name "source_context_json" -Status "FAIL" -Detail "Source context JSON could not be read."
}

$legacyBlueprintFiles = @(
    Get-ChildItem -LiteralPath $resolvedOutputFolder -File -Filter "ebook-blueprint.*" -ErrorAction SilentlyContinue
) + @(
    Get-ChildItem -LiteralPath $resolvedOutputFolder -File -Filter "*Blueprint*.docx" -ErrorAction SilentlyContinue
)
Add-AuditCheck -Checks $checks -Category "Artifact Hygiene" -Name "legacy_blueprint_artifacts" -Status (Get-CheckStatus (@($legacyBlueprintFiles).Count -eq 0)) -Detail "$( @($legacyBlueprintFiles).Count ) legacy blueprint artifact(s) found." -Evidence ((@($legacyBlueprintFiles | ForEach-Object { $_.Name }) -join ", "))

$chapterCount = [regex]::Matches($ebookMarkdown, "(?m)^# Chapter \d+:").Count
Add-AuditCheck -Checks $checks -Category "Manuscript Shape" -Name "chapter_count" -Status (Get-CheckStatus ($chapterCount -eq 5)) -Detail "$chapterCount chapter heading(s) found."

$chapterTitleMatches = @([regex]::Matches($ebookMarkdown, "(?m)^# Chapter \d+:\s*(.+?)\s*$"))
$chapterTitles = @($chapterTitleMatches | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ })
$uniqueChapterTitles = @($chapterTitles | Select-Object -Unique)
$duplicateChapterTitles = @(
    $chapterTitles |
        Group-Object |
        Where-Object { $_.Count -gt 1 } |
        ForEach-Object { "$($_.Name) ($($_.Count)x)" }
)
Add-AuditCheck -Checks $checks -Category "Manuscript Shape" -Name "chapter_title_uniqueness" -Status (Get-CheckStatus ($chapterTitles.Count -gt 0 -and $uniqueChapterTitles.Count -eq $chapterTitles.Count)) -Detail $(if ($duplicateChapterTitles.Count -eq 0) { "$($chapterTitles.Count) unique chapter title(s)." } else { "Duplicate chapter title(s): $($duplicateChapterTitles -join '; ')." })

$localImageFailures = New-Object System.Collections.ArrayList
foreach ($match in [regex]::Matches($ebookMarkdown, "!\[[^\]]*\]\(([^)]+)\)")) {
    $target = $match.Groups[1].Value.Trim()
    if ($target -match "^(https?:|mailto:|#)") { continue }
    $targetPath = ($target -replace "#.*$", "")
    $targetPath = $targetPath -replace "/", [System.IO.Path]::DirectorySeparatorChar
    if ([string]::IsNullOrWhiteSpace($targetPath)) { continue }
    if ($targetPath -match "\s+\.(svg|html?|png|jpe?g|docx|md)$") {
        [void]$localImageFailures.Add($target)
        continue
    }
    if (-not (Test-OutputFilePath -Path (Join-Path $resolvedOutputFolder $targetPath))) {
        [void]$localImageFailures.Add($target)
    }
}
Add-AuditCheck -Checks $checks -Category "Artifact Hygiene" -Name "local_image_links" -Status (Get-CheckStatus ($localImageFailures.Count -eq 0)) -Detail $(if ($localImageFailures.Count -eq 0) { "All local Markdown image links resolve to package files." } else { "Missing or malformed local image link(s): $($localImageFailures -join '; ')." })

$localFileLinkFailures = New-Object System.Collections.ArrayList
foreach ($match in [regex]::Matches($ebookMarkdown, "(?<!\!)\[[^\]]+\]\(([^)]+)\)")) {
    $target = $match.Groups[1].Value.Trim()
    if ($target -match "^(https?:|mailto:|#)") { continue }
    if ($target -match "\s+\.(svg|html?|png|jpe?g|docx|md)") {
        [void]$localFileLinkFailures.Add($target)
        continue
    }
    if ($target -notmatch "\.(svg|html?|png|jpe?g|docx|md)(#.*)?$") { continue }
    $targetPath = ($target -replace "#.*$", "")
    $targetPath = $targetPath -replace "/", [System.IO.Path]::DirectorySeparatorChar
    if (-not (Test-OutputFilePath -Path (Join-Path $resolvedOutputFolder $targetPath))) {
        [void]$localFileLinkFailures.Add($target)
    }
}
Add-AuditCheck -Checks $checks -Category "Artifact Hygiene" -Name "local_file_links" -Status (Get-CheckStatus ($localFileLinkFailures.Count -eq 0)) -Detail $(if ($localFileLinkFailures.Count -eq 0) { "All local Markdown file links resolve to package files." } else { "Missing or malformed local file link(s): $($localFileLinkFailures -join '; ')." })

Import-Module (Join-Path $PSScriptRoot 'lib/EbookGenerator.psm1') -Force
$editorialModule = Get-Module EbookGenerator
$sourcePlan=Read-JsonFile -Path (Join-Path $resolvedOutputFolder 'ebook-plan.json')
if($sourcePlan.sourceMode -eq 'UploadedOnly'){
    $brief=Read-JsonFile -Path (Join-Path $resolvedOutputFolder 'source-brief.json')
    $uploadedReview=& $editorialModule {param($p,$s,$ctx,$md) Get-EbookUploadedSourceReview -Plan $p -Sources $s -SourceContext $ctx -Markdown $md} $sourcePlan $brief $sourceContext $ebookMarkdown
    Add-AuditCheck -Checks $checks -Category 'Sources' -Name 'uploaded_source_boundary' -Status $uploadedReview.status -Detail $uploadedReview.detail
}
$currentChapters = @([regex]::Matches($ebookMarkdown, '(?ms)^# Chapter \d+:.*?(?=^# Chapter |\z)'))
Add-AuditCheck -Checks $checks -Category 'Style Gates' -Name 'editorial_chapters_present' -Status (Get-CheckStatus ($currentChapters.Count -gt 0)) -Detail 'Current manuscript must contain chapters for a live editorial review.'
foreach ($chapterMatch in $currentChapters) {
    $number = [regex]::Match($chapterMatch.Value, '^# Chapter (\d+):').Groups[1].Value
    $liveStyle = & $editorialModule { param($text) Get-UmaWritingStyleGuideMetrics -Markdown $text } $chapterMatch.Value
    Add-AuditCheck -Checks $checks -Category 'Style Gates' -Name "chapter_${number}_live_editorial" -Status $liveStyle.status -Detail $liveStyle.detail -Evidence "Recomputed from current manuscript with policy $((Get-EbookEditorialPolicy).version), not trusted from a cached report."
}
$imageProduction = Get-EbookImageProductionReview -OutputFolder $resolvedOutputFolder
Add-AuditCheck -Checks $checks -Category 'Image Production' -Name 'generated_chapter_images' -Status $imageProduction.status -Detail $imageProduction.detail
$imageExports = Get-EbookImageExportReview -OutputFolder $resolvedOutputFolder
Add-AuditCheck -Checks $checks -Category 'Image Production' -Name 'generated_images_in_deliverables' -Status $imageExports.status -Detail $imageExports.detail
$failCount = @($checks | Where-Object { $_.status -eq "FAIL" }).Count
$warningCount = @($checks | Where-Object { $_.status -eq "WARNING" }).Count
$passCount = @($checks | Where-Object { $_.status -eq "PASS" }).Count
$overallStatus = if ($failCount -gt 0) { "FAIL" } elseif ($warningCount -gt 0) { "WARNING" } else { "PASS" }

$approvals = Read-JsonFile -Path (Join-Path $resolvedOutputFolder 'publication-approvals.json')
$currentDocxHash = if ($paths.ebookDocx -and (Test-Path -LiteralPath $paths.ebookDocx)) { (Get-FileHash -LiteralPath $paths.ebookDocx -Algorithm SHA256).Hash } else { '' }
$readiness = Get-EbookDeliveryReadiness -Checks @($checks) -Approvals $approvals -DocxSha256 $currentDocxHash
$report = [pscustomobject]@{
    auditName = "ebook-output-audit"
    generatedAt = (Get-Date).ToString("s")
    courseCode = $CourseCode
    outputFolder = $resolvedOutputFolder
    status = $overallStatus
    readiness = $readiness
    docxSha256 = $currentDocxHash
    editorialPolicyVersion = (Get-EbookEditorialPolicy).version
    summary = [pscustomobject]@{
        pass = $passCount
        warning = $warningCount
        fail = $failCount
        total = @($checks).Count
    }
    checks = @($checks)
}

$jsonPath = Join-Path $resolvedOutputFolder "ebook-output-audit.json"
$markdownPath = Join-Path $resolvedOutputFolder "ebook-output-audit.md"
Set-Content -LiteralPath $jsonPath -Value ($report | ConvertTo-Json -Depth 10) -Encoding UTF8
Set-Content -LiteralPath $markdownPath -Value (ConvertTo-AuditMarkdown -Report $report) -Encoding UTF8

Write-Host ""
Write-Host "E-book output audit complete."
Write-Host "Status: $($report.status)"
Write-Host "Technical readiness: $($readiness.technicalStatus). Draft ready for review: $($readiness.draftReadyForReview). Publication approved: $($readiness.publicationReady)."
Write-Host "Checks: $($report.summary.pass) pass, $($report.summary.warning) warning, $($report.summary.fail) fail."
Write-Host "JSON: $jsonPath"
Write-Host "Markdown: $markdownPath"

if ($FailOnFinding -and $report.status -ne "PASS") {
    throw "E-book output audit status is $($report.status). See $markdownPath."
}
if ($RequireDraftReady -and -not $readiness.draftReadyForReview) { throw 'Draft delivery blocked by technical/editorial findings. See ebook-output-audit.json.' }
if ($RequirePublicationReady -and -not $readiness.publicationReady) { throw 'Publication blocked. Technical checks and current human academic/permissions approvals are required.' }
