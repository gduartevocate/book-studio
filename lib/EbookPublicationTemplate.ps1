function Get-EbookPublicationTemplate {
    param([string]$PackageFolder, [ValidateSet('standard','large-text')][string]$Layout = 'standard')
    $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'config/book-publication-template.json'
    $template = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($template.id -ne 'gm1000-book-standard-v1' -or $template.sections.Count -ne 4) {
        throw 'Publication template is missing or unsupported. Review the layout contract before generating books.'
    }
    if ($PackageFolder) {
        $settingsPath = Join-Path $PackageFolder 'book-format-settings.json'
        if (Test-Path -LiteralPath $settingsPath) {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($settings.layout -notin @('standard','large-text')) { throw 'Unsupported book layout. Recreate and approve the format preview.' }
            $Layout = $settings.layout
        }
    }
    if ($Layout -eq 'large-text') {
        $template.bodyPoints = 14; $template.chapterPoints = 22; $template.sectionPoints = 17; $template.subsectionPoints = 16
    }
    $template | Add-Member -NotePropertyName layout -NotePropertyValue $Layout -Force
    return $template
}

function ConvertTo-EbookBusinessCaseLabel {
    param([AllowNull()][string]$Markdown)
    # Migrate labels, not source titles, objective wording, or quoted prose.
    return [regex]::Replace([string]$Markdown, '(?im)^(\s*(?:#{1,4}\s+)?(?:\*\*)?)Case\s+and\s+(?:a\s+)?face(?=\s*[:*]|\s*$)', '${1}Business Case')
}

function Test-EbookDeprecatedCaseLabel {
    param([AllowNull()][string]$Text)
    return [string]$Text -match '(?i)\bcase\s+and\s+(?:a\s+)?face\b'
}

function ConvertTo-EbookPublicationMarkdown {
    param([AllowNull()][string]$Markdown)

    # Normalize syntax only. Never invent sections, renumber chapters, or change
    # objectives, source text, quotations, or examples inside code fences.
    # Known layout aliases retain their original title after the canonical label.
    $lines = New-Object Collections.Generic.List[string]
    $chapter = 0; $section = 0; $inOpening = $false; $fence = ''; $awaitingSynthesis = $false
    foreach ($rawLine in ([string]$Markdown -split '\r?\n')) {
        $line = $rawLine
        if ($line -match '^\s*(`{3,}|~{3,})') {
            $awaitingSynthesis = $false
            $marker = $Matches[1]
            if (-not $fence) { $fence = $marker }
            elseif ($marker[0] -eq $fence[0] -and $marker.Length -ge $fence.Length) { $fence = '' }
            $lines.Add($line); continue
        }
        if ($fence) { $lines.Add($line); continue }
        if ($line -match '^#{1,6}[ \t]+(.+?)[ \t]*$') {
            $title = $Matches[1] -replace '[ \t]+#+[ \t]*$', ''
            if ($title -match '^\*\*(.+)\*\*$') { $title = $Matches[1] }
            $inOpening = $false
            # An immediate Synthesis wrapper is a layout alias, not missing prose.
            if ($awaitingSynthesis -and $title -eq 'Synthesis') { $awaitingSynthesis = $false; continue }
            $awaitingSynthesis = $false
            if ($title -match '^Chapter[ \t]+(\d+):[ \t]*(\S.*)$') {
                $chapter = [int]$Matches[1]
                $line = "# Chapter ${chapter}: $($Matches[2])"
                $section = 0
            }
            elseif ($chapter -gt 0 -and $title -match '^(?:Section[ \t]+)?(\d+)\.([1-4])[ \t]*(?:[-\u2013\u2014:]|[ \t])[ \t]*(\S.*)$') {
                # Keep mismatched numbering visible to validation.
                if ([int]$Matches[1] -eq $chapter) {
                    $section = [int]$Matches[2]; $sectionTitle = $Matches[3]
                    if ($section -eq 4 -and $sectionTitle -notmatch '^Integrating\b') { $sectionTitle = "Integrating: $sectionTitle" }
                    $line = "## Section $chapter.$section - $sectionTitle"
                    $awaitingSynthesis = $section -eq 4
                }
            }
            elseif ($chapter -gt 0 -and $section -eq 3 -and $title -match '^Modeled (?:Communication )?Artifact(?:[ \t]*:.*)?$') { $line = "### Communication Toolbox: $title" }
            elseif ($chapter -gt 0 -and $title -match '^(Introduction|Learning Objectives|Opening Scenario(?:[ \t]*:.*)?|Chapter Roadmap|Case Study Progression(?:[ \t]*:.*)?|Communication Toolbox(?:[ \t]*:.*)?|(?:Practical )?Field Guide(?:[ \t]*:.*)?|Key Takeaways|Vocabulary Review|Looking Ahead|Conclusion|Scholarly Sources(?:\s*/\s*Numbered Notes)?|Numbered Scholarly Notes|Numbered Notes|Notes)$') {
                $line = "### $title"
                $inOpening = $title -match '^Opening Scenario(?:[ \t]*:|$)'
            }
        }
        elseif ($inOpening -and $line -match '^[ \t]*(?:\*\*Business Case\*\*[ \t]*:|\*\*Business Case:\*\*|__Business Case__\s*:|__Business Case:__|Business Case:)[ \t]+(\S.*)$') {
            $line = "**Business Case:** $($Matches[1])"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($line)) { $awaitingSynthesis = $false }
        $lines.Add($line)
    }
    return ($lines -join "`n")
}

function Test-EbookManuscriptPreflight {
    param([AllowNull()][string]$Markdown, [int[]]$ExpectedChapterNumbers = @())

    $normalized = ConvertTo-EbookPublicationMarkdown -Markdown $Markdown
    $issues = New-Object Collections.Generic.List[string]
    try { $normalized = ConvertTo-EbookCitationMarkdown -Markdown $normalized }
    catch { $issues.Add($_.Exception.Message) }
    $template = Test-EbookPublicationTemplate -Markdown $normalized
    foreach ($issue in $template.issues) { $issues.Add($issue) }
    if ($ExpectedChapterNumbers.Count) {
        $actual = @([regex]::Matches($normalized, '(?m)^# Chapter (\d+):') | ForEach-Object { [int]$_.Groups[1].Value })
        if (($actual -join ',') -ne ($ExpectedChapterNumbers -join ',')) { $issues.Add('The manuscript chapter numbers do not match the approved plan. Restore missing chapters and preserve their order.') }
    }
    [pscustomobject]@{ status = $(if ($issues.Count) { 'FAIL' } else { 'PASS' }); issues = $issues.ToArray(); markdown = $normalized }
}

function Update-EbookManuscriptPreflight {
    param([Parameter(Mandatory)][string]$MarkdownPath, [int[]]$ExpectedChapterNumbers = @())

    $original = Get-Content -LiteralPath $MarkdownPath -Raw -Encoding UTF8
    $result = Test-EbookManuscriptPreflight -Markdown $original -ExpectedChapterNumbers $ExpectedChapterNumbers
    $folder = Split-Path -Parent $MarkdownPath
    $planPath = Join-Path $folder 'ebook-plan.json'
    if (Test-Path -LiteralPath $planPath) {
        $savedPlan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($savedPlan.sourceMode -eq 'Assigned') {
            $sourceReview = Get-EbookRequiredSourceReview -Plan $savedPlan -OutputFolder $folder -Markdown $result.markdown
            $result.issues = @($result.issues) + @($sourceReview.issues)
            if ($sourceReview.status -ne 'PASS') { $result.status = 'FAIL' }
        }
    }
    if ($result.markdown -cne ($original -replace '\r\n', "`n")) {
        $backupFolder = Join-Path $folder 'manuscript-backups'
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
        Copy-Item -LiteralPath $MarkdownPath -Destination (Join-Path $backupFolder ('preflight-' + [guid]::NewGuid().ToString('N') + '.md'))
        Set-Content -LiteralPath $MarkdownPath -Value $result.markdown -Encoding UTF8 -NoNewline
    }
    $report = [pscustomobject]@{status=$result.status;checkedAt=(Get-Date).ToString('o');manuscriptSha256=(Get-FileHash -LiteralPath $MarkdownPath).Hash;issues=@($result.issues)}
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $folder 'manuscript-preflight.json') -Encoding UTF8
    @('# Manuscript preflight', '', "Status: $($result.status)", '', 'Checked chapter structure and citation syntax before image generation or export.', '') + @($result.issues | ForEach-Object { "- $_" }) | Set-Content -LiteralPath (Join-Path $folder 'manuscript-preflight.md') -Encoding UTF8
    return $report
}

function Test-EbookPublicationTemplate {
    param([AllowNull()][string]$Markdown)
    $template = Get-EbookPublicationTemplate
    $issues = New-Object Collections.Generic.List[string]
    if (Test-EbookDeprecatedCaseLabel $Markdown) { $issues.Add('Replace the deprecated Case and Face wording with Business Case.') }
    if ($Markdown -match '(?m)^#{1,6}\s+[^\r\n]*#{2,6}\s*\S') { $issues.Add('A heading contains an embedded Markdown heading marker; repair the merged or duplicated heading.') }
    # The policy excludes prohibited learner SECTIONS and links to the local
    # interactive study page. Matching the same words anywhere in the prose
    # failed whole books for one ordinary sentence, and the old message named
    # neither the text nor its chapter, so nobody could act on it.
    $excluded = 'knowledge checks?|check your reasoning|reflection activit\w*|workplace challenge|chapter summary|think about it|interactive study(?: activity)?'
    $chapterStarts = @([regex]::Matches([string]$Markdown, '(?m)^# Chapter (\d+):'))
    $locate = {
        param([int]$Index)
        $number = ''
        foreach ($start in $chapterStarts) { if ($start.Index -le $Index) { $number = $start.Groups[1].Value } }
        if ($number) { "Chapter $number" } else { 'the front matter' }
    }
    $prohibited = New-Object Collections.Generic.List[string]
    foreach ($match in [regex]::Matches([string]$Markdown, "(?im)^#{1,6}\s*(?:$excluded)\b[^\r\n]*$")) {
        $prohibited.Add("$(& $locate $match.Index): heading '$($match.Value.Trim())'")
    }
    foreach ($match in [regex]::Matches([string]$Markdown, "(?im)^\s*\*\*(?:$excluded)\b[^*\r\n]*\*\*")) {
        $prohibited.Add("$(& $locate $match.Index): label '$($match.Value.Trim())'")
    }
    foreach ($match in [regex]::Matches([string]$Markdown, '(?i)interactive-study\.html[^\s)"]*')) {
        $prohibited.Add("$(& $locate $match.Index): link to $($match.Value)")
    }
    if ($prohibited.Count) {
        $shown = @($prohibited | Select-Object -Unique | Select-Object -First 5)
        $more = if ($prohibited.Count -gt $shown.Count) { " Plus $($prohibited.Count - $shown.Count) more." } else { '' }
        $issues.Add("Remove these prohibited learner sections, labels, or interactive-study links: $($shown -join '; ').$more")
    }
    $chapters = @([regex]::Matches([string]$Markdown, '(?ms)^# Chapter (?<number>\d+):[^\r\n]+(?<body>.*?)(?=^# Chapter \d+:|\z)'))
    if ($chapters.Count -eq 0) { $issues.Add('No chapter structure was found for the publication template.') }
    if ($chapters.Count -gt 0 -and $Markdown.Substring(0, $chapters[0].Index).Trim()) { $issues.Add('The book must begin with Chapter 1, without a separate cover or preface.') }
    $seen = @{}
    for ($i=0; $i -lt $chapters.Count; $i++) {
        $number = [int]$chapters[$i].Groups['number'].Value
        $body = $chapters[$i].Groups['body'].Value
        if ($number -ne ($i + 1) -or $seen.ContainsKey($number)) { $issues.Add("Chapter numbering is not sequential at Chapter $number.") }
        $seen[$number] = $true
        $headings = @([regex]::Matches($body, '(?m)^#{2,4}\s+([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
        $last = -1
        foreach ($pattern in $template.requiredHeadingPatterns) {
            $pattern = $pattern.Replace('{chapter}', [string]$number).Replace('{closing}', $(if($i -eq $chapters.Count-1){'Conclusion'}else{'Looking Ahead'}))
            $found = -1
            for ($h=$last+1; $h -lt $headings.Count; $h++) { if ($headings[$h] -match $pattern) { $found=$h; break } }
            if ($found -lt 0) { $issues.Add("Chapter ${number}: missing or out-of-order heading matching '$pattern'.") } else { $last=$found }
        }
        $sectionNumbers = @([regex]::Matches($body, '(?m)^## Section (\d+)\.(\d+)\s+-') | ForEach-Object { $_.Groups[1].Value + '.' + $_.Groups[2].Value })
        if (($sectionNumbers -join ',') -ne ((1..4 | ForEach-Object { "$number.$_" }) -join ',')) { $issues.Add("Chapter ${number}: require exactly four correctly numbered main sections.") }
        $opening = [regex]::Match($body, '(?ms)^### Opening Scenario[^\r\n]*\r?\n(?<body>.*?)(?=^#{1,4} |\z)').Groups['body'].Value
        if ($opening -notmatch '(?m)^\*\*Business Case:\*\*\s+\p{Lu}[\p{L}''-]+\b') { $issues.Add("Chapter ${number}: the Opening Scenario must introduce a named **Business Case:**.") }
        $integration = [regex]::Match($body, '(?ms)^## Section \d+\.4[^\r\n]*\r?\n(?<body>.*?)(?=^#{1,4} |\z)').Groups['body'].Value
        if ([regex]::Matches($integration, '\b\w+\b').Count -lt 25) { $issues.Add("Chapter ${number}: Section $number.4 needs developed synthesis prose before its subsections.") }
    }
    return [pscustomobject]@{templateId=$template.id;status=$(if($issues.Count){'FAIL'}else{'PASS'});issues=$issues.ToArray();detail=$(if($issues.Count){$issues -join ' '}else{'Every chapter follows the GM1000 layout standard with Business Case, four main sections, required supports, and no excluded activities.'})}
}

function Get-EbookTemplateInstructions {
    $t = Get-EbookPublicationTemplate
    return @"
Use the $($t.name) ($($t.id)) as a FORMAT-ONLY standard for every course.
Begin with Chapter 1, not a cover or preface. Each chapter starts with Introduction and Learning Objectives, then has exactly four main sections, numbered N.1 through N.4 with course-specific titles.
Use '# Chapter N: Title', '## Section N.1 - Title' through '## Section N.4 - Integrating ...', and '###' for required support headings (including Scholarly Sources). Use a plain hyphen between section number and title, not an en/em dash. Section N.4 must include at least 25 words of developed synthesis before its first subsection.
Section N.1 contains Opening Scenario, a named **Business Case:**, Chapter Roadmap, and context. Section N.2 develops the concepts. Section N.3 contains Case Study Progression, Communication Toolbox, and Practical Field Guide. Section N.4 begins with synthesis prose, then Key Takeaways, Vocabulary Review, Looking Ahead (or Conclusion in the final chapter), and Scholarly Sources.
Write the opening heading as '### Opening Scenario' (an optional ': scenario title' may follow). In its body, before the next heading, start a paragraph with the literal '**Business Case:** ' immediately followed by the scenario person's capitalized name, then their role, decision, and stakes. Keep the colon inside the bold label. Do not turn that label into a separate heading or replace it with '**Business Case**:'.
Use $($t.font) $($t.bodyPoints)-point body text and the shared $($t.chapterPoints)/$($t.sectionPoints)/$($t.subsectionPoints)-point heading hierarchy. Tables or visuals support the explanation only where useful.
Preserve this course's exact weekly objectives and assigned sources. Do not copy GM1000 topics, people, sources, or objectives into another course. Do not introduce GM1025 leadership content into unrelated courses.
Do not include Knowledge Checks, Check Your Reasoning, Reflection Activity, Workplace Challenge, Chapter Summary, Think About It, or interactive-study links. Keep operational examples and job aids, not renamed learner assessments.
"@
}

function Add-EbookLearningObjectives {
    param([Collections.ArrayList]$Lines, [object]$Chapter)
    $records = @($Chapter.learningTargetRecords)
    if ($records.Count -eq 0) { throw "Objective traceability contract is missing for Chapter $($Chapter.number)." }
    [void]$Lines.Add("### Learning Objectives`n`nBy the end of this chapter, you should be able to:`n")
    $number = 0
    foreach ($record in $records) {
        if (-not $record.objectiveId -or -not $record.objective) { throw 'Learning objectives must preserve their source ID and exact wording.' }
        $number++
        [void]$Lines.Add("$number. $($record.objective)")
    }
    [void]$Lines.Add('')
}

function Get-EbookWordTemplateIssues {
    param([xml]$Styles, [xml]$Document, [string]$PackageFolder)
    $issues = New-Object Collections.Generic.List[string]
    $t = Get-EbookPublicationTemplate -PackageFolder $PackageFolder
    $ns = New-Object Xml.XmlNamespaceManager($Styles.NameTable)
    $ns.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
    foreach ($item in @(@('Normal',$t.bodyPoints),@('Heading1',$t.chapterPoints),@('Heading2',$t.sectionPoints),@('Heading3',$t.subsectionPoints))) {
        $actual = $Styles.SelectSingleNode("//w:style[@w:styleId='$($item[0])']/w:rPr/w:sz/@w:val",$ns).Value
        if ([int]$actual -ne (2*[int]$item[1])) { $issues.Add("Word style $($item[0]) does not match the publication template size.") }
    }
    if ($Styles.SelectSingleNode('//w:style[@w:styleId="Normal"]/w:rPr/w:rFonts/@w:ascii',$ns).Value -ne $t.font) { $issues.Add('Word body font does not match the publication template.') }
    if (-not $Styles.SelectSingleNode('//w:style[@w:styleId="Heading3"]/w:rPr/w:i',$ns)) { $issues.Add('Word subsection style must be italic.') }
    if ($Styles.SelectSingleNode('//w:style[@w:styleId="Heading2"]/w:rPr/w:color/@w:val',$ns).Value -ne $t.sectionColor) { $issues.Add('Word section color does not match the publication template.') }
    if ($Document) {
        $docNs = [Xml.XmlNamespaceManager]::new($Document.NameTable)
        $docNs.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $first = ($Document.SelectNodes('/w:document/w:body/w:p[1]//w:t',$docNs) | ForEach-Object InnerText) -join ''
        if ($first -match '^Chapter 1:' -and $Document.SelectSingleNode('//w:sectPr/w:pgNumType/@w:start',$docNs).Value -ne '1') { $issues.Add('A chapter-first book must start page counting at 1, not at cover-page zero.') }
        foreach ($table in $Document.SelectNodes('//w:tbl',$docNs)) {
            $headers = @($table.SelectNodes('w:tr[1]/w:tc/w:p',$docNs))
            if ($headers.Count -and @($headers | Where-Object {-not $_.SelectSingleNode('w:pPr/w:keepNext',$docNs)}).Count) { $issues.Add('A table header must stay with the first data row.') }
        }
        foreach ($paragraph in $Document.SelectNodes('/w:document/w:body/w:p',$docNs)) {
            $text = ($paragraph.SelectNodes('.//w:t',$docNs) | ForEach-Object InnerText) -join ''
            if ($text -match '^>\s+\S') { $issues.Add('A Markdown quotation marker leaked into Word text.'); break }
            $headingStyle = $paragraph.SelectSingleNode('w:pPr/w:pStyle/@w:val',$docNs)
            if ($headingStyle -and $headingStyle.Value -match '^Heading' -and $text -match '#{2,6}\s*\S') { $issues.Add('A merged Markdown heading marker leaked into a Word heading.'); break }
        }
    }
    return $issues.ToArray()
}
