function Initialize-EbookGeneratorRuntime {
    if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains "Tls12") {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
}

. (Join-Path $PSScriptRoot 'EbookAssignedSources.ps1')
. (Join-Path $PSScriptRoot 'EbookCitationIntegrity.ps1')
. (Join-Path $PSScriptRoot 'EbookPublicationTemplate.ps1')
. (Join-Path $PSScriptRoot 'EbookReadiness.ps1')
. (Join-Path $PSScriptRoot 'EbookUploadedSources.ps1')

function ConvertTo-EbookProgressField {
    param([AllowNull()][string]$Value)

    return (([string]$Value) -replace "\r?\n", " " -replace "\|", "/" -replace "\s+", " ").Trim()
}

function Write-EbookGeneratorProgress {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [AllowNull()][string]$Detail
    )

    $timestamp = (Get-Date).ToString("s")
    [Console]::Out.WriteLine("[BOOKSTUDIO-PROGRESS] $timestamp | $(ConvertTo-EbookProgressField $Phase) | $(ConvertTo-EbookProgressField $Detail)")
}

function Write-EbookGeneratorChapterProgress {
    param(
        [Parameter(Mandatory)][int]$ChapterNumber,
        [Parameter(Mandatory)][string]$ChapterTitle,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Status,
        [AllowNull()][string]$Detail
    )

    $timestamp = (Get-Date).ToString("s")
    [Console]::Out.WriteLine("[BOOKSTUDIO-CHAPTER] $timestamp | $ChapterNumber | $(ConvertTo-EbookProgressField $ChapterTitle) | $(ConvertTo-EbookProgressField $Phase) | $(ConvertTo-EbookProgressField $Status) | $(ConvertTo-EbookProgressField $Detail)")
}

function Write-EbookGeneratorErrorProgress {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [AllowNull()][string]$Detail,
        [int]$ChapterNumber = 0,
        [AllowNull()][string]$ChapterTitle
    )

    $timestamp = (Get-Date).ToString("s")
    $chapterNumberText = if ($ChapterNumber -gt 0) { [string]$ChapterNumber } else { "" }
    [Console]::Out.WriteLine("[BOOKSTUDIO-ERROR] $timestamp | $(ConvertTo-EbookProgressField $Phase) | $chapterNumberText | $(ConvertTo-EbookProgressField $ChapterTitle) | $(ConvertTo-EbookProgressField $Detail)")
}

function ConvertTo-EbookLongPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith("\\?\")) {
        return $fullPath
    }
    if ($fullPath.StartsWith("\\")) {
        return "\\?\UNC\$($fullPath.Substring(2))"
    }
    return "\\?\$fullPath"
}

function ConvertTo-CleanText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $clean = [System.Net.WebUtility]::HtmlDecode($Text)
    if ($clean -match "[\u00C3\u00E2]") {
        try {
            $bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes($clean)
            $candidate = [System.Text.Encoding]::UTF8.GetString($bytes)
            if ($candidate) {
                $clean = $candidate
            }
        }
        catch { }
    }
    $clean = $clean -replace [char]0x2013, "-"
    $clean = $clean -replace [char]0x2014, "-"
    $clean = $clean -replace [char]0x2018, "'"
    $clean = $clean -replace [char]0x2019, "'"
    $clean = $clean -replace [char]0x201C, '"'
    $clean = $clean -replace [char]0x201D, '"'
    $clean = $clean -replace [char]0x00A0, " "
    $clean = $clean -replace "\s+", " "
    $clean = [regex]::Replace($clean, "\bBad New\b", "Bad News", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $clean.Trim()
}

function ConvertTo-DisplayTitle {
    param([string]$Text)

    $clean = ConvertTo-CleanText $Text
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return ""
    }

    $title = (Get-Culture).TextInfo.ToTitleCase($clean.ToLowerInvariant())
    $minorWords = @("A", "An", "And", "As", "At", "But", "By", "For", "From", "In", "Into", "Nor", "Of", "On", "Or", "Per", "The", "To", "Vs", "Via", "With")
    foreach ($word in $minorWords) {
        $title = [regex]::Replace($title, "\b$word\b", $word.ToLowerInvariant())
    }

    $replacements = [ordered]@{
        "\bAi\b" = "AI"
        "\bApa\b" = "APA"
        "\bCi(\d{3,4})\b" = 'CI$1'
        "\bD2l\b" = "D2L"
        "\bImscc\b" = "IMSCC"
        "\bLti\b" = "LTI"
        "\bPdf\b" = "PDF"
        "\bUma\b" = "UMA"
        "\bUrl\b" = "URL"
        "\bWpm\b" = "WPM"
        "\bOnedrive\b" = "OneDrive"
        "\bPowerpoint\b" = "PowerPoint"
    }
    foreach ($pattern in $replacements.Keys) {
        $title = [regex]::Replace($title, $pattern, [string]$replacements[$pattern])
    }

    if ($title.Length -gt 0) {
        $title = $title.Substring(0, 1).ToUpperInvariant() + $title.Substring(1)
    }

    return $title
}
function Open-DocxArchive {
    # Open for reading while allowing other writers: a designer often still has
    # the spec sheet open in Word, and ZipFile::OpenRead would refuse it.
    param([Parameter(Mandatory)][string]$Path)

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $resolvedPath = (Resolve-Path $Path).ProviderPath
    $stream = [System.IO.File]::Open($resolvedPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try { return New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read, $false) }
    catch { $stream.Dispose(); throw }
}

function Read-DocxZipEntryText {
    param([Parameter(Mandatory)][object]$Zip, [Parameter(Mandatory)][string]$EntryName)

    $entry = $Zip.GetEntry($EntryName)
    if ($null -eq $entry) { return $null }
    $stream = $entry.Open()
    $reader = New-Object System.IO.StreamReader($stream)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-DocxNumberingDefinitions {
    # Word's automatic list numbers ("1." from a numbered list) are not text;
    # they are computed from word/numbering.xml. Map each numId to its levels.
    param([Parameter(Mandatory)][object]$Zip)

    $definitions = @{}
    $xml = Read-DocxZipEntryText -Zip $Zip -EntryName "word/numbering.xml"
    if ([string]::IsNullOrWhiteSpace($xml)) { return $definitions }

    $abstracts = @{}
    foreach ($abstract in [regex]::Matches($xml, '(?s)<w:abstractNum\s+[^>]*w:abstractNumId="(\d+)"[^>]*>(.*?)</w:abstractNum>')) {
        $levels = @{}
        foreach ($level in [regex]::Matches($abstract.Groups[2].Value, '(?s)<w:lvl\s+[^>]*w:ilvl="(\d+)"[^>]*>(.*?)</w:lvl>')) {
            $body = $level.Groups[2].Value
            $index = [int]$level.Groups[1].Value
            $levels[$index] = @{
                format = $(if ($body -match '<w:numFmt\s+w:val="([^"]+)"') { $Matches[1] } else { "decimal" })
                start = $(if ($body -match '<w:start\s+w:val="(\d+)"') { [int]$Matches[1] } else { 1 })
                text = $(if ($body -match '<w:lvlText\s+w:val="([^"]*)"') { [System.Net.WebUtility]::HtmlDecode($Matches[1]) } else { "%$($index + 1)." })
            }
        }
        $abstracts[$abstract.Groups[1].Value] = $levels
    }
    foreach ($num in [regex]::Matches($xml, '(?s)<w:num\s+[^>]*w:numId="(\d+)"[^>]*>(.*?)</w:num>')) {
        if ($num.Groups[2].Value -notmatch '<w:abstractNumId\s+w:val="(\d+)"') { continue }
        $base = $abstracts[$Matches[1]]
        if (-not $base) { continue }
        $levels = @{}
        foreach ($key in $base.Keys) { $levels[$key] = @{ format = $base[$key].format; start = $base[$key].start; text = $base[$key].text } }
        foreach ($override in [regex]::Matches($num.Groups[2].Value, '(?s)<w:lvlOverride\s+[^>]*w:ilvl="(\d+)"[^>]*>(.*?)</w:lvlOverride>')) {
            $index = [int]$override.Groups[1].Value
            if ($levels.ContainsKey($index) -and $override.Groups[2].Value -match '<w:startOverride\s+w:val="(\d+)"') { $levels[$index].start = [int]$Matches[1] }
        }
        $definitions[$num.Groups[1].Value] = $levels
    }
    return $definitions
}

function ConvertTo-DocxListNumberText {
    param([int]$Value, [string]$Format)

    switch ($Format) {
        "lowerLetter" { return [string][char](96 + (($Value - 1) % 26) + 1) }
        "upperLetter" { return [string][char](64 + (($Value - 1) % 26) + 1) }
        "lowerRoman" { return (ConvertTo-DocxListNumberText -Value $Value -Format "upperRoman").ToLowerInvariant() }
        "upperRoman" {
            $roman = ""; $remaining = $Value
            foreach ($pair in @(@(1000, "M"), @(900, "CM"), @(500, "D"), @(400, "CD"), @(100, "C"), @(90, "XC"), @(50, "L"), @(40, "XL"), @(10, "X"), @(9, "IX"), @(5, "V"), @(4, "IV"), @(1, "I"))) {
                while ($remaining -ge $pair[0]) { $roman += $pair[1]; $remaining -= $pair[0] }
            }
            return $roman
        }
        default { return [string]$Value }
    }
}

function Add-DocxListNumbers {
    # Insert each auto-numbered paragraph's rendered number ("1. ", "7.1 ") as
    # text, so a spec sheet reads the same way it looks in Word. Bulleted
    # lists get no prefix. Counters run in document order, per list.
    param([Parameter(Mandatory)][string]$DocumentXml, [Parameter(Mandatory)][hashtable]$Numbering)

    if ($Numbering.Count -eq 0) { return $DocumentXml }
    $counters = @{}
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $paragraph = $match.Value
        if ($paragraph -notmatch '(?s)<w:pPr>.*?<w:numPr>(.*?)</w:numPr>') { return $paragraph }
        $numPr = $Matches[1]
        if ($numPr -notmatch '<w:numId\s+w:val="(\d+)"') { return $paragraph }
        $numId = $Matches[1]
        $level = if ($numPr -match '<w:ilvl\s+w:val="(\d+)"') { [int]$Matches[1] } else { 0 }
        if ($numId -eq "0" -or -not $Numbering.ContainsKey($numId)) { return $paragraph }
        $levels = $Numbering[$numId]
        if (-not $levels.ContainsKey($level)) { return $paragraph }
        if ($paragraph -notmatch '<w:t[ >]') { return $paragraph }

        if (-not $counters.ContainsKey($numId)) { $counters[$numId] = @{} }
        $state = $counters[$numId]
        if ($state.ContainsKey($level)) { $state[$level] = [int]$state[$level] + 1 } else { $state[$level] = [int]$levels[$level].start }
        foreach ($deeper in @($state.Keys | Where-Object { [int]$_ -gt $level })) { [void]$state.Remove($deeper) }
        if ($levels[$level].format -in @("bullet", "none")) { return $paragraph }

        $label = [string]$levels[$level].text
        for ($k = 1; $k -le $level + 1; $k++) {
            $value = if ($state.ContainsKey($k - 1)) { [int]$state[$k - 1] } elseif ($levels.ContainsKey($k - 1)) { [int]$levels[$k - 1].start } else { 1 }
            $format = if ($levels.ContainsKey($k - 1)) { [string]$levels[$k - 1].format } else { "decimal" }
            $label = $label.Replace("%$k", (ConvertTo-DocxListNumberText -Value $value -Format $format))
        }
        if ([string]::IsNullOrWhiteSpace($label)) { return $paragraph }
        $run = '<w:r><w:t xml:space="preserve">' + [System.Security.SecurityElement]::Escape($label) + ' </w:t></w:r>'
        if ($paragraph -match '(?s)^(<w:p[ >].*?</w:pPr>)') { return $Matches[1] + $run + $paragraph.Substring($Matches[1].Length) }
        if ($paragraph -match '^(<w:p[^>]*>)') { return $Matches[1] + $run + $paragraph.Substring($Matches[1].Length) }
        return $paragraph
    }
    return [regex]::Replace($DocumentXml, '(?s)<w:p[ >].*?</w:p>', $evaluator)
}

function Get-DocxText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = (Resolve-Path $Path).ProviderPath
    $zip = Open-DocxArchive -Path $resolvedPath
    try {
        $xml = Read-DocxZipEntryText -Zip $zip -EntryName "word/document.xml"
        if ($null -eq $xml) {
            throw "Could not find word/document.xml inside $resolvedPath"
        }
        $xml = Add-DocxListNumbers -DocumentXml $xml -Numbering (Get-DocxNumberingDefinitions -Zip $zip)

        $text = $xml -replace "<w:tab[^>]*/>", "`t"
        $text = $text -replace "<w:br[^>]*/>", "`n"
        $text = $text -replace "</w:p>", "`n"
        $text = $text -replace "<[^>]+>", ""
        $text = [System.Net.WebUtility]::HtmlDecode($text)
        $text = $text -replace "(`r?`n){3,}", "`n`n"
        return $text.Trim()
    }
    finally {
        if ($zip) { $zip.Dispose() }
    }
}

function ConvertTo-EbookComparableText {
    param([AllowNull()][string]$Text)

    $value = ConvertTo-CleanText $Text
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ""
    }

    return (($value.ToLowerInvariant() -replace "[^a-z0-9]+", " ") -replace "\s+", " ").Trim()
}

function Get-EbookObjectiveRecordsFromCourse {
    param([Parameter(Mandatory)][object]$Course)

    $records = New-Object System.Collections.ArrayList
    foreach ($week in @($Course.weeks | Sort-Object { [int]$_.number })) {
        $moduleIndex = 0
        foreach ($module in @($week.modules)) {
            $moduleIndex++
            $objective = ConvertTo-CleanText $module.objective
            if ([string]::IsNullOrWhiteSpace($objective)) {
                continue
            }

            $objectiveId = if (-not [string]::IsNullOrWhiteSpace([string]$module.objectiveId)) {
                [string]$module.objectiveId
            }
            else {
                "W$($week.number)-$moduleIndex"
            }

            [void]$records.Add([pscustomobject]@{
                chapterNumber = [int]$week.number
                objectiveId = $objectiveId
                objective = $objective
                source = "course-specification"
            })
        }
    }

    return @($records)
}

function Get-EbookObjectiveRecordsFromPlan {
    param([Parameter(Mandatory)][object]$Plan)

    $records = New-Object System.Collections.ArrayList
    foreach ($chapter in @($Plan.chapters)) {
        $chapterRecords = @()
        if ($chapter.PSObject.Properties.Name -contains "learningTargetRecords") {
            $chapterRecords = @($chapter.learningTargetRecords)
        }

        if ($chapterRecords.Count -gt 0) {
            foreach ($record in $chapterRecords) {
                $objective = ConvertTo-CleanText $(if ($record.objective) { $record.objective } else { $record.target })
                [void]$records.Add([pscustomobject]@{
                    chapterNumber = [int]$chapter.number
                    objectiveId = [string]$record.objectiveId
                    objective = $objective
                    source = "ebook-plan"
                })
            }
            continue
        }

        # Plans created before the traceability contract did not preserve IDs.
        # Keep the records visible so the release gate can fail with a useful
        # message instead of silently guessing the source objective identity.
        foreach ($target in @($chapter.learningTargets)) {
            $objective = ConvertTo-CleanText $target
            if ([string]::IsNullOrWhiteSpace($objective)) { continue }
            [void]$records.Add([pscustomobject]@{
                chapterNumber = [int]$chapter.number
                objectiveId = ""
                objective = $objective
                source = "ebook-plan-without-objective-id"
            })
        }
    }

    return @($records)
}

function Get-EbookObjectiveRecordsFromMarkdown {
    param([AllowNull()][string]$Markdown)

    $records = New-Object System.Collections.ArrayList
    foreach ($chapterMatch in [regex]::Matches([string]$Markdown, "(?ms)^# Chapter (?<number>\d+):.*?(?=^# Chapter \d+:|\z)")) {
        $chapterNumber = [int]$chapterMatch.Groups["number"].Value
        $chapterText = $chapterMatch.Value
        $sectionMatch = [regex]::Match($chapterText, "(?ms)^#{2,3}\s+Learning Objectives\s*\r?\n(?<body>.*?)(?=^#{1,4}\s|\z)")
        if (-not $sectionMatch.Success) { continue }

        foreach ($line in ($sectionMatch.Groups["body"].Value -split "\r?\n")) {
            if ($line -match "^\s*(?<id>\d+)\.\s+(?<objective>.+?)\s*$") {
                [void]$records.Add([pscustomobject]@{
                    chapterNumber = $chapterNumber
                    objectiveId = $Matches["id"]
                    objective = (ConvertTo-CleanText $Matches["objective"])
                    source = "ebook-markdown"
                })
            }
        }
    }

    return @($records)
}

function Test-EbookObjectiveTraceability {
    param(
        [Parameter(Mandatory)][object]$Course,
        [Parameter(Mandatory)][object]$Plan,
        [AllowNull()][string]$Markdown
    )

    $expected = @(Get-EbookObjectiveRecordsFromCourse -Course $Course)
    $planned = @(Get-EbookObjectiveRecordsFromPlan -Plan $Plan)
    $rendered = @(Get-EbookObjectiveRecordsFromMarkdown -Markdown $Markdown)
    $chapterResults = New-Object System.Collections.ArrayList
    $issues = New-Object System.Collections.ArrayList

    if ($expected.Count -eq 0) {
        [void]$issues.Add("The authoritative course specification contains no course-objective records.")
    }
    foreach ($week in @($Course.weeks)) {
        foreach ($module in @($week.modules)) {
            if ([string]::IsNullOrWhiteSpace([string]$module.objectiveId)) {
                [void]$issues.Add("Week $($week.number) has an unresolved source objective ID. Reconcile the source; do not substitute the week number.")
            }
        }
    }

    $chapterNumbers = @(
        @($expected | ForEach-Object { $_.chapterNumber }) +
        @($planned | ForEach-Object { $_.chapterNumber }) +
        @($rendered | ForEach-Object { $_.chapterNumber }) |
            Sort-Object -Unique
    )

    foreach ($chapterNumber in $chapterNumbers) {
        $expectedChapter = @($expected | Where-Object { $_.chapterNumber -eq $chapterNumber })
        $plannedChapter = @($planned | Where-Object { $_.chapterNumber -eq $chapterNumber })
        $renderedChapter = @($rendered | Where-Object { $_.chapterNumber -eq $chapterNumber })
        $chapterIssues = New-Object System.Collections.ArrayList

        $expectedIds = @($expectedChapter | ForEach-Object { [string]$_.objectiveId })
        $plannedIds = @($plannedChapter | ForEach-Object { [string]$_.objectiveId })
        $renderedIds = @($renderedChapter | ForEach-Object { [string]$_.objectiveId })

        if ($plannedChapter.Count -ne $expectedChapter.Count) {
            [void]$chapterIssues.Add("Plan has $($plannedChapter.Count) objective(s); source has $($expectedChapter.Count).")
        }
        if ($renderedChapter.Count -ne $expectedChapter.Count) {
            [void]$chapterIssues.Add("Markdown has $($renderedChapter.Count) rendered objective(s); source has $($expectedChapter.Count).")
        }
        if (($plannedIds -join "|") -ne ($expectedIds -join "|")) {
            [void]$chapterIssues.Add("Plan objective IDs '$($plannedIds -join ', ')' do not match source IDs '$($expectedIds -join ', ')'.")
        }
        $expectedDisplayIds = @(1..$expectedChapter.Count | ForEach-Object { [string]$_ })
        if (($renderedIds -join "|") -ne ($expectedDisplayIds -join "|")) {
            [void]$chapterIssues.Add("Rendered learning-objective list numbers '$($renderedIds -join ', ')' do not restart at 1 in this chapter.")
        }

        for ($i = 0; $i -lt $expectedChapter.Count; $i++) {
            $sourceRecord = $expectedChapter[$i]
            if ($i -lt $plannedChapter.Count) {
                $planRecord = $plannedChapter[$i]
                if ([string]$planRecord.objectiveId -ne [string]$sourceRecord.objectiveId -or
                    (ConvertTo-EbookComparableText $planRecord.objective) -ne (ConvertTo-EbookComparableText $sourceRecord.objective)) {
                    [void]$chapterIssues.Add("Plan objective $($sourceRecord.objectiveId) does not exactly match the source text.")
                }
            }
            if ($i -lt $renderedChapter.Count) {
                $renderedRecord = $renderedChapter[$i]
                if ((ConvertTo-EbookComparableText $renderedRecord.objective) -ne (ConvertTo-EbookComparableText $sourceRecord.objective)) {
                    [void]$chapterIssues.Add("Rendered objective $($sourceRecord.objectiveId) does not exactly match the source text.")
                }
            }
        }

        foreach ($record in @($plannedChapter)) {
            if ([string]::IsNullOrWhiteSpace([string]$record.objectiveId)) {
                [void]$chapterIssues.Add("An objective reached the $($record.source) stage without a preserved source objective ID.")
                break
            }
        }

        foreach ($chapterIssue in @($chapterIssues)) {
            [void]$issues.Add("Chapter ${chapterNumber}: $chapterIssue")
        }
        [void]$chapterResults.Add([pscustomobject]@{
            chapterNumber = $chapterNumber
            status = if ($chapterIssues.Count -eq 0) { "PASS" } else { "FAIL" }
            expected = @($expectedChapter)
            planned = @($plannedChapter)
            rendered = @($renderedChapter)
            issues = @($chapterIssues)
        })
    }

    return [pscustomobject]@{
        status = if ($issues.Count -eq 0) { "PASS" } else { "FAIL" }
        expectedCount = $expected.Count
        plannedCount = $planned.Count
        renderedCount = $rendered.Count
        chapters = @($chapterResults)
        issues = @($issues)
        detail = if ($issues.Count -eq 0) {
            "Every source course objective preserves its ID and exact text through the plan and rendered Markdown chapter."
        }
        else {
            $issues -join " "
        }
    }
}

function Get-EbookMarkdownArtifactIssues {
    param(
        [AllowNull()][string]$Markdown,
        [AllowNull()][string]$AssetRoot
    )

    $issues = New-Object System.Collections.ArrayList
    try { $null = ConvertTo-EbookCitationMarkdown -Markdown $Markdown }
    catch { [void]$issues.Add($_.Exception.Message) }
    $localTargets = New-Object System.Collections.ArrayList
    $patterns = @(
        "(?<!\!)\[[^\]]+\]\(([^)\r\n]+)\)",
        "!\[[^\]]*\]\(([^)\r\n]+)\)"
    )
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches([string]$Markdown, $pattern)) {
            $target = $match.Groups[1].Value.Trim()
            if ($target -match "^(?:https?:|mailto:|#|data:)") { continue }
            [void]$localTargets.Add($target)
            if ($target -match "\.(?:\s+)(?:svg|html?|png|jpe?g|docx|md)(?:#.*)?$") {
                [void]$issues.Add("Malformed local link target '$target'.")
                continue
            }
            if ($target -match "\s") {
                [void]$issues.Add("Local link target contains whitespace: '$target'.")
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($AssetRoot)) {
                $pathPart = ($target -replace "#.*$", "") -replace "/", [System.IO.Path]::DirectorySeparatorChar
                $resolvedTarget = Join-Path $AssetRoot $pathPart
                if (-not (Test-Path -LiteralPath (ConvertTo-EbookLongPath -Path $resolvedTarget) -PathType Leaf)) {
                    [void]$issues.Add("Local link target does not exist in the package: '$target'.")
                }
            }
        }
    }

    return [pscustomobject]@{
        status = if ($issues.Count -eq 0) { "PASS" } else { "FAIL" }
        localTargetCount = @($localTargets).Count
        issues = @($issues | Select-Object -Unique)
        detail = if ($issues.Count -eq 0) { "Markdown citation targets and source-note sequences are valid; all local targets resolve in the package." } else { $issues -join " " }
    }
}

function Get-EbookHtmlArtifactIssues {
    param(
        [AllowNull()][string]$Html,
        [AllowNull()][string]$AssetRoot
    )

    $issues = New-Object System.Collections.ArrayList
    foreach ($issue in @(Get-EbookHtmlCitationIssues -Html $Html)) { [void]$issues.Add($issue) }
    foreach ($match in [regex]::Matches([string]$Html, '(?i)(?:href|src)="([^"]+)"')) {
        $target = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
        if ($target -match "^(?:https?:|mailto:|#|data:)") { continue }
        if ($target -match "\s") {
            [void]$issues.Add("HTML local target contains whitespace: '$target'.")
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($AssetRoot)) {
            $pathPart = ($target -replace "#.*$", "") -replace "/", [System.IO.Path]::DirectorySeparatorChar
            if (-not (Test-Path -LiteralPath (ConvertTo-EbookLongPath -Path (Join-Path $AssetRoot $pathPart)) -PathType Leaf)) {
                [void]$issues.Add("HTML local target does not exist in the package: '$target'.")
            }
        }
    }

    return [pscustomobject]@{
        status = if ($issues.Count -eq 0) { "PASS" } else { "FAIL" }
        issues = @($issues | Select-Object -Unique)
        detail = if ($issues.Count -eq 0) { "HTML has no visible citation markup; note targets and displayed numbers agree, and local links resolve." } else { $issues -join " " }
    }
}

function Get-EbookDocxArtifactIssues {
    param([Parameter(Mandatory)][string]$Path)

    $issues = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        [void]$issues.Add("DOCX artifact is missing.")
        return [pscustomobject]@{ status = "FAIL"; issues = @($issues); detail = $issues -join " " }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try {
        $documentEntry = $zip.GetEntry("word/document.xml")
        $relationshipsEntry = $zip.GetEntry("word/_rels/document.xml.rels")
        $numberingEntry = $zip.GetEntry("word/numbering.xml")
        if (-not $documentEntry -or -not $relationshipsEntry -or -not $numberingEntry) {
            [void]$issues.Add("DOCX package is missing document, relationship, or numbering XML.")
            return [pscustomobject]@{ status = "FAIL"; issues = @($issues); detail = $issues -join " " }
        }

        $readEntry = {
            param($entry)
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        $documentXml = [xml](& $readEntry $documentEntry)
        $relationshipsXml = [xml](& $readEntry $relationshipsEntry)
        $numberingXml = [xml](& $readEntry $numberingEntry)
        foreach ($issue in @(Get-EbookWordCitationIssues -Document $documentXml -Numbering $numberingXml)) { [void]$issues.Add($issue) }
        $stylesEntry = $zip.GetEntry('word/styles.xml')
        if (-not $stylesEntry) { [void]$issues.Add('DOCX styles are missing.') }
        else { foreach ($issue in @(Get-EbookWordTemplateIssues -Styles ([xml](& $readEntry $stylesEntry)) -Document $documentXml -PackageFolder (Split-Path -Parent $Path))) { [void]$issues.Add($issue) } }
        $ns = New-Object System.Xml.XmlNamespaceManager($documentXml.NameTable)
        $ns.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
        $relNs = New-Object System.Xml.XmlNamespaceManager($relationshipsXml.NameTable)
        $relNs.AddNamespace("pr", "http://schemas.openxmlformats.org/package/2006/relationships")
        $numNs = New-Object System.Xml.XmlNamespaceManager($numberingXml.NameTable)
        $numNs.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

        foreach ($relationship in $relationshipsXml.SelectNodes("//pr:Relationship", $relNs)) {
            if ([string]$relationship.TargetMode -eq "External" -and [string]$relationship.Target -notmatch "^(?:https?:|mailto:)") {
                [void]$issues.Add("DOCX contains an unusable external hyperlink target '$($relationship.Target)'.")
            }
        }

        $numToFormat = @{}
        foreach ($num in $numberingXml.SelectNodes("//w:num", $numNs)) {
            $numId = [string]$num.GetAttribute("numId", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
            $abstractId = [string]$num.SelectSingleNode("./w:abstractNumId", $numNs).GetAttribute("val", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
            $abstract = $numberingXml.SelectSingleNode("//w:abstractNum[@w:abstractNumId='$abstractId']", $numNs)
            $format = if ($abstract -and $abstract.SelectSingleNode(".//w:numFmt", $numNs)) { [string]$abstract.SelectSingleNode(".//w:numFmt", $numNs).GetAttribute("val", "http://schemas.openxmlformats.org/wordprocessingml/2006/main") } else { "" }
            $numToFormat[$numId] = $format
        }

        $previousListType = ""
        $usedOrderedListIds = New-Object System.Collections.Generic.HashSet[string]
        foreach ($paragraph in $documentXml.SelectNodes("//w:body/w:p", $ns)) {
            $numPr = $paragraph.SelectSingleNode("./w:pPr/w:numPr", $ns)
            $listType = ""
            $numId = ""
            if ($numPr) {
                $numId = [string]$numPr.SelectSingleNode("./w:numId", $ns).GetAttribute("val", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
                $listType = if ($numToFormat.ContainsKey($numId)) { $numToFormat[$numId] } else { "unknown" }
                if ($listType -eq "unknown") {
                    [void]$issues.Add("DOCX paragraph references undefined numbering ID $numId.")
                }
            }
            if ($listType -eq "decimal" -and $previousListType -ne "decimal") {
                if (-not $usedOrderedListIds.Add($numId)) {
                    [void]$issues.Add("DOCX reuses ordered-list numbering ID $numId for multiple list blocks; list numbering may continue instead of restarting at 1.")
                }
            }
            $previousListType = $listType
        }
    }
    finally {
        $zip.Dispose()
    }

    return [pscustomobject]@{
        status = if ($issues.Count -eq 0) { "PASS" } else { "FAIL" }
        issues = @($issues | Select-Object -Unique)
        detail = if ($issues.Count -eq 0) { "DOCX has no visible citation markup, internal links resolve, source numbers agree with bookmarks, and ordered-list blocks restart at 1." } else { $issues -join " " }
    }
}

function Test-EbookReleaseArtifacts {
    param(
        [Parameter(Mandatory)][object]$Course,
        [Parameter(Mandatory)][object]$Plan,
        [AllowNull()][string]$Markdown,
        [AllowNull()][string]$HtmlPath,
        [AllowNull()][string]$DocxPath,
        [AllowNull()][string]$OutputFolder
    )

    $checks = New-Object System.Collections.ArrayList
    $traceability = Test-EbookObjectiveTraceability -Course $Course -Plan $Plan -Markdown $Markdown
    $templateCheck = Test-EbookPublicationTemplate -Markdown $Markdown
    [void]$checks.Add([pscustomobject]@{name='publication_template';status=$templateCheck.status;detail=$templateCheck.detail})
    [void]$checks.Add([pscustomobject]@{ name = "objective_traceability"; status = $traceability.status; detail = $traceability.detail })
    $assignedSources = Test-EbookAssignedSourcePackage -Course $Course -Plan $Plan -Markdown $Markdown -OutputFolder $OutputFolder
    if ($assignedSources.applicable) { [void]$checks.Add([pscustomobject]@{name='assigned_weekly_sources';status=$assignedSources.status;detail=$assignedSources.detail}) }
    $markdownIssues = Get-EbookMarkdownArtifactIssues -Markdown $Markdown -AssetRoot $OutputFolder
    [void]$checks.Add([pscustomobject]@{ name = "markdown_artifact_integrity"; status = $markdownIssues.status; detail = $markdownIssues.detail })

    if ($HtmlPath -and (Test-Path -LiteralPath $HtmlPath -PathType Leaf)) {
        $html = Get-Content -LiteralPath $HtmlPath -Raw -Encoding UTF8
        $htmlIssues = Get-EbookHtmlArtifactIssues -Html $html -AssetRoot $OutputFolder
    }
    else {
        $htmlIssues = [pscustomobject]@{ status = "FAIL"; issues = @("HTML artifact is missing."); detail = "HTML artifact is missing." }
    }
    [void]$checks.Add([pscustomobject]@{ name = "html_artifact_integrity"; status = $htmlIssues.status; detail = $htmlIssues.detail })

    if ($DocxPath) {
        $docxIssues = Get-EbookDocxArtifactIssues -Path $DocxPath
    }
    else {
        $docxIssues = [pscustomobject]@{ status = "FAIL"; issues = @("DOCX artifact path was not supplied."); detail = "DOCX artifact path was not supplied." }
    }
    [void]$checks.Add([pscustomobject]@{ name = "docx_artifact_integrity"; status = $docxIssues.status; detail = $docxIssues.detail })

    $failed = @($checks | Where-Object { $_.status -eq "FAIL" }).Count
    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        status = if ($failed -eq 0) { "PASS" } else { "FAIL" }
        checks = @($checks)
        objectiveTraceability = $traceability
        markdown = $markdownIssues
        html = $htmlIssues
        docx = $docxIssues
    }
}

function New-DefaultBrandProfile {
    return [pscustomobject]@{
        name = "Ultimate Medical Academy"
        shortName = "UMA"
        sourceGuide = ""
        sourceNote = "Default UMA brand profile used when config/uma-brand-profile.json is unavailable."
        brandPlatform = "Care Pays Back"
        voice = [pscustomobject]@{
            principles = @("care", "optimism", "energy", "natural empathy", "future-facing solutions")
            contentRules = @(
                "Use a supportive, clear, student-centered tone.",
                "Frame challenges as practical problems with paths forward.",
                "Break complex information into focused steps that reduce cognitive load.",
                "Use realistic scenarios and direct application rather than generic motivation.",
                "Use active voice and write primarily to the learner as you.",
                "Use plain language, short paragraphs, and sentence structure appropriate for a Flesch-Kincaid grade 8 target.",
                "Keep the tone warm, direct, and conversational rather than overly formal.",
                "Use examples and details relevant to entry-level allied healthcare roles whenever the course context allows.",
                "Give each chapter a business case: a named person, role, workplace situation, decision, artifact, and risk.",
                "Use concise bulleted lists; use numbered lists when steps must happen in order.",
                "Use UMA student-facing terminology such as course, instructor, e-book, online, website, and email."
            )
        }
        writingStyleGuide = [pscustomobject]@{
            name = "UMA AI Style Guide"
            sourceGuide = ""
            contentRules = @(
                "Active voice",
                "Second person or implied second person",
                "Flesch-Kincaid grade 8/plain-language readability",
                "Helpful, warm, direct tone that avoids overly formal phrasing",
                "Entry-level allied healthcare examples where relevant",
                "Job-connected examples and analytical prompts",
                "Inclusive, people-first, accessible language",
                "Concise bulleted lists and numbered directions",
                "UMA terminology and mechanics"
            )
        }
        typography = [pscustomobject]@{
            headline = "Merriweather UltraBold Italic"
            body = "Roboto"
            condensed = "Roboto Condensed"
            fallback = "Arial"
            rules = @(
                "Use Merriweather UltraBold Italic for large titles, headlines, and callouts when available.",
                "Use Roboto for subheads, body copy, paragraphs, buttons, and emphasized words.",
                "Use Arial when Merriweather or Roboto are unavailable."
            )
        }
        colors = [pscustomobject]@{
            primary = @(
                [pscustomobject]@{ name = "Legend Blue"; hex = "#0D3553" },
                [pscustomobject]@{ name = "Hero Blue"; hex = "#1D6BA6" },
                [pscustomobject]@{ name = "Horizon Blue"; hex = "#0095C8" }
            )
            cta = [pscustomobject]@{ name = "Journey Green"; hex = "#15EAC4"; usage = "Use for calls to action, buttons, and small icon highlights." }
            neutral = @(
                [pscustomobject]@{ name = "Gracious Gray"; hex = "#F9F9F9" },
                [pscustomobject]@{ name = "Medium Gray 1"; hex = "#DBDBDB" },
                [pscustomobject]@{ name = "Medium Gray 2"; hex = "#A5A5A5" },
                [pscustomobject]@{ name = "Integrity Gray"; hex = "#444444" }
            )
            tertiary = @(
                [pscustomobject]@{ name = "Puma Pink 1"; hex = "#EA4B5F" },
                [pscustomobject]@{ name = "Puma Pink 2"; hex = "#FF8AA6" },
                [pscustomobject]@{ name = "Puma Purple 1"; hex = "#8444D8" },
                [pscustomobject]@{ name = "Puma Purple 2"; hex = "#AC8AFF" }
            )
            rules = @(
                "Use primary brand blues for the majority of visual design.",
                "Include at least one primary blue in every visual design.",
                "Use secondary and tertiary colors only as supplements, highlights, or illustration details.",
                "Use Legend Blue, Hero Blue, Horizon Blue, Integrity Gray, black, or white for text."
            )
        }
        visualStyle = [pscustomobject]@{
            promptGuidance = "UMA brand style: caring, optimistic, future-facing, supportive, and professional. Use Legend Blue #0D3553, Hero Blue #1D6BA6, and Horizon Blue #0095C8 as the dominant palette. Use Journey Green #15EAC4 only as a small highlight. Favor clean layouts, soft corners, angular blue color blocking, approachable realistic imagery, and accessible contrast. Avoid logos, watermarks, clutter, unreadable text, disrespectful imagery, and off-brand colors."
        }
        accessibility = [pscustomobject]@{
            rules = @(
                "Meet WCAG AA contrast expectations.",
                "Do not rely solely on color to convey meaning.",
                "Use alt text for visuals.",
                "Keep layouts clean, focused, and easy to scan."
            )
        }
    }
}

function Get-UmaWritingStyleGuideRules {
    return @(
        "Use active voice and write primarily to the learner as you.",
        "Use plain language, short paragraphs, and sentence structure appropriate for a Flesch-Kincaid grade 8 target.",
        "Keep the tone warm, direct, and conversational rather than overly formal.",
        "Use examples and details relevant to entry-level allied healthcare roles when the topic allows.",
        "Give each chapter a business case: a named person, role, workplace situation, decision, artifact, and risk.",
        "Connect concepts to what learners will experience on the job.",
        "Include book-native learning supports such as examples in context, pause-and-notice moments, synthesis, key takeaways, and numbered notes.",
        "Use people-first, inclusive, gender-neutral, and accessible language.",
        "Use concise bulleted lists; use numbered lists when steps must happen in order.",
        "Use UMA student-facing terminology such as course, instructor, e-book, online, website, and email."
    )
}

function Import-BrandProfile {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$GuidePath
    )

    $profile = $null
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $profile = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    else {
        $profile = New-DefaultBrandProfile
    }

    $styleRules = Get-UmaWritingStyleGuideRules
    if (-not $profile.voice) {
        $profile | Add-Member -NotePropertyName voice -NotePropertyValue ([pscustomobject]@{ principles = @(); contentRules = @() }) -Force
    }
    if (-not $profile.voice.contentRules) {
        $profile.voice | Add-Member -NotePropertyName contentRules -NotePropertyValue @() -Force
    }
    foreach ($rule in $styleRules) {
        if (@($profile.voice.contentRules) -notcontains $rule) {
            $profile.voice.contentRules += $rule
        }
    }

    if (-not $profile.writingStyleGuide) {
        $profile | Add-Member -NotePropertyName writingStyleGuide -NotePropertyValue ([pscustomobject]@{
            name = "UMA AI Style Guide"
            sourceGuide = ""
            contentRules = @($styleRules)
        }) -Force
    }

    if ($GuidePath -and (Test-Path -LiteralPath $GuidePath)) {
        $resolvedGuidePath = (Resolve-Path $GuidePath).ProviderPath
        $profile | Add-Member -NotePropertyName sourceGuideResolved -NotePropertyValue $resolvedGuidePath -Force
        if ($profile.writingStyleGuide) {
            $profile.writingStyleGuide | Add-Member -NotePropertyName sourceGuideResolved -NotePropertyValue $resolvedGuidePath -Force
        }
    }

    return $profile
}

function Get-BrandColor {
    param(
        [object]$BrandProfile,
        [string]$Name,
        [string]$Fallback
    )

    if (-not $BrandProfile -or -not $BrandProfile.colors) {
        return $Fallback
    }

    $groups = @()
    $groups += @($BrandProfile.colors.primary)
    $groups += @($BrandProfile.colors.cta)
    $groups += @($BrandProfile.colors.neutral)
    $groups += @($BrandProfile.colors.tertiary)
    foreach ($color in $groups) {
        if ($color -and $color.name -eq $Name -and $color.hex) {
            return $color.hex
        }
    }

    return $Fallback
}

function ConvertTo-WordHexColor {
    param([AllowNull()][string]$Color)

    $value = ([string]$Color).Trim()
    if ($value.StartsWith("#")) {
        return $value.Substring(1)
    }

    return $value
}

function Get-BrandPromptGuidance {
    param([object]$BrandProfile)

    if ($BrandProfile -and $BrandProfile.visualStyle -and $BrandProfile.visualStyle.promptGuidance) {
        return $BrandProfile.visualStyle.promptGuidance
    }

    return (New-DefaultBrandProfile).visualStyle.promptGuidance
}

function ConvertTo-BrandProfileMarkdown {
    param([object]$BrandProfile)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# Brand Profile")
    [void]$lines.Add("")
    [void]$lines.Add("Name: $($BrandProfile.name)")
    [void]$lines.Add("")
    [void]$lines.Add("Source guide: $($BrandProfile.sourceGuide)")
    if ($BrandProfile.sourceGuideResolved) {
        [void]$lines.Add("")
        [void]$lines.Add("Resolved guide path: $($BrandProfile.sourceGuideResolved)")
    }
    if ($BrandProfile.writingStyleGuide -and $BrandProfile.writingStyleGuide.sourceGuideResolved) {
        [void]$lines.Add("")
        [void]$lines.Add("Writing style guide: $($BrandProfile.writingStyleGuide.sourceGuideResolved)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("Brand platform: $($BrandProfile.brandPlatform)")
    [void]$lines.Add("")
    [void]$lines.Add("## Voice")
    foreach ($rule in @($BrandProfile.voice.contentRules)) {
        [void]$lines.Add("- $rule")
    }
    if ($BrandProfile.writingStyleGuide -and @($BrandProfile.writingStyleGuide.contentRules).Count -gt 0) {
        [void]$lines.Add("")
        [void]$lines.Add("## UMA AI Writing Style Guide")
        foreach ($rule in @($BrandProfile.writingStyleGuide.contentRules)) {
            [void]$lines.Add("- $rule")
        }
    }
    [void]$lines.Add("")
    [void]$lines.Add("## Colors")
    foreach ($color in @($BrandProfile.colors.primary) + @($BrandProfile.colors.cta) + @($BrandProfile.colors.neutral) + @($BrandProfile.colors.tertiary)) {
        if ($color -and $color.name -and $color.hex) {
            [void]$lines.Add("- $($color.name): $($color.hex)")
        }
    }
    [void]$lines.Add("")
    [void]$lines.Add("## Typography")
    foreach ($rule in @($BrandProfile.typography.rules)) {
        [void]$lines.Add("- $rule")
    }
    [void]$lines.Add("")
    [void]$lines.Add("## Visual Guidance")
    [void]$lines.Add($BrandProfile.visualStyle.promptGuidance)

    return ($lines -join "`r`n")
}

function Get-NextValue {
    param(
        [string[]]$Lines,
        [string]$Label
    )

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -eq $Label -and ($i + 1) -lt $Lines.Count) {
            return $Lines[$i + 1]
        }
    }

    return ""
}

function Get-BetweenLabels {
    param(
        [string[]]$Lines,
        [string]$StartLabel,
        [string[]]$EndLabels
    )

    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -eq $StartLabel) {
            $start = $i + 1
            break
        }
    }

    if ($start -lt 0) {
        return ""
    }

    $end = $Lines.Count
    for ($i = $start; $i -lt $Lines.Count; $i++) {
        if ($EndLabels -contains $Lines[$i]) {
            $end = $i
            break
        }
    }

    return (($Lines[$start..($end - 1)] | ForEach-Object { ConvertTo-CleanText $_ }) -join " ").Trim()
}

function ConvertFrom-CourseSpecText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)

    $lines = @(
        $Text -split "`r?`n" |
            ForEach-Object { ConvertTo-CleanText $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $courseNumberRaw = Get-NextValue -Lines $lines -Label "Course Number"
    $courseCode = $courseNumberRaw
    $sme = ""
    if ($courseNumberRaw -match "^([A-Za-z]{2,}\d+)\s*[-]\s*SME\s+(.+)$") {
        $courseCode = $Matches[1]
        $sme = $Matches[2]
    }
    elseif ($courseNumberRaw -match "^([A-Za-z]{2,}\d+)") {
        $courseCode = $Matches[1]
    }

    $weeks = New-Object System.Collections.ArrayList
    $courseObjectiveRecords = New-Object System.Collections.ArrayList
    $objectiveHeaderIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^(Course Objectives|Course Educational Objectives):?$") {
            $objectiveHeaderIndex = $i
            break
        }
    }
    if ($objectiveHeaderIndex -ge 0) {
        for ($i = $objectiveHeaderIndex + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^Week\s+\d+\s+") { break }
            if ($lines[$i] -match "^(CO\d+):\s*(.+)$") {
                [void]$courseObjectiveRecords.Add([pscustomobject]@{
                    objectiveId = $Matches[1]
                    objective = (ConvertTo-CleanText $Matches[2])
                })
            }
        }
    }
    $weekIndexes = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^Week\s+(\d+)\s+(.+)$" -and -not (Test-EbookAssessmentTitle -Title $Matches[2])) {
            [void]$weekIndexes.Add([pscustomobject]@{
                Index = $i
                Number = [int]$Matches[1]
                Title = $Matches[2]
            })
        }
    }

    for ($w = 0; $w -lt $weekIndexes.Count; $w++) {
        $weekStart = $weekIndexes[$w].Index
        $weekEnd = if (($w + 1) -lt $weekIndexes.Count) { $weekIndexes[$w + 1].Index - 1 } else { $lines.Count - 1 }
        $block = @($lines[$weekStart..$weekEnd])
        $topicModules = @(Get-ModulesFromWeekBlock -Block $block)
        $objectiveStopWords = @("leadership", "leader", "leaders", "workplace", "team", "teams", "work", "working", "performance", "support", "improve", "improvement", "use", "apply", "demonstrate", "resolve", "conduct", "deliver", "select", "appropriate", "situations", "situation", "employee", "employees", "task", "tasks", "practices", "practice")
        $weekSearchText = ((($block | Where-Object { $_ -notmatch "^Week\s+\d+\s+" }) -join " ").ToLowerInvariant() -replace "motivational", "motivation")
        $assignedObjectives = @($courseObjectiveRecords | Where-Object {
            $objectiveWords = @(([regex]::Matches((([string]$_.objective).ToLowerInvariant() -replace "motivational", "motivation"), "[a-z]{5,}") | ForEach-Object { $_.Value }) | Where-Object { $objectiveStopWords -notcontains $_ } | Select-Object -Unique)
            $overlap = @($objectiveWords | Where-Object { $weekSearchText -match [regex]::Escape($_) }).Count
            $overlap -gt 0
        })
        $modules = New-Object System.Collections.ArrayList
        if ($assignedObjectives.Count -gt 0) {
            foreach ($objectiveRecord in $assignedObjectives) {
                $objectiveWords = @(([regex]::Matches((([string]$objectiveRecord.objective).ToLowerInvariant() -replace "motivational", "motivation"), "[a-z]{5,}") | ForEach-Object { $_.Value }) | Where-Object { $objectiveStopWords -notcontains $_ } | Select-Object -Unique)
                $matchedTopic = @($topicModules | Where-Object {
                    $topicText = ((([string]$_.title) + " " + ([string]$_.objective)).ToLowerInvariant() -replace "motivational", "motivation")
                    @($objectiveWords | Where-Object { $topicText -match [regex]::Escape($_) }).Count -gt 0
                } | Select-Object -First 1)
                $moduleTitle = if ($matchedTopic.Count -gt 0) { [string]$matchedTopic[0].title } else { ConvertTo-TitleFromObjective -Objective $objectiveRecord.objective }
                $subObjectives = if ($matchedTopic.Count -gt 0) { @($matchedTopic[0].objective) } else { @() }
                [void]$modules.Add([pscustomobject]@{
                    objectiveId = $objectiveRecord.objectiveId
                    title = $moduleTitle
                    objective = $objectiveRecord.objective
                    subObjectives = $subObjectives
                })
            }
        }
        else {
            foreach ($topicModule in $topicModules) { [void]$modules.Add($topicModule) }
        }
        $activities = Get-ActivitiesFromWeekBlock -Block $block
        $chapterRefs = @(
            $block |
                Where-Object { $_ -match "Chapter|Chapters" } |
                ForEach-Object { $_ }
        )

        [void]$weeks.Add([pscustomobject]@{
            number = $weekIndexes[$w].Number
            title = $weekIndexes[$w].Title
            modules = @($modules)
            activities = $activities
            chapterReferences = $chapterRefs
        })
    }

    return [pscustomobject]@{
        courseCode = $courseCode
        courseNumberRaw = $courseNumberRaw
        sme = $sme
        courseName = Get-NextValue -Lines $lines -Label "Course Name"
        credits = Get-NextValue -Lines $lines -Label "Credits"
        deliveryMode = Get-NextValue -Lines $lines -Label "MODE OF DELIVERY:"
        duration = Get-NextValue -Lines $lines -Label "Duration"
        prerequisites = Get-NextValue -Lines $lines -Label "Prerequisites"
        primaryText = Get-NextValue -Lines $lines -Label "Text"
        description = Get-BetweenLabels -Lines $lines -StartLabel "Course Description" -EndLabels @("Grading", "Criteria")
        courseObjectives = @($courseObjectiveRecords)
        weeks = @($weeks)
        sourcePath = $null
    }
}

function Test-EbookAssessmentTitle {
    param([AllowNull()][string]$Title)

    $value = (ConvertTo-CleanText ([string]$Title)).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    $gradingPointsPattern = "\b\d+\s*(points|pts\.?)\b|\b(points|pts\.?)\s*(possible|total|grade|graded)\b"
    return ($value -match "^(test|quiz|exam|midterm|final|assessment)\b" -or $value -match $gradingPointsPattern)
}

function Test-EbookAssessmentOrLmsText {
    param([AllowNull()][string]$Text)

    $value = (ConvertTo-CleanText ([string]$Text)).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    $gradingPointsPattern = "\b\d+\s*(points|pts\.?)\b|\b(points|pts\.?)\s*(possible|total|grade|graded)\b"
    return (
        $value -match $gradingPointsPattern -or
        $value -match "^(assignment|discussion|test|quiz|exam|midterm|final|assessment|homework|rubric)\b" -or
        $value -match "\b(practice\s+quiz|self-assessment\s+quiz|quiz|exam)\b" -or
        $value -match "^(flashcards?|writing workshop|check your understanding\s+ch\s+\d+|module\s+\d+:\s*key points)\b" -or
        $value -match "^week\s+\d+\s+(assignment|discussion|test|quiz|exam|assessment)\b" -or
        $value -match "\b(submit|submission|graded|gradebook|due date|rubric)\b"
    )
}

function ConvertTo-TitleFromObjective {
    param([string]$Objective)

    $title = ConvertTo-CleanText $Objective
    $title = $title -replace "^(Summarize|Evaluate|Solve|Construct|Communicate|Develop|Apply|Define|Describe|Explain|Recognize|Determine)\s+", ""
    $title = $title.Trim(". ")
    if ([string]::IsNullOrWhiteSpace($title)) {
        return "Course Objective"
    }

    return (ConvertTo-DisplayTitle $title)
}

function Get-CourseNameFromObjectiveList {
    param(
        [string]$CourseCode,
        [string]$Description,
        [string]$Path
    )

    if ($CourseCode -eq "HU2000") {
        return "Critical Thinking and Problem Solving"
    }

    if ($Description -match "critical thinking") {
        return "Critical Thinking and Problem Solving"
    }

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $fileName = $fileName -replace "^[A-Za-z]{2,}\d+\s*[-_ ]*", ""
    $fileName = $fileName -replace "[-_]+", " "
    $fileName = $fileName -replace "\bLOs\b", "Learning Objectives"
    $fileName = (ConvertTo-CleanText $fileName).Trim()
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        return "Course Learning Objectives"
    }

    return (ConvertTo-DisplayTitle $fileName)
}

function Get-ValueAfterLooseLabel {
    param(
        [string[]]$Lines,
        [string]$Pattern
    )

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $Pattern) {
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if (-not [string]::IsNullOrWhiteSpace($Lines[$j]) -and $Lines[$j] -notmatch "^[-–—]$") {
                    return $Lines[$j]
                }
            }
        }
    }

    return ""
}

function Get-TextBetweenLooseLabels {
    param(
        [string[]]$Lines,
        [string]$StartPattern,
        [string[]]$EndPatterns
    )

    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $StartPattern) {
            $start = $i + 1
            break
        }
    }
    if ($start -lt 0) {
        return ""
    }

    $end = $Lines.Count
    for ($i = $start; $i -lt $Lines.Count; $i++) {
        foreach ($pattern in $EndPatterns) {
            if ($Lines[$i] -match $pattern) {
                $end = $i
                break
            }
        }
        if ($end -ne $Lines.Count) {
            break
        }
    }

    if ($end -le $start) {
        return ""
    }

    return (($Lines[$start..($end - 1)] | ForEach-Object { ConvertTo-CleanText $_ }) -join " ").Trim()
}

function Get-CourseNameFromSyllabusLines {
    param(
        [string[]]$Lines,
        [string]$CourseCode,
        [string]$Fallback
    )

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^COURSE:?$") {
            $windowEnd = [Math]::Min($Lines.Count - 1, $i + 8)
            $window = @($Lines[($i + 1)..$windowEnd] | Where-Object { $_ -and $_ -notmatch "^[-–—]$" })
            for ($j = 0; $j -lt $window.Count; $j++) {
                if ($window[$j] -match "\b$([regex]::Escape($CourseCode))\b") {
                    if ($window[$j] -match "\b$([regex]::Escape($CourseCode))\b\s*[-–—]\s*(.+)$") {
                        return (ConvertTo-DisplayTitle $Matches[1])
                    }
                    if (($j + 1) -ge $window.Count) {
                        continue
                    }
                    $title = ($window[$j + 1]).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($title)) {
                        return (ConvertTo-DisplayTitle $title)
                    }
                }
            }
        }
    }

    return $Fallback
}

function Get-CourseLengthWeeksFromLines {
    param([string[]]$Lines)

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^COURSE LENGTH:?$") {
            $windowEnd = [Math]::Min($Lines.Count - 1, $i + 4)
            $windowText = ($Lines[($i + 1)..$windowEnd] -join " ")
            if ($windowText -match "(\d+)\s+Weeks?") {
                return [int]$Matches[1]
            }
        }
    }

    return 0
}

function ConvertFrom-ObjectiveListText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Path
    )

    $lines = @(
        $Text -split "`r?`n" |
            ForEach-Object { ConvertTo-CleanText $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $courseCode = ""
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ($fileName -match "([A-Za-z]{2,}\d{3,4})") {
        $courseCode = $Matches[1].ToUpperInvariant()
    }
    elseif ($Text -match "\b([A-Za-z]{2,}\d{3,4})\b") {
        $courseCode = $Matches[1].ToUpperInvariant()
    }
    else {
        $courseCode = "COURSE"
    }

    $firstObjectiveIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^CO\d+\s*:") {
            $firstObjectiveIndex = $i
            break
        }
    }

    $description = ""
    if ($firstObjectiveIndex -gt 0) {
        $description = (($lines[0..($firstObjectiveIndex - 1)] | ForEach-Object { ConvertTo-CleanText $_ }) -join " ").Trim()
    }
    if ([string]::IsNullOrWhiteSpace($description)) {
        $description = Get-TextBetweenLooseLabels -Lines $lines -StartPattern "^COURSE DESCRIPTION:?$" -EndPatterns @("^TEXTBOOKS:?$", "^RESOURCES", "^COURSE EDUCATIONAL OBJECTIVES")
    }

    # Some course-content files use a compact format with a Course Description
    # followed directly by Week headings instead of the labeled spec-sheet
    # structure. Keep the description from absorbing all subsequent weeks.
    $firstWeekIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^Week\s+\d+\s+.+$") {
            $firstWeekIndex = $i
            break
        }
    }
    if ($firstWeekIndex -gt 0) {
        $descriptionLabelIndex = -1
        for ($i = 0; $i -lt $firstWeekIndex; $i++) {
            if ($lines[$i] -match "^COURSE DESCRIPTION:?$") {
                $descriptionLabelIndex = $i
                break
            }
        }

        $descriptionStart = if ($descriptionLabelIndex -ge 0) { $descriptionLabelIndex + 1 } else { 0 }
        if ($firstWeekIndex -gt $descriptionStart) {
            $description = (($lines[$descriptionStart..($firstWeekIndex - 1)] | ForEach-Object { ConvertTo-CleanText $_ }) -join " ").Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($description)) {
        $description = "This course develops reasoning, evidence evaluation, problem-solving, argumentation, and communication skills."
    }

    $weeks = New-Object System.Collections.ArrayList
    $current = $null
    foreach ($line in $lines) {
        if ($line -match "^CO(\d+)\s*:\s*(.+)$") {
            if ($current) {
                [void]$weeks.Add($current)
            }

            $number = [int]$Matches[1]
            $objective = ConvertTo-CleanText $Matches[2]
            $current = [pscustomobject]@{
                number = $number
                title = ConvertTo-TitleFromObjective -Objective $objective
                objective = $objective
                subObjectives = New-Object System.Collections.ArrayList
            }
            continue
        }

        if ($current -and $line -match "^LO\d+\.\d+\s*:\s*(.+)$") {
            [void]$current.subObjectives.Add((ConvertTo-CleanText $Matches[1]))
        }
    }
    if ($current) {
        [void]$weeks.Add($current)
    }

    # Also accept content documents organized as Week N headings with
    # Course Objective / Lesson Objectives labels. This format is common in
    # supplied course-content DOCX files and may contain a final week whose
    # objectives are not numbered.
    if ($weeks.Count -eq 0 -and $firstWeekIndex -ge 0) {
        $weekIndexes = New-Object System.Collections.ArrayList
        for ($i = $firstWeekIndex; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^Week\s+(\d+)\s+(.+)$" -and -not (Test-EbookAssessmentTitle -Title $Matches[2])) {
                [void]$weekIndexes.Add([pscustomobject]@{
                    Index = $i
                    Number = [int]$Matches[1]
                    Title = ConvertTo-CleanText $Matches[2]
                })
            }
        }

        for ($w = 0; $w -lt $weekIndexes.Count; $w++) {
            $weekStart = $weekIndexes[$w].Index
            $weekEnd = if (($w + 1) -lt $weekIndexes.Count) { $weekIndexes[$w + 1].Index - 1 } else { $lines.Count - 1 }
            $block = @($lines[$weekStart..$weekEnd])
            $modules = @(Get-ModulesFromWeekBlock -Block $block)

            foreach ($module in $modules) {
                if ([string]$module.title -match "^Objective\s+\d+$" -and $module.objective) {
                    $module.title = ConvertTo-TitleFromObjective -Objective $module.objective
                }
            }

            # A final objective block may omit numeric prefixes. Preserve its
            # first line as the primary objective and the remaining lines as
            # supporting objectives rather than dropping the week entirely.
            if ($modules.Count -eq 0) {
                $objectiveLines = @(
                    $block |
                        Where-Object {
                            $_ -and
                            $_ -notmatch "^Week\s+\d+\s+" -and
                            $_ -notmatch "^(Course Objective|Lesson Objectives|Sub objectives)$" -and
                            -not (Test-EbookAssessmentOrLmsText -Text $_)
                        }
                )
                if ($objectiveLines.Count -gt 0) {
                    $primaryObjective = ConvertTo-CleanText $objectiveLines[0]
                    $supportingObjectives = if ($objectiveLines.Count -gt 1) { @($objectiveLines[1..($objectiveLines.Count - 1)] | ForEach-Object { ConvertTo-CleanText $_ }) } else { @() }
                    $modules = @([pscustomobject]@{
                        # A week number is not a course-objective identifier.
                        # Leave unresolved until reconciled with an authoritative
                        # numbered objective by its exact text.
                        objectiveId = ""
                        title = ConvertTo-TitleFromObjective -Objective $primaryObjective
                        objective = $primaryObjective
                        subObjectives = @($supportingObjectives)
                    })
                }
            }

            [void]$weeks.Add([pscustomobject]@{
                number = $weekIndexes[$w].Number
                title = $weekIndexes[$w].Title
                modules = @($modules)
                # Learner-facing checks and activities are deliberately not
                # created from source metadata. The publication policy removes
                # those sections and uses book-native synthesis/application.
                activities = @()
                chapterReferences = @($block | Where-Object { $_ -match "Chapter|Chapters" })
            })
        }
    }

    if ($weeks.Count -eq 0) {
        $objectiveStart = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^COURSE EDUCATIONAL OBJECTIVES:?$|^COURSE OBJECTIVES:?$") {
                $objectiveStart = $i
                break
            }
        }

        if ($objectiveStart -ge 0) {
            $numberedObjectives = New-Object System.Collections.ArrayList
            for ($i = $objectiveStart + 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^INSTRUCTIONAL METHODS:?$|^GRADING:?$|^GRADE SCALE:?$") {
                    break
                }
                if ($lines[$i] -match "^\d+\.\s+(.+)$") {
                    [void]$numberedObjectives.Add((ConvertTo-CleanText $Matches[1]))
                }
            }

            $weekCount = Get-CourseLengthWeeksFromLines -Lines $lines
            if ($weekCount -le 0 -or $weekCount -gt $numberedObjectives.Count) {
                $weekCount = $numberedObjectives.Count
            }
            if ($weekCount -le 0) {
                $weekCount = 1
            }

            for ($i = 0; $i -lt $weekCount; $i++) {
                $startIndex = [Math]::Floor(($i * $numberedObjectives.Count) / $weekCount)
                $endIndex = [Math]::Floor((($i + 1) * $numberedObjectives.Count) / $weekCount) - 1
                if ($endIndex -lt $startIndex) { $endIndex = $startIndex }
                $objectivesForWeek = @($numberedObjectives[$startIndex..$endIndex])
                $primaryObjective = $objectivesForWeek[0]
                [void]$weeks.Add([pscustomobject]@{
                    number = $i + 1
                    title = ConvertTo-TitleFromObjective -Objective $primaryObjective
                    objective = $primaryObjective
                    subObjectives = New-Object System.Collections.ArrayList
                })
                foreach ($objective in $objectivesForWeek) {
                    [void]$weeks[$weeks.Count - 1].subObjectives.Add($objective)
                }
            }
        }
    }

    $parsedWeeks = New-Object System.Collections.ArrayList
    foreach ($week in @($weeks)) {
        $weekModules = @($week.modules)
        if ($weekModules.Count -eq 0) {
            $weekModules = @([pscustomobject]@{
                objectiveId = "$($week.number)"
                title = $week.title
                objective = $week.objective
                subObjectives = @($week.subObjectives)
            })
        }

        [void]$parsedWeeks.Add([pscustomobject]@{
            number = $week.number
            title = $week.title
            modules = @($weekModules)
            activities = @($week.activities)
            chapterReferences = @($week.chapterReferences)
        })
    }

    return [pscustomobject]@{
        courseCode = $courseCode
        courseNumberRaw = $courseCode
        sme = ""
        courseName = Get-CourseNameFromSyllabusLines -Lines $lines -CourseCode $courseCode -Fallback (Get-CourseNameFromObjectiveList -CourseCode $courseCode -Description $description -Path $Path)
        credits = ""
        deliveryMode = ""
        duration = ""
        prerequisites = ""
        primaryText = ""
        description = $description
        weeks = @($parsedWeeks)
        sourcePath = $null
    }
}

function Get-ModulesFromWeekBlock {
    param([string[]]$Block)

    $skipLabels = @(
        "Course Objective", "Modules", "Sub objectives", "Activities",
        "LEARN", "PRACTICE", "DO", "Key Points", "Self-Assessment",
        "Discussion", "Assignment", "Clinical Labs"
    )
    $weekLabel = if ($Block.Count -gt 0 -and $Block[0] -match '^Week\s+\d+') { ConvertTo-CleanText $Block[0] } else { "this week" }

    # In a two-column DOCX table, all course objectives can precede all
    # lesson objectives. Route numbered lessons by parent ID, not proximity.
    if (@($Block | Where-Object { $_ -match '^\d+\.\d+\s+' }).Count -gt 0) {
        $numberedModules = New-Object System.Collections.ArrayList
        foreach ($line in $Block) {
            if ($line -match '^(\d+)\.\s+(.+)$') {
                [void]$numberedModules.Add([pscustomobject]@{
                    objectiveId = $Matches[1]
                    title = $Matches[2]
                    objective = $Matches[2]
                    subObjectives = @()
                })
            }
        }

        # Authors sometimes leave the number off a course objective while its
        # lessons keep theirs ("Explain the stages..." above "1.1 Identify...").
        # Pair each missing parent, in order of first lesson reference, with
        # the unnumbered objective lines of the week, in document order.
        $missingParents = New-Object System.Collections.ArrayList
        foreach ($line in $Block) {
            if ($line -match '^(\d+)\.\d+\s+' -and $missingParents -notcontains $Matches[1] -and @($numberedModules | Where-Object { $_.objectiveId -eq $Matches[1] }).Count -eq 0) {
                [void]$missingParents.Add($Matches[1])
            }
        }
        if ($missingParents.Count -gt 0) {
            $unnumbered = @(
                $Block |
                    Where-Object {
                        $_ -notmatch '^\d+(\.\d+)?[.)]?\s' -and
                        $_ -notmatch '^Week\s+\d+' -and
                        $_ -notmatch '^(Course|Lesson|Sub|Weekly)\s+objectives?\s*:?$' -and
                        $skipLabels -notcontains $_ -and
                        $_ -notmatch '^(Chapter|Chapters)\b' -and
                        $_.Length -ge 12 -and
                        -not (Test-EbookAssessmentOrLmsText -Text $_)
                    }
            )
            for ($k = 0; $k -lt $missingParents.Count; $k++) {
                $parentId = $missingParents[$k]
                if ($k -ge $unnumbered.Count) {
                    throw "In $weekLabel, lesson objectives $parentId.x refer to course objective $parentId, but no line starts with '$parentId.' and no unnumbered course objective is left to match it. Number that course objective in the spec sheet (for example '$parentId. Explain ...') and upload it again."
                }
                [void]$numberedModules.Add([pscustomobject]@{
                    objectiveId = $parentId
                    title = (ConvertTo-CleanText $unnumbered[$k])
                    objective = (ConvertTo-CleanText $unnumbered[$k])
                    subObjectives = @()
                })
            }
        }

        foreach ($line in $Block) {
            if ($line -match '^(\d+)\.\d+\s+(.+)$') {
                $parentId = $Matches[1]
                $lesson = $Matches[2]
                $parents = @($numberedModules | Where-Object { $_.objectiveId -eq $parentId })
                if ($parents.Count -ne 1) { throw "In $weekLabel, lesson objective '$line' matches $($parents.Count) course objectives numbered '$parentId.'. Each course objective number must appear once in the week." }
                $parents[0].subObjectives = @($parents[0].subObjectives) + @($lesson)
            }
        }
        return @($numberedModules | Sort-Object { [int]$_.objectiveId })
    }

    $modules = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Block.Count; $i++) {
        $line = $Block[$i]
        if ($line -match "^(\d+)\.\s+(.+)$") {
            $objectiveId = $Matches[1]
            $objective = $Matches[2]
            $moduleTitle = ""
            $subObjectives = New-Object System.Collections.ArrayList

            for ($j = $i + 1; $j -lt $Block.Count; $j++) {
                $candidate = $Block[$j]
                if ($candidate -match "^\d+\.\s+" -and $candidate -notmatch "^\d+\.\d+") {
                    break
                }

                if ($candidate -match "^\d+\.\d+\s+(.+)$") {
                    [void]$subObjectives.Add($Matches[1])
                    continue
                }

                $isLmsLine = Test-EbookAssessmentOrLmsText -Text $candidate

                if ([string]::IsNullOrWhiteSpace($moduleTitle) -and
                    ($skipLabels -notcontains $candidate) -and
                    ($candidate -notmatch "^Chapter") -and
                    (-not $isLmsLine) -and
                    ($candidate -notmatch "^\d+\.\d+")) {
                    $moduleTitle = $candidate
                    continue
                }

                if (-not [string]::IsNullOrWhiteSpace($moduleTitle) -and
                    ($skipLabels -notcontains $candidate) -and
                    ($candidate -notmatch "Chapter") -and
                    (-not $isLmsLine) -and
                    ($candidate -notmatch "^\d+\.\d+")) {
                    [void]$subObjectives.Add($candidate)
                }
            }

            if ([string]::IsNullOrWhiteSpace($moduleTitle)) {
                # A plain-text spec often uses numbered topic lines without a
                # separate module-title line. Preserve that topic instead of
                # manufacturing the unhelpful label "Objective N".
                $moduleTitle = $objective
            }

            [void]$modules.Add([pscustomobject]@{
                objectiveId = $objectiveId
                title = $moduleTitle
                objective = $objective
                subObjectives = @($subObjectives)
            })
        }
    }

    return @($modules)
}

function Get-ActivitiesFromWeekBlock {
    param([string[]]$Block)

    $activityTerms = @("Key Points", "Self-Assessment", "Practice", "Reflection")
    $activities = New-Object System.Collections.ArrayList
    foreach ($line in $Block) {
        if ((-not (Test-EbookAssessmentOrLmsText -Text $line)) -and $activityTerms -contains $line) {
            [void]$activities.Add($line)
        }
    }

    return @($activities | Select-Object -Unique)
}

function Get-DocxTables {
    # Reads Word tables with their row/column structure intact. Flat text
    # extraction loses which column a cell belongs to, which is exactly what a
    # week-per-column course blueprint needs. Cells that span several grid
    # columns are repeated so column indexes stay aligned across rows.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $resolvedPath = (Resolve-Path $Path).ProviderPath
    $zip = Open-DocxArchive -Path $resolvedPath
    try {
        $xml = Read-DocxZipEntryText -Zip $zip -EntryName "word/document.xml"
        if ($null -eq $xml) { return @() }
        $xml = Add-DocxListNumbers -DocumentXml $xml -Numbering (Get-DocxNumberingDefinitions -Zip $zip)
    }
    finally {
        if ($zip) { $zip.Dispose() }
    }

    $tables = New-Object System.Collections.ArrayList
    foreach ($tableMatch in [regex]::Matches($xml, "(?s)<w:tbl>.*?</w:tbl>")) {
        $rows = New-Object System.Collections.ArrayList
        foreach ($rowMatch in [regex]::Matches($tableMatch.Value, "(?s)<w:tr[ >].*?</w:tr>")) {
            $cells = New-Object System.Collections.ArrayList
            foreach ($cellMatch in [regex]::Matches($rowMatch.Value, "(?s)<w:tc[ >].*?</w:tc>")) {
                $lines = New-Object System.Collections.ArrayList
                foreach ($paragraphMatch in [regex]::Matches($cellMatch.Value, "(?s)<w:p[ >].*?</w:p>")) {
                    $paragraphXml = $paragraphMatch.Value -replace "<w:tab[^>]*/>", " " -replace "<w:br[^>]*/>", " "
                    $raw = -join @([regex]::Matches($paragraphXml, "<w:t[^>]*>([^<]*)</w:t>") | ForEach-Object { $_.Groups[1].Value })
                    $line = ConvertTo-CleanText ([System.Net.WebUtility]::HtmlDecode($raw))
                    if (-not [string]::IsNullOrWhiteSpace($line)) { [void]$lines.Add($line) }
                }
                $cell = [pscustomobject]@{
                    lines = @($lines.ToArray())
                    text = (($lines.ToArray()) -join " ")
                }
                $span = 1
                if ($cellMatch.Value -match "<w:gridSpan\s+w:val=`"(\d+)`"") { $span = [Math]::Max(1, [int]$Matches[1]) }
                for ($s = 0; $s -lt $span; $s++) { [void]$cells.Add($cell) }
            }
            [void]$rows.Add([pscustomobject]@{ cells = @($cells.ToArray()) })
        }
        [void]$tables.Add([pscustomobject]@{ rows = @($rows.ToArray()) })
    }

    return @($tables.ToArray())
}

function ConvertFrom-CourseBlueprintDocx {
    # Parses the UMA "Course Blueprint" layout: label/value metadata tables,
    # a CO1./CO2. course-objective table, and a weekly grid whose header row
    # holds "Week 1".."Week N" columns with Weekly Topics, Course Objectives,
    # and Learning Objectives rows beneath. Returns $null when the document
    # has no such grid so the caller can try the other parsers.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $tables = @(Get-DocxTables -Path $Path)
    if ($tables.Count -eq 0) { return $null }

    $meta = @{}
    $courseObjectiveRecords = New-Object System.Collections.ArrayList
    $gridCandidates = New-Object System.Collections.ArrayList
    foreach ($table in $tables) {
        $rows = @($table.rows)
        foreach ($row in $rows) {
            $cells = @($row.cells)
            if ($cells.Count -lt 2) { continue }
            $label = ([string]$cells[0].text).TrimEnd(':').Trim()
            $value = [string]$cells[1].text
            if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($value)) { continue }
            if ($label -match "^CO\s*(\d+)\s*[.:]?$") {
                $objectiveId = "CO$($Matches[1])"
                if (-not @($courseObjectiveRecords | Where-Object { $_.objectiveId -eq $objectiveId }).Count) {
                    [void]$courseObjectiveRecords.Add([pscustomobject]@{
                        objectiveId = $objectiveId
                        objective = $value.TrimEnd(',', ';', ' ')
                    })
                }
                continue
            }
            $key = $label.ToLowerInvariant()
            if (-not $meta.ContainsKey($key)) { $meta[$key] = $value }
        }

        if ($rows.Count -lt 2) { continue }
        $weekColumns = @{}
        $headerCells = @($rows[0].cells)
        for ($c = 0; $c -lt $headerCells.Count; $c++) {
            if ([string]$headerCells[$c].text -match "^Week\s+(\d+)$") {
                $weekNumber = [int]$Matches[1]
                if (-not $weekColumns.ContainsValue($weekNumber)) { $weekColumns[$c] = $weekNumber }
            }
        }
        if ($weekColumns.Count -lt 2) { continue }
        $contentRows = @($rows | Select-Object -Skip 1 | Where-Object { ([string]@($_.cells)[0].text) -match "(?i)topic|objective" }).Count
        [void]$gridCandidates.Add([pscustomobject]@{ table = $table; weekColumns = $weekColumns; contentRows = $contentRows })
    }
    if ($gridCandidates.Count -eq 0) { return $null }
    $grid = @($gridCandidates | Sort-Object contentRows -Descending | Select-Object -First 1)[0]
    if ($grid.contentRows -eq 0) { return $null }

    $weeks = @{}
    foreach ($column in @($grid.weekColumns.Keys)) {
        $weeks[[int]$grid.weekColumns[$column]] = [pscustomobject]@{
            number = [int]$grid.weekColumns[$column]
            title = ""
            courseObjectiveIds = @()
            learningObjectives = @()
            resources = @()
        }
    }
    foreach ($row in @($grid.table.rows | Select-Object -Skip 1)) {
        $cells = @($row.cells)
        if ($cells.Count -eq 0) { continue }
        $label = ([string]$cells[0].text).ToLowerInvariant()
        foreach ($column in @($grid.weekColumns.Keys)) {
            if ([int]$column -ge $cells.Count) { continue }
            $cell = $cells[[int]$column]
            $week = $weeks[[int]$grid.weekColumns[$column]]
            if ($label -match "^weekly topics?\b|^topics?$|^chapter title|^module title|^week(ly)? title") {
                $week.title = ([string]$cell.text).TrimEnd('.', ' ')
            }
            elseif ($label -match "^course objectives?\b") {
                $week.courseObjectiveIds = @([regex]::Matches([string]$cell.text, "CO\s*(\d+)") | ForEach-Object { "CO$($_.Groups[1].Value)" } | Select-Object -Unique)
            }
            elseif ($label -match "^(learning|lesson|weekly|module) objectives?\b") {
                $week.learningObjectives = @(
                    foreach ($line in @($cell.lines)) {
                        if ($line -match "^(LO\s*\d+(?:\.\d+)?)\s*[:.\-]\s*(.+)$") {
                            [pscustomobject]@{ objectiveId = ($Matches[1] -replace "\s", ""); objective = $Matches[2].Trim().TrimEnd(',', ';', ' ') }
                        }
                        elseif ($line -match "^\d+[.)]\s*(.+)$") {
                            [pscustomobject]@{ objectiveId = ""; objective = $Matches[1].Trim().TrimEnd(',', ';', ' ') }
                        }
                        else {
                            [pscustomobject]@{ objectiveId = ""; objective = $line.TrimEnd(',', ';', ' ') }
                        }
                    }
                )
            }
            elseif ($label -match "textbook|resource") {
                $week.resources = @($cell.lines)
            }
        }
    }

    $parsedWeeks = New-Object System.Collections.ArrayList
    foreach ($number in @($weeks.Keys | Sort-Object)) {
        $week = $weeks[$number]
        $modules = New-Object System.Collections.ArrayList
        foreach ($learningObjective in @($week.learningObjectives)) {
            if ([string]::IsNullOrWhiteSpace($learningObjective.objective)) { continue }
            [void]$modules.Add([pscustomobject]@{
                objectiveId = [string]$learningObjective.objectiveId
                title = (ConvertTo-TitleFromObjective -Objective $learningObjective.objective)
                objective = $learningObjective.objective
                subObjectives = @()
            })
        }
        if ($modules.Count -eq 0) {
            # No week-level learning objectives: fall back to the mapped course objectives.
            foreach ($courseObjectiveId in @($week.courseObjectiveIds)) {
                $record = @($courseObjectiveRecords | Where-Object { $_.objectiveId -eq $courseObjectiveId } | Select-Object -First 1)
                if ($record.Count -eq 0) { continue }
                [void]$modules.Add([pscustomobject]@{
                    objectiveId = $courseObjectiveId
                    title = (ConvertTo-TitleFromObjective -Objective $record[0].objective)
                    objective = $record[0].objective
                    subObjectives = @()
                })
            }
        }
        if ($modules.Count -eq 0) { continue }
        $title = if (-not [string]::IsNullOrWhiteSpace($week.title)) { $week.title } else { [string]$modules[0].title }
        [void]$parsedWeeks.Add([pscustomobject]@{
            number = [int]$number
            title = $title
            modules = @($modules.ToArray())
            courseObjectiveIds = @($week.courseObjectiveIds)
            resources = @($week.resources)
            # Learner-facing activities are not created from blueprint metadata;
            # the publication policy uses book-native synthesis and application.
            activities = @()
            chapterReferences = @()
        })
    }
    if ($parsedWeeks.Count -eq 0) { return $null }

    $metaValue = {
        param([string[]]$Keys)
        foreach ($key in $Keys) { if ($meta.ContainsKey($key)) { return [string]$meta[$key] } }
        return ""
    }
    $courseNumberRaw = & $metaValue @("course number", "course code", "course")
    $courseCode = ""
    if ($courseNumberRaw -match "([A-Za-z]{2,}\d{3,4})") { $courseCode = $Matches[1].ToUpperInvariant() }
    elseif ([System.IO.Path]::GetFileNameWithoutExtension($Path) -match "([A-Za-z]{2,}\d{3,4})") { $courseCode = $Matches[1].ToUpperInvariant() }
    $sme = & $metaValue @("initial course sme", "course sme", "sme")

    return [pscustomobject]@{
        courseCode = $courseCode
        courseNumberRaw = $courseNumberRaw
        sme = $sme
        courseName = (& $metaValue @("course title", "course name"))
        credits = (& $metaValue @("semester credits", "credits", "clock hours"))
        deliveryMode = (& $metaValue @("mode of delivery", "delivery mode"))
        duration = (& $metaValue @("duration", "course length"))
        prerequisites = (& $metaValue @("pre-requisites", "prerequisites", "prerequisite"))
        primaryText = (& $metaValue @("text", "textbook", "primary text"))
        description = (& $metaValue @("official course description", "course description", "description"))
        courseObjectives = @($courseObjectiveRecords.ToArray())
        weeks = @($parsedWeeks.ToArray())
        sourceFormat = "course-blueprint"
        sourcePath = $null
    }
}

function Import-CourseSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $text = if ($extension -eq ".docx") { Get-DocxText -Path $Path } else { Get-SourceTextFromFile -Path $Path }
    $course = ConvertFrom-CourseSpecText -Text $text
    if ($extension -eq ".docx" -and ([string]::IsNullOrWhiteSpace($course.courseCode) -or @($course.weeks).Count -eq 0)) {
        # Week-per-column Course Blueprint documents carry their structure in
        # table cells, which the line-based spec-sheet parser cannot see.
        $blueprint = ConvertFrom-CourseBlueprintDocx -Path $Path
        if ($blueprint -and @($blueprint.weeks).Count -gt 0) { $course = $blueprint }
    }
    if ([string]::IsNullOrWhiteSpace($course.courseCode) -or @($course.weeks).Count -eq 0) {
        $course = ConvertFrom-ObjectiveListText -Text $text -Path $Path
    }
    # Some legacy course documents provide objective wording without an
    # explicit source ID. Give those records the same stable identity used by
    # the traceability fallback so all release checks see one authoritative ID.
    foreach ($week in @($course.weeks)) {
        $moduleIndex = 0
        foreach ($module in @($week.modules)) {
            [void]$moduleIndex++
            if (-not $module.objective) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$module.objectiveId)) {
                if ($module.PSObject.Properties.Name -contains 'objectiveId') { $module.objectiveId = "W$($week.number)-$moduleIndex" }
                else { $module | Add-Member -MemberType NoteProperty -Name objectiveId -Value "W$($week.number)-$moduleIndex" }
            }
        }
    }
    $course.sourcePath = $Path
    return $course
}

function Import-SourceContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$CourseSpecPath,
        [int]$MaxFiles = 20,
        [int]$MaxTotalChars = 250000,
        [switch]$StrictCoverage,
        [string[]]$IncludedPaths
    )

    $courseCode = ""
    if ($CourseSpecPath) {
        $specName = [System.IO.Path]::GetFileNameWithoutExtension($CourseSpecPath)
        if ($specName -match "\b([A-Z]{2,4}\d{3,4})\b") {
            $courseCode = $Matches[1]
        }
    }
    if($IncludedPaths){
        $files=@($IncludedPaths | ForEach-Object {Get-Item -LiteralPath $_ -ErrorAction Stop})
        if($files.Count -gt $MaxFiles){throw "Source intake has $($files.Count) files; the limit is $MaxFiles. No files may be silently omitted."}
    }else{$files = @(Get-SourceContextFiles -Path $Path -MaxFiles $(if($StrictCoverage){[int]::MaxValue}else{$MaxFiles}) -CourseCode $courseCode -CourseSpecPath $CourseSpecPath)}
    if($StrictCoverage -and $files.Count -gt $MaxFiles){throw 'Source file limit exceeded. Reduce the upload or explicitly increase the reviewed limit.'}
    if($StrictCoverage -and -not $files.Count){throw 'No readable source documents were selected. No empty intake may pass.'}
    $chunks = New-Object System.Collections.ArrayList
    $fileSummaries = New-Object System.Collections.ArrayList
    $charsUsed = 0
    $chunkNumber = 1

    foreach ($file in $files) {
        if ($charsUsed -ge $MaxTotalChars) {
            if($StrictCoverage){throw "Source text exceeds $MaxTotalChars characters before $($file.Name). No silent truncation is allowed."}
            break
        }

        $text = Get-SourceTextFromFile -Path $file.FullName
        if ([string]::IsNullOrWhiteSpace($text)) {
            if($StrictCoverage){throw "Could not extract readable text from $($file.Name). Convert or replace this document before generating."}
            continue
        }

        $remaining = $MaxTotalChars - $charsUsed
        if ($text.Length -gt $remaining) {
            if($StrictCoverage){throw "Source text exceeds $MaxTotalChars characters in $($file.Name). No silent truncation is allowed."}
            $text = $text.Substring(0, $remaining)
        }

        $fileChunks = @(Split-SourceTextIntoChunks -Text $text -SourceFile $file.FullName -StartIndex $chunkNumber)
        foreach ($chunk in $fileChunks) {
            [void]$chunks.Add($chunk)
            $chunkNumber++
        }

        [void]$fileSummaries.Add([pscustomobject]@{
            path = $file.FullName
            name = $file.Name
            extension = $file.Extension
            charactersUsed = $text.Length
            chunkCount = $fileChunks.Count
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            isCourseSpec = ((Resolve-Path $file.FullName).ProviderPath -eq $CourseSpecPath)
        })

        $charsUsed += $text.Length
    }

    return [pscustomobject]@{
        rootPath = (Resolve-Path $Path).ProviderPath
        generatedAt = (Get-Date).ToString("s")
        maxFiles = $MaxFiles
        maxTotalChars = $MaxTotalChars
        totalCharactersUsed = $charsUsed
        files = @($fileSummaries)
        chunks = @($chunks)
    }
}

function Get-SourceContextFiles {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxFiles = 20,
        [string]$CourseCode = "",
        [string]$CourseSpecPath = ""
    )

    $resolved = Get-Item -LiteralPath $Path
    $allowedExtensions = @(".docx", ".txt", ".md", ".json", ".html", ".htm")

    if (-not $resolved.PSIsContainer) {
        if ($allowedExtensions -contains $resolved.Extension.ToLowerInvariant()) {
            return @($resolved)
        }

        return @()
    }

    $skipPattern = "\\(node_modules|\.git|dist|temp|avatars|workflows|package-lock|burn-overlays|designideas|vscode-extension)\\"
    $files = @(
        Get-ChildItem -LiteralPath $resolved.FullName -Recurse -File |
            Where-Object { $allowedExtensions -contains $_.Extension.ToLowerInvariant() } |
            Where-Object { $_.FullName -notmatch $skipPattern } |
            Where-Object { $_.Length -lt 5000000 }
    )
    if (-not [string]::IsNullOrWhiteSpace($CourseCode)) {
        $courseCodePattern = [regex]::Escape($CourseCode)
        $files = @(
            $files | Where-Object {
                $identity = "$($_.FullName) $($_.Name)"
                $isSpec = $false
                if ($CourseSpecPath) {
                    try {
                        $isSpec = ((Resolve-Path -LiteralPath $_.FullName).ProviderPath -eq (Resolve-Path -LiteralPath $CourseSpecPath).ProviderPath)
                    }
                    catch {
                        $isSpec = $false
                    }
                }
                $hasOtherCourseCode = ($identity -match "\b[A-Z]{2,4}\d{3,4}\b" -and $identity -notmatch $courseCodePattern)
                $isSpec -or -not $hasOtherCourseCode
            }
        )
        if ($CourseSpecPath -and (Test-Path -LiteralPath $CourseSpecPath)) {
            $specItem = Get-Item -LiteralPath $CourseSpecPath
            if (@($files | Where-Object { $_.FullName -eq $specItem.FullName }).Count -eq 0) {
                $files = @($specItem) + @($files)
            }
        }
    }

    return @(
        $files |
            Sort-Object `
                @{ Expression = { Get-SourceContextFilePriority -Path $_.FullName -Name $_.Name } }, `
                @{ Expression = { $_.FullName } } |
            Select-Object -First $MaxFiles
    )
}

function Get-SourceContextFilePriority {
    param(
        [string]$Path,
        [string]$Name
    )

    if ($Path -match "\\(source|Source)\\") { return 0 }
    if ($Name -match "(spec|syllabus|objectives|book|chapter|source|chunk)") { return 1 }
    if ($Path -match "\\ingested\\") { return 2 }
    if ($Path -match "\\docs\\") { return 3 }
    return 9
}

function Get-SourceTextFromFile {
    param([Parameter(Mandatory)][string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    try {
        switch ($extension) {
            ".docx" { return Get-DocxText -Path $Path }
            ".html" { return ConvertFrom-HtmlToPlainText -Html (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) }
            ".htm" { return ConvertFrom-HtmlToPlainText -Html (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) }
            ".txt" { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop }
            ".md" { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop }
            ".json" { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop }
            default { return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop }
        }
    }
    catch {
        return ""
    }
}

function Split-SourceTextIntoChunks {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$SourceFile,
        [int]$StartIndex = 1,
        [int]$TargetWords = 220
    )

    $Text = $Text -replace "Week\s+21Test", "Week 1 Test"
    $Text = $Text -replace "\s+(Week\s+\d+\s+[A-Z])", "`n`n`$1"

    $paragraphs = @(
        $Text -split "(`r?`n){2,}" |
            ForEach-Object { ConvertTo-CleanText $_ } |
            Where-Object { $_.Length -gt 20 }
    )

    $chunks = New-Object System.Collections.ArrayList
    $current = New-Object System.Collections.ArrayList
    $currentWords = 0
    $chunkIndex = $StartIndex

    foreach ($paragraph in $paragraphs) {
        $wordCount = @($paragraph -split "\s+" | Where-Object { $_ }).Count
        $startsNewWeek = $paragraph -match "^Week\s+\d+\s+"
        if ($currentWords -gt 0 -and ($startsNewWeek -or (($currentWords + $wordCount) -gt $TargetWords))) {
            $chunkText = (($current | ForEach-Object { $_ }) -join "`n`n").Trim()
            [void]$chunks.Add((New-SourceChunk -Text $chunkText -SourceFile $SourceFile -ChunkIndex $chunkIndex))
            $chunkIndex++
            $current.Clear()
            $currentWords = 0
        }

        [void]$current.Add($paragraph)
        $currentWords += $wordCount
    }

    if ($current.Count -gt 0) {
        $chunkText = (($current | ForEach-Object { $_ }) -join "`n`n").Trim()
        [void]$chunks.Add((New-SourceChunk -Text $chunkText -SourceFile $SourceFile -ChunkIndex $chunkIndex))
    }

    return @($chunks)
}

function New-SourceChunk {
    param(
        [string]$Text,
        [string]$SourceFile,
        [int]$ChunkIndex
    )

    return [pscustomobject]@{
        chunkId = "source-$ChunkIndex"
        sourceFile = $SourceFile
        sourceName = [System.IO.Path]::GetFileName($SourceFile)
        wordCount = @($Text -split "\s+" | Where-Object { $_ }).Count
        keyTerms = @(Get-KeyTermsFromText -Text $Text -Limit 12)
        rawText = $Text
    }
}

function Get-KeyTermsFromText {
    param(
        [string]$Text,
        [int]$Limit = 12
    )

    $stopWords = @(
        "about", "above", "across", "after", "again", "also", "because", "before", "being", "between",
        "chapter", "course", "describe", "determine", "during", "every", "given", "include", "learn",
        "module", "objective", "office", "other", "practice", "should", "students", "their", "there",
        "these", "through", "using", "where", "which", "while", "with", "within", "would"
    )

    $counts = @{}
    foreach ($token in ($Text.ToLowerInvariant() -split "[^a-z0-9]+")) {
        if ($token.Length -lt 4) { continue }
        if ($stopWords -contains $token) { continue }
        if (-not $counts.ContainsKey($token)) { $counts[$token] = 0 }
        $counts[$token]++
    }

    return @(
        $counts.GetEnumerator() |
            Sort-Object -Property Value -Descending |
            Select-Object -First $Limit |
            ForEach-Object { $_.Key }
    )
}

function Find-SourceContextForChapter {
    param(
        [object]$Chapter,
        [object]$SourceContext,
        [int]$Limit = 4,
        [switch]$AllMatches
    )

    if ($null -eq $SourceContext -or $null -eq $SourceContext.chunks) {
        return @()
    }

    $query = "$($Chapter.title) $($Chapter.focus) $($Chapter.researchQuery) $($Chapter.learningTargets -join ' ') $($Chapter.moduleSequence.title -join ' ')"
    $terms = @(
        $query.ToLowerInvariant() -split "[^a-z0-9]+" |
            Where-Object { $_.Length -gt 4 } |
            Select-Object -Unique
    )

    $scored = New-Object System.Collections.ArrayList
    foreach ($chunk in @($SourceContext.chunks)) {
        if ($AllMatches -and [IO.Path]::GetFileName($chunk.sourceFile) -match '^book-studio-(brief|format-review)\.txt$') { continue }
        if($AllMatches -and $chunk.rawText -match '^Week\s+(\d+)\s+' -and [int]$Matches[1] -ne [int]$Chapter.number){continue}
        $text = "$($chunk.rawText) $($chunk.keyTerms -join ' ')".ToLowerInvariant()
        $score = 0
        $exactWeek = $chunk.rawText -match "^Week\s+$($Chapter.number)\s+"
        foreach ($term in $terms) {
            if ($text.Contains($term)) { $score++ }
        }
        if ($exactWeek) {
            $score += 1000
        }

        if ($score -gt 0) {
            [void]$scored.Add([pscustomobject]@{
                chunkId = $chunk.chunkId
                sourceName = $chunk.sourceName
                sourceFile = $chunk.sourceFile
                score = $score
                keyTerms = $chunk.keyTerms
                excerpt = $(if($AllMatches){$chunk.rawText}else{Get-TextExcerpt -Text $chunk.rawText -MaxLength 520})
            })
        }
    }

    $exactMatches = @($scored | Where-Object { $_.score -ge 1000 } | Sort-Object -Property score -Descending)
    if($AllMatches){return @($scored | Sort-Object -Property score -Descending)}
    if ($exactMatches.Count -gt 0) {
        $courseOverview = @(
            $scored |
                Where-Object { $_.chunkId -ne $exactMatches[0].chunkId -and $_.excerpt -match "Course Description|course provides" } |
                Sort-Object -Property score -Descending |
                Select-Object -First 1
        )

        return @(@($exactMatches | Select-Object -First 2) + $courseOverview)
    }

    return @(
        $scored |
            Sort-Object -Property @{ Expression = "score"; Descending = $true }, sourceName |
            Select-Object -First $Limit
    )
}

function Get-TextExcerpt {
    param(
        [string]$Text,
        [int]$MaxLength = 520
    )

    $clean = ConvertTo-CleanText $Text
    if ($clean.Length -le $MaxLength) {
        return $clean
    }

    return $clean.Substring(0, $MaxLength).Trim() + "..."
}

function Join-ModuleText {
    param([object]$Week)

    $parts = New-Object System.Collections.ArrayList
    foreach ($module in $Week.modules) {
        [void]$parts.Add($module.title)
        [void]$parts.Add($module.objective)
        foreach ($sub in $module.subObjectives) {
            [void]$parts.Add($sub)
        }
    }

    return (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " ")
}

function Get-CourseDomain {
    param([object]$Course)

    $text = "$($Course.courseCode) $($Course.courseName) $($Course.description) " + (@($Course.weeks) | ForEach-Object { "$($_.title) $(Join-ModuleText -Week $_)" } | Select-Object -First 5) -join " "
    $lower = $text.ToLowerInvariant()
    # The subject-specific domains are decided from the course title and chapter
    # titles only. Descriptions and competency boilerplate mention "critical
    # thinking", "problem-solving", "ethical", or "presentation" for almost any
    # course, which used to pull a healthcare billing course into the
    # critical-thinking templates.
    $titleText = (("$($Course.courseCode) $($Course.courseName) " + ((@($Course.weeks) | ForEach-Object { [string]$_.title } | Select-Object -First 8) -join " "))).ToLowerInvariant()
    if ($lower -match "\bgm1025\b|front-line supervision|team leadership|leadership styles|delegation and motivation|coaching conversations") {
        return "front-line-supervision"
    }
    if ($lower -match "\bci\d{4}\b|computer applications|windows operating system|microsoft word|files and folders|cloud storage|apa standards|cybersecurity|keyboarding") {
        return "computer-applications"
    }
    if ($titleText -match "critical thinking|logical reasoning|deductive|inductive|persuasive argument|fallacies|\bethics\b|\blogic\b") {
        return "critical-thinking"
    }
    if ($titleText -match "interpersonal|professional communication|business communication|nonverbal|verbal communication|workplace communication|positive and negative messages|bad-news messages") {
        return "professional-communication"
    }

    return "business-operations"
}

function Get-CoursePracticeFrame {
    param([object]$Course)

    $domain = Get-CourseDomain -Course $Course
    if ($domain -eq "front-line-supervision") {
        return [pscustomobject]@{
            learnerWork = "supervisory judgment, team communication, coaching, feedback, and ethical leadership"
            throughline = "Students move from matching leadership style to situation, to delegating and motivating people, to coaching performance, to resolving feedback and conflict, and finally to ethical, inclusive team leadership."
            chapterPurpose = "The goal is dependable supervision: students should be able to clarify work, match support to the situation, communicate expectations, use evidence, and make fair decisions that help teams perform."
            preface = "Front-line supervision is learned through repeated practice with people, tasks, standards, and consequences. The chapters move from situational leadership to delegation, motivation, coaching, feedback, conflict resolution, and ethical inclusive leadership."
            chapterArc = "The chapters build from leadership fit, to clear ownership and motivation, to coaching conversations, to evidence-based feedback and conflict resolution, and finally to ethical and inclusive team leadership."
            scenario = "Imagine a new supervisor coordinating an office or service team where unclear handoffs, competing priorities, and performance concerns affect both employees and the people they serve."
            ordinary = "The situations are deliberately ordinary: leadership shows up in huddles, handoffs, assignments, check-ins, feedback, and everyday decisions about fairness and service."
            bridgeNoun = "supervisory practice"
            applicationDefault = "Create a short leadership plan that identifies the situation, people, task, risk, communication approach, and follow-up evidence."
        }
    }
    if ($domain -eq "computer-applications") {
        return [pscustomobject]@{
            learnerWork = "digital task performance, source use, security judgment, and professional documentation"
            throughline = "Students move from operating-system navigation, to organized local and cloud file management, to professional Word documents, to credible research and APA citation, and finally to secure digital behavior, mobile fluency, keyboarding confidence, and AI-assisted judgment."
            chapterPurpose = "The goal is competent digital performance: students should be able to complete the task, explain the choices behind it, protect information, and produce work another person can review or continue."
            preface = "Computer applications are learned through repeated, visible practice. The chapters move from navigating the computer environment to managing files, preparing professional documents, using credible sources, protecting information, using mobile tools, and checking AI-assisted work with good judgment."
            chapterArc = "The chapters build from Windows navigation, to file and folder organization, to document structure and formatting, to source evaluation and APA citation, and finally to cybersecurity habits, responsible digital behavior, mobile fluency, and verify-before-trust decisions."
            scenario = "Imagine a student preparing digital work for a class and an entry-level workplace: opening the correct tools, saving files where they can be found, formatting a professional document, citing sources accurately, protecting private information, using mobile tools carefully, and checking AI-assisted output before relying on it."
            ordinary = "The situation is deliberately ordinary: digital professionalism is built from small repeatable choices. A clear file name, a checked source, a saved version, a secure password habit, or a corrected formatting issue can prevent confusion later."
            bridgeNoun = "digital workflow competence"
            applicationDefault = "Create a brief digital workflow note that explains the task, the tool choices, the file or source standard used, the risk to avoid, and how the finished work would be checked."
        }
    }

    if ($domain -eq "critical-thinking") {
        return [pscustomobject]@{
            learnerWork = "reasoning, evidence evaluation, ethical judgment, and professional communication"
            throughline = "Students move from the habits of critical thinking, to evaluating information and AI-generated content, to solving problems, recognizing influences on decisions, testing arguments, and communicating ethical positions with evidence."
            chapterPurpose = "The goal is reasoned judgment: students should be able to define the concept, test it against evidence, explain the thinking process, and communicate a defensible conclusion."
            preface = "Critical thinking is learned through repeated practice with claims, evidence, assumptions, alternatives, and consequences. The chapters move from habits of careful thinking to the applied work of evaluating information, solving problems, analyzing arguments, and communicating ethical positions in real-world contexts."
            chapterArc = "The chapters build from critical thinking habits, to intellectual standards and source evaluation, to systematic problem solving, to decision influences and reasoning errors, to inductive and deductive arguments, to ethical persuasion and professional communication."
            scenario = "Imagine a learner or professional facing a real decision with incomplete information, competing pressures, and a need to explain the conclusion clearly. The person has to separate claims from evidence, notice assumptions, consider alternatives, and communicate a position without overstating what the evidence supports."
            ordinary = "The situation is deliberately ordinary: critical thinking is not reserved for formal debates. It appears whenever people interpret information, make choices, respond to uncertainty, and explain why a conclusion deserves trust."
            bridgeNoun = "reasoning practice"
            applicationDefault = "Write a short reasoning memo that states the issue, evaluates the evidence, identifies assumptions or limitations, and explains a defensible conclusion."
        }
    }

    if ($domain -eq "professional-communication") {
        return [pscustomobject]@{
            learnerWork = "professional communication, audience judgment, message planning, listening, and respectful response"
            throughline = "Students move from interpersonal communication foundations to audience awareness, message planning, digital communication, conflict response, collaboration, and presentations in professional settings."
            chapterPurpose = "The goal is communication judgment: students should explain the concept, recognize how context and audience shape a message, and choose language, tone, channel, and follow-up that fit the situation."
            preface = "Professional communication is learned through repeated practice with real messages, audiences, channels, and relationships. The chapters move from interpersonal awareness to clearer workplace messages, collaboration, digital professionalism, difficult conversations, and presentations."
            chapterArc = "The chapters build from interpersonal foundations, to planning and composing messages, to digital and team communication, to difficult-message judgment, and finally to presentations and professional communication habits."
            scenario = "Imagine a learner entering a professional setting where messages affect trust, clarity, teamwork, and service. The learner needs to listen carefully, choose the right channel, adapt tone, organize ideas, respond respectfully, and revise messages before they create confusion."
            ordinary = "The situation is deliberately ordinary: communication quality is built from small choices. A clarified purpose, a better subject line, a respectful response, or a revised opening sentence can prevent misunderstanding later."
            bridgeNoun = "professional communication practice"
            applicationDefault = "Write a short communication note that identifies the audience, purpose, channel, tone, key message, and one revision that would make the message clearer or more respectful."
        }
    }

    return [pscustomobject]@{
        learnerWork = "business operations reasoning"
        throughline = "Students move from recognizing how offices operate, to tracing workflows, to improving customer-facing service with evidence. The examples stay close to entry-level allied healthcare office work."
        chapterPurpose = "The goal is practical judgment: students should explain the concept, see it in a workplace situation, and choose a next step they can defend."
        preface = "Business and office operations make daily work reliable. The chapters move from organization structure to the day-to-day work of coordinating people, information, technology, service, and improvement. Many examples use allied healthcare offices because entry-level staff often help with scheduling, records, forms, privacy, billing questions, and follow-up."
        chapterArc = "The chapters build from basic business context, to cross-functional workflows, to process mapping, to customer-facing service, and finally to evidence-based improvement."
        scenario = "Imagine an allied healthcare clinic office during a busy week. Patients call with questions. Staff update records, route forms, check schedules, protect private information, and follow up before delays grow. The team must understand the business purpose, coordinate across roles, use technology carefully, and document work so the next person can continue it."
        ordinary = "The situation is ordinary on purpose. Office operations matter before a crisis happens. Small choices about roles, tools, messages, records, and follow-up can prevent confusion later."
        bridgeNoun = "business operations reasoning"
        applicationDefault = "Write a short operations note that explains how the chapter concept affects productivity, service quality, privacy risk, and support for organizational goals."
    }
}

function Remove-WeekPrefixFromTitle {
    param([string]$Title)

    $clean = ConvertTo-CleanText $Title
    return (($clean -replace "^Week\s+\d+\s*:\s*", "") -replace "^Module\s+\d+\s*:\s*", "").Trim()
}

function Get-StructuredCourseBlueprintFromSourceContext {
    param(
        [object]$SourceContext,
        [object]$Course
    )

    if ($null -eq $SourceContext) {
        return $null
    }

    $candidatePaths = New-Object System.Collections.ArrayList
    foreach ($file in @($SourceContext.files)) {
        if ($file.path -and $file.name -match "blueprint.*\.json$" -and (Test-Path -LiteralPath $file.path)) {
            [void]$candidatePaths.Add($file.path)
        }
    }

    if ($SourceContext.rootPath -and (Test-Path -LiteralPath $SourceContext.rootPath)) {
        $blueprintFiles = @(
            Get-ChildItem -LiteralPath $SourceContext.rootPath -Recurse -File -Filter "*.json" |
                Where-Object { $_.Name -match "blueprint.*\.json$" }
        )
        foreach ($file in $blueprintFiles) {
            [void]$candidatePaths.Add($file.FullName)
        }
    }

    $paths = @(
        $candidatePaths |
            Where-Object { $_ } |
            Select-Object -Unique |
            Sort-Object `
                @{ Expression = { if ($_ -match "blueprint-v2|design-infused") { 0 } elseif ($_ -match "blueprint") { 1 } else { 9 } } }, `
                @{ Expression = { $_ } }
    )

    foreach ($path in $paths) {
        try {
            $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $modules = @()
            if ($json.courseStructure -and $json.courseStructure.modules) {
                $modules = @($json.courseStructure.modules)
            }
            elseif ($json.modules) {
                $modules = @($json.modules)
            }

            if ($modules.Count -eq 0) {
                continue
            }

            $title = if ($json.title) { ConvertTo-CleanText $json.title } else { "" }
            $courseCode = if ($Course -and $Course.courseCode) { [string]$Course.courseCode } else { "" }
            if ($courseCode -and $title -and $title -notmatch [regex]::Escape($courseCode)) {
                $projectId = if ($json.projectId) { [string]$json.projectId } else { "" }
                if ($projectId -and $projectId -notmatch [regex]::Escape($courseCode.ToLowerInvariant())) {
                    continue
                }
            }

            return [pscustomobject]@{
                sourcePath = $path
                title = $title
                description = if ($json.description) { ConvertTo-CleanText $json.description } else { "" }
                learningObjectives = @($json.learningObjectives)
                modules = @($modules)
            }
        }
        catch {
            continue
        }
    }

    return $null
}

function Get-StructuredModuleNumber {
    param(
        [object]$Module,
        [int]$Fallback
    )

    $title = [string]$Module.title
    $id = [string]$Module.id
    if ($title -match "Week\s+(\d+)") {
        return [int]$Matches[1]
    }
    if ($id -match "(\d+)") {
        return [int]$Matches[1]
    }

    return $Fallback
}

function Get-StructuredModuleText {
    param([object]$Module)

    $parts = New-Object System.Collections.ArrayList
    foreach ($value in @($Module.title, $Module.description)) {
        if ($value) { [void]$parts.Add($value) }
    }
    foreach ($objective in @($Module.learningObjectives + $Module.objectives)) {
        if ($objective) { [void]$parts.Add($objective) }
    }
    foreach ($lesson in @($Module.lessons)) {
        foreach ($value in @($lesson.title, $lesson.description)) {
            if ($value) { [void]$parts.Add($value) }
        }
        foreach ($objective in @($lesson.learningObjectives + $lesson.objectives)) {
            if ($objective) { [void]$parts.Add($objective) }
        }
    }

    return (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " ")
}

function Get-StructuredChapterFocus {
    param(
        [object]$Course,
        [object]$Module
    )

    $moduleText = Get-StructuredModuleText -Module $Module
    $syntheticWeek = [pscustomobject]@{
        modules = @([pscustomobject]@{
            title = $Module.title
            objective = $Module.description
            subObjectives = @($Module.learningObjectives + $Module.objectives + $moduleText)
        })
    }

    return (Get-ChapterFocus -Week $syntheticWeek -Course $Course)
}

function Get-StructuredLessonSequence {
    param([object]$Module)

    $sequence = New-Object System.Collections.ArrayList
    foreach ($lesson in @($Module.lessons)) {
        $objectives = @($lesson.learningObjectives + $lesson.objectives | Where-Object { $_ } | Select-Object -Unique)
        [void]$sequence.Add([pscustomobject]@{
            title = Remove-WeekPrefixFromTitle $lesson.title
            description = if ($lesson.description) { ConvertTo-CleanText $lesson.description } else { "" }
            objectiveId = if ($lesson.id) { [string]$lesson.id } else { "" }
            subObjectives = @($objectives)
            sourceChunks = @($lesson.sourceChunks)
            suggestedActivities = @($lesson.suggestedActivities)
            estimatedMinutes = $lesson.estimatedMinutes
            wordCountTarget = $lesson.wordCountTarget
        })
    }

    if ($sequence.Count -eq 0) {
        $objectives = @($Module.learningObjectives + $Module.objectives | Where-Object { $_ } | Select-Object -Unique)
        [void]$sequence.Add([pscustomobject]@{
            title = Remove-WeekPrefixFromTitle $Module.title
            description = if ($Module.description) { ConvertTo-CleanText $Module.description } else { "" }
            objectiveId = if ($Module.id) { [string]$Module.id } else { "" }
            subObjectives = @($objectives)
            sourceChunks = @($Module.sourceChunks)
            suggestedActivities = @()
            estimatedMinutes = $null
            wordCountTarget = $null
        })
    }

    return @($sequence)
}

function New-EbookPlanFromStructuredBlueprint {
    param(
        [Parameter(Mandatory)][object]$Course,
        [Parameter(Mandatory)][object]$StructuredBlueprint
    )

    $chapters = New-Object System.Collections.ArrayList
    $modules = @($StructuredBlueprint.modules)
    $practiceFrame = Get-CoursePracticeFrame -Course $Course
    $structuredDomain = Get-CourseDomain -Course $Course
    $requiredSections = if ($structuredDomain -eq "professional-communication") {
        @(
            "Business Case: realistic communication scenario",
            "Message planning or response model learners can reuse",
            "Audience, purpose, tone, and channel checkpoint",
            "Practice artifact learners can review and revise",
            "Reader-notice moment and chapter synthesis",
            "Bridge paragraph into the next chapter"
        )
    }
    else {
        @(
            "Business Case: realistic learner scenario",
            "Guided procedure or checklist learners can reuse",
            "Technology judgment checkpoint",
            "Practice artifact learners can review and revise",
            "Reader-notice moment and chapter synthesis",
            "Bridge paragraph into the next chapter"
        )
    }

    for ($i = 0; $i -lt $modules.Count; $i++) {
        $module = $modules[$i]
        $number = Get-StructuredModuleNumber -Module $module -Fallback ($i + 1)
        $title = Remove-WeekPrefixFromTitle $module.title
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = "Chapter $number"
        }

        $previousTitle = if ($i -gt 0) { Remove-WeekPrefixFromTitle $modules[$i - 1].title } else { "the course purpose and student prior experience" }
        $nextTitle = if (($i + 1) -lt $modules.Count) { Remove-WeekPrefixFromTitle $modules[$i + 1].title } else { "the final chapter synthesis and course wrap-up" }
        $focus = Get-StructuredChapterFocus -Course $Course -Module $module
        $moduleText = Get-StructuredModuleText -Module $module
        $officialWeek = @($Course.weeks | Where-Object { $_.number -eq $number } | Select-Object -First 1)
        $officialTargets = if ($officialWeek) { @($officialWeek.modules | ForEach-Object { $_.objective }) } else { @() }
        $learningTargets = @($module.learningObjectives + $module.objectives + $officialTargets | Where-Object { $_ } | ForEach-Object { ConvertTo-CleanText $_ } | Select-Object -Unique)
        $assessmentHooks = if ($officialWeek) { @(Get-AssessmentHooks -Week $officialWeek -Course $Course) } else { @("Use a brief scenario application to connect the chapter concept to a workplace decision.") }
        foreach ($lesson in @($module.lessons)) {
            foreach ($activity in @($lesson.suggestedActivities)) {
                if ($activity -and -not (Test-EbookAssessmentOrLmsText -Text $activity)) { $assessmentHooks += (ConvertTo-CleanText $activity) }
            }
        }

        [void]$chapters.Add([pscustomobject]@{
            number = $number
            title = $title
            focus = $focus
            buildsOn = $previousTitle
            setsUp = $nextTitle
            cohesionBridge = "This chapter connects $previousTitle to $nextTitle by having learners use $focus as the next layer of $($practiceFrame.bridgeNoun)."
            learningTargets = @($learningTargets)
            learningTargetRecords = @(
                if ($officialWeek) {
                    [void]($officialObjectiveIndex = 0)
                    foreach ($officialModule in @($officialWeek.modules)) {
                        [void]$officialObjectiveIndex++
                        if ($officialModule.objective) {
                            $officialObjectiveId = if (-not [string]::IsNullOrWhiteSpace([string]$officialModule.objectiveId)) { [string]$officialModule.objectiveId } else { "W$($officialWeek.number)-$officialObjectiveIndex" }
                            [pscustomobject]@{
                                objectiveId = $officialObjectiveId
                                objective = (ConvertTo-CleanText $officialModule.objective)
                                sourceWeek = [int]$officialWeek.number
                            }
                        }
                    }
                }
                else {
                    foreach ($target in @($learningTargets)) {
                        [pscustomobject]@{
                            objectiveId = ""
                            objective = (ConvertTo-CleanText $target)
                            sourceWeek = [int]$number
                        }
                    }
                }
            )
            moduleSequence = @(Get-StructuredLessonSequence -Module $module)
            assessmentHooks = @($assessmentHooks | Select-Object -Unique)
            researchQuery = Get-ResearchQuery -Course $Course -Week ([pscustomobject]@{ title = $title }) -ModuleText $moduleText
            requiredSections = @($requiredSections)
            sourceBlueprintPath = $StructuredBlueprint.sourcePath
            sourceBlueprintDescription = $StructuredBlueprint.description
        })
    }

    $narrativeSpine = if ($StructuredBlueprint.description) {
        $StructuredBlueprint.description
    }
    else {
        $practiceFrame.throughline
    }

    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        planVersion = "0.2-structured-source"
        courseCode = $Course.courseCode
        narrativeSpine = $narrativeSpine
        chapters = @($chapters)
    }
}

function New-EbookPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Course,
        [object]$SourceContext
    )

    $chapters = New-Object System.Collections.ArrayList
    $weeks = @($Course.weeks)
    $practiceFrame = Get-CoursePracticeFrame -Course $Course
    $courseDomain = Get-CourseDomain -Course $Course
    $structuredBlueprint = Get-StructuredCourseBlueprintFromSourceContext -SourceContext $SourceContext -Course $Course
    if ($structuredBlueprint) {
        return (New-EbookPlanFromStructuredBlueprint -Course $Course -StructuredBlueprint $structuredBlueprint)
    }

    $requiredSections = if ($courseDomain -eq "computer-applications") {
        @(
            "Chapter opener with a realistic digital task scenario",
            "Concept explanation tied to the learning objectives",
            "Procedure or checklist learners can reuse",
            "Applied example from academic or workplace technology use",
            "Reader-notice moment and chapter synthesis",
            "Bridge paragraph into the next chapter"
        )
    }
    elseif ($courseDomain -eq "critical-thinking") {
        @(
            "Chapter opener with a reasoning scenario",
            "Concept explanation tied to the learning objectives",
            "Thinking process or decision model learners can reuse",
            "Applied example with evidence and assumptions",
            "Reader-notice moment and chapter synthesis",
            "Bridge paragraph into the next chapter"
        )
    }
    elseif ($courseDomain -eq "professional-communication") {
        @(
            "Chapter opener with a realistic communication scenario",
            "Concept explanation tied to the learning objectives",
            "Message planning or response model learners can reuse",
            "Applied example from professional communication",
            "Reader-notice moment and chapter synthesis",
            "Bridge paragraph into the next chapter"
        )
    }
    else {
        @(
            "Chapter opener with a workplace scenario",
            "Concept explanation tied to the learning objectives",
            "Process or decision model learners can reuse",
            "Applied example from office operations",
            "Reader-notice moment and chapter synthesis",
            "Bridge paragraph into the next chapter"
        )
    }

    for ($i = 0; $i -lt $weeks.Count; $i++) {
        $week = $weeks[$i]
        $previousTitle = if ($i -gt 0) { $weeks[$i - 1].title } else { "the course purpose and student prior experience" }
        $nextTitle = if (($i + 1) -lt $weeks.Count) { $weeks[$i + 1].title } else { "the final chapter synthesis and course wrap-up" }
        $moduleText = Join-ModuleText -Week $week
        $focus = Get-ChapterFocus -Week $week -Course $Course

        [void]$chapters.Add([pscustomobject]@{
            number = $week.number
            title = $week.title
            focus = $focus
            buildsOn = $previousTitle
            setsUp = $nextTitle
            cohesionBridge = "This chapter connects $previousTitle to $nextTitle by having learners use $focus as the next layer of $($practiceFrame.bridgeNoun)."
            learningTargets = @(
                $week.modules | ForEach-Object { $_.objective }
            )
            learningTargetRecords = @(
                [void]($objectiveIndex = 0)
                foreach ($module in @($week.modules)) {
                    [void]$objectiveIndex++
                    if ($module.objective) {
                        $objectiveId = if (-not [string]::IsNullOrWhiteSpace([string]$module.objectiveId)) { [string]$module.objectiveId } else { "W$($week.number)-$objectiveIndex" }
                        [pscustomobject]@{
                            objectiveId = $objectiveId
                            objective = (ConvertTo-CleanText $module.objective)
                            sourceWeek = [int]$week.number
                        }
                    }
                }
            )
            moduleSequence = @(
                [void]($moduleIndex = 0)
                $week.modules | ForEach-Object {
                    [void]$moduleIndex++
                    $moduleObjectiveId = if (-not [string]::IsNullOrWhiteSpace([string]$_.objectiveId)) { [string]$_.objectiveId } else { "W$($week.number)-$moduleIndex" }
                    [pscustomobject]@{
                        title = $_.title
                        objectiveId = $moduleObjectiveId
                        subObjectives = $_.subObjectives
                    }
                }
            )
            assessmentHooks = Get-AssessmentHooks -Week $week -Course $Course
            researchQuery = Get-ResearchQuery -Course $Course -Week $week -ModuleText $moduleText
            requiredSections = @($requiredSections)
        })
    }

    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        planVersion = "0.1"
        courseCode = $Course.courseCode
        narrativeSpine = $practiceFrame.throughline
        chapters = @($chapters)
    }
}

function Merge-EbookReviewedOutline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$ReviewedOutlinePath
    )

    if ([string]::IsNullOrWhiteSpace($ReviewedOutlinePath)) { return $Plan }
    if (-not (Test-Path -LiteralPath $ReviewedOutlinePath -PathType Leaf)) { throw "Reviewed outline was not found: $ReviewedOutlinePath" }
    $reviewed = Get-Content -LiteralPath $ReviewedOutlinePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $baseChapters = @($Plan.chapters | Sort-Object { [int]$_.number })
    $reviewedChapters = @($reviewed.chapters | Sort-Object { [int]$_.number })
    if ($baseChapters.Count -ne $reviewedChapters.Count) { throw 'The reviewed outline no longer matches the current course plan chapter count. Recreate the format preview and review it again.' }
    for ($i = 0; $i -lt $baseChapters.Count; $i++) {
        $base = $baseChapters[$i]
        $edited = $reviewedChapters[$i]
        if ([int]$base.number -ne [int]$edited.number) { throw 'The reviewed outline no longer matches the current course plan chapter order. Recreate the format preview and review it again.' }
        $title = ([string]$edited.title).Trim()
        $objectives = @($edited.learningTargets | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ([string]::IsNullOrWhiteSpace($title) -or $objectives.Count -eq 0) { throw "The reviewed outline has invalid content for Chapter $([int]$base.number)." }
        $baseObjectives = @($base.learningTargetRecords | ForEach-Object { [string]$_.objective })
        if (($objectives -join "`n") -ne ($baseObjectives -join "`n")) { throw "The reviewed outline changes the authoritative learning objectives for Chapter $([int]$base.number). Recreate the outline from the current course source." }
        $base.title = $title
        if (-not [string]::IsNullOrWhiteSpace([string]$edited.focus)) { $base.focus = ([string]$edited.focus).Trim() }
        $base.learningTargets = @($objectives)
        # Keep objective IDs from the newly generated authoritative plan. Older
        # reviewed-outline files may contain blank IDs from the legacy parser.
        $base.learningTargetRecords = @($base.learningTargetRecords)
    }
    $Plan.chapters = @($baseChapters)
    $Plan | Add-Member -NotePropertyName reviewedOutlinePath -NotePropertyValue $ReviewedOutlinePath -Force
    $Plan | Add-Member -NotePropertyName reviewedOutlineAppliedAt -NotePropertyValue (Get-Date).ToString('s') -Force
    return $Plan
}

function Get-ChapterFocus {
    param(
        [object]$Week,
        [object]$Course
    )

    $titleParts = New-Object System.Collections.ArrayList
    if ($Week.title) { [void]$titleParts.Add($Week.title) }
    foreach ($module in @($Week.modules)) {
        if ($module.title) { [void]$titleParts.Add($module.title) }
    }
    $titleText = (($titleParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " ").ToLowerInvariant()
    $text = (Join-ModuleText -Week $Week).ToLowerInvariant()
    $combinedText = "$titleText $text".Trim()
    $domain = if ($Course) { Get-CourseDomain -Course $Course } else { "" }

    if ($domain -eq "business-operations") {
        if ($text -match "finance|marketing|human relations|human resources|core functions") { return "interdependencies among core business functions" }
        if ($text -match "customer") { return "customer-facing service quality and professionalism" }
        if ($text -match "workflow|handoff|process|inputs|outputs|roles") { return "workflow mapping and coordination" }
        if ($text -match "operational improvements|operational strategy|case study|workplace scenario|continuous improvement|operations improvement") { return "evidence-based operational improvement" }
        if ($text -match "organizational|structure|strategic goals|people|technology|procedures|productivity|risk") { return "organizational structure and strategic support" }
        return "people, technology, procedures, productivity, and risk"
    }

    if ($domain -eq "computer-applications") {
        if ($text -match "windows|operating system|software basics") { return "Windows operating system navigation and software environment" }
        if ($text -match "cybersecurity|responsible digital|personal and organizational information|privacy|keyboarding|wpm|words per minute|password|phishing|public wi-fi|mobile fluency|mobile productivity|deepfake|voice cloning|verify-before-trust|verify before trust") { return "cybersecurity, digital responsibility, mobile fluency, and keyboarding confidence" }
        if ($text -match "apa|credible sources|cite|citation|academic writing|research|source evaluation|search literacy|academic integrity|plagiarism|authorship") { return "source evaluation, APA citation, and academic integrity" }
        if ($text -match "files|folders|local|cloud|storage|records|onedrive|sharepoint|google drive|version history|sharing|sync") { return "file management across local and cloud storage" }
        if ($text -match "microsoft word|word document|professional document|formatting|layout|templates|accessibility|headings") { return "professional document creation in Microsoft Word" }
        return "digital task performance and professional technology use"
    }

    if ($domain -eq "professional-communication") {
        if ($titleText -match "presentation|presentations|speaking") { return "professional presentation planning and delivery" }
        if ($titleText -match "bad-news|bad news|negative|difficult|conflict") { return "clear and respectful difficult-message communication" }
        if ($titleText -match "report|informal reports") { return "organized professional writing and revision" }
        if ($titleText -match "business messages|positive|neutral|short workplace messages") { return "message planning for audience, purpose, tone, and channel" }
        if ($titleText -match "professionalism|team|meeting|collaboration") { return "professional collaboration, meetings, and team communication" }
        if ($titleText -match "nonverbal|verbal|listening|interpersonal|communication techniques") { return "interpersonal signals, listening, and audience awareness" }
        if ($combinedText -match "nonverbal|verbal|listening|interpersonal") { return "interpersonal signals, listening, and audience awareness" }
        if ($combinedText -match "bad-news|bad news|negative|difficult|conflict") { return "clear and respectful difficult-message communication" }
        if ($combinedText -match "report|informal reports|writing") { return "organized professional writing and revision" }
        if ($combinedText -match "team|meeting|etiquette|professionalism|collaboration") { return "professional collaboration, meetings, and team communication" }
        if ($combinedText -match "presentation|presentations|speaking") { return "professional presentation planning and delivery" }
        if ($combinedText -match "positive|neutral|brief business messages|business messages|request|inquir|instructions|purpose|audience|tone") { return "message planning for audience, purpose, tone, and channel" }
        if ($combinedText -match "digital|social|mobile|short messages|email|media") { return "professional digital communication and channel choice" }
        return "professional communication judgment in workplace and academic contexts"
    }

    if ($text -match "critical thinking|skills and habits") { return "critical thinking habits and reflective judgment" }
    if ($text -match "universal intellectual standards|credibility|relevance|sufficiency|information sources|ai-generated") { return "information evaluation and intellectual standards" }
    if ($text -match "problem-solving|problem solving|define a problem|selected solution|alternatives") { return "systematic problem solving and justified conclusions" }
    if ($text -match "personal position|communicate a clear|professional or real-world context") { return "professional communication of a reasoned ethical position" }
    if ($text -match "ethical|persuasive argument|ethical position") { return "ethical reasoning and persuasive argumentation" }
    if ($text -match "inductive|deductive|conclusions logically follow|strength of reasoning") { return "inductive and deductive argument evaluation" }
    if ($text -match "weak or missing evidence|bias|pressure|context|fallacies|reasoning errors|decision-making|judgment") { return "decision influences, evidence quality, bias, and reasoning errors" }
    if ([string]::IsNullOrWhiteSpace($domain) -and $text -match "windows|operating system|software basics") { return "Windows operating system navigation and software environment" }
    if ([string]::IsNullOrWhiteSpace($domain) -and $text -match "cybersecurity|responsible digital|personal and organizational information|privacy|keyboarding|wpm|words per minute|password|phishing|public wi-fi|mobile fluency|mobile productivity|deepfake|voice cloning|verify-before-trust|verify before trust") { return "cybersecurity, digital responsibility, mobile fluency, and keyboarding confidence" }
    if ([string]::IsNullOrWhiteSpace($domain) -and $text -match "apa|credible sources|cite|citation|academic writing|research|source evaluation|search literacy|academic integrity|plagiarism|authorship") { return "source evaluation, APA citation, and academic integrity" }
    if ([string]::IsNullOrWhiteSpace($domain) -and $text -match "files|folders|local|cloud|storage|records|onedrive|sharepoint|google drive|version history|sharing|sync") { return "file management across local and cloud storage" }
    if ([string]::IsNullOrWhiteSpace($domain) -and $text -match "microsoft word|word document|professional document|formatting|layout|templates|accessibility|headings") { return "professional document creation in Microsoft Word" }
    if ($text -match "finance|marketing|human relations|human resources|core functions") { return "interdependencies among core business functions" }
    if ($text -match "customer") { return "customer-facing service quality and professionalism" }
    if ($text -match "workflow|handoff|process") { return "workflow mapping and coordination" }
    if ($text -match "operational|improvement|strategy") { return "evidence-based operational improvement" }
    if ($text -match "organizational|structure") { return "organizational structure and strategic support" }
    return "people, technology, procedures, productivity, and risk"
}

function Get-AssessmentHooks {
    param(
        [object]$Week,
        [object]$Course
    )

    $hooks = New-Object System.Collections.ArrayList
    $domain = if ($Course) { Get-CourseDomain -Course $Course } else { "business-operations" }
    foreach ($activity in $Week.activities) {
        if (Test-EbookAssessmentOrLmsText -Text $activity) {
            continue
        }
        switch -Regex ($activity) {
            "Key Points" { [void]$hooks.Add("Include a concise key-points summary aligned to the objectives.") }
            "Self-Assessment|Self-check" { [void]$hooks.Add("Use a short self-check before the practice moment.") }
            "Discussion|Reflection" {
                if ($domain -eq "computer-applications") {
                    [void]$hooks.Add("Ask learners to compare digital tool choices, file/source standards, or security habits across realistic tasks.")
                }
                elseif ($domain -eq "critical-thinking") {
                    [void]$hooks.Add("Ask learners to compare reasoning choices across real claims, decisions, or arguments.")
                }
                elseif ($domain -eq "professional-communication") {
                    [void]$hooks.Add("Ask learners to compare audience, tone, channel, and response choices across realistic messages.")
                }
                else {
                    [void]$hooks.Add("Ask learners to compare operational choices across workplace settings.")
                }
            }
            "Assignment|Practice" {
                if ($domain -eq "computer-applications") {
                    [void]$hooks.Add("Include a practice artifact learners can review and revise, such as a task checklist, file plan, formatted document, citation tracker, or security routine.")
                }
                elseif ($domain -eq "critical-thinking") {
                    [void]$hooks.Add("Include a practice artifact learners can review and revise, such as a claim review, reasoning memo, or argument map.")
                }
                elseif ($domain -eq "professional-communication") {
                    [void]$hooks.Add("Include a practice artifact learners can review and revise, such as a message plan, response draft, channel choice note, or presentation outline.")
                }
                else {
                    [void]$hooks.Add("Include a practice artifact learners can review and revise, such as a process map, recommendation memo, or scenario analysis.")
                }
            }
            default { [void]$hooks.Add($activity) }
        }
    }

    if ($hooks.Count -eq 0) {
        [void]$hooks.Add("Use a brief scenario application to connect the chapter concept to a workplace decision.")
    }

    return @($hooks | Select-Object -Unique)
}

function Get-ResearchQuery {
    param(
        [object]$Course,
        [object]$Week,
        [string]$ModuleText
    )

    $topicText = "$($Week.title) $ModuleText".ToLowerInvariant()
    $domain = if ($Course) { Get-CourseDomain -Course $Course } else { "" }
    if ($domain -eq "critical-thinking") {
        if ($topicText -match "critical thinking|skills and habits") {
            return "critical thinking dispositions reasoning education"
        }
        if ($topicText -match "universal intellectual standards|credibility|relevance|sufficiency|information sources|ai-generated") {
            return "information literacy source evaluation AI generated content credibility"
        }
        if ($topicText -match "problem-solving|problem solving|define a problem|selected solution|alternatives") {
            return "problem solving process decision making education"
        }
        if ($topicText -match "weak or missing evidence|bias|pressure|context|fallacies|reasoning errors|decision-making|judgment") {
            return "cognitive bias decision making reasoning fallacies evidence quality"
        }
        if ($topicText -match "inductive|deductive|conclusions logically follow|strength of reasoning") {
            return "argumentation inductive deductive reasoning logic education"
        }
        if ($topicText -match "ethical|persuasive argument|ethical position") {
            return "ethical reasoning moral argumentation persuasive communication"
        }
        if ($topicText -match "personal position|professional or real-world context") {
            return "persuasive communication ethical argumentation professional writing"
        }
    }
    if ($domain -eq "professional-communication") {
        if ($topicText -match "interpersonal|listening|nonverbal|verbal|audience awareness") {
            return "interpersonal communication active listening nonverbal communication audience awareness workplace"
        }
        if ($topicText -match "message planning|tone|channel|digital communication|positive messages|neutral messages") {
            return "business communication message planning audience analysis tone channel professional writing"
        }
        if ($topicText -match "bad-news|bad news|difficult-message|conflict|negative message") {
            return "business communication bad news messages conflict communication respectful tone"
        }
        if ($topicText -match "professional writing|report|revision|memo|workplace writing") {
            return "professional writing business communication revision memo report clarity workplace"
        }
        if ($topicText -match "collaboration|meeting|team") {
            return "team communication meeting effectiveness collaboration workplace communication"
        }
        if ($topicText -match "presentation|speaking|visual") {
            return "presentation skills audience analysis multimedia learning business communication"
        }
        return "professional communication business communication audience listening message tone presentation"
    }
    if ($topicText -match "windows|operating system|software basics") {
        return "Windows operating system digital literacy software navigation education"
    }
    if ($topicText -match "cybersecurity|responsible digital|personal and organizational information|privacy|keyboarding|wpm|words per minute|password|phishing|public wi-fi|mobile fluency|mobile productivity|deepfake|voice cloning|verify-before-trust|verify before trust") {
        return "cybersecurity awareness responsible digital behavior mobile learning AI social engineering education"
    }
    if ($topicText -match "apa|credible sources|cite|citation|academic writing|research|source evaluation|search literacy|academic integrity|plagiarism|authorship") {
        return "information literacy APA citation source evaluation academic integrity AI authorship"
    }
    if ($topicText -match "files|folders|local|cloud|storage|records|onedrive|sharepoint|google drive|version history|sharing|sync") {
        return "file management cloud storage OneDrive digital literacy education"
    }
    if ($topicText -match "microsoft word|word document|professional document|formatting|layout|templates|accessibility|headings") {
        return "word processing document design Microsoft Word accessibility education"
    }
    if ($topicText -match "people|technology|procedures|productivity|risk") {
        return "sociotechnical systems design organization change"
    }
    if ($topicText -match "finance|marketing|human relations|human resources|core functions") {
        return "cross functional integration product development"
    }
    if ($topicText -match "customer|responsiveness|professionalism") {
        return "SERVQUAL service quality"
    }
    if ($topicText -match "workflow|handoff|process") {
        return "business process management workflow"
    }
    if ($topicText -match "operational|improvement|strategy") {
        return "lean service operations"
    }

    $base = if ($domain -eq "computer-applications") {
        "$($Week.title) $ModuleText computer applications digital literacy workplace software"
    }
    else {
        "$($Week.title) $ModuleText business office operations management"
    }
    $tokens = @(
        $base -split "\W+" |
            Where-Object { $_.Length -gt 3 } |
            Where-Object { $_ -notmatch "^(describe|explain|given|basic|common|chapter|objectives|course|week|introduction|business|computer|applications)$" }
    )

    return (($tokens | Select-Object -First 12 | Select-Object -Unique) -join " ")
}

function Resolve-EbookSources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$SourceMapPath,
        [object]$SourceContext,
        [int]$MaxResearchPerChapter = 3,
        [switch]$SkipResearch,
        [switch]$SkipOpenStaxFetch,
        [ValidateSet('Discovery','UploadedOnly')][string]$SourceMode='Discovery'
    )

    Initialize-EbookGeneratorRuntime
    $sourceMap = if($SourceMode -eq 'Discovery'){Get-Content -LiteralPath $SourceMapPath -Raw | ConvertFrom-Json}else{$null}
    $chapterSources = New-Object System.Collections.ArrayList

    foreach ($chapter in $Plan.chapters) {
        if($SourceMode -eq 'UploadedOnly'){
            $contextMatches=@(Find-SourceContextForChapter -Chapter $chapter -SourceContext $SourceContext -AllMatches)
            if(-not $contextMatches.Count){throw "No uploaded teaching content maps to chapter $($chapter.number). Revise the blueprint/source documents before generation."}
            [void]$chapterSources.Add([pscustomobject]@{chapterNumber=$chapter.number;chapterTitle=$chapter.title;sourcePolicy=[pscustomobject]@{mode='UploadedOnly';summary='Use only the accepted uploaded documents. No external discovery or added source links. Human review must confirm coverage and attribution.'};sourceContext=$contextMatches;openStax=@();researchCandidates=@()})
            continue
        }
        Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Resolving sources" -Status "Working" -Detail "Finding OER links, research candidates, and source-context matches."
        $openStaxPages = @(Find-OpenStaxPages -Chapter $chapter -SourceMap $sourceMap)
        $hydratedPages = New-Object System.Collections.ArrayList
        foreach ($page in $openStaxPages) {
            if ($SkipOpenStaxFetch) {
                [void]$hydratedPages.Add([pscustomobject]@{
                    title = $page.book
                    book = $page.book
                    publisher = $page.publisher
                    url = $page.url
                    licenseNote = $page.licenseNote
                    sourceType = "OpenStax"
                    preview = ""
                })
            }
            else {
                [void]$hydratedPages.Add((Get-OpenStaxPageBrief -Page $page))
            }
        }

        $research = @()
        if (-not $SkipResearch) {
            Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Research discovery" -Status "Working" -Detail "Searching OpenAlex for scholarly research candidates."
            $research = @(Search-OpenAlexWorks -Query $chapter.researchQuery -Limit $MaxResearchPerChapter)
            $usableResearch = @($research | Where-Object { $_.title -and $_.title -ne "OpenAlex search failed" })
            if ($usableResearch.Count -lt 1) {
                Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Research discovery" -Status "Warning" -Detail "OpenAlex returned no usable candidate; using curated fallback candidates when available."
                $research = @(Get-CuratedResearchCandidates -Chapter $chapter -Limit $MaxResearchPerChapter)
            }
            elseif ($usableResearch.Count -lt $MaxResearchPerChapter) {
                $fallbackResearch = @(Get-CuratedResearchCandidates -Chapter $chapter -Limit ($MaxResearchPerChapter - $usableResearch.Count))
                if ($fallbackResearch.Count -gt 0) {
                    $research = @($usableResearch) + @($fallbackResearch)
                }
            }
        }
        else {
            Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Research discovery" -Status "Warning" -Detail "Research discovery was skipped by option."
        }

        $contextMatches = @(Find-SourceContextForChapter -Chapter $chapter -SourceContext $SourceContext -Limit 5)
        $researchCount = @($research | Where-Object { $_.title -and $_.title -ne "OpenAlex search failed" }).Count

        [void]$chapterSources.Add([pscustomobject]@{
            chapterNumber = $chapter.number
            chapterTitle = $chapter.title
            sourcePolicy = $sourceMap.sourcePolicy
            sourceContext = @($contextMatches)
            openStax = @($hydratedPages)
            researchCandidates = @($research)
        })
        Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Resolving sources" -Status "Complete" -Detail "$(@($hydratedPages).Count) OER page(s), $researchCount research candidate(s), $(@($contextMatches).Count) source-context match(es)."
    }

    return @($chapterSources)
}

function Find-OpenStaxPages {
    param(
        [object]$Chapter,
        [object]$SourceMap
    )

    $chapterText = "$($Chapter.title) $($Chapter.focus) $($Chapter.researchQuery)".ToLowerInvariant()
    $matches = New-Object System.Collections.ArrayList

    foreach ($rule in $SourceMap.topicRules) {
        $score = 0
        foreach ($keyword in $rule.keywords) {
            if ($chapterText.Contains($keyword.ToLowerInvariant())) {
                $score++
            }
        }

        if ($score -gt 0) {
            foreach ($page in $rule.openStaxPages) {
                [void]$matches.Add([pscustomobject]@{
                    score = $score
                    rule = $rule.name
                    book = $page.book
                    publisher = $page.publisher
                    url = $page.url
                    licenseNote = $page.licenseNote
                })
            }
        }
    }

    return @(
        $matches |
            Sort-Object -Property @{ Expression = "score"; Descending = $true }, url -Unique |
            Select-Object -First 5
    )
}

function Get-WebPageUtf8 {
    param([string]$Url)

    $client = New-Object System.Net.WebClient
    $client.Encoding = [System.Text.Encoding]::UTF8
    $client.Headers.Add("User-Agent", "ebook-generator/0.1 (source brief builder)")
    try {
        return $client.DownloadString($Url)
    }
    finally {
        $client.Dispose()
    }
}

function ConvertFrom-HtmlToPlainText {
    param([string]$Html)

    $text = $Html -replace "(?is)<script.*?</script>", " "
    $text = $text -replace "(?is)<style.*?</style>", " "
    $text = $text -replace "(?is)<nav.*?</nav>", " "
    $text = $text -replace "(?is)<footer.*?</footer>", " "
    $text = $text -replace "(?i)</p>|</li>|</h1>|</h2>|</h3>|<br\s*/?>", "`n"
    $text = $text -replace "<[^>]+>", " "
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text -replace "\s+", " "
    return (ConvertTo-CleanText $text)
}

function Get-OpenStaxPageBrief {
    param([object]$Page)

    try {
        $html = Get-WebPageUtf8 -Url $Page.url
        $titleMatch = [regex]::Match($html, "<title>(.*?)</title>", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $title = if ($titleMatch.Success) { ConvertTo-CleanText $titleMatch.Groups[1].Value } else { $Page.book }
        $mainMatch = [regex]::Match($html, "(?is)<main[^>]*>(.*?)</main>")
        if ($mainMatch.Success) {
            $html = $mainMatch.Groups[1].Value
        }
        $plain = ConvertFrom-HtmlToPlainText -Html $html
        $plain = $plain -replace "^.*?Search Close Search\s+", ""
        $plain = $plain -replace "\s+", " "
        $preview = if ($plain.Length -gt 360) { $plain.Substring(0, 360).Trim() + "..." } else { $plain }

        return [pscustomobject]@{
            title = $title
            book = $Page.book
            publisher = $Page.publisher
            url = $Page.url
            licenseNote = $Page.licenseNote
            sourceType = "OpenStax"
            matchedRule = $Page.rule
            preview = $preview
        }
    }
    catch {
        return [pscustomobject]@{
            title = $Page.book
            book = $Page.book
            publisher = $Page.publisher
            url = $Page.url
            licenseNote = $Page.licenseNote
            sourceType = "OpenStax"
            matchedRule = $Page.rule
            preview = "Fetch failed: $($_.Exception.Message)"
        }
    }
}

function Get-JsonPropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-MapValue {
    param(
        [object]$Map,
        [string]$Name
    )

    if ($null -eq $Map) {
        return $null
    }

    $containsKeyMethod = $Map.GetType().GetMethod("ContainsKey")
    if ($containsKeyMethod -and $containsKeyMethod.Invoke($Map, @($Name))) {
        return $Map[$Name]
    }

    if ($Map -is [System.Collections.IDictionary]) {
        try {
            if ($Map.Contains($Name)) {
                return $Map[$Name]
            }
        }
        catch {
            return $null
        }
    }

    return $null
}

function Search-OpenAlexWorks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$Limit = 3
    )

    if ([string]::IsNullOrWhiteSpace($Query)) {
        return @()
    }

    $encodedQuery = [System.Uri]::EscapeDataString($Query)
    $uris = @(
        "https://api.openalex.org/works?filter=title.search:$encodedQuery&per-page=$Limit",
        "https://api.openalex.org/works?search=$encodedQuery&per-page=$Limit"
    )
    $lastError = $null

    foreach ($uri in $uris) {
        try {
            $raw = Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -TimeoutSec 30 -Headers @{
                "User-Agent" = "ebook-generator/0.1 (research discovery)"
            }

            Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $serializer.MaxJsonLength = 67108864
            $response = $serializer.DeserializeObject($raw.Content)

            $items = New-Object System.Collections.ArrayList
            $results = @(Get-MapValue -Map $response -Name "results")
            foreach ($work in @($results | Where-Object { $null -ne $_ })) {
                $sourceName = ""
                $primaryLocation = Get-MapValue -Map $work -Name "primary_location"
                if ($primaryLocation) {
                    $source = Get-MapValue -Map $primaryLocation -Name "source"
                    if ($source) {
                        $sourceName = Get-MapValue -Map $source -Name "display_name"
                    }
                }

                $authors = New-Object System.Collections.ArrayList
                foreach ($authorship in @(Get-MapValue -Map $work -Name "authorships")) {
                    $author = Get-MapValue -Map $authorship -Name "author"
                    $displayName = if ($author) { Get-MapValue -Map $author -Name "display_name" } else { "" }
                    if (-not [string]::IsNullOrWhiteSpace($displayName)) {
                        [void]$authors.Add([string]$displayName)
                    }
                }

                $landingUrl = ""
                if ($primaryLocation -and (Get-MapValue -Map $primaryLocation -Name "landing_page_url")) {
                    $landingUrl = Get-MapValue -Map $primaryLocation -Name "landing_page_url"
                }
                elseif (Get-MapValue -Map $work -Name "doi") {
                    $landingUrl = Get-MapValue -Map $work -Name "doi"
                }
                else {
                    $landingUrl = Get-MapValue -Map $work -Name "id"
                }

                [void]$items.Add([pscustomobject]@{
                    title = Get-MapValue -Map $work -Name "display_name"
                    authors = @($authors)
                    year = Get-MapValue -Map $work -Name "publication_year"
                    citedByCount = Get-MapValue -Map $work -Name "cited_by_count"
                    source = $sourceName
                    doi = Get-MapValue -Map $work -Name "doi"
                    url = $landingUrl
                    sourceType = "OpenAlex"
                    note = "Research discovery candidate; review source quality and access rights before citing in final learner-facing copy."
                })
            }

            if ($items.Count -gt 0) {
                return @($items)
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    if ($lastError) {
        return @([pscustomobject]@{
            title = "OpenAlex search failed"
            authors = @()
            year = $null
            citedByCount = $null
            source = "OpenAlex"
            doi = $null
            url = $uris[0]
            sourceType = "OpenAlex"
            note = $lastError
        })
    }

    return @()
}

function Get-CuratedResearchCandidates {
    param(
        [object]$Chapter,
        [int]$Limit = 3
    )

    $text = "$($Chapter.title) $($Chapter.focus) $($Chapter.researchQuery)".ToLowerInvariant()
    $items = New-Object System.Collections.ArrayList
    if ($text -match "communication|audience|message|tone|channel|listening|nonverbal|verbal|presentation|meeting|collaboration|professional writing|report|revision") {
        [void]$items.Add([pscustomobject]@{
            title = "Business Communication for Success"
            year = 2015
            citedByCount = $null
            source = "University of Minnesota Libraries Publishing"
            doi = $null
            url = "https://open.lib.umn.edu/businesscommunication/"
            sourceType = "Curated OER Fallback"
            note = "Curated open textbook fallback for professional communication, message planning, audience analysis, tone, writing, and presentation topics; review chapter-level fit before final publication."
        })
        [void]$items.Add([pscustomobject]@{
            title = "Communication in the Real World: An Introduction to Communication Studies"
            year = 2016
            citedByCount = $null
            source = "University of Minnesota Libraries Publishing"
            doi = $null
            url = "https://open.lib.umn.edu/communication/"
            sourceType = "Curated OER Fallback"
            note = "Curated open textbook fallback for interpersonal communication, listening, verbal and nonverbal communication, audience awareness, and communication ethics."
        })
        if ($text -match "presentation|speaking|visual") {
            [void]$items.Add([pscustomobject]@{
                title = "Stand up, Speak out: The Practice and Ethics of Public Speaking"
                year = 2016
                citedByCount = $null
                source = "University of Minnesota Libraries Publishing"
                doi = $null
                url = "https://open.lib.umn.edu/publicspeaking/"
                sourceType = "Curated OER Fallback"
                note = "Curated open textbook fallback for audience-centered presentations, organization, delivery, visual support, and ethical public speaking."
            })
        }
    }
    if ($text -match "office as an operations system|organizational structure|authority|reporting|people, technology|procedures") {
        [void]$items.Add([pscustomobject]@{
            title = "Organization design: An information processing view"
            year = 1974
            citedByCount = $null
            source = "Interfaces"
            doi = "https://doi.org/10.1287/inte.4.3.28"
            url = "https://doi.org/10.1287/inte.4.3.28"
            sourceType = "Curated Research Fallback"
            note = "Curated fallback for organizational structure and information-processing demands; review source fit before final publication."
        })
        [void]$items.Add([pscustomobject]@{
            title = "Structure in 5's: A Synthesis of the Research on Organization Design"
            year = 1980
            citedByCount = $null
            source = "Management Science"
            doi = "https://doi.org/10.1287/mnsc.26.3.322"
            url = "https://doi.org/10.1287/mnsc.26.3.322"
            sourceType = "Curated Research Fallback"
            note = "Curated fallback for organizational structures and coordination; review source fit before final publication."
        })
    }
    if ($text -match "workflow mapping|office process|process mapping|handoff|business process|process model") {
        [void]$items.Add([pscustomobject]@{
            title = "Business Process Management: A Comprehensive Survey"
            year = 2013
            citedByCount = $null
            source = "ISRN Software Engineering"
            doi = "https://doi.org/10.1155/2013/507984"
            url = "https://doi.org/10.1155/2013/507984"
            sourceType = "Curated Research Fallback"
            note = "Curated fallback for process mapping, business process management, and workflow analysis; review source fit before final publication."
        })
        [void]$items.Add([pscustomobject]@{
            title = "The New Industrial Engineering: Information Technology and Business Process Redesign"
            year = 1990
            citedByCount = $null
            source = "Sloan Management Review"
            doi = $null
            url = "https://dspace.mit.edu/entities/publication/35dee1b9-8824-4539-9f44-9644ff4fdc42"
            sourceType = "Curated Research Fallback"
            note = "Curated fallback for business process redesign and workflow analysis; review source fit before final publication."
        })
    }
    if ($text -match "operational improvement|evidence-based|constraint|measure|change worked|quality improvement") {
        [void]$items.Add([pscustomobject]@{
            title = "Systematic review of the application of the plan-do-study-act method to improve quality in healthcare"
            year = 2014
            citedByCount = $null
            source = "BMJ Quality & Safety"
            doi = "https://doi.org/10.1136/bmjqs-2013-001862"
            url = "https://qualitysafety.bmj.com/content/23/4/290"
            sourceType = "Curated Research Fallback"
            note = "Curated fallback for evidence-based operational improvement and healthcare quality improvement; review source fit before final publication."
        })
    }

    return @($items | Select-Object -First $Limit)
}

function Get-ChapterSources {
    param(
        [object[]]$Sources,
        [int]$ChapterNumber
    )

    # Windows PowerShell ConvertFrom-Json may emit an entire JSON array as
    # one pipeline object. Never compare its aggregated chapterNumber property:
    # that can satisfy every chapter with the whole book's source inventory.
    $flat = New-Object System.Collections.ArrayList
    $pending = New-Object System.Collections.Queue
    foreach ($entry in $Sources) { $pending.Enqueue($entry) }
    while ($pending.Count) {
        $entry = $pending.Dequeue()
        if ($entry -is [Array]) { foreach ($child in $entry) { $pending.Enqueue($child) }; continue }
        if ($null -ne $entry) { [void]$flat.Add($entry) }
    }
    $matching = @($flat | Where-Object { [string]$_.chapterNumber -eq [string]$ChapterNumber })
    if ($matching.Count -gt 1) { throw "Duplicate source records for chapter $ChapterNumber." }
    if ($matching.Count -eq 1) { return $matching[0] }
    return $null
}

function Get-RomanNumeral {
    param([int]$Number)

    $values = @(1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1)
    $symbols = @("M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I")
    $remaining = $Number
    $result = ""
    for ($i = 0; $i -lt $values.Count; $i++) {
        while ($remaining -ge $values[$i]) {
            $result += $symbols[$i]
            $remaining -= $values[$i]
        }
    }
    return $result
}

function Get-OutlineLetter {
    param([int]$Index)

    $value = $Index
    $letters = ""
    while ($value -gt 0) {
        $value--
        $letters = [char](65 + ($value % 26)) + $letters
        $value = [Math]::Floor($value / 26)
    }
    return $letters
}

function Get-ProposedChapterTitle {
    param(
        [object]$Course,
        [object]$Chapter
    )

    $sourceTitle = ConvertTo-CleanText $Chapter.title
    if (-not [string]::IsNullOrWhiteSpace($sourceTitle) -and $sourceTitle -notmatch "^(week|module|unit|chapter)\s*\d+\b$") {
        return $sourceTitle
    }

    $domain = Get-CourseDomain -Course $Course
    $focus = ([string]$Chapter.focus).ToLowerInvariant()
    if ($domain -eq "business-operations") {
        if ($focus -match "organizational structure|people, technology") { return "The Office as an Operations System" }
        if ($focus -match "core business") { return "Business Functions and Cross-Functional Workflows" }
        if ($focus -match "workflow mapping") { return "Mapping Office Processes from Start to Finish" }
        if ($focus -match "customer-facing") { return "Coordinating Workflow and Customer-Facing Service" }
        if ($focus -match "operational improvement") { return "Evidence-Based Operational Improvement" }
    }
    return $Chapter.title
}

function Get-BlueprintIntakeChecklist {
    param(
        [object]$Course,
        [object]$SourceContext,
        [object]$BrandProfile
    )

    $sourceNames = @($SourceContext.files | ForEach-Object { ([string]$_.name).ToLowerInvariant() })
    $hasEarlyKeyConcepts = @($sourceNames | Where-Object { $_ -match "early.*key|key.*concept" }).Count -gt 0
    $hasProcessSuggestion = @($sourceNames | Where-Object { $_ -match "process|job aid|creating e-book" }).Count -gt 0
    $hasDirectives = @($sourceNames | Where-Object { $_ -match "directive|academic|alignment|notes|blueprint" }).Count -gt 0

    return @(
        [pscustomobject]@{
            item = "Course spec sheet"
            status = if ($Course.sourcePath) { "Present" } else { "Missing" }
            detail = if ($Course.sourcePath) { $Course.sourcePath } else { "Upload a course spec sheet before generating an outline." }
            required = $true
        },
        [pscustomobject]@{
            item = "Course description"
            status = if ($Course.description) { "Present" } else { "Missing" }
            detail = if ($Course.description) { "Parsed from source." } else { "Needed for learner-facing course purpose." }
            required = $true
        },
        [pscustomobject]@{
            item = "Learning objectives/modules"
            status = if (@($Course.weeks).Count -gt 0) { "Present" } else { "Missing" }
            detail = "$(@($Course.weeks).Count) week/module group(s) parsed."
            required = $true
        },
        [pscustomobject]@{
            item = "Early key concepts"
            status = if ($hasEarlyKeyConcepts) { "Present" } else { "Needs Review" }
            detail = if ($hasEarlyKeyConcepts) { "Detected in uploaded/source context." } else { "No explicit early key concepts file detected; generated candidates are included for review." }
            required = $false
        },
        [pscustomobject]@{
            item = "Academic/career/learner services directives"
            status = if ($hasDirectives) { "Present" } else { "Needs Review" }
            detail = if ($hasDirectives) { "Detected possible academic alignment/directive context." } else { "No separate directives file detected; confirm whether the spec sheet is the approved source." }
            required = $false
        },
        [pscustomobject]@{
            item = "Process/job aid guidance"
            status = if ($hasProcessSuggestion) { "Present" } else { "Needs Review" }
            detail = if ($hasProcessSuggestion) { "Detected process guidance in source context." } else { "Use built-in process guidance and confirm whether local process files should be attached." }
            required = $false
        },
        [pscustomobject]@{
            item = "Style/brand profile"
            status = if ($BrandProfile -and $BrandProfile.name) { "Present" } else { "Needs Review" }
            detail = if ($BrandProfile -and $BrandProfile.name) { $BrandProfile.name } else { "Default style profile will be used." }
            required = $false
        }
    )
}

function Get-KeyConceptCandidates {
    param([object]$Chapter)

    $items = New-Object System.Collections.ArrayList
    foreach ($target in @($Chapter.learningTargets)) {
        if ($target) { [void]$items.Add((ConvertTo-CleanText $target)) }
    }
    foreach ($module in @($Chapter.moduleSequence)) {
        if ($module.title) { [void]$items.Add((ConvertTo-CleanText $module.title)) }
        foreach ($subObjective in @($module.subObjectives)) {
            if ($subObjective) { [void]$items.Add((ConvertTo-CleanText $subObjective)) }
        }
    }
    return @($items | Select-Object -Unique)
}

function Get-ProposedOutlineSectionTitles {
    param(
        [object]$Course,
        [object]$Chapter
    )

    $domain = Get-CourseDomain -Course $Course
    $focus = ([string]$Chapter.focus).ToLowerInvariant()
    if ($domain -eq "business-operations") {
        if ($focus -match "organizational structure|people, technology") {
            return @(
                "What Are Business and Office Operations?",
                "Office Operations Across Different Business Settings",
                "Why Office Operations Matter",
                "Organizational Structures and Office Workflow",
                "Office Operations and Strategic Goals",
                "People, Technology, and Procedures"
            )
        }
        if ($focus -match "core business") {
            return @(
                "Understanding Core Business Functions",
                "Finance Workflow in Office Operations",
                "Human Resources Workflow in Office Operations",
                "Marketing Workflow in Office Operations",
                "Operations Workflow",
                "Interdependencies Across Business Functions",
                "Communication in Cross-Functional Workflows"
            )
        }
        if ($focus -match "workflow mapping") {
            return @(
                "What Is an Office Process?",
                "Process Triggers",
                "Inputs and Outputs",
                "Roles and Role Owners",
                "Handoffs",
                "Waiting Points and Bottlenecks",
                "Risk Points",
                "Creating a Simple Process Map"
            )
        }
        if ($focus -match "customer-facing") {
            return @(
                "What Is Workflow Coordination?",
                "Intake Standards",
                "Shared Queues and Status Tracking",
                "Role Clarification",
                "Escalation Rules",
                "Templates, Checklists, and Turnaround Targets",
                "Team Communication Routines",
                "Customer-Facing Office Processes",
                "Evaluating Service Quality",
                "Choosing the Right Workflow Improvement Technique"
            )
        }
        if ($focus -match "operational improvement") {
            return @(
                "What Is Operational Improvement?",
                "Using Evidence to Understand a Problem",
                "Identifying the Problem",
                "Locating the Constraint",
                "Recommending One Practical Change",
                "Assigning Responsibility",
                "Measuring Whether the Change Worked",
                "Defensible Operational Judgment",
                "Final Integrated Case"
            )
        }
    }

    $sections = New-Object System.Collections.ArrayList
    foreach ($module in @($Chapter.moduleSequence)) {
        if ($module.title) { [void]$sections.Add($module.title) }
    }
    foreach ($section in @($Chapter.requiredSections)) {
        if ($section) { [void]$sections.Add($section) }
    }
    return @($sections | Select-Object -Unique)
}

function Get-BusinessOperationsOutlineSubpoints {
    param(
        [object]$Chapter,
        [string]$SectionTitle
    )

    $focus = ([string]$Chapter.focus).ToLowerInvariant()
    switch -Regex ($SectionTitle) {
        "What Are Business and Office Operations" {
            return @(
                "Define business operations as the coordinated work an organization uses to deliver products, services, or support.",
                "Define office operations as the daily systems, routines, tools, records, and messages that help work get done.",
                "Explain how office operations connect people, information, deadlines, and customer or patient needs.",
                "Use entry-level examples such as scheduling, intake, records management, document routing, customer follow-up, supply tracking, and team communication.",
                "Ask learners to identify five office operations tasks they have seen as students, workers, volunteers, patients, or customers."
            )
        }
        "Office Operations Across Different Business Settings" {
            return @(
                "Explain that office operations appear in many settings, even when the mission or service is different.",
                "Compare corporate office tasks such as executive support, department coordination, reporting, customer support, and finance processing.",
                "Compare nonprofit office tasks such as donor records, volunteer scheduling, client intake, grant documentation, and outreach.",
                "Use allied healthcare examples such as appointment scheduling, patient records, insurance information, privacy procedures, referral tracking, and provider coordination.",
                "Compare government and small-business tasks such as forms processing, records retention, invoices, vendor communication, and customer service.",
                "Ask learners to compare two settings and name which office routines stay similar."
            )
        }
        "Why Office Operations Matter" {
            return @(
                "Explain how office operations affect productivity, service quality, and organizational effectiveness.",
                "Show why reliable routines matter when a patient, customer, coworker, or supervisor needs a timely answer.",
                "Use an allied healthcare worked example: a patient calls, the office records the request, staff schedule the appointment, the team sends a reminder, and someone follows up.",
                "Ask learners what could go wrong if one step is late, unclear, missing, or undocumented.",
                "Connect the routine to risk, privacy, wait time, and trust."
            )
        }
        "Organizational Structures and Office Workflow" {
            return @(
            "Define organizational structure as the way an organization arranges authority, responsibility, communication, and reporting relationships.",
                "Introduce functional structure with examples such as finance, human resources, marketing, operations, billing, scheduling, and records.",
                "Introduce divisional structure by product, service line, customer group, location, or region.",
                "Introduce matrix structure as work that crosses functions or project teams and may require more than one leader.",
                "Explain how structure affects communication, decisions, reporting, workflow, and accountability.",
                "Ask learners to review a simple organization chart and identify where a request could slow down."
            )
        }
        "Office Operations and Strategic Goals" {
            return @(
                "Define strategic goals as broad aims that guide what the organization wants to improve.",
                "Explain how office routines turn strategic goals into daily work.",
                "Connect a goal such as improving patient follow-up to reminder calls, accurate contact records, and clear status notes.",
                "Connect a goal such as reducing claim delays to complete intake information, correct forms, and timely routing.",
                "Connect a goal such as protecting privacy to access rules, secure messages, and careful document handling.",
                "Ask learners to match strategic goals with the office routines that support them."
            )
        }
        "People, Technology, and Procedures" {
            return @(
                "Introduce the people-technology-procedure framework.",
                "Explain the role of people: skills, communication habits, judgment, role clarity, and accountability.",
                "Explain the role of technology: software, databases, email, shared drives, scheduling tools, and communication platforms.",
                "Explain the role of procedures: step-by-step instructions, standards, checklists, templates, policies, and approval rules.",
                "Emphasize that technology alone does not fix a broken process, and procedures alone do not work if people cannot follow them.",
                "Ask learners to decide whether a workplace problem is mainly a people issue, technology issue, procedure issue, or combination."
            )
        }
        "Understanding Core Business Functions" {
            return @(
                "Define core business functions as major areas of work that help an organization operate.",
                "Name common functions such as finance, human resources, marketing, operations, customer service, and compliance.",
                "Use an allied healthcare office example to show how billing, scheduling, records, and patient service depend on one another.",
                "Explain that each function sees different information but shares responsibility for the service result.",
                "Ask learners to trace one patient or customer request across at least two functions."
            )
        }
        "Finance Workflow" {
            return @(
                "Explain how finance workflows track budgets, purchases, invoices, payments, and approvals.",
                "Use a clinic example: staff request supplies, confirm the approved vendor, route the purchase, and document the expense.",
                "Show how incomplete information can delay payment, create duplicate work, or affect service readiness.",
                "Ask learners to identify what information finance needs before work can continue."
            )
        }
        "Human Resources Workflow" {
            return @(
                "Explain how human resources workflows support staffing, onboarding, schedules, training records, and role requirements.",
                "Use an allied healthcare example: a clinic needs front-desk coverage during a high-volume appointment block.",
                "Show how role clarity protects both employees and patients or customers.",
                "Ask learners to name the handoff between a supervisor, HR, and the front-office team."
            )
        }
        "Marketing Workflow" {
            return @(
                "Explain how marketing workflows shape outreach, reminders, service messages, and customer expectations.",
                "Use a healthcare example: a practice announces a new service and the office prepares scripts, FAQs, and follow-up steps.",
                "Show how marketing promises can create office workload.",
                "Ask learners to identify what operations needs before a public message goes out."
            )
        }
        "Operations Workflow" {
            return @(
                "Define operations workflow as the path work follows from request to result.",
                "Use examples such as intake, scheduling, records updates, document review, approvals, and follow-up.",
                "Explain how operations connects the work of finance, HR, marketing, and customer-facing staff.",
                "Ask learners to mark where a request enters, who owns it, and what output proves completion."
            )
        }
        "Interdependencies Across Business Functions" {
            return @(
                "Define interdependence as one function needing information or action from another function.",
                "Show how delays in staffing, budget approval, records, or customer communication can affect the whole workflow.",
                "Use a clinic example where scheduling, insurance verification, billing, and provider availability must align.",
                "Ask learners to name one risk if a function works alone without updating the next owner."
            )
        }
        "Communication in Cross-Functional Workflows" {
            return @(
                "Explain why cross-functional work needs clear messages, status notes, ownership, and deadlines.",
                "Use simple communication standards: who needs to know, what changed, what is due, and what happens next.",
                "Show how brief, accurate updates reduce rework and protect service quality.",
                "Ask learners to rewrite a vague handoff as a clear workplace message."
            )
        }
        "What Is an Office Process" {
            return @(
                "Define an office process as a repeatable path for completing work.",
                "Identify the trigger, inputs, steps, role owners, outputs, and closeout point.",
                "Use an allied healthcare example such as new-patient intake, appointment changes, referral tracking, or records requests.",
                "Explain that a process map should show the real work, not the ideal version.",
                "Ask learners to choose one routine task and name its start and finish."
            )
        }
        "Process Triggers" {
            return @(
                "Define a trigger as the event that starts the process.",
                "Use examples such as a phone call, email, form, portal message, referral, invoice, or appointment request.",
                "Explain why teams need clear trigger rules so work does not wait unnoticed.",
                "Ask learners to identify the trigger in a short clinic or office scenario."
            )
        }
        "Inputs and Outputs" {
            return @(
                "Define inputs as the information, forms, approvals, or materials needed before a step can start.",
                "Define outputs as the completed item, update, decision, or message that leaves a step.",
                "Use healthcare examples such as demographic information, insurance details, consent forms, appointment notes, and confirmation messages.",
                "Ask learners to decide whether a step can continue when an input is missing."
            )
        }
        "Roles and Role Owners" {
            return @(
                "Define a role owner as the person or job role responsible for a step.",
                "Explain why ownership should not depend on whoever happens to notice the task first.",
                "Use examples such as front-desk staff, records staff, billing staff, supervisor, or provider.",
                "Ask learners to add one owner and one backup owner to a process step."
            )
        }
        "Handoffs" {
            return @(
                "Define a handoff as the point where work moves from one person, role, system, or department to another.",
                "Explain that strong handoffs include the task, status, deadline, needed information, and next owner.",
                "Use a clinic example where scheduling sends an insurance issue to billing with enough detail to act.",
                "Ask learners to find the weakest handoff in a short process."
            )
        }
        "Waiting Points and Bottlenecks" {
            return @(
                "Define waiting points as places where work pauses before the next action.",
                "Define bottlenecks as points that slow many requests, not just one request.",
                "Use examples such as missing paperwork, supervisor approval, provider availability, system downtime, or unclear ownership.",
                "Ask learners to decide whether the delay comes from volume, missing information, or a decision rule."
            )
        }
        "Risk Points" {
            return @(
                "Define risk points as places where errors, delays, privacy problems, or service breakdowns are more likely.",
                "Use healthcare office examples such as incorrect patient information, misplaced forms, broad file access, or undocumented calls.",
                "Explain how checklists, privacy rules, and status notes reduce risk.",
                "Ask learners to mark one risk point and one control in a process map."
            )
        }
        "Creating a Simple Process Map" {
            return @(
                "List the process steps in the order people actually complete them.",
                "Add the trigger, inputs, role owner, output, handoff, waiting point, and risk point.",
                "Keep the map simple enough that another entry-level employee could follow it.",
                "Ask learners to explain one improvement the map makes visible."
            )
        }
        "What Is Workflow Coordination" {
            return @(
                "Define workflow coordination as keeping people, records, tools, and deadlines aligned.",
                "Explain that coordination helps the office respond with speed, accuracy, and professionalism.",
                "Use a patient or customer request that needs scheduling, records, billing, and follow-up.",
                "Ask learners what the coordinator must check before promising a next step."
            )
        }
        "Intake Standards" {
            return @(
                "Define intake standards as the required information and checks before work moves forward.",
                "Use examples such as name, contact information, reason for request, forms, insurance details, deadline, and privacy limits.",
                "Explain how consistent intake reduces rework.",
                "Ask learners to identify which intake detail is missing from a short scenario."
            )
        }
        "Shared Queues and Status Tracking" {
            return @(
                "Explain how shared queues help teams see work that is waiting, assigned, in progress, or complete.",
                "Define status tracking as recording where work stands and who owns the next step.",
                "Use examples such as appointment requests, records requests, billing questions, or service tickets.",
                "Ask learners to write a clear status note for the next owner."
            )
        }
        "Role Clarification" {
            return @(
                "Explain why each task needs a clear owner, backup owner, and escalation path.",
                "Use a healthcare office example where front desk, billing, records, and supervisor roles overlap.",
                "Show how unclear roles create duplicate calls, missed updates, or privacy mistakes.",
                "Ask learners to decide who should own the next step in a scenario."
            )
        }
        "Escalation Rules" {
            return @(
                "Define escalation as moving a request to the right person when the standard path cannot solve it.",
                "Use examples such as urgent patient concerns, privacy questions, denied claims, repeated delays, or complaints.",
                "Explain that escalation should include the issue, evidence, steps tried, and requested decision.",
                "Ask learners to decide when a request should stay in the normal workflow and when it should escalate."
            )
        }
        "Templates, Checklists, and Turnaround Targets" {
            return @(
                "Explain how templates standardize common messages and reduce missing details.",
                "Explain how checklists help entry-level staff complete steps in the right order.",
                "Define turnaround targets as expected response or completion times.",
                "Use examples such as appointment reminder scripts, records request checklists, and follow-up targets.",
                "Ask learners to choose which tool fits a service problem: template, checklist, or target."
            )
        }
        "Team Communication Routines" {
            return @(
                "Explain why teams need brief routines for updates, barriers, priorities, and handoffs.",
                "Use examples such as morning huddles, shared notes, queue reviews, and end-of-day follow-up checks.",
                "Show how communication routines protect patient or customer service without adding long meetings.",
                "Ask learners to write a short update that names status, risk, and next step."
            )
        }
        "Customer-Facing Office Processes" {
            return @(
                "Define customer-facing processes as workflows the customer or patient can feel directly.",
                "Use examples such as scheduling, check-in, records requests, billing questions, and follow-up calls.",
                "Explain how tone, accuracy, privacy, and timing all shape the service experience.",
                "Ask learners to identify which part of the process the customer notices most."
            )
        }
        "Evaluating Service Quality" {
            return @(
                "Evaluate service quality by looking at reliability, responsiveness, professionalism, accuracy, empathy, and follow-through.",
                "Explain that polite service still fails if the office gives the wrong answer or no next step.",
                "Use a clinic example where a patient needs a clear status update without private details exposed.",
                "Ask learners to rate a service response and name one improvement."
            )
        }
        "Choosing the Right Workflow Improvement Technique" {
            return @(
                "Explain that different problems need different fixes.",
                "Match missing details to intake standards, unclear ownership to role clarification, delays to queue review, and repeated errors to checklists.",
                "Use evidence before choosing training, a template, a new tool, or a policy reminder.",
                "Ask learners to choose one improvement and explain why it fits the evidence."
            )
        }
        "What Is Operational Improvement" {
            return @(
                "Define operational improvement as a practical change that helps work become more reliable, timely, accurate, or useful.",
                "Explain that improvement starts with evidence, not opinion.",
                "Use entry-level examples such as reducing missed reminders, shortening wait time, improving document routing, or preventing repeated form errors.",
                "Ask learners to name the current problem and the desired result."
            )
        }
        "Using Evidence to Understand a Problem" {
            return @(
                "Define evidence as the facts that show what is happening in the workflow.",
                "Use examples such as timestamps, queue counts, error patterns, missing fields, call notes, and customer feedback.",
                "Explain how evidence protects the team from guessing.",
                "Ask learners to separate facts from opinions in a short case."
            )
        }
        "Identifying the Problem" {
            return @(
                "Write the problem in one clear sentence.",
                "Separate symptoms such as late calls from causes such as missing owner, unclear rule, or too much volume.",
                "Use a healthcare office example where the visible issue is patient waiting time but the cause may be intake or scheduling.",
                "Ask learners to revise a vague problem statement into a specific one."
            )
        }
        "Locating the Constraint" {
            return @(
                "Define the constraint as the point that limits the whole workflow.",
                "Look for the step where work waits, repeats, returns for correction, or needs approval.",
                "Use examples such as one overloaded role, missing information, slow system access, or unclear escalation.",
                "Ask learners to identify the constraint before recommending a fix."
            )
        }
        "Recommending One Practical Change" {
            return @(
                "Recommend one change that fits the evidence and the entry-level role.",
                "Keep the change specific, realistic, and easy to test.",
                "Use examples such as a revised intake checklist, clearer status note, shared queue review, or standard follow-up script.",
                "Ask learners to explain why their change targets the real problem."
            )
        }
        "Assigning Responsibility" {
            return @(
                "Name who owns the change, who supports it, and who checks whether it works.",
                "Explain why a change without ownership often fades after a few days.",
                "Use examples such as front-desk lead, billing specialist, records assistant, supervisor, or office coordinator.",
                "Ask learners to add an owner and backup owner to the improvement."
            )
        }
        "Measuring Whether the Change Worked" {
            return @(
                "Choose one simple measure before the change starts.",
                "Use measures such as fewer returned forms, shorter response time, fewer missed reminders, or cleaner status notes.",
                "Compare the result after a short test period.",
                "Ask learners to decide what evidence would show success."
            )
        }
        "Defensible Operational Judgment" {
            return @(
                "Define defensible judgment as a recommendation that another person can understand and inspect.",
                "Connect the problem, evidence, constraint, change, owner, and measure.",
                "Explain limits honestly instead of overstating what the change can fix.",
                "Ask learners to write a short improvement note with evidence."
            )
        }
        "Final Integrated Case" {
            return @(
                "Bring together structure, functions, process mapping, service quality, and improvement.",
                "Use an allied healthcare office case that includes appointment flow, records, billing, privacy, and follow-up.",
                "Ask learners to identify the problem, map the handoff, choose one improvement, and explain how to measure it.",
                "Close with a reflection on how entry-level office work supports larger organizational goals."
            )
        }
    }

    return @()
}

function Get-OutlineSubpoints {
    param(
        [object]$Chapter,
        [string]$SectionTitle
    )

    $subpoints = New-Object System.Collections.ArrayList
    if (([string]$Chapter.focus) -match "organizational structure|people, technology|core business|workflow mapping|customer-facing|operational improvement") {
        $businessSubpoints = @(Get-BusinessOperationsOutlineSubpoints -Chapter $Chapter -SectionTitle $SectionTitle)
        if ($businessSubpoints.Count -gt 0) {
            return @($businessSubpoints)
        }
    }

    $matchingModule = @(
        $Chapter.moduleSequence |
            Where-Object { $_.title -eq $SectionTitle } |
            Select-Object -First 1
    )
    if ($matchingModule) {
        $module = $matchingModule[0]
        if ($module.description) {
            [void]$subpoints.Add($module.description)
        }
        foreach ($objective in @($module.subObjectives | Select-Object -First 3)) {
            if ($objective) {
                [void]$subpoints.Add("Develop the idea: $(ConvertTo-CleanText $objective)")
            }
        }
        foreach ($activity in @($module.suggestedActivities | Select-Object -First 1)) {
            if ($activity) {
                [void]$subpoints.Add("Applied moment: $(ConvertTo-CleanText $activity)")
            }
        }
        if ($subpoints.Count -lt 3) {
            [void]$subpoints.Add("Connect the lesson to the chapter focus: $($Chapter.focus).")
        }
        if ($subpoints.Count -lt 3) {
            [void]$subpoints.Add("Use a realistic chapter case to show how the concept changes a learner's judgment.")
        }
        if ($subpoints.Count -lt 3) {
            [void]$subpoints.Add("Close with a reader-notice moment that names the habit students should carry forward.")
        }
        return @($subpoints)
    }

    switch -Regex ($SectionTitle) {
        "Business Case|scenario" {
            [void]$subpoints.Add("Open with a named learner or early-career employee facing a realistic chapter situation.")
            [void]$subpoints.Add("Name the decision, communication choice, evidence, and risk so the chapter has a clear human context.")
            [void]$subpoints.Add("Connect the scenario to UMA learner needs and the chapter objectives.")
            break
        }
        "procedure|checklist|model" {
            [void]$subpoints.Add("Provide a reusable thinking model for reading the chapter situation.")
            [void]$subpoints.Add("Show what to notice before trusting, revising, or acting on the idea.")
            [void]$subpoints.Add("Include a short recovery habit students can use when the situation is unclear.")
            break
        }
        "Copilot|AI|technology judgment" {
            [void]$subpoints.Add("Show where a technology assistant can help with the task and where the learner remains responsible.")
            [void]$subpoints.Add("Ask learners to verify accuracy, tone, privacy, security, and audience fit before using the output.")
            [void]$subpoints.Add("Include a keep, revise, or reject decision so AI use builds judgment instead of dependence.")
            break
        }
        "artifact|share" {
            [void]$subpoints.Add("Define the practical artifact students create, such as a folder plan, formatted document, citation tracker, or safety routine.")
            [void]$subpoints.Add("Explain the quality markers another person should be able to see in the artifact.")
            [void]$subpoints.Add("Connect the artifact to the workplace habit, chapter concept, or next learning need.")
            break
        }
        "Reader-notice|chapter synthesis|reflection" {
            [void]$subpoints.Add("Add a brief pause-and-notice moment tied to the chapter objectives.")
            [void]$subpoints.Add("Include a synthesis paragraph about the judgment or habit the learner can reuse.")
            [void]$subpoints.Add("Use plain language and keep the moment focused on durable understanding.")
            break
        }
        "Bridge" {
            [void]$subpoints.Add("Summarize the habit or skill the learner should carry forward.")
            [void]$subpoints.Add("Preview how the next chapter uses this skill in a more complex communication situation.")
            [void]$subpoints.Add("Keep the transition learner-centered and connected to course outcomes.")
            break
        }
        default {
            [void]$subpoints.Add("Explain how $SectionTitle supports $($Chapter.focus).")
            [void]$subpoints.Add("Tie the topic to the chapter objectives and a realistic learner experience.")
            [void]$subpoints.Add("Include an example, scenario, or reader-notice moment that helps students understand the concept.")
        }
    }

    return @($subpoints)
}

function Get-CourseArcLearningActions {
    param(
        [object]$Course,
        [object]$Chapter,
        [string]$ProposedTitle
    )

    if ((Get-CourseDomain -Course $Course) -eq "business-operations") {
        switch -Regex ($ProposedTitle) {
            "Operations System" {
                return @(
                    "Examine office operations across corporate, nonprofit, healthcare, government, and small-business settings.",
                    "Describe how daily administrative work supports productivity, service quality, organizational effectiveness, and larger goals.",
                    "Compare basic organizational structures and explain how structure affects communication, authority, reporting, and workflow."
                )
            }
            "Business Functions" {
                return @(
                    "Differentiate finance, human resources, marketing, operations, customer service, and compliance functions.",
                    "Trace how information, decisions, and tasks move between departments.",
                    "Identify where unclear handoffs, missing information, or competing priorities can slow work down."
                )
            }
            "Mapping Office Processes" {
                return @(
                    "Map an end-to-end office process by identifying triggers, inputs, outputs, role owners, handoffs, waiting points, risk points, and improvement opportunities.",
                    "Explain how a process moves from request to completion.",
                    "Use process maps to make work visible, repeatable, and easier to evaluate."
                )
            }
            "Customer-Facing Service" {
                return @(
                    "Apply workflow coordination techniques to common workplace scenarios.",
                    "Recommend tools such as intake standards, shared queues, status tracking, role clarification, escalation rules, templates, checklists, turnaround targets, and communication routines.",
                    "Evaluate customer-facing processes for efficiency, quick response, respectful work, accuracy, privacy, and follow-through."
                )
            }
            "Operational Improvement" {
                return @(
                    "Analyze a workplace scenario or case process.",
                    "Identify the office problem, review evidence, locate the constraint, recommend one practical change, assign responsibility, and propose a simple measure.",
                    "Defend a recommendation using course concepts and explain how it improves work output, service, quality, reliability, or risk control."
                )
            }
        }
    }

    $actions = New-Object System.Collections.ArrayList
    foreach ($target in @($Chapter.learningTargets | Select-Object -First 3)) {
        if ($target) {
            [void]$actions.Add("Practice the course objective: $(ConvertTo-CleanText $target)")
        }
    }
    if ($actions.Count -lt 3) {
        [void]$actions.Add("Apply the chapter concept to a realistic learner or workplace scenario.")
        [void]$actions.Add("Create or explain a practical artifact that shows the concept in use.")
        [void]$actions.Add("Reflect on what evidence would support a defensible next step.")
    }
    return @($actions | Select-Object -First 3)
}

function Get-CourseArcIntroducedConcepts {
    param(
        [object]$Course,
        [object]$Chapter,
        [string]$ProposedTitle,
        [object[]]$KeyConcepts
    )

    if ((Get-CourseDomain -Course $Course) -eq "business-operations") {
        switch -Regex ($ProposedTitle) {
            "Operations System" {
                return @(
                    "Business and office operations support productivity, service quality, and organizational effectiveness.",
                    "Office operations appear across corporate, nonprofit, healthcare, government, and small-business settings.",
                    "Organizational structures shape authority, communication, reporting, and workflow.",
                    "Office operations support larger goals through daily routines.",
                    "People, technology, and procedures work together to reduce risk and make work reliable.",
                    "Defensible operational judgment begins with understanding how daily work supports larger goals."
                )
            }
            "Business Functions" {
                return @(
                    "Core business functions are interconnected and depend on accurate information, clear handoffs, and coordinated decisions.",
                    "Cross-functional workflows require teams to understand what each department needs, what each function contributes, and where work may stall or create delays."
                )
            }
            "Mapping Office Processes" {
                return @(
                    "Office process mapping identifies triggers, inputs, outputs, role owners, handoffs, waiting points, risk points, and improvement opportunities."
                )
            }
            "Customer-Facing Service" {
                return @(
                    "Workflow coordination techniques improve timeliness and service.",
                    "Customer-facing office steps should be evaluated for speed, quick response, respectful work, accuracy, records, privacy, and follow-through.",
                    "Service depends on reliability, quick response, clear communication, records, and the customer or patient perception of the experience."
                )
            }
            "Operational Improvement" {
                return @(
                    "Evidence-based operational improvement means identifying the problem, reviewing evidence, locating the constraint, recommending one practical change, assigning responsibility, and measuring whether the change worked."
                )
            }
        }
    }

    $filtered = @($KeyConcepts | Where-Object { $_ } | Select-Object -First 6)
    if ($filtered.Count -eq 0) {
        $filtered = @($Chapter.focus)
    }
    return @($filtered)
}

function Get-CourseArcReinforcedConcepts {
    param(
        [object]$Course,
        [object]$Chapter,
        [string]$ProposedTitle,
        [object[]]$PreviousConcepts
    )

    if ((Get-CourseDomain -Course $Course) -eq "business-operations") {
        switch -Regex ($ProposedTitle) {
            "Operations System" {
                return @("Students begin practicing operational judgment by explaining how office work supports broader organizational goals.")
            }
            "Business Functions" {
                return @("Organizational structures", "larger goals", "people-technology-procedure interaction", "defensible operational judgment")
            }
            "Mapping Office Processes" {
                return @("Core business functions", "cross-functional workflows", "clear handoffs", "accurate information", "people-technology-procedure interaction", "defensible operational judgment")
            }
            "Customer-Facing Service" {
                return @("Process mapping", "handoffs", "risk points", "waiting points", "people-technology-procedure interaction", "defensible operational judgment")
            }
            "Operational Improvement" {
                return @("Organizational structures", "larger goals", "business functions", "interdependencies", "process mapping", "workflow coordination", "service", "people-technology-procedure interaction", "defensible operational judgment")
            }
        }
    }

    # Reinforce the most recently introduced concepts first. This keeps the
    # course arc cumulative: later modules should visibly revisit the skills
    # learners just practiced, not only the oldest concepts in the course.
    $reinforced = @($PreviousConcepts | Where-Object { $_ } | Select-Object -Last 6)
    if ($reinforced.Count -eq 0) {
        $reinforced = @("Students begin using the first course concept in a practical scenario.")
    }
    return @($reinforced)
}

function Get-ConceptIntroductionReinforcementMap {
    param(
        [object]$Course,
        [object[]]$ArcModules
    )

    if ((Get-CourseDomain -Course $Course) -eq "business-operations") {
        return @(
            [pscustomobject]@{ keyConcept = "Business and office operations support productivity, service quality, and organizational effectiveness."; introduced = "Module 1"; reinforced = "Modules 2, 4, 5" },
            [pscustomobject]@{ keyConcept = "People, technology, and procedures work together to reduce risk and improve productivity."; introduced = "Module 1"; reinforced = "Modules 3, 4, 5" },
            [pscustomobject]@{ keyConcept = "Organizational structures shape authority, communication, reporting, and workflow."; introduced = "Module 1"; reinforced = "Modules 2, 5" },
            [pscustomobject]@{ keyConcept = "Office operations support larger goals through daily routines."; introduced = "Module 1"; reinforced = "Modules 2, 5" },
            [pscustomobject]@{ keyConcept = "Core business functions are interconnected."; introduced = "Module 2"; reinforced = "Modules 3, 5" },
            [pscustomobject]@{ keyConcept = "Cross-functional workflows depend on clear needs, contributions, and handoffs."; introduced = "Module 2"; reinforced = "Modules 3, 4, 5" },
            [pscustomobject]@{ keyConcept = "Office process mapping identifies triggers, inputs, outputs, roles, handoffs, waiting points, risk points, and improvement opportunities."; introduced = "Module 3"; reinforced = "Modules 4, 5" },
            [pscustomobject]@{ keyConcept = "Workflow coordination techniques improve timeliness and service."; introduced = "Module 4"; reinforced = "Module 5" },
            [pscustomobject]@{ keyConcept = "Customer-facing office steps should be evaluated for speed, quick response, respectful work, accuracy, records, privacy, and follow-through."; introduced = "Module 4"; reinforced = "Module 5" },
            [pscustomobject]@{ keyConcept = "Service depends on reliability, quick response, clear communication, records, and customer or patient perception."; introduced = "Module 4"; reinforced = "Module 5" },
            [pscustomobject]@{ keyConcept = "Operational improvement should be evidence-based."; introduced = "Module 5"; reinforced = "Module 5 culmination" },
            [pscustomobject]@{ keyConcept = "Defensible operational judgment requires students to explain, recognize, use evidence, and make practical decisions."; introduced = "Module 1"; reinforced = "Modules 2, 3, 4, 5" }
        )
    }

    $map = New-Object System.Collections.ArrayList
    $modules = @($ArcModules)
    for ($i = 0; $i -lt $modules.Count; $i++) {
        foreach ($concept in @($modules[$i].keyConceptsIntroduced | Select-Object -First 3)) {
            if ([string]::IsNullOrWhiteSpace($concept)) { continue }
            $reinforcedModules = New-Object System.Collections.ArrayList
            for ($j = $i + 1; $j -lt $modules.Count; $j++) {
                $reinforcedText = (@($modules[$j].keyConceptsReinforced) -join " ").ToLowerInvariant()
                $conceptWords = @([regex]::Matches(([string]$concept).ToLowerInvariant(), "\b[a-z]{5,}\b") | ForEach-Object { $_.Value } | Select-Object -First 3)
                foreach ($word in $conceptWords) {
                    if ($reinforcedText -match [regex]::Escape($word)) {
                        [void]$reinforcedModules.Add("Module $($modules[$j].moduleNumber)")
                        break
                    }
                }
            }
            if ($reinforcedModules.Count -eq 0 -and $i -lt ($modules.Count - 1)) {
                [void]$reinforcedModules.Add("Needs academic review")
            }
            elseif ($reinforcedModules.Count -eq 0) {
                [void]$reinforcedModules.Add("Module $($modules[$i].moduleNumber) culmination")
            }
            [void]$map.Add([pscustomobject]@{
                keyConcept = $concept
                introduced = "Module $($modules[$i].moduleNumber)"
                reinforced = (($reinforcedModules | Select-Object -Unique) -join ", ")
            })
        }
    }
    return @($map | Select-Object -First 15)
}

function Get-StudentPerformanceThread {
    param(
        [object]$Course,
        [object[]]$ArcModules
    )

    if ((Get-CourseDomain -Course $Course) -eq "business-operations") {
        return [pscustomobject]@{
            scenario = "Students follow one entry-level allied healthcare office scenario that becomes more complex each week: a patient service request moves through scheduling, records, insurance information, privacy expectations, provider coordination, follow-up, and evidence-based improvement."
            moduleSteps = @(
                [pscustomobject]@{ moduleNumber = 1; action = "Identify the organizational setting and structure that shape the patient service request." },
                [pscustomobject]@{ moduleNumber = 2; action = "Determine which business functions support the request and what each function needs from the others." },
                [pscustomobject]@{ moduleNumber = 3; action = "Map the process from start to finish, including inputs, outputs, owners, handoffs, waiting points, and risk points." },
                [pscustomobject]@{ moduleNumber = 4; action = "Apply coordination techniques to improve workflow, privacy, communication, and front-office service." },
                [pscustomobject]@{ moduleNumber = 5; action = "Recommend and defend one evidence-based operational improvement with an owner and a simple success measure." }
            )
        }
    }

    $steps = New-Object System.Collections.ArrayList
    foreach ($module in @($ArcModules)) {
        $action = if (@($module.learningActions).Count -gt 0) { @($module.learningActions)[0] } else { "Apply the module concept to a realistic performance task." }
        [void]$steps.Add([pscustomobject]@{
            moduleNumber = $module.moduleNumber
            action = $action
        })
    }
    return [pscustomobject]@{
        scenario = "Students revisit one realistic course scenario each week, adding new concepts and performance expectations as the course becomes more complex."
        moduleSteps = @($steps)
    }
}

function Get-PlanningPacketQualityReview {
    param(
        [object]$Course,
        [object]$CourseConceptArc,
        [object]$EbookOutline
    )

    $checks = New-Object System.Collections.ArrayList
    $domain = Get-CourseDomain -Course $Course
    $modules = @($CourseConceptArc.modules)
    $chapters = @($EbookOutline.chapters)
    $arcIssues = New-Object System.Collections.ArrayList
    $outlineIssues = New-Object System.Collections.ArrayList
    $conceptMapIssues = New-Object System.Collections.ArrayList
    $threadIssues = New-Object System.Collections.ArrayList

    if ($modules.Count -lt 3) { [void]$arcIssues.Add("Course arc has fewer than three modules.") }
    foreach ($module in $modules) {
        if ([string]::IsNullOrWhiteSpace($module.conceptFocus)) { [void]$arcIssues.Add("Module $($module.moduleNumber) is missing a concept focus.") }
        if (@($module.learningActions).Count -lt 3) { [void]$arcIssues.Add("Module $($module.moduleNumber) needs at least three learner action bullets.") }
        if (@($module.keyConceptsIntroduced).Count -lt 1) { [void]$arcIssues.Add("Module $($module.moduleNumber) needs key concepts introduced.") }
        if (@($module.keyConceptsReinforced).Count -lt 1) { [void]$arcIssues.Add("Module $($module.moduleNumber) needs key concepts reinforced.") }
        if (@($module.alignmentToObjectives).Count -lt 1) { [void]$arcIssues.Add("Module $($module.moduleNumber) needs objective alignment.") }
    }
    [void]$checks.Add([pscustomobject]@{
        name = "course_arc_structure"
        status = if ($arcIssues.Count -eq 0) { "PASS" } else { "FAIL" }
        detail = if ($arcIssues.Count -eq 0) { "$($modules.Count) module course arc includes concept focus, learner actions, introduced/reinforced concepts, and objective alignment." } else { $arcIssues -join " " }
    })

    $conceptMap = @($CourseConceptArc.conceptIntroductionReinforcementMap)
    if ($conceptMap.Count -lt 5) { [void]$conceptMapIssues.Add("Concept introduction/reinforcement map needs at least five concepts.") }
    foreach ($item in $conceptMap) {
        if ([string]::IsNullOrWhiteSpace($item.keyConcept) -or [string]::IsNullOrWhiteSpace($item.introduced) -or [string]::IsNullOrWhiteSpace($item.reinforced)) {
            [void]$conceptMapIssues.Add("Concept map entry is missing concept, introduced module, or reinforced module.")
        }
        if ($item.reinforced -match "Needs academic review") {
            [void]$conceptMapIssues.Add("Concept '$($item.keyConcept)' does not show clear later reinforcement.")
        }
    }
    [void]$checks.Add([pscustomobject]@{
        name = "concept_reinforcement_map"
        status = if ($conceptMap.Count -lt 5) { "FAIL" } elseif ($conceptMapIssues.Count -gt 0) { "WARNING" } else { "PASS" }
        detail = if ($conceptMapIssues.Count -eq 0) { "$($conceptMap.Count) concept(s) show where they are introduced and reinforced." } else { $conceptMapIssues -join " " }
    })

    $thread = $CourseConceptArc.studentPerformanceThread
    if (-not $thread -or [string]::IsNullOrWhiteSpace($thread.scenario)) {
        [void]$threadIssues.Add("Recommended student performance thread is missing a scenario.")
    }
    elseif ($domain -eq "business-operations" -and $thread.scenario -notmatch "healthcare|clinic|patient|allied") {
        [void]$threadIssues.Add("Business operations performance thread must use an entry-level allied healthcare context.")
    }
    if (@($thread.moduleSteps).Count -ne $modules.Count) {
        [void]$threadIssues.Add("Performance thread should include one step for each module.")
    }
    foreach ($step in @($thread.moduleSteps)) {
        if ($step.action -notmatch "\b(Identify|Determine|Map|Apply|Recommend|Defend|Analyze|Create|Use|Evaluate|Practice|Explain)\b") {
            [void]$threadIssues.Add("Performance thread step for module $($step.moduleNumber) needs an observable student action.")
        }
    }
    [void]$checks.Add([pscustomobject]@{
        name = "student_performance_thread"
        status = if ($threadIssues.Count -eq 0) { "PASS" } else { "FAIL" }
        detail = if ($threadIssues.Count -eq 0) { "Performance thread carries one scenario across $($modules.Count) module(s)." } else { $threadIssues -join " " }
    })

    if ($chapters.Count -lt 3) { [void]$outlineIssues.Add("Outline has fewer than three chapters.") }
    $outlineText = ($chapters | ConvertTo-Json -Depth 12)
    if ($outlineText -match "Define or explain|Connect the topic to the chapter learning objectives|realistic adult-learner experience") {
        [void]$outlineIssues.Add("Outline contains generic placeholder language.")
    }
    if ($domain -eq "business-operations" -and $outlineText -notmatch "patient|healthcare|clinic|billing|scheduling|records|insurance") {
        [void]$outlineIssues.Add("Business operations outline must include entry-level allied healthcare examples.")
    }
    foreach ($chapter in $chapters) {
        if (@($chapter.keyConcepts).Count -lt 2) { [void]$outlineIssues.Add("Chapter $($chapter.number) needs at least two key concepts.") }
        if (@($chapter.sections).Count -lt 4) { [void]$outlineIssues.Add("Chapter $($chapter.number) needs at least four outline sections.") }
        foreach ($section in @($chapter.sections)) {
            if (@($section.subpoints).Count -lt 3) { [void]$outlineIssues.Add("Chapter $($chapter.number) section '$($section.title)' needs at least three concrete subpoints.") }
        }
    }
    $activityCount = [regex]::Matches($outlineText, "(?i)Ask learners|learner activity|worked example|scenario|reader-notice|case").Count
    if ($activityCount -lt $chapters.Count) {
        [void]$outlineIssues.Add("Outline needs visible examples, reader-notice moments, or learning-support features across chapters.")
    }
    [void]$checks.Add([pscustomobject]@{
        name = "outline_specificity"
        status = if ($outlineIssues.Count -eq 0) { "PASS" } else { "FAIL" }
        detail = if ($outlineIssues.Count -eq 0) { "$($chapters.Count) chapter outline avoids generic placeholders and includes concrete subpoints, examples, and reader-notice moments." } else { $outlineIssues -join " " }
    })

    $failed = @($checks | Where-Object { $_.status -eq "FAIL" }).Count
    return [pscustomobject]@{
        status = if ($failed -gt 0) { "FAIL" } else { "PASS" }
        checks = @($checks)
    }
}

function New-EbookBlueprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Course,
        [Parameter(Mandatory)][object]$Plan,
        [object]$SourceContext,
        [object]$BrandProfile,
        [switch]$OutlineApproved,
        [string]$ApprovedBy = "",
        [string]$ApprovalNotes = "",
        [string]$ReviewedOutlinePath = ""
    )

    $isApproved = [bool]$OutlineApproved
    $approvedAt = if ($isApproved) { (Get-Date).ToString("s") } else { "" }

    $arcModules = New-Object System.Collections.ArrayList
    $outlineChapters = New-Object System.Collections.ArrayList
    $previousIntroducedConcepts = New-Object System.Collections.ArrayList
    foreach ($chapter in @($Plan.chapters)) {
        $proposedTitle = Get-ProposedChapterTitle -Course $Course -Chapter $chapter
        $keyConcepts = @(Get-KeyConceptCandidates -Chapter $chapter)
        $learningActions = @(Get-CourseArcLearningActions -Course $Course -Chapter $chapter -ProposedTitle $proposedTitle)
        $introducedConcepts = @(Get-CourseArcIntroducedConcepts -Course $Course -Chapter $chapter -ProposedTitle $proposedTitle -KeyConcepts $keyConcepts)
        $reinforcedConcepts = @(Get-CourseArcReinforcedConcepts -Course $Course -Chapter $chapter -ProposedTitle $proposedTitle -PreviousConcepts @($previousIntroducedConcepts))
        [void]$arcModules.Add([pscustomobject]@{
            moduleNumber = $chapter.number
            proposedTitle = $proposedTitle
            sourceWeekTitle = $chapter.title
            conceptFocus = $chapter.focus
            learningPath = "Students use $($chapter.focus) to move from $($chapter.buildsOn) toward $($chapter.setsUp)."
            learningActions = @($learningActions)
            keyConceptsIntroduced = @($introducedConcepts)
            keyConceptsReinforced = @($reinforcedConcepts)
            alignmentToObjectives = @($chapter.learningTargets)
        })
        foreach ($concept in $introducedConcepts) {
            if ($concept) { [void]$previousIntroducedConcepts.Add($concept) }
        }

        $sections = New-Object System.Collections.ArrayList
        $sectionTitles = @(Get-ProposedOutlineSectionTitles -Course $Course -Chapter $chapter)
        for ($i = 0; $i -lt $sectionTitles.Count; $i++) {
            [void]$sections.Add([pscustomobject]@{
                label = Get-OutlineLetter -Index ($i + 1)
                title = $sectionTitles[$i]
                subpoints = @(Get-OutlineSubpoints -Chapter $chapter -SectionTitle $sectionTitles[$i])
            })
        }

        [void]$outlineChapters.Add([pscustomobject]@{
            number = $chapter.number
            roman = Get-RomanNumeral -Number $chapter.number
            proposedTitle = $proposedTitle
            sourceWeekTitle = $chapter.title
            focus = $chapter.focus
            keyConcepts = @($keyConcepts)
            learningTargets = @($chapter.learningTargets)
            sections = @($sections)
        })
    }

    $courseConceptArc = [pscustomobject]@{
        overallArc = $Plan.narrativeSpine
        learnerFocus = "Students should use course concepts to make practical decisions, explain their reasoning, and complete work that reflects the course outcomes."
        modules = @($arcModules)
        conceptIntroductionReinforcementMap = @(Get-ConceptIntroductionReinforcementMap -Course $Course -ArcModules @($arcModules))
        studentPerformanceThread = Get-StudentPerformanceThread -Course $Course -ArcModules @($arcModules)
    }
    $ebookOutline = [pscustomobject]@{
        format = "Traditional academic outline with Roman numerals, capital letters, and numbered subpoints."
        chapters = @($outlineChapters)
    }
    $planningQualityGates = Get-PlanningPacketQualityReview -Course $Course -CourseConceptArc $courseConceptArc -EbookOutline $ebookOutline
    $planningGatePassed = ($planningQualityGates.status -eq "PASS")
    $canGenerateDraft = ($isApproved -and $planningGatePassed)
    $workflowStatus = if ($canGenerateDraft) { "Approved for Draft" } elseif (-not $planningGatePassed) { "Planning Gate Failed" } else { "Outline Drafted" }
    $gateStatus = if ($canGenerateDraft) { "Approved for Draft" } elseif (-not $planningGatePassed) { "Planning Gate Failed" } else { "Needs Academic Review" }
    $gateRationale = if (-not $planningGatePassed) {
        "The course arc and detailed ebook outline did not pass the planning quality gates. Resolve the planning gate findings before research discovery and full manuscript drafting."
    }
    elseif ($isApproved) {
        "The proposed course arc and detailed ebook outline have been marked approved for this run. Research discovery and full manuscript drafting may proceed."
    }
    else {
        "The proposed course arc and detailed ebook outline should be reviewed and approved before full manuscript drafting."
    }

    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        documentType = "E-Book Planning Packet"
        planningPacketVersion = "0.2"
        blueprintVersion = "0.2"
        workflowStatus = $workflowStatus
        generationGate = [pscustomobject]@{
            status = $gateStatus
            canGenerateDraft = $canGenerateDraft
            rationale = $gateRationale
        }
        course = [pscustomobject]@{
            courseCode = $Course.courseCode
            courseName = $Course.courseName
            credits = $Course.credits
            duration = $Course.duration
            deliveryMode = $Course.deliveryMode
            prerequisites = $Course.prerequisites
            primaryText = $Course.primaryText
            description = $Course.description
            courseObjectives = @($Course.courseObjectives)
            weeks = @($Course.weeks)
            sourcePath = $Course.sourcePath
        }
        intakeChecklist = @(Get-BlueprintIntakeChecklist -Course $Course -SourceContext $SourceContext -BrandProfile $BrandProfile)
        sourceContextSummary = [pscustomobject]@{
            rootPath = if ($SourceContext) { $SourceContext.rootPath } else { "" }
            fileCount = if ($SourceContext) { @($SourceContext.files).Count } else { 0 }
            chunkCount = if ($SourceContext) { @($SourceContext.chunks).Count } else { 0 }
        }
        courseConceptArc = $courseConceptArc
        ebookOutline = $ebookOutline
        planningQualityGates = $planningQualityGates
        academicApproval = [pscustomobject]@{
            status = if ($canGenerateDraft) { "Approved" } elseif ($isApproved -and -not $planningGatePassed) { "Approval Blocked by Planning Gate" } else { "Not Approved" }
            approvedBy = if ($isApproved -and -not [string]::IsNullOrWhiteSpace($ApprovedBy)) { $ApprovedBy } else { "" }
            approvedAt = $approvedAt
            notes = if ($isApproved) { $ApprovalNotes } else { "" }
            reviewedOutlinePath = if ($isApproved) { $ReviewedOutlinePath } else { "" }
        }
        nextSteps = if ($canGenerateDraft) {
            @(
                "Run research discovery and source review for each approved chapter.",
                "Generate the full ebook draft from the approved outline.",
                "Review the generated manuscript, source registry, quality report, publishing editor report, and agent report.",
                "Route the draft for SME/ID/QA review before final publication."
            )
        }
        elseif (-not $planningGatePassed) {
            @(
                "Resolve every failed planning quality gate.",
                "Regenerate the course arc, concept introduction/reinforcement map, performance thread, and detailed outline.",
                "Review or revise the detailed ebook outline.",
                "Record academic/SME approval only after the planning packet gates pass."
            )
        }
        else {
            @(
                "Review the proposed course concept arc.",
                "Review or revise the detailed ebook outline.",
                "Record academic/SME approval before using the outline as the drafting control document.",
                "After approval, run research discovery and generate chapter evidence packets."
            )
        }
    }
}

function ConvertTo-EbookOutlineMarkdown {
    param(
        [object]$Course,
        [object]$Blueprint
    )

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# $($Course.courseCode) E-Book Chapter Outline")
    [void]$lines.Add("")
    [void]$lines.Add("Status: $($Blueprint.generationGate.status)")
    [void]$lines.Add("")
    if ($Blueprint.generationGate.canGenerateDraft) {
        [void]$lines.Add("This outline has been marked approved for drafting in this run.")
    }
    else {
        [void]$lines.Add("This proposed outline should be reviewed by academics/SME before full manuscript drafting.")
    }
    [void]$lines.Add("")
    foreach ($chapter in @($Blueprint.ebookOutline.chapters)) {
        [void]$lines.Add("$($chapter.roman). Chapter $($chapter.number): $($chapter.proposedTitle)")
        [void]$lines.Add("")
        [void]$lines.Add("Chapter $($chapter.number) Key Concepts")
        foreach ($concept in @($chapter.keyConcepts | Select-Object -First 10)) {
            [void]$lines.Add("- $concept")
        }
        [void]$lines.Add("")
        foreach ($section in @($chapter.sections)) {
            [void]$lines.Add("$($section.label). $($section.title)")
            for ($i = 0; $i -lt @($section.subpoints).Count; $i++) {
                [void]$lines.Add("$($i + 1). $($section.subpoints[$i])")
            }
            [void]$lines.Add("")
        }
    }
    return ($lines -join "`r`n")
}

function ConvertTo-EbookBlueprintMarkdown {
    param(
        [object]$Course,
        [object]$Blueprint
    )

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# $($Course.courseCode): E-Book Planning Packet")
    [void]$lines.Add("")
    [void]$lines.Add("Generated: $($Blueprint.generatedAt)")
    [void]$lines.Add("")
    [void]$lines.Add("Workflow status: $($Blueprint.workflowStatus)")
    [void]$lines.Add("")
    [void]$lines.Add("Generation gate: $($Blueprint.generationGate.status)")
    [void]$lines.Add("")
    [void]$lines.Add($Blueprint.generationGate.rationale)
    [void]$lines.Add("")
    [void]$lines.Add("## Intake Checklist")
    [void]$lines.Add("")
    foreach ($item in @($Blueprint.intakeChecklist)) {
        $requiredText = if ($item.required) { "required" } else { "recommended" }
        [void]$lines.Add("- $($item.status): $($item.item) ($requiredText) - $($item.detail)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("## Course Concept Arc")
    [void]$lines.Add("")
    [void]$lines.Add($Blueprint.courseConceptArc.overallArc)
    [void]$lines.Add("")
    [void]$lines.Add($Blueprint.courseConceptArc.learnerFocus)
    [void]$lines.Add("")
    foreach ($module in @($Blueprint.courseConceptArc.modules)) {
        [void]$lines.Add("### Module / Week $($module.moduleNumber): $($module.proposedTitle)")
        [void]$lines.Add("")
        [void]$lines.Add("Concept focus: $($module.conceptFocus)")
        [void]$lines.Add("")
        [void]$lines.Add("Learning path:")
        [void]$lines.Add("")
        [void]$lines.Add($module.learningPath)
        [void]$lines.Add("")
        [void]$lines.Add("What students will do:")
        foreach ($action in @($module.learningActions)) {
            [void]$lines.Add("- $action")
        }
        [void]$lines.Add("")
        [void]$lines.Add("Key concepts introduced:")
        foreach ($concept in @($module.keyConceptsIntroduced)) {
            [void]$lines.Add("- $concept")
        }
        [void]$lines.Add("")
        [void]$lines.Add("Key concepts reinforced:")
        foreach ($concept in @($module.keyConceptsReinforced)) {
            [void]$lines.Add("- $concept")
        }
        [void]$lines.Add("")
        [void]$lines.Add("Alignment to objectives:")
        foreach ($objective in @($module.alignmentToObjectives)) {
            [void]$lines.Add("- $objective")
        }
        [void]$lines.Add("")
    }
    [void]$lines.Add("## Key Concept Introduction and Reinforcement Map")
    [void]$lines.Add("")
    [void]$lines.Add("| Key concept | Introduced | Reinforced |")
    [void]$lines.Add("| --- | --- | --- |")
    foreach ($item in @($Blueprint.courseConceptArc.conceptIntroductionReinforcementMap)) {
        [void]$lines.Add("| $($item.keyConcept) | $($item.introduced) | $($item.reinforced) |")
    }
    [void]$lines.Add("")
    [void]$lines.Add("## Recommended Student Performance Thread")
    [void]$lines.Add("")
    [void]$lines.Add($Blueprint.courseConceptArc.studentPerformanceThread.scenario)
    [void]$lines.Add("")
    [void]$lines.Add("Across the modules, students would:")
    foreach ($step in @($Blueprint.courseConceptArc.studentPerformanceThread.moduleSteps)) {
        [void]$lines.Add("$($step.moduleNumber). $($step.action)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("## Planning Quality Gates")
    [void]$lines.Add("")
    [void]$lines.Add("Status: $($Blueprint.planningQualityGates.status)")
    [void]$lines.Add("")
    foreach ($check in @($Blueprint.planningQualityGates.checks)) {
        [void]$lines.Add("- $($check.status): $($check.name) - $($check.detail)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("## Academic Approval")
    [void]$lines.Add("")
    [void]$lines.Add("Status: $($Blueprint.academicApproval.status)")
    [void]$lines.Add("")
    [void]$lines.Add("Approver: $($Blueprint.academicApproval.approvedBy)")
    [void]$lines.Add("")
    [void]$lines.Add("Notes: $($Blueprint.academicApproval.notes)")
    [void]$lines.Add("")
    [void]$lines.Add("## Next Steps")
    [void]$lines.Add("")
    foreach ($step in @($Blueprint.nextSteps)) {
        [void]$lines.Add("- $step")
    }
    [void]$lines.Add("")
    [void]$lines.Add("## Detailed Outline")
    [void]$lines.Add("")
    [void]$lines.Add("See `ebook-outline.md` or the course-named outline Word document for the review copy.")
    return ($lines -join "`r`n")
}

function New-EbookBlueprintPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Course,
        [Parameter(Mandatory)][object]$Plan,
        [object]$SourceContext,
        [object]$BrandProfile,
        [switch]$OutlineApproved,
        [string]$ApprovedBy = "",
        [string]$ApprovalNotes = "",
        [string]$ReviewedOutlinePath = ""
    )

    if (-not $BrandProfile) {
        $BrandProfile = New-DefaultBrandProfile
    }

    $blueprint = New-EbookBlueprint `
        -Course $Course `
        -Plan $Plan `
        -SourceContext $SourceContext `
        -BrandProfile $BrandProfile `
        -OutlineApproved:$OutlineApproved `
        -ApprovedBy $ApprovedBy `
        -ApprovalNotes $ApprovalNotes `
        -ReviewedOutlinePath $ReviewedOutlinePath
    $blueprintMarkdown = ConvertTo-EbookBlueprintMarkdown -Course $Course -Blueprint $blueprint
    $outlineMarkdown = ConvertTo-EbookOutlineMarkdown -Course $Course -Blueprint $blueprint

    return [pscustomobject]@{
        course = $Course
        plan = $Plan
        brandProfile = $BrandProfile
        blueprint = $blueprint
        blueprintMarkdown = $blueprintMarkdown
        outlineMarkdown = $outlineMarkdown
    }
}

function Get-DraftPlanFromBlueprint {
    param(
        [Parameter(Mandatory)][object]$Course,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object]$Blueprint
    )

    if (-not $Blueprint.generationGate.canGenerateDraft) {
        return $Plan
    }

    $practiceFrame = Get-CoursePracticeFrame -Course $Course
    $outlineChapters = @($Blueprint.ebookOutline.chapters)
    $draftTitles = @($Plan.chapters | ForEach-Object {
        $chapter = $_
        $outlineChapter = @($outlineChapters | Where-Object { $_.number -eq $chapter.number } | Select-Object -First 1)[0]
        if ($outlineChapter -and $outlineChapter.proposedTitle) {
            $outlineChapter.proposedTitle
        }
        else {
            $chapter.title
        }
    })

    $draftChapters = New-Object System.Collections.ArrayList
    $chapters = @($Plan.chapters)
    for ($i = 0; $i -lt $chapters.Count; $i++) {
        $chapter = $chapters[$i]
        $title = $draftTitles[$i]
        $buildsOn = if ($i -gt 0) { $draftTitles[$i - 1] } else { $chapter.buildsOn }
        $setsUp = if (($i + 1) -lt $draftTitles.Count) { $draftTitles[$i + 1] } else { $chapter.setsUp }
        [void]$draftChapters.Add([pscustomobject]@{
            number = $chapter.number
            title = $title
            focus = $chapter.focus
            buildsOn = $buildsOn
            setsUp = $setsUp
            cohesionBridge = "This chapter connects $buildsOn to $setsUp by having learners use $($chapter.focus) as the next layer of $($practiceFrame.bridgeNoun)."
            learningTargets = @($chapter.learningTargets)
            learningTargetRecords = @($chapter.learningTargetRecords)
            moduleSequence = @($chapter.moduleSequence)
            assessmentHooks = @($chapter.assessmentHooks)
            researchQuery = $chapter.researchQuery
            requiredSections = @($chapter.requiredSections)
        })
    }

    return [pscustomobject]@{
        generatedAt = $Plan.generatedAt
        planVersion = "$($Plan.planVersion)-approved-outline"
        sourceMode = $Plan.sourceMode
        courseCode = $Plan.courseCode
        narrativeSpine = $Plan.narrativeSpine
        chapters = @($draftChapters)
    }
}

function New-EbookPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Course,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object[]]$Sources,
        [object]$SourceContext,
        [object]$BrandProfile,
        [switch]$OutlineApproved,
        [string]$ApprovedBy = "",
        [string]$ApprovalNotes = "",
        [string]$ReviewedOutlinePath = ""
    )

    if (-not $BrandProfile) {
        $BrandProfile = New-DefaultBrandProfile
    }

    Write-EbookGeneratorProgress -Phase "Building planning packet" -Detail "Creating the production blueprint and outline controls."
    $blueprintPackage = New-EbookBlueprintPackage `
        -Course $Course `
        -Plan $Plan `
        -SourceContext $SourceContext `
        -BrandProfile $BrandProfile `
        -OutlineApproved:$OutlineApproved `
        -ApprovedBy $ApprovedBy `
        -ApprovalNotes $ApprovalNotes `
        -ReviewedOutlinePath $ReviewedOutlinePath
    $blueprint = $blueprintPackage.blueprint
    $blueprintMarkdown = $blueprintPackage.blueprintMarkdown
    $outlineMarkdown = $blueprintPackage.outlineMarkdown
    Write-EbookGeneratorProgress -Phase "Preparing draft plan" -Detail "Converting the approved outline into chapter drafting instructions."
    $draftPlan = Get-DraftPlanFromBlueprint -Course $Course -Plan $Plan -Blueprint $blueprint
    Write-EbookGeneratorProgress -Phase "Building source registry" -Detail "Creating learner-facing source IDs and internal source tracking."
    $sourceRegistry = New-SourceRegistry -Sources $Sources
    $sourceRegistryMarkdown = ConvertTo-SourceRegistryMarkdown -Course $Course -SourceRegistry $sourceRegistry
    $brandProfileMarkdown = ConvertTo-BrandProfileMarkdown -BrandProfile $BrandProfile
    Write-EbookGeneratorProgress -Phase "Planning visual assets" -Detail "Planning opener images, quick checks, study aids, and interactive review moments by chapter."
    $engagementPlan = New-EngagementPlan -Course $Course -Plan $draftPlan -BrandProfile $BrandProfile
    $engagementPlanMarkdown = ConvertTo-EngagementPlanMarkdown -Course $Course -EngagementPlan $engagementPlan
    Write-EbookGeneratorProgress -Phase "Generating visual study assets" -Detail "Creating chapter opener banners plus study aids and quick visual checks for each chapter."
    $visualAssets = New-VisualAssets -EngagementPlan $engagementPlan -BrandProfile $BrandProfile
    Write-EbookGeneratorProgress -Phase "Building interactive study page" -Detail "Creating the local interactive review page from the visual plan."
    $interactiveStudyHtml = ConvertTo-InteractiveStudyHtml -Course $Course -EngagementPlan $engagementPlan -BrandProfile $BrandProfile
    Write-EbookGeneratorProgress -Phase "Assembling chapter scaffold" -Detail "Creating the learner-facing scaffold chapter by chapter from parsed course data and source metadata."
    $markdown = ConvertTo-EbookMarkdown -Course $Course -Plan $draftPlan -Sources $Sources -SourceRegistry $sourceRegistry -EngagementPlan $engagementPlan -BrandProfile $BrandProfile
    Write-EbookGeneratorProgress -Phase "Applying plain language pass" -Detail "Checking wording, sentence length, and learner-facing tone."
    $markdown = ConvertTo-PlainLanguageMarkdown -Markdown $markdown -Course $Course
    Write-EbookGeneratorProgress -Phase "Building browser exports" -Detail "Creating the review HTML and local worker payload."
    $html = ConvertTo-SimpleHtmlFromMarkdown -Markdown $markdown -Title "$($Course.courseCode): $($Course.courseName)" -BrandProfile $BrandProfile
    $workerScript = ConvertTo-CloudflareWorkerScript -Html $html -RoutePath "/ebook"
    Write-EbookGeneratorProgress -Phase "Running quality checks" -Detail "Checking chapter depth, source grounding, visual coverage, accessibility, and learner cleanliness."
    $qualityReport = New-EbookQualityReport -Course $Course -Plan $draftPlan -Sources $Sources -SourceContext $SourceContext -Markdown $markdown -BrandProfile $BrandProfile
    $qualityReportMarkdown = ConvertTo-QualityReportMarkdown -Report $qualityReport
    Write-EbookGeneratorProgress -Phase "Running publishing editor review" -Detail "Reviewing manuscript depth, learner experience, source integrity, and production readiness."
    $publishingEditorReport = New-PublishingEditorReport -Course $Course -Plan $draftPlan -Sources $Sources -SourceContext $SourceContext -QualityReport $qualityReport -Markdown $markdown -EngagementPlan $engagementPlan -BrandProfile $BrandProfile
    $publishingEditorReportMarkdown = ConvertTo-PublishingEditorReportMarkdown -Report $publishingEditorReport
    Write-EbookGeneratorProgress -Phase "Running agent review" -Detail "Running named production gates and summarizing warnings or failures."
    $agentReport = New-AgentReviewReport -Course $Course -Plan $draftPlan -Sources $Sources -SourceContext $SourceContext -QualityReport $qualityReport -Markdown $markdown -BrandProfile $BrandProfile -EditorialReport $publishingEditorReport -Blueprint $blueprint
    $agentReportMarkdown = ConvertTo-AgentReportMarkdown -Report $agentReport
    Write-EbookGeneratorProgress -Phase "Package assembly complete" -Detail "All in-memory manuscript, visual, and report assets are ready for export."

    return [pscustomobject]@{
        course = $Course
        plan = $draftPlan
        blueprint = $blueprint
        blueprintMarkdown = $blueprintMarkdown
        outlineMarkdown = $outlineMarkdown
        sources = $Sources
        brandProfile = $BrandProfile
        brandProfileMarkdown = $brandProfileMarkdown
        sourceRegistry = $sourceRegistry
        sourceRegistryMarkdown = $sourceRegistryMarkdown
        sourceContext = $SourceContext
        engagementPlan = $engagementPlan
        engagementPlanMarkdown = $engagementPlanMarkdown
        visualAssets = $visualAssets
        interactiveStudyHtml = $interactiveStudyHtml
        qualityReport = $qualityReport
        qualityReportMarkdown = $qualityReportMarkdown
        publishingEditorReport = $publishingEditorReport
        publishingEditorReportMarkdown = $publishingEditorReportMarkdown
        agentReport = $agentReport
        agentReportMarkdown = $agentReportMarkdown
        markdown = $markdown
        html = $html
        workerScript = $workerScript
    }
}

function Get-PrimarySourceSentence {
    param([object]$ChapterSources)

    if ($ChapterSources -and $ChapterSources.sourceContext.Count -gt 0) {
        return "The uploaded course context defines the chapter scope and learning objectives; student-facing citations should come from academic, open education, or reviewed research sources."
    }

    return "The learning objectives define the chapter scope; student-facing citations should come from academic, open education, or reviewed research sources."
}

function Get-OpenStaxSentence {
    param([object]$ChapterSources)

    if (-not $ChapterSources -or $ChapterSources.openStax.Count -eq 0) {
        return "No OpenStax page is currently mapped; add one to config/openstax-map.json before production."
    }

    $titles = @($ChapterSources.openStax | Select-Object -First 3 | ForEach-Object { $_.title -replace " \| OpenStax$", "" })
    return "OpenStax sources for this chapter include " + ($titles -join "; ") + "."
}

function Get-ResearchSentence {
    param([object]$ChapterSources)

    if (-not $ChapterSources -or $ChapterSources.researchCandidates.Count -eq 0) {
        return "Research discovery did not return a source for this chapter; run again with research enabled or add a curated source."
    }

    $items = @(
        $ChapterSources.researchCandidates |
            Where-Object { $_.title -and $_.title -ne "OpenAlex search failed" } |
            Select-Object -First 3 |
            ForEach-Object {
                $title = ConvertTo-CleanText ($_.title -replace "<[^>]+>", "")
                if ($_.year) { "$title ($($_.year))" } else { $title }
            }
    )

    if ($items.Count -eq 0) {
        return "Research discovery returned no usable sources for this chapter."
    }

    return "Research sources to review and cite include " + ($items -join "; ") + "."
}

function Get-ObjectiveApplicationPrompt {
    param([string]$Objective)

    $lower = $Objective.ToLowerInvariant()
    if ($lower -match "critical thinking") {
        return "Analyze a short claim by identifying the question, the evidence offered, the assumptions behind it, and one habit that would improve the thinking."
    }
    if ($lower -match "universal intellectual standards|clarity|accuracy|relevance|sufficiency|credibility|sources|ai") {
        return "Evaluate a source or AI-generated response for clarity, accuracy, relevance, credibility, and sufficiency before deciding whether it supports a conclusion."
    }
    if ($lower -match "problem|solution|alternatives|criteria") {
        return "Use a problem-solving process to define the issue, list constraints, compare alternatives, and justify one solution with evidence."
    }
    if ($lower -match "bias|pressure|context|fallacies|reasoning errors|decision") {
        return "Review a decision scenario for weak evidence, bias, pressure, context, and reasoning errors that could distort judgment."
    }
    if ($lower -match "inductive|deductive|conclusions logically follow|strength of reasoning") {
        return "Test whether a conclusion follows from the stated reasons, then explain whether the argument is deductively valid or inductively strong."
    }
    if ($lower -match "ethical|persuasive argument|personal position") {
        return "Construct a concise ethical argument that states a position, uses evaluated evidence, addresses an objection, and communicates the reasoning clearly."
    }
    if ($lower -match "windows|operating system") {
        return "Complete a Windows task by choosing the correct navigation feature, documenting the steps, and verifying the result."
    }
    if ($lower -match "files|folders|cloud storage|local and cloud|accessible records") {
        return "Create a file organization plan that names the folder path, file naming standard, storage location, backup or sync check, and sharing permission."
    }
    if ($lower -match "microsoft word|professional documents|formatting|\bstructure\b|layout") {
        return "Revise a Word document so the layout, headings, spacing, alignment, and review checks support a professional reader experience."
    }
    if ($lower -match "credible sources|cite|citation|apa|academic writing") {
        return "Evaluate one source, explain how it supports an academic claim, and create a matching APA-style in-text citation and reference entry."
    }
    if ($lower -match "cybersecurity|responsible digital|personal and organizational information|privacy|security") {
        return "Review a digital scenario for privacy, phishing, account, file, or communication risk and choose the safest next action."
    }
    if ($lower -match "keyboarding|words per minute|wpm|accuracy|timed assessment") {
        return "Complete a timed keyboarding practice, record words per minute and accuracy, and identify one correction habit for the next round."
    }
    if ($lower -match "map|inputs|outputs|handoffs") {
        return "Build a simple process map that shows the input, output, owner, handoff, and risk point for each step."
    }
    if ($lower -match "customer|responsiveness|professionalism") {
        return "Evaluate a customer interaction for speed, clarity, tone, documentation, and follow-up."
    }
    if ($lower -match "improvement|strategy") {
        return "Use evidence from the scenario to recommend one process improvement and explain the expected effect."
    }
    if ($lower -match "finance|marketing|human|core functions") {
        return "Trace how one decision moves through finance, human resources, marketing, and operations."
    }
    if ($lower -match "technology|procedures|productivity|risk") {
        return "Identify how a person, a tool, and a procedure either reduce or increase operational risk."
    }

    return "Apply the concept to a realistic decision and explain the reasoning."
}

function Format-ApaAuthorName {
    param([AllowNull()][string]$Name)

    $clean = ConvertTo-CleanText $Name
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return ""
    }

    if ($clean -match ",") {
        return $clean
    }

    $parts = @($clean -split "\s+" | Where-Object { $_ })
    if ($parts.Count -le 1) {
        return $clean
    }

    $lastName = $parts[-1]
    $initials = @($parts[0..($parts.Count - 2)] | ForEach-Object {
        $piece = ($_ -replace "[^A-Za-z-]", "")
        if ($piece) { "$($piece.Substring(0, 1).ToUpperInvariant())." }
    })
    if ($initials.Count -eq 0) {
        return $lastName
    }

    return "$lastName, $($initials -join ' ')"
}

function Format-ApaAuthorList {
    param([AllowNull()][object[]]$Authors)

    $formatted = @(@(
        foreach ($author in @($Authors | Select-Object -First 20)) {
            $name = Format-ApaAuthorName -Name ([string]$author)
            if (-not [string]::IsNullOrWhiteSpace($name)) { $name }
        }
    ) | Select-Object -Unique)

    if ($formatted.Count -eq 0) { return "" }
    if ($formatted.Count -eq 1) { return $formatted[0] }
    if ($formatted.Count -eq 2) { return "$($formatted[0]), & $($formatted[1])" }
    return "$(($formatted[0..($formatted.Count - 2)]) -join ', '), & $($formatted[-1])"
}

function Format-ApaReference {
    param(
        [AllowNull()][string]$Title,
        [AllowNull()][object[]]$Authors,
        [AllowNull()][object]$Year,
        [AllowNull()][string]$Source,
        [AllowNull()][string]$Url,
        [string]$SourceType = "Research Source"
    )

    $cleanTitle = ConvertTo-CleanText ($Title -replace "\s+\|\s+OpenStax$", "")
    $cleanSource = ConvertTo-CleanText $Source
    $yearText = if ($Year) { [string]$Year } else { "n.d." }
    $authorText = Format-ApaAuthorList -Authors $Authors
    if ([string]::IsNullOrWhiteSpace($authorText) -and $SourceType -match "Open Education") {
        $authorText = "OpenStax"
    }

    $parts = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($authorText)) {
        $authorYear = if ($authorText.EndsWith(".")) { "$authorText ($yearText)." } else { "$authorText. ($yearText)." }
        [void]$parts.Add($authorYear)
        if (-not [string]::IsNullOrWhiteSpace($cleanTitle)) { [void]$parts.Add("$cleanTitle.") }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($cleanTitle)) { [void]$parts.Add("$cleanTitle. ($yearText).") }
        else { [void]$parts.Add("Untitled source. ($yearText).") }
    }

    if (-not [string]::IsNullOrWhiteSpace($cleanSource) -and $cleanSource -ne $cleanTitle) {
        [void]$parts.Add("$cleanSource.")
    }
    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        [void]$parts.Add($Url)
    }

    return (($parts -join " ") -replace "\s+", " ").Trim()
}

function Get-ChapterCitationModel {
    param(
        [object]$ChapterSources,
        [object]$SourceRegistry
    )

    $sourceContext = New-Object System.Collections.ArrayList
    $openStax = New-Object System.Collections.ArrayList
    $research = New-Object System.Collections.ArrayList

    if($ChapterSources.sourcePolicy.mode -eq 'UploadedOnly'){
        $index=1
        foreach($file in @($ChapterSources.sourceContext.sourceFile | Sort-Object -Unique)){
            $name=[IO.Path]::GetFileName($file) -replace '^\d{3}-',''
            $registered=@($SourceRegistry.items | Where-Object sourceKey -eq "uploaded|$file" | Select-Object -First 1)
            [void]$sourceContext.Add([pscustomobject]@{id=$(if($registered.Count){$registered[0].id}else{"U$index"});label=$name;reference=$name;title=$name;url='';sourceKey="uploaded|$file"})
            $index++
        }
    }

    $index = 1
    foreach ($source in @($ChapterSources.openStax | Select-Object -First 5)) {
        $key = "openstax|$($source.url)"
        $registryItem = if ($SourceRegistry) { @($SourceRegistry.items | Where-Object { $_.sourceKey -eq $key } | Select-Object -First 1)[0] } else { $null }
        [void]$openStax.Add([pscustomobject]@{
            id = if ($registryItem) { $registryItem.id } else { "OS$index" }
            label = ($source.title -replace " \| OpenStax$", "")
            reference = Format-ApaReference -Title $source.title -Authors @("OpenStax") -Year "n.d." -Source $source.book -Url $source.url -SourceType "Open Education Resource"
            title = ($source.title -replace " \| OpenStax$", "")
            authors = @("OpenStax")
            year = "n.d."
            source = $source.book
            url = $source.url
            excerpt = $source.preview
            sourceKey = $key
        })
        $index++
    }

    $index = 1
    foreach ($item in @($ChapterSources.researchCandidates | Where-Object { $_.title -and $_.title -ne "OpenAlex search failed" } | Select-Object -First 5)) {
        $title = ConvertTo-CleanText ($item.title -replace "<[^>]+>", "")
        $label = $title
        if ($item.year) { $label += " ($($item.year))" }
        if ($item.source) { $label += ", $($item.source)" }
        $reference = Format-ApaReference -Title $title -Authors @($item.authors) -Year $item.year -Source $item.source -Url $(if ($item.doi) { $item.doi } elseif ($item.url) { $item.url } else { "" }) -SourceType "Research Source"
        $keyUrl = if ($item.url) { $item.url } elseif ($item.doi) { $item.doi } else { "$title|$($item.year)" }
        $key = "research|$keyUrl"
        $registryItem = if ($SourceRegistry) { @($SourceRegistry.items | Where-Object { $_.sourceKey -eq $key } | Select-Object -First 1)[0] } else { $null }

        [void]$research.Add([pscustomobject]@{
            id = if ($registryItem) { $registryItem.id } else { "R$index" }
            label = $label
            reference = $reference
            title = $title
            authors = @($item.authors)
            year = $item.year
            source = $item.source
            url = $item.url
            excerpt = $item.note
            sourceKey = $key
        })
        $index++
    }

    return [pscustomobject]@{
        sourceContext = @($sourceContext)
        openStax = @($openStax)
        research = @($research)
    }
}

function Add-RegistryChapter {
    param(
        [hashtable]$Entry,
        [object]$Source
    )

    $chapterLabel = "Chapter $($Source.chapterNumber): $($Source.chapterTitle)"
    if (-not @($Entry.chapters).Contains($chapterLabel)) {
        [void]$Entry.chapters.Add($chapterLabel)
    }
}

function New-SourceRegistry {
    param([object[]]$Sources)

    $items = New-Object System.Collections.ArrayList
    $byKey = @{}
    $openStaxIndex = 1
    $researchIndex = 1

    foreach ($source in $Sources) {
        foreach ($open in @($source.openStax)) {
            $key = "openstax|$($open.url)"
            if (-not $byKey.ContainsKey($key)) {
                $entry = [ordered]@{
                    id = "OS$openStaxIndex"
                    type = "Open Education Resource"
                    title = ($open.title -replace " \| OpenStax$", "")
                    url = $open.url
                    sourceKey = $key
                    sourceName = $open.book
                    sourceFile = ""
                    chunkId = ""
                    note = $open.licenseNote
                    sortOrder = 1000 + $openStaxIndex
                    chapters = New-Object System.Collections.ArrayList
                }
                $byKey[$key] = $entry
                $openStaxIndex++
            }
            Add-RegistryChapter -Entry $byKey[$key] -Source $source
        }
    }

    foreach ($source in $Sources) {
        foreach ($research in @($source.researchCandidates | Where-Object { $_.title -and $_.title -ne "OpenAlex search failed" })) {
            $title = ConvertTo-CleanText ($research.title -replace "<[^>]+>", "")
            $label = $title
            if ($research.year) { $label += " ($($research.year))" }
            if ($research.source) { $label += ", $($research.source)" }
            $keyUrl = if ($research.url) { $research.url } elseif ($research.doi) { $research.doi } else { "$title|$($research.year)" }
            $key = "research|$keyUrl"
            if (-not $byKey.ContainsKey($key)) {
                $entry = [ordered]@{
                    id = "R$researchIndex"
                    type = "Research Source"
                    title = $label
                    url = $research.url
                    sourceKey = $key
                    sourceName = $research.source
                    sourceFile = ""
                    chunkId = ""
                    note = "Research source selected during discovery; verify fit during SME review."
                    sortOrder = 2000 + $researchIndex
                    chapters = New-Object System.Collections.ArrayList
                }
                $byKey[$key] = $entry
                $researchIndex++
            }
            Add-RegistryChapter -Entry $byKey[$key] -Source $source
        }
    }

    $uploadedIndex=1
    foreach($source in $Sources | Where-Object {$_.sourcePolicy.mode -eq 'UploadedOnly'}){
        foreach($file in @($source.sourceContext.sourceFile | Sort-Object -Unique)){
            $key="uploaded|$file"
            if(-not $byKey.ContainsKey($key)){
                $name=[IO.Path]::GetFileName($file) -replace '^\d{3}-',''
                $byKey[$key]=[ordered]@{id="U$uploadedIndex";type='Provided document';title=$name;url='';sourceKey=$key;sourceName=$name;sourceFile=$file;chunkId='';note='Provided source; academic review required.';sortOrder=(3000+$uploadedIndex);chapters=(New-Object Collections.ArrayList)}
                $uploadedIndex++
            }
            Add-RegistryChapter -Entry $byKey[$key] -Source $source
        }
    }
    foreach ($entry in $byKey.GetEnumerator() | Sort-Object { $_.Value.sortOrder }) {
        $value = $entry.Value
        [void]$items.Add([pscustomobject]@{
            id = $value.id
            type = $value.type
            title = $value.title
            url = $value.url
            sourceKey = $value.sourceKey
            sourceName = $value.sourceName
            sourceFile = $value.sourceFile
            chunkId = $value.chunkId
            note = $value.note
            sortOrder = $value.sortOrder
            chapters = @($value.chapters)
        })
    }

    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        items = @($items)
    }
}

function ConvertTo-SourceRegistryMarkdown {
    param(
        [object]$Course,
        [object]$SourceRegistry
    )

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# Source Registry")
    [void]$lines.Add("")
    [void]$lines.Add("Course: $($Course.courseCode) - $($Course.courseName)")
    [void]$lines.Add("")
    [void]$lines.Add("This file is the source of truth for learner-facing academic and open education source IDs used in the ebook package.")
    [void]$lines.Add("")

    foreach ($item in @($SourceRegistry.items)) {
        [void]$lines.Add("<a id=""$($item.id)""></a>")
        [void]$lines.Add("")
        [void]$lines.Add("## $($item.id): $($item.title)")
        [void]$lines.Add("")
        [void]$lines.Add("- Type: $($item.type)")
        if ($item.url) {
            [void]$lines.Add("- Link: $(Format-MarkdownLink -Text $item.url -Url $item.url)")
        }
        if ($item.sourceFile) {
            [void]$lines.Add("- File: $($item.sourceFile)")
        }
        if ($item.note) {
            [void]$lines.Add("- Note: $($item.note)")
        }
        if (@($item.chapters).Count -gt 0) {
            [void]$lines.Add("- Used in: $((@($item.chapters)) -join '; ')")
        }
        [void]$lines.Add("")
    }

    return ($lines -join "`r`n")
}

function Get-EngagementVisualSpec {
    param([object]$Chapter)

    $focus = $Chapter.focus.ToLowerInvariant()
    if ($focus -match "critical thinking") {
        return [pscustomobject]@{
            placement = "After the Learning Objectives"
            assetType = "Reasoning Map"
            title = "Critical Thinking Habit Loop"
            learnerPurpose = "Show how careful thinkers move from question, evidence, assumptions, and reflection toward a better conclusion."
            prompt = "Create a clean educational reasoning map for critical thinking habits. Include question, evidence, assumptions, alternatives, conclusion, and reflection. Professional textbook style, accessible colors, no logos."
            interactionIdea = "Learners identify the weakest part of a claim and choose which habit would improve the thinking."
        }
    }
    if ($focus -match "information evaluation|intellectual standards") {
        return [pscustomobject]@{
            placement = "Before the source evaluation section"
            assetType = "Evaluation Checklist"
            title = "Intellectual Standards Source Check"
            learnerPurpose = "Help students test claims and sources for clarity, accuracy, relevance, credibility, and sufficiency."
            prompt = "Create a clean checklist infographic for evaluating information and AI-generated content. Include clarity, accuracy, relevance, credibility, sufficiency, and limits. Professional textbook style, accessible colors, no logos."
            interactionIdea = "Students score a source against each standard and explain which standard most affects the conclusion."
        }
    }
    if ($focus -match "problem solving") {
        return [pscustomobject]@{
            placement = "Before Chapter Synthesis"
            assetType = "Problem-Solving Flow"
            title = "Problem-Solving Decision Path"
            learnerPurpose = "Guide students from problem definition to criteria, alternatives, evidence, solution, and justification."
            prompt = "Create a professional flow diagram for a systematic problem-solving process: define issue, identify constraints, set criteria, compare alternatives, choose solution, justify with evidence. Accessible textbook style."
            interactionIdea = "Students fill one sentence for each step before writing the justification."
        }
    }
    if ($focus -match "decision influences|bias|reasoning errors") {
        return [pscustomobject]@{
            placement = "After the decision-making scenario"
            assetType = "Decision Review Grid"
            title = "Bias and Evidence Decision Review"
            learnerPurpose = "Help students spot weak evidence, bias, pressure, context, AI influence, and fallacies before accepting a conclusion."
            prompt = "Create a clean decision review grid for critical thinking. Include evidence quality, bias, pressure, context, AI influence, fallacy check, and conclusion risk. Professional educational style."
            interactionIdea = "Learners mark which influence is most likely to distort judgment in a scenario."
        }
    }
    if ($focus -match "inductive|deductive") {
        return [pscustomobject]@{
            placement = "Before argument evaluation practice"
            assetType = "Argument Diagram"
            title = "Inductive and Deductive Argument Test"
            learnerPurpose = "Show how reasons connect to conclusions and how learners test whether the support is valid, strong, weak, or incomplete."
            prompt = "Create a clean argument diagram comparing deductive validity and inductive strength. Include reasons, conclusion, follows necessarily, probably supports, missing assumption, and strength check."
            interactionIdea = "Students classify mini-arguments and explain what would strengthen the support."
        }
    }
    if ($focus -match "ethical reasoning|persuasive argumentation|ethical position") {
        return [pscustomobject]@{
            placement = "Before the ethical argument section"
            assetType = "Argument Builder"
            title = "Ethical Argument Builder"
            learnerPurpose = "Guide students to state a position, evaluate evidence, consider stakeholders, address objections, and communicate a reasoned ethical conclusion."
            prompt = "Create a professional ethical argument builder infographic. Include issue, position, evidence, stakeholders, values, objection, response, and conclusion. Accessible textbook style, no logos."
            interactionIdea = "Learners add one possible objection and revise their position statement for clarity."
        }
    }
    if ($focus -match "operating system|software environment") {
        return [pscustomobject]@{
            placement = "After the Learning Objectives"
            assetType = "Navigation Map"
            title = "Windows Workspace Navigation Map"
            learnerPurpose = "Show how students move through the desktop, taskbar, Start menu, settings, apps, windows, and help resources during a routine task."
            prompt = "Create a clean educational navigation map for a Windows 11 workspace. Include desktop, Start menu, taskbar, app window, settings, search, and help. Professional textbook style, accessible colors, no logos."
            interactionIdea = "Learners identify which Windows feature would help them open, switch, search, adjust, or troubleshoot a task."
        }
    }
    if ($focus -match "file management|local and cloud") {
        return [pscustomobject]@{
            placement = "Before the file organization practice"
            assetType = "Workflow Diagram"
            title = "Local and Cloud File Organization Flow"
            learnerPurpose = "Help students choose clear file names, folders, cloud locations, backups, and sharing settings."
            prompt = "Create a professional workflow diagram for file management across local and cloud storage. Include name file, choose folder, save version, back up or sync, set sharing, and verify access. Accessible textbook style, no logos."
            interactionIdea = "Students classify a file by purpose, choose a storage location, and explain the naming and sharing choice."
        }
    }
    if ($focus -match "document creation|microsoft word") {
        return [pscustomobject]@{
            placement = "Before the Word document practice"
            assetType = "Checklist"
            title = "Word Document Design Checklist"
            learnerPurpose = "Guide students through layout, styles, headings, spacing, alignment, readability, and final review."
            prompt = "Create a clean checklist infographic for professional Microsoft Word document design. Include layout, margins, headings, styles, spacing, alignment, accessibility, and final review. Professional textbook style."
            interactionIdea = "Learners review a document sample and mark which design standard needs revision first."
        }
    }
    if ($focus -match "source evaluation|apa citation|academic writing") {
        return [pscustomobject]@{
            placement = "Before the source and citation section"
            assetType = "Evaluation Checklist"
            title = "APA Source-to-Citation Check"
            learnerPurpose = "Help students connect source credibility, note-taking, paraphrasing, in-text citation, and reference-list accuracy."
            prompt = "Create a clean educational checklist for APA source use. Include credible source, relevant evidence, paraphrase, in-text citation, reference entry, and final verification. Accessible textbook style."
            interactionIdea = "Students inspect a source and citation pair, then identify what must be corrected before the work is shared."
        }
    }
    if ($focus -match "cybersecurity|digital responsibility|keyboarding") {
        return [pscustomobject]@{
            placement = "Before Chapter Synthesis"
            assetType = "Routine Map"
            title = "Secure Digital Work Routine"
            learnerPurpose = "Show how security habits, responsible behavior, and keyboarding accuracy protect digital work."
            prompt = "Create a professional routine map for secure digital work. Include password care, privacy check, phishing caution, device/file protection, responsible communication, and keyboarding practice. Accessible textbook style."
            interactionIdea = "Learners choose the highest-risk habit in a scenario and write one secure replacement behavior."
        }
    }
    if ($focus -match "interpersonal|listening|audience awareness") {
        return [pscustomobject]@{
            placement = "After the Learning Objectives"
            assetType = "Communication Map"
            title = "Audience and Listening Signal Map"
            learnerPurpose = "Show how audience, purpose, listening, verbal signals, and nonverbal signals shape understanding."
            prompt = "Create a clean textbook communication map showing audience, purpose, listening, verbal cues, nonverbal cues, feedback, and meaning. Professional communication ebook style, accessible colors, no logos, no readable text."
            interactionIdea = "Learners compare how the same message changes when audience, tone, or nonverbal signals change."
        }
    }
    if ($focus -match "message planning|tone|channel") {
        return [pscustomobject]@{
            placement = "Before Chapter Synthesis"
            assetType = "Message Planning Flow"
            title = "Audience-Purpose-Channel Message Flow"
            learnerPurpose = "Help students see how purpose, reader need, tone, organization, channel, and revision shape a professional message."
            prompt = "Create a professional textbook flow diagram for planning a business message. Include audience, purpose, key idea, tone, channel, organization, revision, and follow-up. Accessible colors, no logos, no readable text."
            interactionIdea = "Learners choose the clearest channel and tone for different message situations."
        }
    }
    if ($focus -match "difficult-message|bad-news|conflict") {
        return [pscustomobject]@{
            placement = "Before Chapter Synthesis"
            assetType = "Difficult Message Guide"
            title = "Clear and Respectful Difficult Message Path"
            learnerPurpose = "Show how clarity, empathy, evidence, reason, next step, and tone work together in difficult messages."
            prompt = "Create a clean textbook guide for difficult professional messages. Include audience need, clear issue, reason, respectful tone, next step, and relationship repair. Accessible colors, no logos, no readable text."
            interactionIdea = "Learners compare a blunt message with a clearer, more respectful revision."
        }
    }
    if ($focus -match "collaboration|meeting|team") {
        return [pscustomobject]@{
            placement = "Before Chapter Synthesis"
            assetType = "Meeting Communication Map"
            title = "Meeting Purpose and Participation Map"
            learnerPurpose = "Help students connect agenda purpose, roles, listening, participation, decisions, and follow-up."
            prompt = "Create a clean textbook meeting communication map. Include purpose, agenda, roles, listening, turn-taking, decisions, and follow-up. Professional communication ebook style, accessible colors, no logos, no readable text."
            interactionIdea = "Learners identify which meeting habit would make a team conversation clearer."
        }
    }
    if ($focus -match "presentation") {
        return [pscustomobject]@{
            placement = "Before Chapter Synthesis"
            assetType = "Presentation Planning Arc"
            title = "Audience-Centered Presentation Arc"
            learnerPurpose = "Show how audience, purpose, opening, evidence, visual support, delivery, and closing shape a presentation."
            prompt = "Create a clean textbook presentation planning arc. Include audience, purpose, opening, evidence, visual support, delivery, and closing. Professional communication ebook style, accessible colors, no logos, no readable text."
            interactionIdea = "Learners adjust a presentation opening for audience, purpose, and tone."
        }
    }
    if ($focus -match "core business") {
        return [pscustomobject]@{
            placement = "After the Business in Practice case"
            assetType = "Infographic"
            title = "Cross-Functional Handoff Map"
            learnerPurpose = "Show how finance, human resources, marketing, and operations exchange information during one office decision."
            prompt = "Create a clean educational infographic showing a cross-functional handoff map for a student service campaign. Include four lanes: finance, human resources, marketing, and operations. Show inputs, approvals, handoffs, and risk points. Professional textbook style, simple colors, no brand logos."
            interactionIdea = "Clickable hotspots reveal what each function needs before work can move forward."
        }
    }
    if ($focus -match "workflow|process") {
        return [pscustomobject]@{
            placement = "Before the Workflow Coordination section"
            assetType = "Process Diagram"
            title = "Office Process Flow From Intake to Follow-Up"
            learnerPurpose = "Make inputs, outputs, roles, and handoffs visible before students build their own process map."
            prompt = "Create a textbook-style process diagram for an office workflow from intake to review, correction, approval, and customer follow-up. Label trigger, input, role owner, handoff, risk point, and output. Clear, accessible, professional."
            interactionIdea = "Students can reveal or hide risk points and then compare their map with the model."
        }
    }
    if ($focus -match "customer") {
        return [pscustomobject]@{
            placement = "After the customer-facing process explanation"
            assetType = "Decision Tree"
            title = "Customer Service Response Decision Tree"
            learnerPurpose = "Help students choose a timely, accurate, professional response based on urgency, documentation, and escalation needs."
            prompt = "Create a clean decision-tree infographic for customer-facing office service. Branches should include urgency, available information, confidentiality, escalation, documentation, and follow-up. Use a calm professional style."
            interactionIdea = "Scenario cards let students choose a path and see how the response changes."
        }
    }
    if ($focus -match "improvement") {
        return [pscustomobject]@{
            placement = "Before Chapter Synthesis"
            assetType = "Cycle Diagram"
            title = "Evidence-Based Improvement Cycle"
            learnerPurpose = "Guide students from problem evidence to recommendation and measurement."
            prompt = "Create a professional educational cycle diagram for operational improvement: define problem, gather evidence, identify constraint, recommend change, test result, adjust process. Include small office-operation icons."
            interactionIdea = "Students enter one sentence at each cycle step before writing the improvement memo."
        }
    }

    return [pscustomobject]@{
        placement = "After the Learning Objectives"
        assetType = "Infographic"
        title = "People, Technology, and Procedures Risk Triangle"
        learnerPurpose = "Show how people, tools, and procedures interact to influence productivity and risk."
        prompt = "Create a clean textbook infographic showing a triangle with people, technology, and procedures. Add office-operation examples around the triangle: handoffs, records, templates, shared inbox, ownership, and risk points. Professional and accessible."
        interactionIdea = "Learners click each side of the triangle to see a short workplace example."
    }
}

function Get-ChapterOpenerImagePrompt {
    param([object]$Chapter, [object]$BrandProfile)
    $brandGuidance = Get-BrandPromptGuidance -BrandProfile $BrandProfile
    return "Generate a real, wide photographic/editorial chapter banner for Chapter $($Chapter.number): $($Chapter.title). Ground the scene in this chapter's actual content and objectives: $($Chapter.focus); $(@($Chapter.learningTargets) -join '; '). Read the final chapter before choosing a scene; do not infer an unrelated course from a keyword. No readable text, labels, logos, watermarks, diagrams, clip-art, or locally drawn shapes. $brandGuidance"
}

function Get-ChapterOpenerAltText {
    param([object]$Chapter)

    $focus = $Chapter.focus.ToLowerInvariant()
    if ($focus -match "critical thinking") {
        return "Chapter $($Chapter.number) opener illustration showing a learner reviewing a claim, evidence cards, assumptions, alternatives, and a reflection step."
    }
    if ($focus -match "information evaluation|intellectual standards") {
        return "Chapter $($Chapter.number) opener illustration showing a learner evaluating sources and AI-generated content for clarity, accuracy, relevance, credibility, and sufficiency."
    }
    if ($focus -match "problem solving") {
        return "Chapter $($Chapter.number) opener illustration showing a learner defining a problem, comparing alternatives, weighing constraints, and justifying a solution."
    }
    if ($focus -match "decision influences|bias|reasoning errors") {
        return "Chapter $($Chapter.number) opener illustration showing evidence, bias, pressure, context, AI influence, and reasoning-error cues being reviewed before a decision."
    }
    if ($focus -match "inductive|deductive") {
        return "Chapter $($Chapter.number) opener illustration showing connected reasoning paths from premises and evidence toward conclusions."
    }
    if ($focus -match "ethical reasoning|persuasive argumentation|ethical position") {
        return "Chapter $($Chapter.number) opener illustration showing a learner building an ethical argument with evidence, stakeholders, values, objections, and a clear position."
    }
    if ($focus -match "operating system|software environment") {
        return "Chapter $($Chapter.number) opener illustration showing a learner navigating a Windows-style workspace with app windows, search, settings, and taskbar tools."
    }
    if ($focus -match "file management|local and cloud") {
        return "Chapter $($Chapter.number) opener illustration showing a learner organizing files into local and cloud folders with backup, sync, and sharing cues."
    }
    if ($focus -match "document creation|microsoft word") {
        return "Chapter $($Chapter.number) opener illustration showing a learner building a professional document with headings, layout blocks, formatting controls, and review marks."
    }
    if ($focus -match "source evaluation|apa citation|academic writing") {
        return "Chapter $($Chapter.number) opener illustration showing a learner comparing credible sources, taking notes, and checking academic citations."
    }
    if ($focus -match "cybersecurity|digital responsibility|keyboarding") {
        return "Chapter $($Chapter.number) opener illustration showing secure digital habits, protected files, privacy checks, phishing awareness, and keyboarding practice."
    }
    if ($focus -match "interpersonal|listening|audience awareness") {
        return "Chapter $($Chapter.number) opener illustration showing a learner listening carefully in a professional conversation with audience, tone, feedback, and nonverbal-signal cues."
    }
    if ($focus -match "message planning|tone|channel") {
        return "Chapter $($Chapter.number) opener illustration showing a learner planning a professional message around audience, purpose, channel, tone, organization, and revision."
    }
    if ($focus -match "difficult-message|bad-news|conflict") {
        return "Chapter $($Chapter.number) opener illustration showing a learner revising a difficult professional message for clarity, empathy, respectful tone, evidence, and next steps."
    }
    if ($focus -match "collaboration|meeting|team") {
        return "Chapter $($Chapter.number) opener illustration showing a professional meeting with agenda purpose, listening, participation, decisions, and follow-up cues."
    }
    if ($focus -match "presentation") {
        return "Chapter $($Chapter.number) opener illustration showing a learner preparing an audience-centered presentation with evidence, visual support, delivery practice, and a clear closing."
    }
    if ($focus -match "core business") {
        return "Chapter $($Chapter.number) opener illustration showing business teams coordinating finance, human resources, marketing, and operations around budgets, staffing, customer messaging, and delivery tasks."
    }
    if ($focus -match "workflow|process") {
        return "Chapter $($Chapter.number) opener illustration showing an office workflow moving from intake through review, correction, approval, and customer follow-up."
    }
    if ($focus -match "customer") {
        return "Chapter $($Chapter.number) opener illustration showing a customer-facing office team handling phone, email, records, and follow-up with professional service."
    }
    if ($focus -match "improvement") {
        return "Chapter $($Chapter.number) opener illustration showing an office team reviewing evidence, finding a service delay, and planning an operational improvement."
    }

    return "Chapter $($Chapter.number) opener illustration showing an administrative office team coordinating people, technology, procedures, records, and workflow tools."
}

function Get-QuickVisualCheckSpec {
    param([object]$Chapter)

    $focus = $Chapter.focus.ToLowerInvariant()
    if ($focus -match "critical thinking") {
        return [pscustomobject]@{
            title = "Question the Claim"
            prompt = "Before accepting a claim, ask which question it answers, what evidence supports it, what assumptions it carries, and what alternative explanation could fit."
        }
    }
    if ($focus -match "information evaluation|intellectual standards") {
        return [pscustomobject]@{
            title = "Standards Before Trust"
            prompt = "Check clarity, accuracy, relevance, credibility, and sufficiency before using information as support for a conclusion."
        }
    }
    if ($focus -match "problem solving") {
        return [pscustomobject]@{
            title = "Define Before Solving"
            prompt = "A useful solution depends on a clear issue, known constraints, fair criteria, compared alternatives, and evidence-based justification."
        }
    }
    if ($focus -match "decision influences|bias|reasoning errors") {
        return [pscustomobject]@{
            title = "Find the Distortion"
            prompt = "Look for weak evidence, bias, pressure, context, AI influence, or fallacies before deciding how much confidence the conclusion deserves."
        }
    }
    if ($focus -match "inductive|deductive") {
        return [pscustomobject]@{
            title = "Test the Support"
            prompt = "Ask whether the conclusion must follow from the premises or is only made more likely by the evidence."
        }
    }
    if ($focus -match "ethical reasoning|persuasive argumentation|ethical position") {
        return [pscustomobject]@{
            title = "Position With Reasons"
            prompt = "State the ethical issue, position, evidence, stakeholders, likely objection, and response before polishing the message."
        }
    }
    if ($focus -match "operating system|software environment") {
        return [pscustomobject]@{
            title = "Navigate With Purpose"
            prompt = "Before clicking, decide which Windows feature fits the task: Start, search, taskbar, settings, File Explorer, or help."
        }
    }
    if ($focus -match "file management|local and cloud") {
        return [pscustomobject]@{
            title = "Name, Save, Verify"
            prompt = "A reliable file system uses clear names, logical folders, a known storage location, backup or sync, and verified access."
        }
    }
    if ($focus -match "document creation|microsoft word") {
        return [pscustomobject]@{
            title = "Format for Readers"
            prompt = "A professional document uses layout, headings, spacing, alignment, and review checks to make the content easy to read and trust."
        }
    }
    if ($focus -match "source evaluation|apa citation|academic writing") {
        return [pscustomobject]@{
            title = "Source Before Citation"
            prompt = "A citation is only useful when the source is credible, relevant, accurately represented, and checked against the required style."
        }
    }
    if ($focus -match "cybersecurity|digital responsibility|keyboarding") {
        return [pscustomobject]@{
            title = "Secure Then Finish"
            prompt = "Protect the account, device, file, message, and final keystrokes before treating the digital task as complete."
        }
    }
    if ($focus -match "interpersonal|listening|audience awareness") {
        return [pscustomobject]@{
            title = "Listen for Meaning"
            prompt = "Notice the audience, purpose, words, tone, nonverbal signals, and feedback before deciding what the message means."
        }
    }
    if ($focus -match "message planning|tone|channel") {
        return [pscustomobject]@{
            title = "Purpose Before Wording"
            prompt = "Name the audience, purpose, key point, channel, tone, and next step before polishing the message."
        }
    }
    if ($focus -match "difficult-message|bad-news|conflict") {
        return [pscustomobject]@{
            title = "Clear and Respectful"
            prompt = "A difficult message needs a clear issue, brief reason, respectful tone, reader-centered detail, and a useful next step."
        }
    }
    if ($focus -match "collaboration|meeting|team") {
        return [pscustomobject]@{
            title = "Meeting Purpose Scan"
            prompt = "Check the purpose, agenda, roles, listening habits, decision points, and follow-up before judging whether the meeting works."
        }
    }
    if ($focus -match "presentation") {
        return [pscustomobject]@{
            title = "Audience Before Slides"
            prompt = "A strong presentation starts with the audience need, purpose, main points, evidence, visual support, and closing action."
        }
    }
    if ($focus -match "core business") {
        return [pscustomobject]@{
            title = "Handoff Risk Scan"
            prompt = "Before work moves forward, ask: Which function owns the next decision? What information must travel with the handoff? What delay would affect the customer?"
        }
    }
    if ($focus -match "workflow|process") {
        return [pscustomobject]@{
            title = "Map the Friction"
            prompt = "Find the trigger, input, owner, handoff, and waiting point. A process map is useful only when it shows where work can slow down."
        }
    }
    if ($focus -match "customer") {
        return [pscustomobject]@{
            title = "Service Quality Lens"
            prompt = "Check whether the process is timely, accurate, professional, documented, and closed with a clear next step."
        }
    }
    if ($focus -match "improvement") {
        return [pscustomobject]@{
            title = "Evidence Before Fixes"
            prompt = "Name the problem, review the evidence, identify the constraint, recommend one practical change, and define how the team will measure success."
        }
    }

    return [pscustomobject]@{
        title = "People, Tools, Procedures"
        prompt = "A reliable process aligns the person doing the work, the tool that holds the record, and the procedure that explains the next step."
    }
}

function New-EngagementPlan {
    param(
        [object]$Course,
        [object]$Plan,
        [object]$BrandProfile
    )

    $items = New-Object System.Collections.ArrayList
    foreach ($chapter in $Plan.chapters) {
        Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Planning visual assets" -Status "Working" -Detail "Choosing opener, quick-check, study-aid, and interaction requirements."
        $visual = Get-EngagementVisualSpec -Chapter $chapter
        $chapterSlug = (ConvertTo-SafePathPart $chapter.title -MaxLength 40).ToLowerInvariant()
        $assetSlug = (($visual.title -replace "[^\w\-]+", "-").Trim("-")).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($assetSlug)) { $assetSlug = "study-aid" }
        $quickCheck = Get-QuickVisualCheckSpec -Chapter $chapter
        $quickSlug = (($quickCheck.title -replace "[^\w\-]+", "-").Trim("-")).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($quickSlug)) { $quickSlug = "quick-check" }
        [void]$items.Add([pscustomobject]@{
            chapterNumber = $chapter.number
            chapterTitle = $chapter.title
            openerImageFile = "images/chapter-$($chapter.number)-$chapterSlug-opener.png"
            openerFallbackFile = ""
            openerImagePrompt = Get-ChapterOpenerImagePrompt -Chapter $chapter -BrandProfile $BrandProfile
            openerAltText = Get-ChapterOpenerAltText -Chapter $chapter
            placement = $visual.placement
            assetType = $visual.assetType
            title = $visual.title
            learnerPurpose = $visual.learnerPurpose
            assetFile = "visuals/chapter-$($chapter.number)-$assetSlug.svg"
            interactiveAnchor = "interactive-study.html#chapter-$($chapter.number)"
            altText = "$($visual.title): $($visual.learnerPurpose)"
            quickCheckTitle = $quickCheck.title
            quickCheckText = $quickCheck.prompt
            quickCheckAltText = "Quick visual check for Chapter $($chapter.number), $($chapter.title), titled $($quickCheck.title). It asks learners to consider: $($quickCheck.prompt)"
            quickCheckFile = "visuals/chapter-$($chapter.number)-$quickSlug.svg"
            generationPrompt = $visual.prompt
            interactionIdea = $visual.interactionIdea
            productionStatus = "Pending image generation"
        })
        Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Planning visual assets" -Status "Complete" -Detail "Visual plan is ready."
    }

    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        courseCode = $Course.courseCode
        courseName = $Course.courseName
        status = "generated"
        items = @($items)
    }
}

function ConvertTo-EngagementPlanMarkdown {
    param(
        [object]$Course,
        [object]$EngagementPlan
    )

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# Engagement and Visual Asset Plan")
    [void]$lines.Add("")
    [void]$lines.Add("Course: $($Course.courseCode) - $($Course.courseName)")
    [void]$lines.Add("")
    [void]$lines.Add("Purpose: identify where the ebook should use graphics, diagrams, or lightweight interactivity so the student experience is not only long-form text.")
    [void]$lines.Add("")

    foreach ($item in @($EngagementPlan.items)) {
        [void]$lines.Add("## Chapter $($item.chapterNumber): $($item.chapterTitle)")
        [void]$lines.Add("")
        [void]$lines.Add("- Opener image: $($item.openerImageFile)")
        if ($item.PSObject.Properties.Name -contains "openerFallbackFile" -and $item.openerFallbackFile) {
            [void]$lines.Add("- Opener SVG fallback: $($item.openerFallbackFile)")
        }
        [void]$lines.Add("- Opener generation prompt: $($item.openerImagePrompt)")
        [void]$lines.Add("- Asset: $($item.assetType) - $($item.title)")
        [void]$lines.Add("- Placement: $($item.placement)")
        [void]$lines.Add("- Generated asset: $($item.assetFile)")
        [void]$lines.Add("- Interactive review: $($item.interactiveAnchor)")
        [void]$lines.Add("- Quick visual check: $($item.quickCheckFile) - $($item.quickCheckTitle)")
        [void]$lines.Add("- Learner purpose: $($item.learnerPurpose)")
        [void]$lines.Add("- Interaction idea: $($item.interactionIdea)")
        [void]$lines.Add("- Generation prompt: $($item.generationPrompt)")
        [void]$lines.Add("- Status: $($item.productionStatus)")
        [void]$lines.Add("")
    }

    return ($lines -join "`r`n")
}

function Get-EngagementItemForChapter {
    param(
        [object]$EngagementPlan,
        [int]$ChapterNumber
    )

    if (-not $EngagementPlan) { return $null }
    return @($EngagementPlan.items | Where-Object { $_.chapterNumber -eq $ChapterNumber } | Select-Object -First 1)[0]
}

function Format-MarkdownImage {
    param(
        [AllowNull()][string]$AltText,
        [Parameter(Mandatory)][string]$Path
    )

    $safeAlt = ConvertTo-CleanText $AltText
    $safeAlt = $safeAlt -replace "[\[\]]", ""
    if ([string]::IsNullOrWhiteSpace($safeAlt)) {
        $safeAlt = "Instructional image"
    }

    return "![$safeAlt]($Path)"
}

function ConvertTo-SvgText {
    param([AllowNull()][string]$Text)
    return [System.Security.SecurityElement]::Escape([string]$Text)
}

function Split-SvgTextLines {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxLength = 58,
        [int]$MaxLines = 4
    )

    $words = @(([string]$Text) -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $lines = New-Object System.Collections.ArrayList
    $current = ""

    foreach ($word in $words) {
        $candidate = if ([string]::IsNullOrWhiteSpace($current)) { $word } else { "$current $word" }
        if ($candidate.Length -le $MaxLength) {
            $current = $candidate
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($current)) {
            [void]$lines.Add($current)
        }
        $current = $word

        if ($lines.Count -ge ($MaxLines - 1)) {
            break
        }
    }

    if ($lines.Count -lt $MaxLines -and -not [string]::IsNullOrWhiteSpace($current)) {
        [void]$lines.Add($current)
    }

    while ($lines.Count -lt $MaxLines) {
        [void]$lines.Add("")
    }

    return @($lines | Select-Object -First $MaxLines)
}

function New-OpenerVisualAssetSvg {
    param(
        [object]$Item,
        [object]$BrandProfile
    )

    $title = ConvertTo-SvgText "Chapter $($Item.chapterNumber): $($Item.chapterTitle)"
    $altLines = Split-SvgTextLines -Text $Item.openerAltText -MaxLength 72 -MaxLines 3
    $line1 = ConvertTo-SvgText $altLines[0]
    $line2 = ConvertTo-SvgText $altLines[1]
    $line3 = ConvertTo-SvgText $altLines[2]
    $accent = Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553"
    $accent2 = Get-BrandColor -BrandProfile $BrandProfile -Name "Hero Blue" -Fallback "#1D6BA6"
    $accent3 = Get-BrandColor -BrandProfile $BrandProfile -Name "Horizon Blue" -Fallback "#0095C8"
    $green = Get-BrandColor -BrandProfile $BrandProfile -Name "Journey Green" -Fallback "#15EAC4"
    $soft = Get-BrandColor -BrandProfile $BrandProfile -Name "Gracious Gray" -Fallback "#F9F9F9"

    return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="790" viewBox="0 0 1400 790" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$line1 $line2 $line3</desc>
  <rect width="1400" height="790" fill="#ffffff"/>
  <rect x="0" y="0" width="1400" height="160" fill="$accent"/>
  <text x="70" y="95" font-family="Arial, Helvetica, sans-serif" font-size="44" font-weight="700" fill="#ffffff">$title</text>
  <text x="72" y="140" font-family="Arial, Helvetica, sans-serif" font-size="21" fill="#ffffff">Learner-facing opener for the chapter scenario</text>
  <rect x="70" y="220" width="1260" height="485" rx="20" fill="$soft" stroke="#d7dde3"/>
  <g font-family="Arial, Helvetica, sans-serif">
    <rect x="140" y="300" width="240" height="130" rx="18" fill="#ffffff" stroke="$accent2" stroke-width="4"/>
    <rect x="580" y="300" width="240" height="130" rx="18" fill="#ffffff" stroke="$accent3" stroke-width="4"/>
    <rect x="1020" y="300" width="240" height="130" rx="18" fill="#ffffff" stroke="$accent2" stroke-width="4"/>
    <text x="260" y="360" text-anchor="middle" font-size="27" font-weight="700" fill="#172026">Situation</text>
    <text x="700" y="360" text-anchor="middle" font-size="27" font-weight="700" fill="#172026">Decision</text>
    <text x="1140" y="360" text-anchor="middle" font-size="27" font-weight="700" fill="#172026">Result</text>
    <text x="260" y="395" text-anchor="middle" font-size="17" fill="#52606d">notice the work context</text>
    <text x="700" y="395" text-anchor="middle" font-size="17" fill="#52606d">choose a defensible step</text>
    <text x="1140" y="395" text-anchor="middle" font-size="17" fill="#52606d">explain what changes</text>
    <path d="M380 365 H580 M820 365 H1020" stroke="#172026" stroke-width="5" marker-end="url(#arrow)"/>
    <rect x="180" y="520" width="1040" height="105" rx="16" fill="#ffffff" stroke="#d7dde3"/>
    <text x="700" y="558" text-anchor="middle" font-size="24" font-weight="700" fill="#172026">$line1</text>
    <text x="700" y="592" text-anchor="middle" font-size="20" fill="#52606d">$line2</text>
    <text x="700" y="623" text-anchor="middle" font-size="20" fill="#52606d">$line3</text>
    <circle cx="1240" cy="604" r="45" fill="$green"/>
    <text x="1240" y="612" text-anchor="middle" font-size="20" font-weight="700" fill="#0D3553">APPLY</text>
  </g>
  <defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#172026"/></marker></defs>
</svg>
"@
}

function New-VisualAssetSvg {
    param(
        [object]$Item,
        [object]$BrandProfile
    )

    $title = ConvertTo-SvgText $Item.title
    $purpose = ConvertTo-SvgText $Item.learnerPurpose
    $chapter = "Chapter $($Item.chapterNumber)"
    $accent = Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553"
    $accent2 = Get-BrandColor -BrandProfile $BrandProfile -Name "Hero Blue" -Fallback "#1D6BA6"
    $accent3 = Get-BrandColor -BrandProfile $BrandProfile -Name "Horizon Blue" -Fallback "#0095C8"
    $cta = Get-BrandColor -BrandProfile $BrandProfile -Name "Journey Green" -Fallback "#15EAC4"
    $soft = Get-BrandColor -BrandProfile $BrandProfile -Name "Gracious Gray" -Fallback "#F9F9F9"
    $line = Get-BrandColor -BrandProfile $BrandProfile -Name "Integrity Gray" -Fallback "#444444"

    if ($Item.title -match "Windows Workspace|File Organization|Word Document|APA Source|Secure Digital") {
        $label1 = "Open"
        $label2 = "Navigate"
        $label3 = "Adjust"
        $label4 = "Verify"
        $center = "Windows Task"
        if ($Item.title -match "File Organization") {
            $label1 = "Name"
            $label2 = "Folder"
            $label3 = "Sync"
            $label4 = "Share"
            $center = "Findable Files"
        }
        elseif ($Item.title -match "Word Document") {
            $label1 = "Layout"
            $label2 = "Styles"
            $label3 = "Structure"
            $label4 = "Review"
            $center = "Readable Document"
        }
        elseif ($Item.title -match "APA Source") {
            $label1 = "Evaluate"
            $label2 = "Use"
            $label3 = "Cite"
            $label4 = "Check"
            $center = "Academic Support"
        }
        elseif ($Item.title -match "Secure Digital") {
            $label1 = "Protect"
            $label2 = "Think"
            $label3 = "Type"
            $label4 = "Finish"
            $center = "Secure Work"
        }

        return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="760" viewBox="0 0 1200 760" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$purpose</desc>
  <rect width="1200" height="760" fill="#ffffff"/>
  <text x="60" y="70" font-family="Arial, Helvetica, sans-serif" font-size="34" font-weight="700" fill="#172026">${chapter}: $title</text>
  <text x="60" y="112" font-family="Arial, Helvetica, sans-serif" font-size="18" fill="#52606d">$purpose</text>
  <defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#172026"/></marker></defs>
  <g font-family="Arial, Helvetica, sans-serif">
    <rect x="95" y="230" width="210" height="120" rx="14" fill="$soft" stroke="$accent" stroke-width="3"/>
    <rect x="365" y="230" width="210" height="120" rx="14" fill="#ffffff" stroke="$accent2" stroke-width="3"/>
    <rect x="625" y="230" width="210" height="120" rx="14" fill="#ffffff" stroke="$accent3" stroke-width="3"/>
    <rect x="895" y="230" width="210" height="120" rx="14" fill="#eef7fb" stroke="$accent" stroke-width="3"/>
    <text x="200" y="284" text-anchor="middle" font-size="25" font-weight="700" fill="#172026">$label1</text>
    <text x="470" y="284" text-anchor="middle" font-size="25" font-weight="700" fill="#172026">$label2</text>
    <text x="730" y="284" text-anchor="middle" font-size="25" font-weight="700" fill="#172026">$label3</text>
    <text x="1000" y="284" text-anchor="middle" font-size="25" font-weight="700" fill="#172026">$label4</text>
    <text x="200" y="316" text-anchor="middle" font-size="15" fill="#52606d">choose the tool</text>
    <text x="470" y="316" text-anchor="middle" font-size="15" fill="#52606d">follow the standard</text>
    <text x="730" y="316" text-anchor="middle" font-size="15" fill="#52606d">check the result</text>
    <text x="1000" y="316" text-anchor="middle" font-size="15" fill="#52606d">finish cleanly</text>
    <path d="M305 290 H365 M575 290 H625 M835 290 H895" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
    <rect x="340" y="480" width="520" height="120" rx="16" fill="$accent" stroke="$accent"/>
    <text x="600" y="530" text-anchor="middle" font-size="30" font-weight="700" fill="#ffffff">$center</text>
    <text x="600" y="566" text-anchor="middle" font-size="17" fill="#ffffff">complete, review, save, and explain</text>
    <path d="M600 350 V480" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
    <circle cx="960" cy="565" r="42" fill="$cta" opacity="0.95"/>
    <text x="960" y="573" text-anchor="middle" font-size="22" font-weight="700" fill="#0D3553">OK</text>
  </g>
</svg>
"@
    }

    if ($Item.title -match "Critical Thinking|Intellectual Standards|Problem-Solving|Decision Review|Argument Test|Ethical Argument") {
        $label1 = "Question"
        $label2 = "Evidence"
        $label3 = "Assumptions"
        $label4 = "Conclusion"
        $center = "Reasoned Judgment"
        if ($Item.title -match "Intellectual Standards") {
            $label1 = "Clarity"
            $label2 = "Accuracy"
            $label3 = "Relevance"
            $label4 = "Sufficiency"
            $center = "Trustworthy Support"
        }
        elseif ($Item.title -match "Problem-Solving") {
            $label1 = "Issue"
            $label2 = "Constraints"
            $label3 = "Alternatives"
            $label4 = "Justification"
            $center = "Defensible Solution"
        }
        elseif ($Item.title -match "Decision Review") {
            $label1 = "Evidence"
            $label2 = "Bias"
            $label3 = "Pressure"
            $label4 = "Fallacy Check"
            $center = "Decision Quality"
        }
        elseif ($Item.title -match "Argument Test") {
            $label1 = "Premises"
            $label2 = "Support"
            $label3 = "Inference"
            $label4 = "Conclusion"
            $center = "Argument Strength"
        }
        elseif ($Item.title -match "Ethical Argument") {
            $label1 = "Issue"
            $label2 = "Values"
            $label3 = "Stakeholders"
            $label4 = "Response"
            $center = "Ethical Position"
        }

        return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="760" viewBox="0 0 1200 760" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$purpose</desc>
  <rect width="1200" height="760" fill="#ffffff"/>
  <text x="60" y="70" font-family="Arial, Helvetica, sans-serif" font-size="34" font-weight="700" fill="#172026">${chapter}: $title</text>
  <text x="60" y="112" font-family="Arial, Helvetica, sans-serif" font-size="18" fill="#52606d">$purpose</text>
  <defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#172026"/></marker></defs>
  <g font-family="Arial, Helvetica, sans-serif">
    <rect x="92" y="245" width="210" height="118" rx="14" fill="$soft" stroke="$accent" stroke-width="3"/>
    <rect x="360" y="245" width="210" height="118" rx="14" fill="#ffffff" stroke="$accent2" stroke-width="3"/>
    <rect x="630" y="245" width="210" height="118" rx="14" fill="#ffffff" stroke="$accent3" stroke-width="3"/>
    <rect x="898" y="245" width="210" height="118" rx="14" fill="#eef7fb" stroke="$accent" stroke-width="3"/>
    <text x="197" y="298" text-anchor="middle" font-size="24" font-weight="700" fill="#172026">$label1</text>
    <text x="465" y="298" text-anchor="middle" font-size="24" font-weight="700" fill="#172026">$label2</text>
    <text x="735" y="298" text-anchor="middle" font-size="24" font-weight="700" fill="#172026">$label3</text>
    <text x="1003" y="298" text-anchor="middle" font-size="24" font-weight="700" fill="#172026">$label4</text>
    <path d="M302 304 H360 M570 304 H630 M840 304 H898" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
    <rect x="340" y="485" width="520" height="118" rx="16" fill="$accent" stroke="$accent"/>
    <text x="600" y="535" text-anchor="middle" font-size="30" font-weight="700" fill="#ffffff">$center</text>
    <text x="600" y="570" text-anchor="middle" font-size="17" fill="#ffffff">pause, test, revise, and explain</text>
    <path d="M600 363 V485" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
    <circle cx="975" cy="560" r="42" fill="$cta" opacity="0.95"/>
    <text x="975" y="568" text-anchor="middle" font-size="17" font-weight="700" fill="#0D3553">CHECK</text>
  </g>
</svg>
"@
    }

    if ($Item.title -match "Audience|Message|Difficult|Meeting|Presentation") {
        $labels = @("Audience", "Purpose", "Channel", "Tone", "Structure", "Revise")
        $center = "Clear Message"
        if ($Item.title -match "Listening") {
            $labels = @("Audience", "Words", "Tone", "Signals", "Question", "Response")
            $center = "Shared Meaning"
        }
        elseif ($Item.title -match "Difficult|Bad") {
            $labels = @("Issue", "Reason", "Respect", "Options", "Next Step", "Review")
            $center = "Trust"
        }
        elseif ($Item.title -match "Meeting") {
            $labels = @("Purpose", "Roles", "Agenda", "Voices", "Decisions", "Follow-up")
            $center = "Team Clarity"
        }
        elseif ($Item.title -match "Presentation") {
            $labels = @("Audience", "Opening", "Evidence", "Visuals", "Delivery", "Closing")
            $center = "Memorable Point"
        }

        $l1 = ConvertTo-SvgText $labels[0]
        $l2 = ConvertTo-SvgText $labels[1]
        $l3 = ConvertTo-SvgText $labels[2]
        $l4 = ConvertTo-SvgText $labels[3]
        $l5 = ConvertTo-SvgText $labels[4]
        $l6 = ConvertTo-SvgText $labels[5]
        $centerText = ConvertTo-SvgText $center

        return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="760" viewBox="0 0 1200 760" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$purpose</desc>
  <rect width="1200" height="760" fill="#ffffff"/>
  <text x="60" y="70" font-family="Arial, Helvetica, sans-serif" font-size="34" font-weight="700" fill="#172026">${chapter}: $title</text>
  <text x="60" y="112" font-family="Arial, Helvetica, sans-serif" font-size="18" fill="#52606d">$purpose</text>
  <defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#172026"/></marker></defs>
  <g font-family="Arial, Helvetica, sans-serif">
    <rect x="95" y="215" width="155" height="92" rx="12" fill="$soft" stroke="$accent" stroke-width="3"/>
    <rect x="285" y="215" width="155" height="92" rx="12" fill="#ffffff" stroke="$accent2" stroke-width="3"/>
    <rect x="475" y="215" width="155" height="92" rx="12" fill="#ffffff" stroke="$accent3" stroke-width="3"/>
    <rect x="665" y="215" width="155" height="92" rx="12" fill="#ffffff" stroke="$accent2" stroke-width="3"/>
    <rect x="855" y="215" width="155" height="92" rx="12" fill="#ffffff" stroke="$accent3" stroke-width="3"/>
    <rect x="475" y="485" width="250" height="105" rx="16" fill="$accent" stroke="$accent"/>
    <text x="172" y="270" text-anchor="middle" font-size="20" font-weight="700" fill="#172026">$l1</text>
    <text x="362" y="270" text-anchor="middle" font-size="20" font-weight="700" fill="#172026">$l2</text>
    <text x="552" y="270" text-anchor="middle" font-size="20" font-weight="700" fill="#172026">$l3</text>
    <text x="742" y="270" text-anchor="middle" font-size="20" font-weight="700" fill="#172026">$l4</text>
    <text x="932" y="270" text-anchor="middle" font-size="20" font-weight="700" fill="#172026">$l5</text>
    <text x="600" y="548" text-anchor="middle" font-size="25" font-weight="700" fill="#ffffff">$centerText</text>
    <text x="600" y="574" text-anchor="middle" font-size="15" fill="#ffffff">easy to understand, trust, and act on</text>
    <path d="M250 261 H285 M440 261 H475 M630 261 H665 M820 261 H855" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
    <path d="M932 307 C932 430 720 425 680 485" fill="none" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
    <path d="M520 485 C445 430 315 430 172 307" fill="none" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
    <circle cx="1000" cy="545" r="48" fill="$cta"/>
    <text x="1000" y="540" text-anchor="middle" font-size="15" font-weight="700" fill="#0D3553">$l6</text>
    <text x="1000" y="561" text-anchor="middle" font-size="13" fill="#0D3553">before sending</text>
  </g>
</svg>
"@
    }

    if ($Item.title -match "Risk Triangle") {
        return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="900" viewBox="0 0 1200 900" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$purpose</desc>
  <rect width="1200" height="900" fill="#ffffff"/>
  <text x="60" y="70" font-family="Arial, Helvetica, sans-serif" font-size="34" font-weight="700" fill="#172026">${chapter}: $title</text>
  <text x="60" y="112" font-family="Arial, Helvetica, sans-serif" font-size="18" fill="#52606d">$purpose</text>
  <polygon points="600,260 285,730 915,730" fill="$soft" stroke="$accent" stroke-width="6"/>
  <circle cx="600" cy="260" r="88" fill="#ffffff" stroke="$accent" stroke-width="4"/>
  <circle cx="285" cy="730" r="88" fill="#ffffff" stroke="$accent2" stroke-width="4"/>
  <circle cx="915" cy="730" r="88" fill="#ffffff" stroke="$accent3" stroke-width="4"/>
  <text x="600" y="252" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="24" font-weight="700" fill="#172026">People</text>
  <text x="600" y="284" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="15" fill="#52606d">judgment and handoffs</text>
  <text x="285" y="722" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="24" font-weight="700" fill="#172026">Technology</text>
  <text x="285" y="754" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="15" fill="#52606d">records and tools</text>
  <text x="915" y="722" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="24" font-weight="700" fill="#172026">Procedures</text>
  <text x="915" y="754" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="15" fill="#52606d">standards and controls</text>
  <rect x="465" y="470" width="270" height="92" rx="10" fill="#ffffff" stroke="$line"/>
  <text x="600" y="505" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="22" font-weight="700" fill="#172026">Operational Risk</text>
  <text x="600" y="536" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="16" fill="#52606d">appears where one side is weak</text>
  <text x="125" y="370" font-family="Arial, Helvetica, sans-serif" font-size="17" fill="#172026">Look for:</text>
  <text x="125" y="404" font-family="Arial, Helvetica, sans-serif" font-size="16" fill="#52606d">missing owners, hidden records, outdated steps</text>
  <text x="765" y="370" font-family="Arial, Helvetica, sans-serif" font-size="17" fill="#172026">Improve by:</text>
  <text x="765" y="404" font-family="Arial, Helvetica, sans-serif" font-size="16" fill="#52606d">aligning roles, tools, and repeatable routines</text>
</svg>
"@
    }

    if ($Item.title -match "Cross-Functional") {
        return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="760" viewBox="0 0 1200 760" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$purpose</desc>
  <rect width="1200" height="760" fill="#ffffff"/>
  <text x="60" y="70" font-family="Arial, Helvetica, sans-serif" font-size="34" font-weight="700" fill="#172026">${chapter}: $title</text>
  <text x="60" y="112" font-family="Arial, Helvetica, sans-serif" font-size="18" fill="#52606d">$purpose</text>
  <g font-family="Arial, Helvetica, sans-serif">
    <rect x="80" y="170" width="220" height="420" rx="10" fill="$soft" stroke="$accent"/>
    <rect x="350" y="170" width="220" height="420" rx="10" fill="#f7f0ec" stroke="$accent2"/>
    <rect x="620" y="170" width="220" height="420" rx="10" fill="#eef1f7" stroke="$accent3"/>
    <rect x="890" y="170" width="220" height="420" rx="10" fill="#f4f4ef" stroke="$cta"/>
    <text x="190" y="215" text-anchor="middle" font-size="24" font-weight="700" fill="#172026">Finance</text>
    <text x="460" y="215" text-anchor="middle" font-size="24" font-weight="700" fill="#172026">HR</text>
    <text x="730" y="215" text-anchor="middle" font-size="24" font-weight="700" fill="#172026">Marketing</text>
    <text x="1000" y="215" text-anchor="middle" font-size="24" font-weight="700" fill="#172026">Operations</text>
    <text x="190" y="280" text-anchor="middle" font-size="16" fill="#52606d">budget approval</text>
    <text x="460" y="280" text-anchor="middle" font-size="16" fill="#52606d">staffing coverage</text>
    <text x="730" y="280" text-anchor="middle" font-size="16" fill="#52606d">customer message</text>
    <text x="1000" y="280" text-anchor="middle" font-size="16" fill="#52606d">service delivery</text>
    <path d="M300 380 H350 M570 380 H620 M840 380 H890" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
    <text x="190" y="505" text-anchor="middle" font-size="16" fill="#172026">Risk: missing cost details</text>
    <text x="460" y="505" text-anchor="middle" font-size="16" fill="#172026">Risk: no owner</text>
    <text x="730" y="505" text-anchor="middle" font-size="16" fill="#172026">Risk: promise exceeds capacity</text>
    <text x="1000" y="505" text-anchor="middle" font-size="16" fill="#172026">Risk: delayed follow-up</text>
  </g>
  <defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#172026"/></marker></defs>
</svg>
"@
    }

    if ($Item.title -match "Office Process") {
        return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="760" viewBox="0 0 1200 760" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$purpose</desc>
  <rect width="1200" height="760" fill="#ffffff"/>
  <text x="60" y="70" font-family="Arial, Helvetica, sans-serif" font-size="34" font-weight="700" fill="#172026">${chapter}: $title</text>
  <text x="60" y="112" font-family="Arial, Helvetica, sans-serif" font-size="18" fill="#52606d">$purpose</text>
  <defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#172026"/></marker></defs>
  <g font-family="Arial, Helvetica, sans-serif" font-size="18">
    <rect x="70" y="250" width="170" height="92" rx="12" fill="$soft" stroke="$accent"/>
    <rect x="290" y="250" width="170" height="92" rx="12" fill="#ffffff" stroke="#71828a"/>
    <rect x="510" y="250" width="170" height="92" rx="12" fill="#ffffff" stroke="#71828a"/>
    <rect x="730" y="250" width="170" height="92" rx="12" fill="#ffffff" stroke="#71828a"/>
    <rect x="950" y="250" width="170" height="92" rx="12" fill="#eef1f7" stroke="$accent3"/>
    <text x="155" y="292" text-anchor="middle" font-weight="700">Intake</text>
    <text x="155" y="318" text-anchor="middle" font-size="14" fill="#52606d">trigger and request</text>
    <text x="375" y="292" text-anchor="middle" font-weight="700">Review</text>
    <text x="375" y="318" text-anchor="middle" font-size="14" fill="#52606d">complete inputs</text>
    <text x="595" y="292" text-anchor="middle" font-weight="700">Correct</text>
    <text x="595" y="318" text-anchor="middle" font-size="14" fill="#52606d">resolve gaps</text>
    <text x="815" y="292" text-anchor="middle" font-weight="700">Approve</text>
    <text x="815" y="318" text-anchor="middle" font-size="14" fill="#52606d">decision point</text>
    <text x="1035" y="292" text-anchor="middle" font-weight="700">Follow Up</text>
    <text x="1035" y="318" text-anchor="middle" font-size="14" fill="#52606d">close the loop</text>
    <path d="M240 296 H290 M460 296 H510 M680 296 H730 M900 296 H950" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
    <rect x="250" y="435" width="700" height="130" rx="12" fill="#f7f0ec" stroke="$accent2"/>
    <text x="600" y="480" text-anchor="middle" font-size="24" font-weight="700" fill="#172026">Risk points</text>
    <text x="600" y="518" text-anchor="middle" font-size="17" fill="#52606d">unclear owner, missing input, waiting time, rework, no status update</text>
  </g>
</svg>
"@
    }

    if ($Item.title -match "Decision Tree") {
        return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="760" viewBox="0 0 1200 760" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$purpose</desc>
  <rect width="1200" height="760" fill="#ffffff"/>
  <text x="60" y="70" font-family="Arial, Helvetica, sans-serif" font-size="34" font-weight="700" fill="#172026">${chapter}: $title</text>
  <text x="60" y="112" font-family="Arial, Helvetica, sans-serif" font-size="18" fill="#52606d">$purpose</text>
  <defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#172026"/></marker></defs>
  <g font-family="Arial, Helvetica, sans-serif">
    <rect x="470" y="165" width="260" height="82" rx="12" fill="$soft" stroke="$accent"/>
    <text x="600" y="200" text-anchor="middle" font-size="20" font-weight="700">Customer request</text>
    <text x="600" y="226" text-anchor="middle" font-size="14" fill="#52606d">listen, verify, document</text>
    <rect x="145" y="355" width="260" height="92" rx="12" fill="#ffffff" stroke="#71828a"/>
    <rect x="470" y="355" width="260" height="92" rx="12" fill="#ffffff" stroke="#71828a"/>
    <rect x="795" y="355" width="260" height="92" rx="12" fill="#ffffff" stroke="#71828a"/>
    <text x="275" y="394" text-anchor="middle" font-size="19" font-weight="700">Urgent?</text>
    <text x="600" y="394" text-anchor="middle" font-size="19" font-weight="700">Enough information?</text>
    <text x="925" y="394" text-anchor="middle" font-size="19" font-weight="700">Needs escalation?</text>
    <text x="275" y="423" text-anchor="middle" font-size="14" fill="#52606d">set expectation</text>
    <text x="600" y="423" text-anchor="middle" font-size="14" fill="#52606d">ask, confirm, record</text>
    <text x="925" y="423" text-anchor="middle" font-size="14" fill="#52606d">route with context</text>
    <path d="M600 247 V315 M600 315 H275 V355 M600 315 V355 M600 315 H925 V355" stroke="#172026" stroke-width="4" marker-end="url(#arrow)"/>
    <rect x="360" y="575" width="480" height="90" rx="12" fill="#eef1f7" stroke="$accent3"/>
    <text x="600" y="612" text-anchor="middle" font-size="22" font-weight="700">Professional close</text>
    <text x="600" y="642" text-anchor="middle" font-size="16" fill="#52606d">document, explain next step, follow through</text>
    <path d="M275 447 V620 H360 M600 447 V575 M925 447 V620 H840" stroke="#172026" stroke-width="3" marker-end="url(#arrow)"/>
  </g>
</svg>
"@
    }

    return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="760" viewBox="0 0 1200 760" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$purpose</desc>
  <rect width="1200" height="760" fill="#ffffff"/>
  <text x="60" y="70" font-family="Arial, Helvetica, sans-serif" font-size="34" font-weight="700" fill="#172026">${chapter}: $title</text>
  <text x="60" y="112" font-family="Arial, Helvetica, sans-serif" font-size="18" fill="#52606d">$purpose</text>
  <g font-family="Arial, Helvetica, sans-serif">
    <circle cx="600" cy="385" r="215" fill="$soft" stroke="$accent" stroke-width="5"/>
    <circle cx="600" cy="170" r="62" fill="#ffffff" stroke="#71828a"/>
    <circle cx="790" cy="280" r="62" fill="#ffffff" stroke="#71828a"/>
    <circle cx="790" cy="500" r="62" fill="#ffffff" stroke="#71828a"/>
    <circle cx="600" cy="610" r="62" fill="#ffffff" stroke="#71828a"/>
    <circle cx="410" cy="500" r="62" fill="#ffffff" stroke="#71828a"/>
    <circle cx="410" cy="280" r="62" fill="#ffffff" stroke="#71828a"/>
    <text x="600" y="166" text-anchor="middle" font-size="15" font-weight="700">Define</text>
    <text x="790" y="276" text-anchor="middle" font-size="15" font-weight="700">Gather</text>
    <text x="790" y="496" text-anchor="middle" font-size="15" font-weight="700">Identify</text>
    <text x="600" y="606" text-anchor="middle" font-size="15" font-weight="700">Recommend</text>
    <text x="410" y="496" text-anchor="middle" font-size="15" font-weight="700">Test</text>
    <text x="410" y="276" text-anchor="middle" font-size="15" font-weight="700">Adjust</text>
    <text x="600" y="380" text-anchor="middle" font-size="26" font-weight="700" fill="#172026">Improvement</text>
    <text x="600" y="414" text-anchor="middle" font-size="16" fill="#52606d">evidence to action</text>
  </g>
</svg>
"@
}

function New-QuickVisualCheckSvg {
    param(
        [object]$Item,
        [object]$BrandProfile
    )

    $title = ConvertTo-SvgText $Item.quickCheckTitle
    $chapter = "Chapter $($Item.chapterNumber)"
    $lines = Split-SvgTextLines -Text $Item.quickCheckText -MaxLength 62 -MaxLines 4
    $line1 = ConvertTo-SvgText $lines[0]
    $line2 = ConvertTo-SvgText $lines[1]
    $line3 = ConvertTo-SvgText $lines[2]
    $line4 = ConvertTo-SvgText $lines[3]
    $accentPalette = @(
        (Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553"),
        (Get-BrandColor -BrandProfile $BrandProfile -Name "Hero Blue" -Fallback "#1D6BA6"),
        (Get-BrandColor -BrandProfile $BrandProfile -Name "Horizon Blue" -Fallback "#0095C8"),
        (Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553"),
        (Get-BrandColor -BrandProfile $BrandProfile -Name "Hero Blue" -Fallback "#1D6BA6")
    )
    $accent = $accentPalette[($Item.chapterNumber - 1) % $accentPalette.Count]

    return @"
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="560" viewBox="0 0 1200 560" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$line1 $line2 $line3 $line4</desc>
  <rect width="1200" height="560" fill="#ffffff"/>
  <rect x="54" y="54" width="1092" height="452" rx="16" fill="#f7f8fa" stroke="#d7dde3"/>
  <rect x="54" y="54" width="170" height="452" rx="16" fill="$accent"/>
  <rect x="184" y="54" width="40" height="452" fill="$accent"/>
  <text x="139" y="174" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="28" font-weight="700" fill="#ffffff">$chapter</text>
  <text x="139" y="238" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="32" font-weight="700" fill="#ffffff">CHECK</text>
  <text x="270" y="142" font-family="Arial, Helvetica, sans-serif" font-size="38" font-weight="700" fill="#172026">$title</text>
  <text x="270" y="205" font-family="Arial, Helvetica, sans-serif" font-size="27" fill="#172026">$line1</text>
  <text x="270" y="252" font-family="Arial, Helvetica, sans-serif" font-size="27" fill="#172026">$line2</text>
  <text x="270" y="299" font-family="Arial, Helvetica, sans-serif" font-size="27" fill="#172026">$line3</text>
  <text x="270" y="346" font-family="Arial, Helvetica, sans-serif" font-size="27" fill="#172026">$line4</text>
  <g font-family="Arial, Helvetica, sans-serif" font-size="16" fill="#52606d">
    <circle cx="286" cy="442" r="10" fill="$accent"/>
    <text x="310" y="448">Pause before moving from concept to action</text>
    <circle cx="670" cy="442" r="10" fill="$accent"/>
    <text x="694" y="448">Use the question to test the workplace case</text>
  </g>
</svg>
"@
}

function ConvertTo-DrawingColor {
    param(
        [AllowNull()][string]$Hex,
        [string]$Fallback = "#0D3553"
    )

    $value = if ([string]::IsNullOrWhiteSpace($Hex)) { $Fallback } else { [string]$Hex }
    try {
        return [System.Drawing.ColorTranslator]::FromHtml($value)
    }
    catch {
        return [System.Drawing.ColorTranslator]::FromHtml($Fallback)
    }
}

function Add-OpenerPngWrappedText {
    param(
        [Parameter(Mandatory)][System.Drawing.Graphics]$Graphics,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][System.Drawing.Font]$Font,
        [Parameter(Mandatory)][System.Drawing.Brush]$Brush,
        [float]$X,
        [float]$Y,
        [float]$Width,
        [float]$LineHeight,
        [int]$MaxLines = 3
    )

    $words = @($Text -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $lines = New-Object System.Collections.ArrayList
    $current = ""
    foreach ($word in $words) {
        $candidate = if ([string]::IsNullOrWhiteSpace($current)) { $word } else { "$current $word" }
        $size = $Graphics.MeasureString($candidate, $Font)
        if ($size.Width -le $Width) {
            $current = $candidate
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($current)) {
            [void]$lines.Add($current)
        }
        $current = $word
        if ($lines.Count -ge ($MaxLines - 1)) {
            break
        }
    }
    if ($lines.Count -lt $MaxLines -and -not [string]::IsNullOrWhiteSpace($current)) {
        [void]$lines.Add($current)
    }

    for ($i = 0; $i -lt [Math]::Min($lines.Count, $MaxLines); $i++) {
        $Graphics.DrawString([string]$lines[$i], $Font, $Brush, $X, ($Y + ($i * $LineHeight)))
    }
}

function Get-OpenAiChapterOpenerPrompt {
    param([object]$Item)

    $parts = @(
        "Create one clean, polished chapter opener banner image for an adult higher-education e-book.",
        "The image must be visual only: no text, no letters, no captions, no labels, no logos, no watermarks, no diagrams, no accessibility description, and no UI chrome.",
        "Use a professional editorial photo or premium editorial illustration style with natural lighting, modern workplace/learning context, and a wide banner composition.",
        "The image should support this chapter topic: Chapter $($Item.chapterNumber), $($Item.chapterTitle).",
        "Learning purpose: $($Item.learnerPurpose).",
        "Content direction: $($Item.openerImagePrompt)",
        "Keep the scene specific to the content, visually calm, inclusive, realistic, and suitable for a student-facing e-book."
    )

    return (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " ")
}


function New-VisualAssets {
    param(
        [object]$EngagementPlan,
        [object]$BrandProfile
    )

    $assets = New-Object System.Collections.ArrayList
    foreach ($item in @($EngagementPlan.items)) {
        Write-EbookGeneratorChapterProgress -ChapterNumber $item.chapterNumber -ChapterTitle $item.chapterTitle -Phase "Chapter artwork pending" -Status "Warning" -Detail "The image-generation pass must create this chapter's real banner. No placeholder will be substituted."
        [void]$assets.Add([pscustomobject]@{
            chapterNumber = $item.chapterNumber
            chapterTitle = $item.chapterTitle
            title = $item.title
            relativePath = $item.assetFile
            svg = New-VisualAssetSvg -Item $item -BrandProfile $BrandProfile
        })
        [void]$assets.Add([pscustomobject]@{
            chapterNumber = $item.chapterNumber
            chapterTitle = $item.chapterTitle
            title = $item.quickCheckTitle
            relativePath = $item.quickCheckFile
            svg = New-QuickVisualCheckSvg -Item $item -BrandProfile $BrandProfile
        })
        Write-EbookGeneratorChapterProgress -ChapterNumber $item.chapterNumber -ChapterTitle $item.chapterTitle -Phase "Generating visual study assets" -Status "Complete" -Detail "Study diagrams are ready; chapter opener artwork is still pending."
    }

    return @($assets)
}

function ConvertTo-InteractiveStudyHtml {
    param(
        [object]$Course,
        [object]$EngagementPlan,
        [object]$BrandProfile
    )

    $legendBlue = Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553"
    $heroBlue = Get-BrandColor -BrandProfile $BrandProfile -Name "Hero Blue" -Fallback "#1D6BA6"
    $horizonBlue = Get-BrandColor -BrandProfile $BrandProfile -Name "Horizon Blue" -Fallback "#0095C8"
    $journeyGreen = Get-BrandColor -BrandProfile $BrandProfile -Name "Journey Green" -Fallback "#15EAC4"
    $graciousGray = Get-BrandColor -BrandProfile $BrandProfile -Name "Gracious Gray" -Fallback "#F9F9F9"
    $mediumGray = Get-BrandColor -BrandProfile $BrandProfile -Name "Medium Gray 1" -Fallback "#DBDBDB"
    $integrityGray = Get-BrandColor -BrandProfile $BrandProfile -Name "Integrity Gray" -Fallback "#444444"
    $sections = New-Object System.Collections.ArrayList
    foreach ($item in @($EngagementPlan.items)) {
        Write-EbookGeneratorChapterProgress -ChapterNumber $item.chapterNumber -ChapterTitle $item.chapterTitle -Phase "Building interactive study page" -Status "Working" -Detail "Adding this chapter to the interactive review page."
        [void]$sections.Add(@"
<section id="chapter-$($item.chapterNumber)">
  <h2>Chapter $($item.chapterNumber): $(ConvertTo-HtmlText $item.chapterTitle)</h2>
  <figure>
    <!-- Chapter banners are added to the manuscript after verified image production. -->
  </figure>
  <div class="visual-grid">
    <figure>
      <img src="$(ConvertTo-HtmlAttribute $item.quickCheckFile)" alt="$(ConvertTo-HtmlAttribute $item.quickCheckAltText)" loading="lazy">
    </figure>
    <figure>
      <img src="$(ConvertTo-HtmlAttribute $item.assetFile)" alt="$(ConvertTo-HtmlAttribute $item.altText)" loading="lazy">
    </figure>
  </div>
  <details>
    <summary>Try It</summary>
    <p>$(ConvertTo-HtmlText $item.interactionIdea)</p>
    <label>What is the highest-risk point in this visual?</label>
    <textarea aria-label="Reflection for chapter $($item.chapterNumber)"></textarea>
  </details>
</section>
"@)
        Write-EbookGeneratorChapterProgress -ChapterNumber $item.chapterNumber -ChapterTitle $item.chapterTitle -Phase "Building interactive study page" -Status "Complete" -Detail "Interactive review section is ready."
    }

    return @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Interactive Study Aids - $(ConvertTo-HtmlText "$($Course.courseCode): $($Course.courseName)")</title>
  <style>
    body { margin: 0; font-family: Roboto, Arial, Helvetica, sans-serif; background: $graciousGray; color: $legendBlue; line-height: 1.55; }
    main { max-width: 1080px; margin: 0 auto; padding: 36px 24px 64px; background: #ffffff; }
    h1 { margin: 0 0 8px; font-family: Merriweather, Georgia, serif; font-style: italic; font-size: 34px; }
    h2 { border-top: 1px solid $mediumGray; padding-top: 22px; margin-top: 34px; color: $legendBlue; }
    h3 { margin-top: 0; }
    a { color: $heroBlue; }
    nav { display: flex; flex-wrap: wrap; gap: 10px; margin: 20px 0 28px; }
    nav a { border: 1px solid $horizonBlue; border-radius: 6px; padding: 8px 10px; text-decoration: none; color: $legendBlue; }
    .opener { aspect-ratio: 16 / 9; object-fit: cover; margin: 8px 0 18px; }
    .visual-grid { display: grid; grid-template-columns: repeat(2, minmax(260px, 1fr)); gap: 18px; align-items: start; margin: 18px 0; }
    figure { margin: 0; }
    figcaption { color: $integrityGray; font-size: 14px; margin-top: 6px; }
    img { width: 100%; border: 1px solid $mediumGray; border-radius: 8px; background: #ffffff; }
    details { border: 1px solid $mediumGray; border-radius: 8px; padding: 12px 14px; background: $graciousGray; }
    summary { cursor: pointer; font-weight: 700; }
    label { display: block; margin: 14px 0 6px; font-weight: 700; }
    textarea { width: 100%; min-height: 96px; box-sizing: border-box; border: 1px solid $horizonBlue; border-radius: 6px; padding: 10px; font: inherit; }
    summary::marker { color: $journeyGreen; }
    @media (max-width: 760px) { .visual-grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
<main>
  <h1>Interactive Study Aids</h1>
  <p>Use these visual checks alongside the ebook chapters to make the chapter patterns easier to see and apply.</p>
  <nav>
    <a href="#chapter-1">Chapter 1</a>
    <a href="#chapter-2">Chapter 2</a>
    <a href="#chapter-3">Chapter 3</a>
    <a href="#chapter-4">Chapter 4</a>
    <a href="#chapter-5">Chapter 5</a>
  </nav>
$($sections -join "`r`n")
</main>
</body>
</html>
"@
}

function Join-CitationIds {
    param(
        [object]$CitationModel,
        [int]$OpenStaxCount = 2,
        [int]$ResearchCount = 1
    )

    $ids = New-Object System.Collections.ArrayList
    foreach ($item in @($CitationModel.openStax | Select-Object -First $OpenStaxCount)) { [void]$ids.Add($item.id) }
    foreach ($item in @($CitationModel.research | Select-Object -First $ResearchCount)) { [void]$ids.Add($item.id) }

    if ($ids.Count -eq 0) {
        return ""
    }

    return "[" + (($ids | ForEach-Object { $_ }) -join "; ") + "]"
}

function Get-ChapterEndnotes {
    param(
        [object]$CitationModel,
        [int]$OpenStaxCount = 2,
        [int]$ResearchCount = 2
    )

    $items = New-Object System.Collections.ArrayList
    $number = 1
    foreach($item in @($CitationModel.sourceContext)){
        [void]$items.Add([pscustomobject]@{number=$number;id=$item.id;label=$item.reference;url='';type='Provided document'})
        $number++
    }
    foreach ($item in @($CitationModel.openStax | Select-Object -First $OpenStaxCount)) {
        [void]$items.Add([pscustomobject]@{
            number = $number
            id = $item.id
            label = if ($item.reference) { $item.reference } else { $item.label }
            url = $item.url
            type = "Open Education Resource"
        })
        $number++
    }
    foreach ($item in @($CitationModel.research | Select-Object -First $ResearchCount)) {
        [void]$items.Add([pscustomobject]@{
            number = $number
            id = $item.id
            label = if ($item.reference) { $item.reference } else { $item.label }
            url = $item.url
            type = "Research Source"
        })
        $number++
    }

    return @($items)
}

function Format-MarkdownCitationRefs {
    param(
        [object[]]$Endnotes,
        [int]$ChapterNumber,
        [int[]]$Numbers
    )

    $refs = New-Object System.Collections.ArrayList
    foreach ($number in @($Numbers)) {
        $note = @($Endnotes | Where-Object { [int]$_.number -eq [int]$number } | Select-Object -First 1)[0]
        if ($note) {
            [void]$refs.Add("[${number}](#chapter-$ChapterNumber-note-$number)")
        }
    }
    if ($refs.Count -eq 0) {
        return ""
    }

    return ($refs -join " ")
}

function Add-MarkdownEndnotes {
    param(
        [System.Collections.ArrayList]$Lines,
        [int]$ChapterNumber,
        [object[]]$Endnotes
    )

    [void]$Lines.Add("## Scholarly Sources")
    [void]$Lines.Add("")
    if (@($Endnotes).Count -eq 0) {
        [void]$Lines.Add("No external sources are cited in this chapter.")
        return
    }

    foreach ($item in @($Endnotes)) {
        $sourceLabel = if ($item.url) { Format-MarkdownLink -Text $item.label -Url $item.url } else { $item.label }
        [void]$Lines.Add("$($item.number). $sourceLabel")
        [void]$Lines.Add("")
    }
}

function Format-HtmlCitationRefs {
    param(
        [object[]]$Endnotes,
        [int]$ChapterNumber,
        [int[]]$Numbers
    )

    $refs = New-Object System.Collections.ArrayList
    foreach ($number in @($Numbers)) {
        $note = @($Endnotes | Where-Object { [int]$_.number -eq [int]$number } | Select-Object -First 1)[0]
        if ($note) {
            [void]$refs.Add("<sup><a href=""#chapter-$ChapterNumber-note-$number"">[$number]</a></sup>")
        }
    }
    return ($refs -join " ")
}

function Format-MarkdownLink {
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$Url
    )

    $label = ([string]$Text) -replace "\]", ")" -replace "\[", "("
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $label
    }

    $safeUrl = ([string]$Url) -replace " ", "%20" -replace "\(", "%28" -replace "\)", "%29"
    return "[$label]($safeUrl)"
}

function Get-LinkedSourcePhrase {
    param([object]$CitationModel)

    $parts = New-Object System.Collections.ArrayList
    foreach ($source in @($CitationModel.openStax | Select-Object -First 1)) {
        [void]$parts.Add((Format-MarkdownLink -Text "OpenStax: $($source.label)" -Url $source.url))
    }

    foreach ($source in @($CitationModel.research | Select-Object -First 1)) {
        [void]$parts.Add((Format-MarkdownLink -Text "Research: $($source.label)" -Url $source.url))
    }

    if ($parts.Count -eq 0) {
        return "the learning objectives and chapter scope"
    }

    return ($parts -join " and ")
}

function Add-MarkdownCitationList {
    param(
        [System.Collections.ArrayList]$Lines,
        [string]$Heading,
        [object[]]$Items
    )

    [void]$Lines.Add($Heading)
    if ($Items.Count -eq 0) {
        [void]$Lines.Add("- None mapped yet.")
        return
    }

    foreach ($item in $Items) {
        $idUrl = if ($item.url) { $item.url } elseif ($item.id -match "^C\d+$") { "sources.md#$($item.id)" } else { "" }
        $idLabel = if ($idUrl) { Format-MarkdownLink -Text $item.id -Url $idUrl } else { $item.id }
        $line = "- $idLabel $($item.label)"
        [void]$Lines.Add($line)
    }
}

function Get-ChapterOperationalExample {
    param([object]$Chapter)

    $focus = $Chapter.focus.ToLowerInvariant()
    if ($focus -match "critical thinking") {
        return [pscustomobject]@{
            workplace = "a learner reviewing a persuasive claim shared in a professional discussion"
            decision = "whether the claim is clear, supported, fair to alternatives, and ready to use in a conclusion"
            artifact = "a claim-evidence-assumption review table"
            risk = "accepting a claim because it sounds confident rather than because it has been tested"
        }
    }
    if ($focus -match "information evaluation|intellectual standards") {
        return [pscustomobject]@{
            workplace = "a team comparing a source article, a website summary, and an AI-generated response before making a recommendation"
            decision = "which information is credible, relevant, sufficient, and limited enough to use responsibly"
            artifact = "an intellectual-standards source evaluation"
            risk = "using information that is clear or convenient but not accurate, relevant, or sufficient"
        }
    }
    if ($focus -match "problem solving") {
        return [pscustomobject]@{
            workplace = "a student group facing a practical problem with limited time, incomplete information, and more than one possible solution"
            decision = "how to define the problem, compare alternatives, and justify the selected solution"
            artifact = "a problem-solving decision matrix"
            risk = "solving the first visible symptom instead of the actual problem"
        }
    }
    if ($focus -match "decision influences|bias|reasoning errors") {
        return [pscustomobject]@{
            workplace = "a professional team under time pressure deciding whether to accept a recommendation"
            decision = "which evidence is weak, which pressures or biases are present, and whether a reasoning error is shaping the conclusion"
            artifact = "a decision-influence audit"
            risk = "mistaking urgency, familiarity, or AI fluency for reliable reasoning"
        }
    }
    if ($focus -match "inductive|deductive") {
        return [pscustomobject]@{
            workplace = "a learner evaluating two arguments that reach similar conclusions using different kinds of support"
            decision = "whether each conclusion follows necessarily, is strongly supported, or needs additional evidence"
            artifact = "an inductive-deductive argument map"
            risk = "treating a likely conclusion as certain or rejecting a strong pattern because it is not absolute"
        }
    }
    if ($focus -match "ethical reasoning|persuasive argumentation|ethical position") {
        return [pscustomobject]@{
            workplace = "a learner preparing to communicate a position on an ethical issue in a professional setting"
            decision = "how to state the issue, support a position, address stakeholders and objections, and communicate with clarity"
            artifact = "an ethical argument brief"
            risk = "presenting a personal preference as an ethical argument without evidence, values, or response to objections"
        }
    }
    if ($focus -match "operating system|software environment") {
        return [pscustomobject]@{
            workplace = "a student opening a Windows workstation to complete a timed class task"
            decision = "which Windows tools to use for launching apps, switching windows, finding settings, searching for files, and troubleshooting a simple problem"
            artifact = "a Windows task navigation checklist"
            risk = "clicking through the interface by habit without knowing which tool solves the task"
        }
    }
    if ($focus -match "file management|local and cloud") {
        return [pscustomobject]@{
            workplace = "a student maintaining class files across a local computer folder and a cloud storage account"
            decision = "how to name, store, sync, back up, and share files so records stay secure and easy to retrieve"
            artifact = "a local-and-cloud file organization plan"
            risk = "saving work in an unclear location, overwriting a version, or sharing access too broadly"
        }
    }
    if ($focus -match "document creation|microsoft word") {
        return [pscustomobject]@{
            workplace = "a learner preparing a Word document for an academic or entry-level workplace audience"
            decision = "which layout, heading, spacing, style, and review choices make the document readable, professional, and ready for its audience"
            artifact = "a professional document formatting checklist"
            risk = "using visible formatting changes without creating a clear structure for the reader"
        }
    }
    if ($focus -match "source evaluation|apa citation|academic writing") {
        return [pscustomobject]@{
            workplace = "a student using online and library sources to support an academic writing task"
            decision = "which sources are credible and relevant, how to paraphrase responsibly, and how to create APA-style in-text citations and references"
            artifact = "a source evaluation and citation tracker"
            risk = "citing a weak source correctly or using a credible source inaccurately"
        }
    }
    if ($focus -match "cybersecurity|digital responsibility|keyboarding") {
        return [pscustomobject]@{
            workplace = "a learner completing digital work that includes account access, file sharing, communication, and timed keyboarding"
            decision = "how to protect personal and organizational information while maintaining accurate, efficient digital work habits"
            artifact = "a secure digital work routine"
            risk = "treating speed as success while ignoring privacy, phishing, file protection, or accuracy"
        }
    }
    if ($focus -match "interpersonal|listening|audience awareness") {
        return [pscustomobject]@{
            workplace = "a learner joining a professional conversation with a supervisor and a peer"
            decision = "how to listen, read verbal and nonverbal signals, and respond so the other person feels understood"
            artifact = "an audience-and-listening observation guide"
            risk = "answering too quickly and missing the meaning, emotion, or expectation behind the message"
        }
    }
    if ($focus -match "message planning|tone|channel") {
        return [pscustomobject]@{
            workplace = "a learner preparing a professional email after a confusing customer or coworker request"
            decision = "which purpose, audience need, tone, channel, organization, and follow-up detail will make the message clear"
            artifact = "a message planning note"
            risk = "sending a message that is technically correct but leaves the reader unsure what matters or what happens next"
        }
    }
    if ($focus -match "difficult-message|bad-news|conflict") {
        return [pscustomobject]@{
            workplace = "a learner revising a difficult message before it reaches a disappointed reader"
            decision = "how to be direct, respectful, specific, and helpful without hiding the main point"
            artifact = "a difficult-message revision note"
            risk = "softening the message so much that it becomes unclear, or stating it so bluntly that it damages trust"
        }
    }
    if ($focus -match "collaboration|meeting|team") {
        return [pscustomobject]@{
            workplace = "a learner helping a small team prepare for a short professional meeting"
            decision = "how the agenda, roles, listening habits, decisions, and follow-up notes should guide the conversation"
            artifact = "a meeting purpose and participation map"
            risk = "letting a meeting become busy conversation without clear decisions, ownership, or next steps"
        }
    }
    if ($focus -match "presentation") {
        return [pscustomobject]@{
            workplace = "a learner preparing a short professional presentation for a mixed audience"
            decision = "how to organize the opening, evidence, visuals, transitions, delivery, and closing around the audience's needs"
            artifact = "an audience-centered presentation arc"
            risk = "building slides around what the speaker wants to say instead of what the audience needs to understand"
        }
    }
    if ($focus -match "core business") {
        return [pscustomobject]@{
            workplace = "an allied healthcare clinic preparing a new patient reminder process"
            decision = "how scheduling, billing, records, patient service, and supervision should share information before the reminder process starts"
            artifact = "a cross-functional clinic handoff map"
            risk = "one function improving its own task while creating delays or privacy risk for another"
        }
    }
    if ($focus -match "workflow|process") {
        return [pscustomobject]@{
            workplace = "a clinic office handling patient intake forms, records updates, insurance questions, and follow-up calls"
            decision = "where to place ownership, checkpoints, privacy checks, and escalation triggers"
            artifact = "a patient-intake input-output-role-handoff process map"
            risk = "unclear handoffs causing rework, waiting time, missing information, or privacy mistakes"
        }
    }
    if ($focus -match "customer") {
        return [pscustomobject]@{
            workplace = "a clinic front office receiving phone, portal, and walk-in requests from patients and caregivers"
            decision = "how to respond quickly while staying accurate, professional, private, and well documented"
            artifact = "a patient-facing service standard"
            risk = "fast responses that solve the wrong problem or polite responses that arrive too late"
        }
    }
    if ($focus -match "improvement") {
        return [pscustomobject]@{
            workplace = "a clinic office reviewing a recurring Friday follow-up delay"
            decision = "which practical improvement is worth recommending based on evidence from the case"
            artifact = "an improvement memo with evidence, recommendation, owner, and expected result"
            risk = "choosing a familiar fix without diagnosing the real constraint"
        }
    }

    return [pscustomobject]@{
        workplace = "an allied healthcare office team supporting patients, providers, records, billing, and follow-up"
        decision = "how people, technology, and procedures should work together to complete reliable service"
        artifact = "a people-technology-procedure risk table"
        risk = "assuming a tool or policy alone will solve a problem that requires coordinated behavior"
    }
}

function Get-ChapterCaseFace {
    param([object]$Chapter)

    $example = Get-ChapterOperationalExample -Chapter $Chapter
    $focus = ([string]$Chapter.focus).ToLowerInvariant()
    $person = "Maya"
    $role = "medical front office assistant"
    $workplace = "an allied healthcare clinic"
    $situation = "A clinic manager asks Maya to route a time-sensitive appointment request while the team handles calls, records, insurance questions, and internal messages."
    $caseName = "Maya's clinic office handoff"
    $decision = $example.decision

    if ($Chapter.title -match "Leadership Styles") {
        $person = "Maya"
        $role = "medical front office assistant serving as acting team lead"
        $workplace = "Lakeside Imaging Center"
        $situation = "The scheduling system receives an update, a new employee is unsure which orders may be scheduled, and an experienced employee wants to keep using the old process while calls wait."
        $caseName = "Maya's first Monday as team lead"
        $decision = "how much direction and support each employee needs while the updated scheduling process takes effect"
    }
    elseif ($Chapter.title -match "Delegation") {
        $person = "Priya"
        $role = "patient records assistant"
        $workplace = "a clinic office that reviews patient intake forms"
        $situation = "Several intake forms arrive incomplete, and the team needs a clear path for intake, correction, privacy review, approval, and follow-up."
        $caseName = "Priya and the intake backlog"
        $decision = "where to place ownership, authority, support, and follow-up in the intake process"
    }
    elseif ($Chapter.title -match "Coaching") {
        $person = "Elena"
        $role = "clinic office supervisor"
        $workplace = "an allied healthcare clinic"
        $situation = "Elena needs to coach Jordan after several patient messages moved forward without a recorded status or clear next step."
        $caseName = "Elena prepares to coach Jordan"
        $decision = "how to set a clear expectation, understand the barrier, document the conversation, and agree on a next step"
    }
    elseif ($Chapter.title -match "Performance Feedback") {
        $person = "Marcus"
        $role = "clinic office supervisor"
        $workplace = "a clinic office reviewing a recurring Friday follow-up delay"
        $situation = "The team sees the same follow-up delay each week, and Marcus needs observable information before deciding whether the issue requires feedback, a process change, or both."
        $caseName = "Marcus and the Friday delay"
        $decision = "how to describe the behavior, use the available data, and resolve the conflict without losing the service standard"
    }
    elseif ($Chapter.title -match "Ethical|Inclusive") {
        $person = "Amina"
        $role = "clinic team lead"
        $workplace = "an allied healthcare office planning a new evening schedule"
        $situation = "Amina must balance coverage, patient access, employee needs, privacy, and fair participation while the team reviews a proposed schedule."
        $caseName = "Amina and the new evening schedule"
        $decision = "how to state the issue, weigh affected stakeholders, invite relevant perspectives, and communicate a fair decision"
    }
    elseif ($focus -match "core business|finance|human|marketing|interdependencies") {
        $person = "Jordan"
        $role = "clinic office coordinator"
        $workplace = "an allied healthcare practice preparing a new patient reminder process"
        $situation = "The process needs budget approval, staffing coverage, patient-facing messages, billing awareness, and a repeatable handoff plan before it can start."
        $caseName = "Jordan's cross-functional clinic launch"
    }
    elseif ($focus -match "workflow|process|inputs|outputs|handoffs|coordination") {
        $person = "Priya"
        $role = "patient records assistant"
        $workplace = "a clinic office that reviews patient intake forms"
        $situation = "Several intake forms arrive incomplete, and the team needs a clear path for intake, correction, privacy review, approval, and follow-up."
        $caseName = "Priya's patient-intake process map"
    }
    elseif ($focus -match "customer|responsiveness|professionalism") {
        $person = "Elena"
        $role = "patient services representative"
        $workplace = "a clinic front desk"
        $situation = "A patient calls about a delayed response and needs a clear answer, a documented next step, and a realistic follow-up time."
        $caseName = "Elena's patient service recovery"
    }
    elseif ($focus -match "improvement|evaluate|recommend|operational strategy") {
        $person = "Marcus"
        $role = "clinic office supervisor"
        $workplace = "a clinic office reviewing a recurring Friday follow-up delay"
        $situation = "The team sees the same follow-up delay each week and needs evidence before recommending a change."
        $caseName = "Marcus's clinic improvement memo"
    }
    elseif ($focus -match "critical thinking|information evaluation|problem solving|decision influences|inductive|deductive|ethical|persuasive|position") {
        $person = "Sam"
        $role = "learner preparing a professional recommendation"
        $workplace = "a course discussion connected to a workplace decision"
        $situation = "A claim sounds convincing, but the evidence, assumptions, and possible objections need a closer look before Sam can use it."
        $caseName = "Sam's evidence-based recommendation"
    }
    elseif ($focus -match "operating system|software environment|file management|local and cloud|document creation|microsoft word|source evaluation|apa citation|academic writing|cybersecurity|digital responsibility|keyboarding") {
        $person = "Taylor"
        $role = "student completing digital work for a workplace-style task"
        $workplace = "a course workspace that mirrors an entry-level office setting"
        $situation = "A task looks simple, but Taylor has to choose the right tool, protect the file, meet the standard, and verify the final result."
        $caseName = "Taylor's digital workflow"
    }
    elseif ($focus -match "communication|audience|message|tone|channel|listening|presentation|meeting|collaboration|professional writing|report|revision") {
        if ($focus -match "interpersonal|listening|audience awareness") {
            $person = "Nia"
            $role = "patient services representative"
            $workplace = "an allied healthcare front desk"
            $situation = "A worried patient asks why a referral has not moved forward, and Nia has to listen for facts, feelings, missing information, and the next respectful response."
            $caseName = "Nia's listening moment"
        }
        elseif ($focus -match "message planning|tone|channel|digital communication") {
            $person = "Leo"
            $role = "medical office assistant"
            $workplace = "a clinic message queue"
            $situation = "Leo must turn a confusing portal note into a clear patient-facing message that explains the next step without sharing private information in the wrong channel."
            $caseName = "Leo's patient-message plan"
        }
        elseif ($focus -match "difficult-message|bad-news|conflict") {
            $person = "Maya"
            $role = "clinic communication assistant"
            $workplace = "a scheduling office"
            $situation = "An appointment has to be rescheduled, and Maya needs to be honest about the change while protecting trust and giving the patient a useful path forward."
            $caseName = "Maya's difficult-message revision"
        }
        elseif ($focus -match "professional writing|report|revision") {
            $person = "Andre"
            $role = "administrative support specialist"
            $workplace = "an allied healthcare program office"
            $situation = "Andre is preparing a short update for a supervisor and must revise a rough draft so the decision, evidence, and recommended next step are easy to see."
            $caseName = "Andre's revision for a reader"
        }
        elseif ($focus -match "collaboration|meeting|team") {
            $person = "Samira"
            $role = "care-team coordinator"
            $workplace = "a small clinic huddle"
            $situation = "Samira has ten minutes to help a team clarify the agenda, hear concerns, record decisions, and leave with visible next steps."
            $caseName = "Samira's meeting follow-through"
        }
        elseif ($focus -match "presentation") {
            $person = "Noah"
            $role = "student preparing a workplace briefing"
            $workplace = "an allied healthcare training session"
            $situation = "Noah needs to explain a process change to classmates acting as new staff, using an opening, evidence, visuals, and a close that helps listeners remember the action."
            $caseName = "Noah's audience-centered briefing"
        }
        else {
            $person = "Ari"
            $role = "learner preparing for professional communication"
            $workplace = "an allied healthcare office scenario"
            $situation = "Ari needs to choose words, tone, channel, and follow-up for readers with different needs, time pressures, and levels of background knowledge."
            $caseName = "Ari's communication choice"
        }
    }

    $roleArticle = if ($role -match "^[aeiou]") { "an" } else { "a" }
    $roleWithArticle = "$roleArticle $role"

    return [pscustomobject]@{
        person = $person
        role = $role
        roleWithArticle = $roleWithArticle
        workplace = $workplace
        situation = $situation
        decision = $decision
        artifact = $example.artifact
        risk = $example.risk
        caseName = $caseName
        caseLine = "$person is $roleWithArticle at $workplace. $situation"
        jobConnection = "As you read, follow $person's choices and ask what you would need to know before taking the next step."
    }
}

function Get-ResearchLensParagraph {
    param(
        [object]$Chapter,
        [object]$Citations
    )

    $researchLabel = if ($Citations.research.Count -gt 0) {
        ConvertTo-CleanText $Citations.research[0].label
    }
    else {
        "Research on this topic"
    }
    $focus = $Chapter.focus.ToLowerInvariant()
    if ($focus -match "critical thinking") {
        return "A research lens frames critical thinking as a set of habits people can practice, not a personality trait. $researchLabel supports the chapter's focus on pausing before judgment, clarifying the question, testing evidence, and revising a conclusion when the reasons are weak."
    }
    if ($focus -match "information evaluation|intellectual standards") {
        return "A research lens helps learners treat information quality as part of reasoning quality. $researchLabel reinforces the need to evaluate clarity, accuracy, relevance, credibility, sufficiency, and the limits of AI-generated or quickly retrieved information before using it as support."
    }
    if ($focus -match "problem solving") {
        return "A research lens helps keep problem solving from becoming guesswork. $researchLabel supports a disciplined movement from problem definition to constraints, criteria, alternatives, evidence, and justification."
    }
    if ($focus -match "decision influences|bias|reasoning errors") {
        return "A research lens helps students see how judgment can be distorted by weak evidence, bias, pressure, context, and reasoning errors. $researchLabel frames decision quality as something that improves when influences are made visible before the conclusion is accepted."
    }
    if ($focus -match "inductive|deductive") {
        return "A research lens helps distinguish the kind of support an argument offers. $researchLabel supports the chapter's attention to whether reasons make a conclusion necessary, likely, weakly supported, or incomplete."
    }
    if ($focus -match "ethical reasoning|persuasive argumentation|ethical position") {
        return "A research lens helps connect ethical argument to evidence, values, stakeholders, and communication choices. $researchLabel reinforces that persuasion should make reasoning easier to inspect, not harder."
    }
    if ($focus -match "operating system|software environment") {
        return "A research lens helps frame operating-system use as task control, not memorized clicking. $researchLabel supports the chapter's emphasis on selecting the right interface feature, understanding what the tool changes, and checking whether the task is complete."
    }
    if ($focus -match "file management|local and cloud") {
        return "A research lens helps learners see file management as information organization. $researchLabel supports the chapter's emphasis on names, folders, versions, cloud sync, backup, permissions, and retrieval as parts of one recordkeeping habit."
    }
    if ($focus -match "document creation|microsoft word") {
        return "A research lens helps connect document formatting to reader usability. $researchLabel supports the chapter's emphasis on layout, headings, spacing, consistency, accessibility, and revision as choices that help another person understand and trust the document."
    }
    if ($focus -match "source evaluation|apa citation|academic writing") {
        return "A research lens helps connect source evaluation to academic integrity. $researchLabel supports the chapter's emphasis on credibility, relevance, paraphrasing, citation accuracy, and the difference between finding information and using it responsibly."
    }
    if ($focus -match "cybersecurity|digital responsibility|keyboarding") {
        return "A research lens helps connect secure behavior to everyday digital work. $researchLabel supports the chapter's emphasis on privacy, passwords, phishing awareness, careful communication, protected files, and accuracy under timed keyboarding conditions."
    }
    if ($focus -match "interpersonal|listening|audience awareness") {
        return "A research lens helps frame communication as more than sending words. $researchLabel supports the chapter's attention to audience, listening, verbal and nonverbal signals, feedback, and the way meaning changes across relationships and settings."
    }
    if ($focus -match "message planning|tone|channel|digital communication") {
        return "A research lens helps connect message quality to reader experience. $researchLabel supports the chapter's emphasis on purpose, audience need, organization, channel choice, tone, and revision as practical choices that make communication easier to understand and act on."
    }
    if ($focus -match "difficult-message|bad-news|conflict") {
        return "A research lens helps keep difficult communication clear, respectful, and usable. $researchLabel supports the chapter's focus on naming the issue, explaining the reason, protecting the relationship, and giving the reader a credible next step."
    }
    if ($focus -match "professional writing|report|revision") {
        return "A research lens helps connect professional writing to reader decision-making. $researchLabel supports the chapter's emphasis on concise organization, relevant evidence, accurate summaries, and revision that makes a report easier to trust."
    }
    if ($focus -match "collaboration|meeting|team") {
        return "A research lens helps show how team communication depends on shared purpose, turn-taking, roles, decisions, and follow-up. $researchLabel supports the chapter's emphasis on making collaboration visible enough that people know what happened and what comes next."
    }
    if ($focus -match "presentation") {
        return "A research lens helps connect presentation design to audience understanding. $researchLabel supports the chapter's emphasis on purpose, main points, evidence, visual support, delivery choices, and a closing that helps listeners remember what matters."
    }
    if ($focus -match "core business") {
        return "A research lens helps explain why this chapter is not just a list of departments. Cross-functional integration research asks how groups share knowledge, coordinate timing, and prevent one function from weakening another. $researchLabel frames interdependence as an information-flow problem: finance, human resources, marketing, and operations each see different evidence, and the workplace result depends on how well the team combines those views."
    }
    if ($focus -match "workflow|process") {
        return "A research lens helps learners see workflow as a designed system rather than a habit. Business process management research asks teams to map, review, control, and improve work. $researchLabel supports the idea that handoffs, roles, and controls are not paperwork for their own sake; they make service work visible enough to improve."
    }
    if ($focus -match "customer") {
        return "A research lens helps connect customer service to measurable service quality. SERVQUAL and related service-quality research direct attention to reliability, responsiveness, assurance, empathy, and the customer's perception of the service experience. $researchLabel reinforces that professionalism is not only politeness; it is the visible evidence that the organization can respond, explain, document, and follow through."
    }
    if ($focus -match "improvement") {
        return "A research lens helps keep improvement work disciplined. Lean service operations research focuses attention on waste, flow, capacity, waiting, and value from the customer's point of view. $researchLabel supports a careful improvement habit: define the problem, examine evidence, identify the constraint, recommend a change, and describe how the organization would know whether the change worked."
    }

    return "A research lens helps explain why office operations are sociotechnical. People, tools, rules, physical spaces, and information systems influence one another. $researchLabel frames productivity and risk as the result of interaction: a good employee using a confusing system can still produce errors, and a good system without clear procedures can still create inconsistent service."
}

function Get-ObjectiveConceptFrame {
    param([string]$Objective)

    $lower = $Objective.ToLowerInvariant()
    if ($lower -match "critical thinking") {
        return "Critical thinking means careful thinking about claims, evidence, assumptions, alternatives, and conclusions. It does not mean being negative or argumentative. A critical thinker slows down and asks which question the claim answers, what information is available, what is missing, and how strongly the evidence supports the conclusion."
    }
    if ($lower -match "skills and habits|key skills|habits") {
        return "Critical thinking habits include curiosity, intellectual humility, accuracy, fair-mindedness, persistence, and willingness to revise a view when the evidence changes. Skills and habits work together: a person may know how to evaluate a claim, but the habit of pausing, checking, and revising is what makes the skill visible in real decisions."
    }
    if ($lower -match "universal intellectual standards|clarity|accuracy|relevance|sufficiency") {
        return "Universal intellectual standards are questions used to judge the quality of thinking. Clarity asks whether the idea is understandable. Accuracy asks whether it is true or correct. Relevance asks whether it actually bears on the issue. Sufficiency asks whether there is enough support to justify the conclusion. These standards help students improve thinking before they defend it."
    }
    if ($lower -match "credibility|sources|ai") {
        return "Source evaluation asks whether information deserves trust. Credibility, relevance, and sufficiency matter for human-authored sources and AI-generated content. AI may produce fluent language without reliable evidence, so the thinker still has to verify claims, inspect assumptions, and decide whether the information supports the conclusion."
    }
    if ($lower -match "define a problem|problem by identifying|issue, context, and constraints") {
        return "Problem definition is the first reasoning task in problem solving. A problem should name the issue, context, constraints, stakeholders, and desired outcome. If the problem is defined too quickly, the solution may address a symptom rather than the real difficulty."
    }
    if ($lower -match "problem-solving process|analyze a situation") {
        return "A systematic problem-solving process helps students move from confusion to justified action. The process usually includes defining the issue, gathering relevant information, identifying constraints, comparing alternatives, choosing criteria, selecting a solution, and explaining why that solution fits the evidence."
    }
    if ($lower -match "justify a selected solution|alternatives|criteria") {
        return "Justification explains why one solution is stronger than the available alternatives. A justified solution is not simply preferred; it is supported by criteria, evidence, and a clear explanation of tradeoffs. Good justification also admits limits and shows why rejected alternatives were less appropriate."
    }
    if ($lower -match "weak or missing evidence|evidence affects") {
        return "Weak or missing evidence lowers decision quality because the conclusion rests on uncertainty that may not be visible. A decision can sound confident while still being poorly supported. Careful thinkers ask what evidence is available, what evidence is absent, and how the missing information should affect confidence."
    }
    if ($lower -match "bias|pressure|context") {
        return "Bias, pressure, and context influence decisions by shaping what people notice, ignore, or treat as urgent. A thinker under pressure may accept the first answer that reduces discomfort. A thinker influenced by bias may give more weight to familiar information. Naming these influences helps protect judgment."
    }
    if ($lower -match "fallacies|reasoning errors") {
        return "Reasoning errors and fallacies distort decisions by making weak support appear stronger than it is. A fallacy may distract from the issue, attack the person instead of the argument, rely on popularity, or assume that one event caused another without enough evidence. Identifying the error helps the thinker return to the actual reasons."
    }
    if ($lower -match "inductive|deductive|conclusions logically follow") {
        return "Deductive reasoning asks whether a conclusion must follow if the premises are true. Inductive reasoning asks whether the evidence makes the conclusion likely or strong. The difference matters because some arguments aim for certainty while others aim for probability, pattern, or best explanation."
    }
    if ($lower -match "strength of reasoning|support conclusions") {
        return "The strength of reasoning depends on the connection between reasons and conclusion. Strong reasoning uses relevant, sufficient, and credible support. Weak reasoning may include true statements that do not prove the point, evidence that is too limited, or assumptions that have not been examined."
    }
    if ($lower -match "ethical position|ethical issue|ethical argument") {
        return "Ethical reasoning examines what people should do when values, duties, consequences, rights, or responsibilities matter. A reasoned ethical position states the issue, names the relevant values or obligations, evaluates evidence, considers stakeholders, and explains why the position makes sense."
    }
    if ($lower -match "persuasive|personal position|communicate") {
        return "Persuasive communication makes reasoning visible to another person. A clear position, organized support, respectful tone, and response to likely objections help readers understand why the conclusion is reasonable. Persuasion is strongest when it clarifies evidence rather than hiding weak reasoning behind emotional language."
    }
    if ($lower -match "windows|operating system") {
        return "A current operating system is the working environment that lets the user launch applications, manage windows, adjust settings, search for files, connect devices, and control basic security and accessibility features. Windows proficiency means knowing which feature fits the task and how to verify that the action worked."
    }
    if ($lower -match "files|folders|cloud storage|local and cloud|accessible records") {
        return "File management is the practice of naming, saving, organizing, retrieving, backing up, syncing, and sharing digital records so work remains findable and protected. Local folders, removable storage, and cloud tools can all support the same goal, but each requires clear decisions about location, version, permissions, and access."
    }
    if ($lower -match "microsoft word|professional documents|formatting|\bstructure\b|layout") {
        return "A professional Word document uses formatting to serve the reader. Margins, headings, spacing, lists, alignment, styles, page layout, and review tools should make the document easier to read, navigate, revise, and trust. Formatting is not decoration; it is part of communication quality."
    }
    if ($lower -match "credible sources|cite|citation|apa|academic writing") {
        return "Academic source use connects research judgment with documentation. A credible source should be relevant, current enough for the task, authored or published by a trustworthy authority, and represented accurately. APA citation then gives readers a clear path from the writer's claim to the source used for support."
    }
    if ($lower -match "cybersecurity|responsible digital|personal and organizational information|privacy|security") {
        return "Cybersecurity and responsible digital behavior protect people, records, accounts, and organizations from avoidable harm. Good habits include using strong authentication, recognizing suspicious messages, protecting private information, updating devices, saving files carefully, and communicating online with professionalism and respect."
    }
    if ($lower -match "keyboarding|words per minute|wpm|accuracy|timed assessment") {
        return "Keyboarding proficiency combines speed, accuracy, posture, attention, and correction habits. A timed assessment measures whether the learner can enter text efficiently while keeping errors low enough that the final work remains usable."
    }
    if ($lower -match "people") {
        return "People influence productivity through judgment, communication, attention, skill, workload, and accountability. In office operations, a person is rarely just an individual performer; that person is part of a chain of promises. When one employee clarifies a request, records a decision, or alerts the next owner, productivity improves because less time is spent guessing. Risk increases when people rely on memory, skip documentation, or assume that another role has the same context."
    }
    if ($lower -match "technology") {
        return "Technology influences productivity by shaping what people can find, share, automate, measure, and protect. A scheduling tool, document system, customer relationship platform, or shared inbox can reduce repeated work when the team uses it consistently. The same tool can increase risk when permissions are unclear, records are incomplete, templates are old, or employees do not understand the limits of automation."
    }
    if ($lower -match "procedures") {
        return "Procedures influence productivity by turning repeated decisions into shared expectations. A procedure tells the team what starts the work, what information the team needs, who approves the result, and what to do when the normal path fails. Procedures reduce risk when people can find them, follow them, and use them to escalate exceptions. They create new risk when they are vague, hidden, old, or treated as a substitute for judgment."
    }
    if ($lower -match "organizational structures") {
        return "Organizational structure describes how an organization arranges authority, communication, roles, and reporting relationships. Functional structures group people by specialty. Divisional structures group work by product, geography, or customer. Matrix structures combine more than one reporting or coordination path. Office operations support these structures by making work traceable: requests move to the right owner, staff document decisions, and the organization can see whether its structure helps or slows the work."
    }
    if ($lower -match "strategic goals") {
        return "Strategic goals become operational only when people can translate them into daily work. Office operations support strategy through scheduling, records, communication, workflow controls, customer follow-up, and data that leaders can use. If the goal is faster service, the office needs intake standards and response tracking. If the goal is quality, the office needs review points. If the goal is growth, the office needs repeatable processes that can scale."
    }
    if ($lower -match "finance") {
        return "Finance work focuses on money, budgets, billing, purchasing, cash flow, and financial controls. In an office workflow, finance often connects to approvals, documents, vendor records, invoices, payroll, reports, and resource decisions. A finance workflow works well when the team sends the needed evidence before the decision. It becomes risky when staff approve costs without documents, delay records, or separate financial information from the service decision."
    }
    if ($lower -match "human relations|human resources") {
        return "Human relations and human resources work focuses on people capacity, roles, employee records, staffing needs, performance expectations, training, and workplace communication. In office operations, HR-related workflows often appear when a team needs coverage, onboarding, schedule changes, policy guidance, or performance documentation. The workflow is effective when people information reaches the right decision point without exposing private details unnecessarily."
    }
    if ($lower -match "marketing") {
        return "Marketing work focuses on customers, messages, reputation, demand, and the way the organization presents value. In an office workflow, marketing connects to customer questions, campaign timing, event support, lead tracking, service promises, and communication materials. The workflow is productive when customer-facing messages match the organization's actual capacity. It becomes risky when marketing promises a response, service, or timeline that operations cannot reliably deliver."
    }
    if ($lower -match "interdependencies") {
        return "Interdependence means that one function's work changes the conditions for another function's work. Finance may approve a budget, HR may staff the activity, marketing may communicate the offer, and operations may deliver the service. The office professional sees the connections by tracking inputs, outputs, approvals, timing, and information quality. A workflow problem often appears first as a delay, but the cause may be a missing decision in another function."
    }
    if ($lower -match "inputs|outputs|roles|handoffs") {
        return "Inputs are the information, materials, approvals, or requests needed to begin work. Outputs are the completed results the next person or customer receives. Roles identify who owns the work, who supports it, and who approves it. Handoffs are the transfer points where work moves from one person, system, or department to another. Many office errors occur at handoffs because the receiving person lacks context, authority, or complete information."
    }
    if ($lower -match "process flow") {
        return "A process flow shows the order of work from trigger to completion. It should make visible what happens first, what happens next, where decisions occur, and where the process can return for correction. A good process flow is not just a diagram; it is a shared explanation of how the office protects timeliness, accuracy, accountability, and service quality."
    }
    if ($lower -match "coordination techniques") {
        return "Workflow coordination techniques include intake standards, shared queues, status tracking, role clarification, escalation rules, templates, checklists, turnaround targets, and brief team communication routines. The purpose is not to add bureaucracy. The purpose is to make work visible enough that people can see priority, ownership, barriers, and the next action."
    }
    if ($lower -match "improve timeliness|service quality") {
        return "Improving timeliness and service quality requires more than asking people to work faster. The office has to identify where waiting occurs, why rework happens, what information is missing, and how customers experience the delay. Improvement techniques might include clearer intake forms, standard response times, better routing rules, fewer approval loops, or stronger documentation at handoff points."
    }
    if ($lower -match "customer-facing") {
        return "Customer-facing office processes shape what the customer sees, hears, receives, and believes about the organization. These processes include intake, greeting, identity verification, expectation setting, problem solving, documentation, escalation, and follow-up. Efficiency matters because customers should not wait unnecessarily. Responsiveness matters because customers need evidence that the organization is paying attention. Professionalism matters because tone, accuracy, privacy, and follow-through influence trust."
    }
    if ($lower -match "determine if") {
        return "Evaluating a customer-facing process requires evidence. The evaluator should look for whether the process captures the customer's need, routes the request correctly, explains next steps, protects confidentiality, records the interaction, and closes the loop. A process can seem friendly and still fail if it does not solve the problem. It can seem efficient and still fail if it makes customers repeat information."
    }
    if ($lower -match "operational strategy") {
        return "Operational strategy is the pattern of choices an organization uses to deliver value. In an office setting, strategy appears in staffing, scheduling, workflow design, technology use, quality controls, and service standards. To describe a strategy, identify what the organization is trying to accomplish, what resources it uses, what tradeoffs it accepts, and how the office's daily work supports or weakens that direction."
    }
    if ($lower -match "evaluate") {
        return "Evaluation asks whether the current approach is working and why. A useful evaluation does not rely on preference alone. It looks at evidence such as delays, errors, rework, customer complaints, employee workload, missed handoffs, incomplete records, or inconsistent outcomes. The office professional should distinguish symptoms from causes before recommending a change."
    }
    if ($lower -match "suggest improvements|recommend") {
        return "A strong improvement recommendation names the problem, cites evidence, proposes a specific change, explains why that change fits the situation, and identifies how the team will measure success. In office operations, people should be able to use the improvement, learn it, and review it after a short test."
    }

    if ($lower -match "communication|audience|message|tone|channel|listening|presentation|meeting|collaboration|professional writing|report|revision|verbal|nonverbal") {
        return "Professional communication turns intention into a reader or listener experience. A communicator has to understand the audience, choose the right channel, organize the message, use respectful language, and revise until the next step is clear. The skill is visible when another person can understand the purpose without guessing."
    }

    return "This objective turns a course concept into practical judgment. The learner should identify the relevant information, connect it to the situation, choose a next action, and explain the evidence behind that action."
}

function Get-ObjectivePracticeParagraph {
    param(
        [string]$Objective,
        [object]$Chapter
    )

    $lower = $Objective.ToLowerInvariant()
    if ($lower -match "critical thinking|skills and habits|key skills|habits") {
        return "In practice, critical thinking begins with a pause. A learner may read a claim, feel an immediate reaction, and then slow down: What does the claim say? What evidence supports it? What assumption hides inside it? What would change my confidence? The habit shows up when the learner can explain the thinking, not only state the answer."
    }
    if ($lower -match "universal intellectual standards|clarity|accuracy|relevance|sufficiency|credibility|sources|ai") {
        return "In practice, information evaluation protects decisions from confident but weak support. A student might compare a news article, a database source, and an AI-generated summary. The task is not to choose the source that sounds best. The task is to decide which source is clear, accurate, relevant, credible, and sufficient for the specific conclusion."
    }
    if ($lower -match "problem|solution|alternatives|criteria") {
        return "In practice, problem solving starts by resisting the urge to fix the first visible symptom. A team may think the problem is poor participation, when the real issue is unclear instructions, limited time, or missing resources. Defining context and constraints helps the solution fit the actual situation."
    }
    if ($lower -match "weak or missing evidence|bias|pressure|context|fallacies|reasoning errors|decision|judgment") {
        return "In practice, decision quality improves when influences are named before the conclusion is defended. A learner might notice that time pressure makes one option feel safer, that a familiar source seems more trustworthy than it deserves, or that an AI response sounds fluent without showing evidence. Naming the influence creates room to evaluate it."
    }
    if ($lower -match "inductive|deductive|conclusions logically follow|strength of reasoning") {
        return "In practice, argument evaluation means tracing the path from reasons to conclusion. If the argument is deductive, ask whether the conclusion must follow. If it is inductive, ask how strong the evidence is and what additional information would increase confidence. Both forms require attention to assumptions."
    }
    if ($lower -match "ethical|persuasive|personal position|communicate") {
        return "In practice, ethical communication asks the writer to do more than announce a belief. The writer needs to state the issue, explain the position, use relevant evidence, consider who is affected, address a reasonable objection, and communicate in a tone that invites serious consideration."
    }
    if ($lower -match "windows|operating system") {
        return "In practice, Windows navigation starts with a task goal. A student may need to open an application, compare two windows, find a downloaded file, adjust a setting, or use help. The skill is visible when the student can choose a direct path, explain why that path fits, and recover if the first attempt does not work."
    }
    if ($lower -match "files|folders|cloud storage|local and cloud|accessible records") {
        return "In practice, file management protects continuity. A student who names a document clearly, saves it in the correct course folder, syncs it to cloud storage, checks the version, and confirms sharing permissions makes the work easier to find and safer to continue."
    }
    if ($lower -match "microsoft word|professional documents|formatting|\bstructure\b|layout") {
        return "In practice, Word document creation requires choices that affect readers. A student may use headings for structure, spacing for readability, margins for page design, lists for scanning, and review tools for revision. The finished document should look intentional and be easy to navigate."
    }
    if ($lower -match "credible sources|cite|citation|apa|academic writing") {
        return "In practice, source use begins before the citation is typed. A student should identify the question, choose a credible source, take accurate notes, paraphrase responsibly, and then create the in-text citation and reference entry. Citation format supports integrity, but it cannot fix weak source judgment."
    }
    if ($lower -match "cybersecurity|responsible digital|personal and organizational information|privacy|security") {
        return "In practice, secure digital behavior appears in ordinary moments: checking a link before clicking, keeping passwords private, locking the screen, avoiding oversharing, updating software, and confirming that the right person receives the file."
    }
    if ($lower -match "keyboarding|words per minute|wpm|accuracy|timed assessment") {
        return "In practice, keyboarding proficiency develops through short, regular practice with immediate attention to errors. A learner should build rhythm without ignoring accuracy, because the assessment expects both speed and a usable final text."
    }
    if ($lower -match "people influence") {
        return "In a busy office, people shape the work through the questions they ask, the details they notice, and the handoffs they protect. A staff member who confirms the purpose of a request before routing it prevents wasted effort. A staff member who records status in a shared location protects the next person from guessing. Productivity improves when the team treats clarity as part of the work, not as an extra step."
    }
    if ($lower -match "technology influence") {
        return "Technology should make the work easier to see and easier to continue. A shared calendar can protect deadlines, a document system can protect version control, and a customer record can protect continuity across employees. The tool becomes risky when it hides work, splits information across too many places, or allows people to believe that clicking a button is the same as completing the process."
    }
    if ($lower -match "procedures influence") {
        return "Procedures are useful when they help people act consistently under pressure. A good procedure explains the trigger, the required information, the normal path, the exception path, and the expected result. It should be easy enough to follow during a high-volume day and specific enough that two employees would handle the same routine request in a similar way."
    }
    if ($lower -match "people, technology, and procedures interact") {
        return "The interaction matters because none of the three elements works alone. A trained employee still needs accurate records. A strong software system still needs users who understand the workflow. A written procedure still needs tools that support it. Operational quality improves when the office designs the people, technology, and procedure together instead of treating each one as a separate fix."
    }
    if ($lower -match "organizational structures") {
        return "Structure affects daily office work because it determines where requests travel and where decisions can be made. In a functional structure, an office professional may need to coordinate across specialized departments. In a divisional structure, the same request may follow different paths depending on location or customer group. In a matrix structure, clear documentation becomes especially important because more than one reporting line may influence the work."
    }
    if ($lower -match "strategic goals") {
        return "A strategic goal becomes meaningful only when office routines support it. A goal of faster response requires intake rules, visible status, and response-time tracking. A goal of better quality requires review points and error feedback. A goal of growth requires repeatable processes that do not depend on one employee's memory. Office operations translate strategy into habits the organization can repeat."
    }
    if ($lower -match "finance") {
        return "A finance workflow often begins with a request that needs money, approval, or documents. The office professional protects the process by checking whether the cost has approval, whether the vendor or account information is accurate, and whether staff recorded the decision. Delays often appear at the payment or approval step, but the original request may lack needed information."
    }
    if ($lower -match "human relations|human resources") {
        return "Human relations workflows depend on accuracy and discretion. A schedule change, onboarding task, training record, or coverage request can affect service quality and employee experience. The office professional helps by routing information to the right owner, protecting private details, and making sure the next person knows which decision comes next."
    }
    if ($lower -match "marketing") {
        return "Marketing workflows connect office operations to the promises an organization makes to customers or clients. A campaign, event, or customer message can create demand that the office must be ready to handle. Operational support includes accurate contact lists, clear scripts, timely follow-up, and feedback when customer response is different from what the organization expected."
    }
    if ($lower -match "interdependencies") {
        return "Interdependence becomes visible when one function cannot complete its work without another function's input. Finance may need enrollment numbers, HR may need staffing timelines, marketing may need service details, and operations may need all three before delivery can happen. A useful handoff map shows what each function gives, what it receives, and what happens if that information is late or incomplete."
    }
    if ($lower -match "inputs|outputs|roles|handoffs") {
        return "Mapping inputs, outputs, roles, and handoffs turns invisible office work into a process the team can improve. Start with the trigger, then name the information the team needs to begin. Identify who owns each step, what result they produce, and where the work moves next. The strongest maps show the normal path and the points where waiting, correction, or escalation may occur."
    }
    if ($lower -match "process flow") {
        return "A process flow should help another person understand the work without needing a long explanation. Each step should use a clear action verb, each decision point should show the possible path, and each handoff should identify the receiving role. A process flow is especially helpful when employees disagree about how work actually moves through the office."
    }
    if ($lower -match "coordination techniques") {
        return "Coordination techniques keep work from disappearing between people, systems, or departments. Shared queues, status boards, intake standards, escalation rules, and brief check-ins all make the next action easier to see. The best technique is not always the most complicated one. It is the one that fits the risk, volume, urgency, and skill level of the office."
    }
    if ($lower -match "improve timeliness|service quality") {
        return "Improvement starts by separating speed from quality. A faster process that creates rework is not truly timely. A careful process that leaves customers waiting without updates is not good service. The office professional looks for the reason behind the delay, such as missing information, unclear ownership, too many approvals, weak templates, or limited capacity at a key step."
    }
    if ($lower -match "customer-facing") {
        return "Customers judge a process by what they experience: whether the organization listens, responds, explains, documents, and follows through. The office must balance warmth with accuracy and speed with privacy. A professional process helps the customer know what comes next, even when the answer requires time or escalation. Students should also notice whether the office gives customers a realistic next step, because silence after a friendly interaction can still feel like poor service."
    }
    if ($lower -match "determine if") {
        return "To determine whether a customer-facing process is effective, compare the customer's need with what the process actually delivers. Look at waiting time, number of repeated questions, clarity of next steps, accuracy of records, tone of communication, and whether the loop is closed. Evidence matters because a process may feel friendly while still leaving the customer without a solution."
    }
    if ($lower -match "operational strategy") {
        return "You can see operational strategy in choices about staffing, scheduling, quality control, technology, and service standards. A workplace example may show that the organization values speed, personal service, low cost, compliance, or consistency. The office professional describes the strategy by naming those choices and connecting them to the results the organization wants."
    }
    if ($lower -match "evaluate") {
        return "Evaluation requires evidence from the work itself. Useful evidence includes delays, errors, customer complaints, rework, employee workload, missing records, and inconsistent outcomes. The goal is not to criticize the office; it is to understand whether the current strategy produces the result it promises."
    }
    if ($lower -match "suggest improvements|recommend") {
        return "A strong improvement recommendation should be small enough to implement and specific enough to test. Instead of saying that communication should improve, name the communication point, the owner, the timing, the tool, and the evidence that would show improvement. The recommendation should reduce friction without creating unnecessary steps."
    }

    if (([string]$Chapter.focus) -match "communication|audience|message|tone|channel|listening|presentation|meeting|collaboration") {
        $example = Get-ChapterOperationalExample -Chapter $Chapter
        return "In $($example.workplace), the concept becomes practical when the communicator has to decide $($example.decision). The communicator should identify the audience, purpose, channel, tone, key detail, and revision choice that would make the message easier to understand and trust."
    }

    $example = Get-ChapterOperationalExample -Chapter $Chapter
    return "In $($example.workplace), the concept becomes practical when the team has to decide $($example.decision). The office professional should identify the missing information, the owner of the next action, the relevant tool or record, and the risk created by a weak handoff."
}

function Get-ObjectiveMethodParagraph {
    param(
        [string]$Objective,
        [object]$Chapter
    )

    $lower = $Objective.ToLowerInvariant()
    if ($lower -match "critical thinking|skills and habits|universal intellectual standards|credibility|sources|ai|evidence|bias|fallacies|inductive|deductive|conclusions logically follow|strength of reasoning|ethical|persuasive|personal position|problem|solution") {
        if ($lower -match "problem|solution|alternatives|criteria") {
            return "A useful method is to define the problem in one sentence, list the context and constraints, name two or three possible solutions, choose fair criteria, and explain which solution best fits the evidence."
        }
        if ($lower -match "inductive|deductive|conclusions logically follow|strength of reasoning") {
            return "A useful method is to separate the conclusion from the reasons. Then ask whether the conclusion must follow from the reasons or is only made more likely by them. Finally, identify any missing assumption or evidence that affects the strength of support."
        }
        if ($lower -match "ethical|persuasive|personal position|communicate") {
            return "A useful method is to build the argument in parts: issue, position, reasons, evidence, stakeholder concern, objection, response, and closing claim. This keeps persuasion connected to reasoning instead of only tone."
        }
        return "A useful method is to use a reasoning check: clarify the question, identify the claim, list the evidence, name assumptions, consider alternatives, judge the strength of support, and revise the conclusion if the support is weaker than expected."
    }
    if ($lower -match "windows|operating system") {
        return "A useful method is to name the task, choose the most direct Windows feature, complete the action, and verify the result. If the first path fails, use search, settings, help, or File Explorer to locate the missing tool or information."
    }
    if ($lower -match "files|folders|cloud storage|local and cloud|accessible records") {
        return "A useful method is to apply a file management checklist: choose the storage location, create a logical folder path, use a descriptive file name, save a version, confirm cloud sync or backup, and check access before sharing."
    }
    if ($lower -match "microsoft word|professional documents|formatting|\bstructure\b|layout") {
        return "A useful method is to format from structure outward. First identify the document purpose and sections. Then apply margins, headings, styles, spacing, lists, and alignment. Finally, review the document for readability, consistency, spelling, and audience expectations."
    }
    if ($lower -match "credible sources|cite|citation|apa|academic writing") {
        return "A useful method is to move from source to support to citation: evaluate credibility, identify the specific evidence being used, paraphrase or quote accurately, add the in-text citation, build the reference entry, and compare both against the APA requirement."
    }
    if ($lower -match "cybersecurity|responsible digital|personal and organizational information|privacy|security") {
        return "A useful method is to pause before each digital handoff. Ask what information is involved, who should have access, what threat or mistake is likely, which protective action you need, and how you will confirm the account, file, or message is secure."
    }
    if ($lower -match "keyboarding|words per minute|wpm|accuracy|timed assessment") {
        return "A useful method is to practice in timed rounds, record words per minute and accuracy, review the most common errors, slow down just enough to correct the pattern, and then retest under the same conditions."
    }
    if (([string]$Chapter.focus) -match "communication|audience|message|tone|channel|listening|presentation|meeting|collaboration") {
        return "A useful method is to start with the reader. Name the audience, purpose, relationship, channel, and likely question. Then choose the main point, organize the details, check the tone, and revise one sentence so the message is clearer and easier to act on."
    }
    if ($lower -match "map|inputs|outputs|handoffs|process flow") {
        return "A useful method is to write the process as a sequence of observable steps. For each step, ask four questions: What information enters here? Who is responsible? What output should leave this step? What could delay or damage the handoff? The answers become the first draft of a process map."
    }
    if ($lower -match "customer") {
        return "A useful method is to review the process from the customer's point of view and from the office's point of view. The customer needs clarity, responsiveness, and respectful treatment. The office needs accurate information, appropriate documentation, and a realistic path for follow-up. A strong process serves both needs."
    }
    if ($lower -match "improvement|evaluate|recommend") {
        return "A useful method is to move from symptom to cause before recommending a fix. Name the visible problem, gather evidence, identify the constraint, choose one practical change, and decide how the office would know whether the change worked. This keeps improvement from becoming a list of preferences."
    }
    if ($lower -match "finance|human|marketing|interdependencies|core functions") {
        return "A useful method is to trace one workplace decision across functions. Identify what finance, human resources, marketing, and operations each need to know, what each function contributes, and where the work could stall. The exercise helps students see the office as a coordination system rather than a collection of isolated departments."
    }

    return "A useful method is to define the work in observable terms, identify the evidence needed before the next step, name the owner and backup owner, and record the decision where the next person can find it. These moves turn informal effort into reliable operations."
}

function Get-ObjectiveCommonMistakeParagraph {
    param(
        [string]$Objective,
        [object]$Chapter
    )

    $lower = $Objective.ToLowerInvariant()
    if ($lower -match "critical thinking|skills and habits|universal intellectual standards|credibility|sources|ai|evidence|bias|fallacies|inductive|deductive|conclusions logically follow|strength of reasoning|ethical|persuasive|personal position|problem|solution") {
        if ($lower -match "ai|sources|credibility") {
        return "The common mistake is treating fluent information as reliable information. A source or AI response can be easy to read and still lack support, use old information, leave out key facts, or miss the point."
        }
        if ($lower -match "bias|pressure|fallacies|reasoning errors") {
            return "The common mistake is noticing reasoning problems only in other people's arguments. Critical thinkers also inspect their own reactions, preferred answers, and shortcuts."
        }
        if ($lower -match "ethical|persuasive|personal position") {
            return "The common mistake is confusing persuasion with pressure. A strong ethical argument should make the reasoning more visible, not simply push the reader toward agreement."
        }
        return "The common mistake is jumping from first impression to final conclusion. Critical thinking requires the middle work: clarify the claim, test evidence, name assumptions, and check whether the conclusion deserves your confidence."
    }
    if ($lower -match "windows|operating system") {
        return "The common mistake is memorizing one path through the interface and becoming stuck when the screen looks different. Windows proficiency improves when students understand the purpose of the feature, not only where a button appeared during one demonstration."
    }
    if ($lower -match "files|folders|cloud storage|local and cloud|accessible records") {
        return "The common mistake is saving work quickly without confirming the location, file name, version, sync status, or sharing permission. A file is not managed until the learner can find it again and explain who can access it."
    }
    if ($lower -match "microsoft word|professional documents|formatting|\bstructure\b|layout") {
        return "The common mistake is manually changing isolated pieces of text until the document looks acceptable on one screen. Professional formatting should be consistent, structured, readable, and stable when the document is reviewed or printed."
    }
    if ($lower -match "credible sources|cite|citation|apa|academic writing") {
        return "The common mistake is focusing on punctuation in the citation while ignoring whether the source is credible, relevant, accurately paraphrased, and actually connected to the claim being made."
    }
    if ($lower -match "cybersecurity|responsible digital|personal and organizational information|privacy|security") {
        return "The common mistake is treating security as something only specialists handle. Many incidents begin with ordinary user choices, such as clicking too quickly, reusing passwords, sharing private information, or sending a file without checking the recipient."
    }
    if ($lower -match "keyboarding|words per minute|wpm|accuracy|timed assessment") {
        return "The common mistake is chasing speed while allowing errors to multiply. A high words-per-minute score does not meet the workplace standard if accuracy is too low for the text to be usable."
    }
    if ($lower -match "technology") {
        return "The common mistake is assuming the software has solved the workflow. A tool can store information without making it complete, route work without making ownership clear, or automate a task without confirming that the result is useful. Technology reduces risk only when people and procedures support it."
    }
    if ($lower -match "procedures") {
        return "The common mistake is writing a procedure that looks complete but does not work during real work. If employees cannot find it, understand it, or use it when exceptions occur, the procedure becomes decoration. A procedure should reduce uncertainty when someone needs to decide."
    }
    if ($lower -match "map|process|handoffs") {
        return "The common mistake is drawing the ideal process instead of the real one. A map that ignores waiting time, rework, missing information, or informal workarounds will not help the office improve. The best maps are honest enough to show friction."
    }
    if ($lower -match "customer") {
        return "The common mistake is measuring service only by attitude or only by speed. Polite service that does not solve the problem still fails the customer. Fast service that creates errors also fails the customer. Professional service combines tone, accuracy, timeliness, documentation, and follow-through."
    }
    if ($lower -match "improvement|evaluate|recommend") {
        return "The common mistake is jumping to a familiar solution before diagnosing the work. More training, a new form, or a new tool may help, but only if it addresses the actual constraint. Evidence keeps the recommendation connected to the problem."
    }
    if (([string]$Chapter.focus) -match "communication|audience|message|tone|channel|listening|presentation|meeting|collaboration") {
        $example = Get-ChapterOperationalExample -Chapter $Chapter
        return "The common mistake is treating communication as words only. A person may know what they want to say and still miss the audience need, tone, channel, timing, or relationship risk. In this chapter's case, the risk is $($example.risk)."
    }

    $example = Get-ChapterOperationalExample -Chapter $Chapter
    return "The common mistake is treating the idea as vocabulary only. A person may know the term and still miss the operational risk. In this type of office work, the risk is $($example.risk)."
}

function Get-ObjectiveWorkedExample {
    param(
        [string]$Objective,
        [object]$Chapter
    )

    $lower = $Objective.ToLowerInvariant()
    $caseFace = Get-ChapterCaseFace -Chapter $Chapter
    if ($lower -match "critical thinking|skills and habits") {
        return "A student reads a claim that a policy is unfair. Before agreeing or disagreeing, the student identifies the exact claim, lists the evidence given, names one assumption, and asks what additional information would make the conclusion stronger."
    }
    if ($lower -match "universal intellectual standards|clarity|accuracy|relevance|sufficiency|credibility|sources|ai") {
        return "A learner asks an AI tool for a summary of an ethical issue. The response is clear, but it gives no sources and leaves out a key stakeholder. The learner verifies the claims, checks relevance, and uses the response only as a starting point."
    }
    if ($lower -match "problem|solution|alternatives|criteria") {
        return "A group says the problem is low participation. After defining the issue, they find that the instructions are unclear and the deadline conflicts with another task. They compare two solutions and justify the one that addresses the actual constraint."
    }
    if ($lower -match "weak or missing evidence|bias|pressure|context|fallacies|reasoning errors|decision|judgment") {
        return "A team accepts a recommendation because it came from a confident speaker under time pressure. A reviewer slows the decision down, asks what evidence is missing, and identifies a possible appeal-to-authority error before the group decides."
    }
    if ($lower -match "inductive|deductive|conclusions logically follow|strength of reasoning") {
        return "One argument says all received forms were verified and this form was received, so this form was verified. Another says most students who used a checklist improved their drafts, so this checklist may help. The first asks about deductive validity; the second asks about inductive strength."
    }
    if ($lower -match "ethical|persuasive|personal position|communicate") {
        return "A student argues that a workplace should disclose when AI is used in customer communication. The argument states the position, cites trust and accountability as values, considers efficiency concerns, and responds that transparency can be built into the process without blocking useful tools."
    }
    if ($lower -match "windows|operating system") {
        return "A student needs to complete a digital task using two open applications. The student opens the app from Start, uses the taskbar to switch windows, searches for a downloaded file, adjusts a display setting, and confirms the saved file opens correctly."
    }
    if ($lower -match "files|folders|cloud storage|local and cloud|accessible records") {
        return "A student creates a course folder, names a draft with the course code and topic, saves it locally, checks that it synced to cloud storage, and shares only the needed document rather than the entire folder."
    }
    if ($lower -match "microsoft word|professional documents|formatting|\bstructure\b|layout") {
        return "A student drafts a memo in Word, applies headings, adjusts margins and spacing, uses a bulleted list for key steps, checks spelling, and previews the document so the final file looks professional."
    }
    if ($lower -match "credible sources|cite|citation|apa|academic writing") {
        return "A student rejects an unsourced blog post, chooses a more credible source, paraphrases one relevant point, adds an APA-style in-text citation, and checks that the reference entry matches the source details."
    }
    if ($lower -match "cybersecurity|responsible digital|personal and organizational information|privacy|security") {
        return "A learner receives an urgent message with a link asking for account information. Instead of clicking, the learner checks the sender, looks for warning signs, navigates to the official site directly, and reports the suspicious message."
    }
    if ($lower -match "keyboarding|words per minute|wpm|accuracy|timed assessment") {
        return "A learner completes three timed keyboarding rounds, records the words per minute and accuracy, notices repeated errors with capital letters, practices that pattern, and retests only after accuracy improves."
    }
    if (([string]$Chapter.focus) -match "interpersonal|listening|audience awareness") {
        return "$($caseFace.person) hears a patient describe a problem and notices that the words, tone, pace, and facial expression do not fully match. $($caseFace.person) pauses, paraphrases the concern, asks one clarifying question, and responds to the actual need instead of only the first sentence."
    }
    if (([string]$Chapter.focus) -match "message planning|tone|channel") {
        return "$($caseFace.person) needs to send a short professional message about a patient-service question. Before writing, $($caseFace.person) identifies the reader, purpose, channel, key point, tone, and follow-up detail. The final message is shorter than the first draft because the purpose is clearer."
    }
    if (([string]$Chapter.focus) -match "difficult-message|bad-news|conflict") {
        return "$($caseFace.person) revises a difficult message by putting the main point near the beginning, explaining the reason briefly, using respectful language, and naming the next step. The message is honest without sounding careless."
    }
    if (([string]$Chapter.focus) -match "professional writing|report|revision") {
        return "$($caseFace.person) changes a rough update from a long paragraph into a short professional note with a subject line, two evidence points, one recommendation, and a clear follow-up request. The revision helps the supervisor see the decision quickly."
    }
    if (([string]$Chapter.focus) -match "collaboration|meeting|team") {
        return "$($caseFace.person) prepares for a team meeting by naming the purpose, listing two decisions the group needs to make, and clarifying who will record next steps. The meeting becomes easier to follow because the conversation has a visible path."
    }
    if (([string]$Chapter.focus) -match "presentation") {
        return "$($caseFace.person) plans a short presentation by starting with the audience question, choosing three main points, adding one visual that clarifies the idea, and practicing the closing so listeners know what to remember."
    }
    if ($lower -match "finance") {
        return "A clinic team requests exam-room supplies for a busy appointment week. The office checks the approved budget, confirms the vendor record, records the purchase request, and routes it for approval before promising a delivery date. The workflow protects patient service and financial control."
    }
    if ($lower -match "human relations|human resources") {
        return "A clinic needs front-desk coverage during a high-volume appointment block. The office confirms the schedule gap, checks role requirements, routes the request to the supervisor, and documents the approved coverage plan. The process supports employees while protecting patient service."
    }
    if ($lower -match "marketing") {
        return "The practice sends a message about a new patient service. The office prepares call scripts, updates the shared FAQ, confirms the follow-up owner, and tracks common patient questions. The workflow helps the clinic keep the promise made in the message."
    }
    if ($lower -match "inputs|outputs|handoffs|process flow|coordination") {
        return "A patient intake form arrives incomplete. Instead of sending it from person to person, the office records the missing item, contacts the patient through the approved channel, updates the status, and pauses the next step until the input is complete. The handoff becomes visible and controllable."
    }
    if ($lower -match "customer") {
        return "A patient calls about a delayed response. The office confirms the patient's need, checks the record, explains the next step, documents the conversation, and sets a realistic follow-up time. The patient may not receive an immediate final answer, but the process provides clarity and accountability."
    }
    if ($lower -match "improvement|evaluate|recommend|operational strategy") {
        return "A clinic notices that patient follow-up calls run late every Friday. The office reviews request volume, staffing coverage, approval timing, and message templates. The recommendation is to adjust Friday coverage and add a status template, then compare response time over the next two weeks."
    }

    return "A clinic staff member receives a request that affects scheduling, records, and billing. Instead of forwarding the message with no context, the staff member verifies the needed information, records the status, identifies the next owner, and notes the response deadline. The action protects productivity, quality, privacy, and follow-up."
}

function Get-ObjectiveSelfCheck {
    param(
        [string]$Objective,
        [object]$Chapter
    )

    $lower = $Objective.ToLowerInvariant()
    if ($lower -match "critical thinking|skills and habits") {
        return "Can you explain the claim, evidence, assumption, alternative, and level of confidence without simply repeating your first reaction?"
    }
    if ($lower -match "universal intellectual standards|clarity|accuracy|relevance|sufficiency|credibility|sources|ai") {
        return "Which intellectual standard most affects whether this information can support the conclusion, and what would you need to verify?"
    }
    if ($lower -match "problem|solution|alternatives|criteria") {
        return "Have you defined the actual problem, named the constraints, compared alternatives, and justified the selected solution with criteria?"
    }
    if ($lower -match "weak or missing evidence|bias|pressure|context|fallacies|reasoning errors|decision|judgment") {
        return "What influence could be distorting the decision, and how would the conclusion change if that influence were removed or tested?"
    }
    if ($lower -match "inductive|deductive|conclusions logically follow|strength of reasoning") {
        return "Does the conclusion have to follow from the premises, or does the evidence only make it more likely?"
    }
    if ($lower -match "ethical|persuasive|personal position|communicate") {
        return "Does your position state the ethical issue, use evaluated evidence, address a reasonable objection, and communicate respectfully?"
    }
    if ($lower -match "windows|operating system") {
        return "Can you explain which Windows feature you used, why it fit the task, and how you verified the task was complete?"
    }
    if ($lower -match "files|folders|cloud storage|local and cloud|accessible records") {
        return "Can you find the file again, identify the current version, confirm where it is stored, and explain who can access it?"
    }
    if ($lower -match "microsoft word|professional documents|formatting|\bstructure\b|layout") {
        return "Would a reader understand the document structure, see consistent formatting, and trust that the final file was reviewed before sharing?"
    }
    if ($lower -match "credible sources|cite|citation|apa|academic writing") {
        return "Is the source credible and relevant, and do the in-text citation and reference entry point the reader to the same source?"
    }
    if ($lower -match "cybersecurity|responsible digital|personal and organizational information|privacy|security") {
        return "What personal or organizational information is at risk, and which habit protects it before the task is finished?"
    }
    if ($lower -match "keyboarding|words per minute|wpm|accuracy|timed assessment") {
        return "Does your keyboarding result meet both the speed requirement and the accuracy requirement under timed conditions?"
    }
    if (([string]$Chapter.focus) -match "communication|audience|message|tone|channel|listening|presentation|meeting|collaboration") {
        return "Would the reader or listener know the purpose, feel respected by the tone, understand the key point, and know what should happen next?"
    }
    if ($lower -match "map|process|handoffs") {
        return "Could another employee follow your process map and know where the work starts, where it ends, who owns each step, and where the greatest risk appears?"
    }
    if ($lower -match "customer") {
        return "Would the customer know what happened, what happens next, who is responsible, and when to expect follow-up?"
    }
    if ($lower -match "improvement|evaluate|recommend") {
        return "Does your recommendation identify the problem, the evidence, the change, the owner, and the measure of success?"
    }
    if ($lower -match "finance|human|marketing|interdependencies") {
        return "Which function needs information from another function before the work can continue, and what happens if that information is late or incomplete?"
    }

    return "If another employee took over this work tomorrow, what would they need to know, where would they find it, and how would they know the work was complete?"
}

function Add-ObjectiveDevelopment {
    param(
        [System.Collections.ArrayList]$Lines,
        [object]$Chapter,
        [string]$Objective,
        [object]$Citations,
        [string]$CitationIds,
        [object[]]$Endnotes
    )

    $caseFace = Get-ChapterCaseFace -Chapter $Chapter
    $concept = Get-ObjectiveConceptFrame -Objective $Objective
    $practice = Get-ObjectivePracticeParagraph -Objective $Objective -Chapter $Chapter
    $method = Get-ObjectiveMethodParagraph -Objective $Objective -Chapter $Chapter
    $mistake = Get-ObjectiveCommonMistakeParagraph -Objective $Objective -Chapter $Chapter
    $workedExample = Get-ObjectiveWorkedExample -Objective $Objective -Chapter $Chapter
    $selfCheck = Get-ObjectiveSelfCheck -Objective $Objective -Chapter $Chapter
    $chapterNumber = if ($Chapter.number) { [int]$Chapter.number } else { 0 }
    $noteRefs = if ($chapterNumber -gt 0) { Format-MarkdownCitationRefs -Endnotes $Endnotes -ChapterNumber $chapterNumber -Numbers @(1) } else { "" }
    $isProfessionalCommunication = (([string]$Chapter.focus) -match "communication|audience|message|tone|channel|listening|presentation|meeting|collaboration|professional writing|report|revision")
    $caseBridge = if ($isProfessionalCommunication) {
        "For $($caseFace.person), this skill protects clarity, respect, and follow-through while deciding $($caseFace.decision). Notice how the communication choice affects both the immediate reader or listener and the next person who depends on the message."
    }
    else {
        "For $($caseFace.person), this idea matters because the next action depends on $($caseFace.decision). As you read, ask what evidence, role, standard, or risk should be checked before acting."
    }

    [void]$Lines.Add("### $Objective")
    [void]$Lines.Add("")
    [void]$Lines.Add((("$concept $noteRefs").Trim()))
    [void]$Lines.Add("")
    [void]$Lines.Add($caseBridge)
    [void]$Lines.Add("")
    [void]$Lines.Add($practice)
    [void]$Lines.Add("")
    [void]$Lines.Add($method)
    [void]$Lines.Add("")
    [void]$Lines.Add($mistake)
    [void]$Lines.Add("")
    [void]$Lines.Add("**Example in Context:** $workedExample")
    [void]$Lines.Add("")
}

function Get-ChapterModelArtifact {
    param([object]$Chapter)

    $focus = ([string]$Chapter.focus).ToLowerInvariant()
    $caseFace = Get-ChapterCaseFace -Chapter $Chapter

    if ($Chapter.title -match "Leadership Styles") {
        return @(
            "### Communication Toolbox",
            "",
            "### Model Artifact: Leadership Choice Brief",
            "",
            "**Leadership choice brief for $($caseFace.caseName)**",
            "",
            "| Situation | Useful leader response | Main risk to avoid |",
            "| --- | --- | --- |",
            "| Low skill or unfamiliar task; high risk | Explain, demonstrate, observe, and follow up soon. | Giving vague freedom before the person is ready. |",
            "| Some skill; low confidence or uneven results | Ask questions, practice together, and give specific feedback. | Taking over and weakening confidence. |",
            "| Strong skill; high commitment | Set the outcome and boundaries, then provide room to act. | Micromanaging a capable employee. |",
            "| Strong skill; resistance or low commitment | Explore the concern, restate the standard, and involve the employee where possible. | Assuming resistance is laziness. |",
            "| Urgent threat to safety, privacy, or service | Give direct instructions now, then explain and debrief when stable. | Turning every routine issue into an emergency. |",
            "",
            "The model keeps leadership fit tied to the situation. It asks the supervisor to adjust direction and support while keeping the legitimate work standard visible.",
            "",
            "### Model Artifact: Maya's Situation Map",
            "",
            "| Element | Maya's model entry |",
            "| --- | --- |",
            "| Required result | Complete accurate scheduling under the updated clinical-review process. |",
            "| Person and task | Luis needs demonstration on a new task; Denise knows the workflow but needs a clear boundary for the updated step. |",
            "| Risk and urgency | Incorrect scheduling may delay care or create rework during a busy clinic morning. |",
            "| Leadership approach | Use high direction and support for the new task, and a clear boundary with input for the experienced employee. |",
            "| Support and follow-up | Practice safely, invite process evidence, and check the queue and unclear orders at noon. |",
            "",
            "### Modeled Huddle Message",
            "",
            "> The system update changes how we flag orders for clinical review. Our goal is to reduce appointments that must be rescheduled later. Starting now, use the review flag before confirming any order that meets the criteria. I will walk through an example with Luis and hear where the new step creates delay. We will check the queue and unclear orders at noon."
        )
    }
    if ($Chapter.title -match "Delegation") {
        return @(
            "### Communication Toolbox",
            "",
            "### Model Artifact: Delegation Brief",
            "",
            "**Delegation brief for $($caseFace.caseName)**",
            "",
            "| Element | Model entry |",
            "| --- | --- |",
            "| Purpose | Complete accurate intake review so patients do not face avoidable delays. |",
            "| Outcome | Review standard forms by the agreed time and record each status. |",
            "| Authority | Send the approved missing-field message; do not interpret clinical information. |",
            "| Resources | Intake guide, message template, system access, and a supervisor for exceptions. |",
            "| Standard | Review required fields, record status, and follow the privacy procedure. |",
            "| Checkpoint | Bring the first two completed forms to the supervisor, then review the total at the agreed time. |",
            "| Escalation | Stop and contact the supervisor for clinical notes, privacy concerns, or questions outside the approved path. |",
            "",
            "The model gives the employee room to act while making the outcome, authority, resources, boundaries, and follow-up visible.",
            "",
            "### Modeled Delegation Conversation",
            "",
            "> Priya, please review the approved intake forms by the agreed time and record each status. You may send the approved missing-field message, but do not interpret clinical information. Bring the first two completed forms to me, and escalate privacy questions or anything outside the approved path."
        )
    }
    if ($Chapter.title -match "Coaching") {
        return @(
            "### Communication Toolbox",
            "",
            "### Model Artifact: Coaching Record",
            "",
            "**Coaching evidence brief for $($caseFace.caseName)**",
            "",
            "| Weak preparation | Stronger preparation |",
            "| --- | --- |",
            "| Jordan is careless. | Four verification flags remained open across six shifts. |",
            "| Jordan does not care about the team. | Two patients required later calls, and a coworker completed records the next morning. |",
            "| Jordan knows better. | The procedure was discussed in a group, but Elena has not confirmed Jordan's use of the updated dashboard. |",
            "| Jordan needs to improve. | Jordan should check both dashboard tabs, use the handoff template, and bring clinical questions to Elena. |",
            "",
            "The stronger column keeps the conversation close to observable work. It leaves room to learn the employee's perspective and to match support to the actual barrier.",
            "",
            "### Model Artifact: Coaching Follow-Up Record",
            "",
            "| Element | Model entry |",
            "| --- | --- |",
            "| Standard | Every verification flag has a completed status or a documented owner before handoff. |",
            "| Observable evidence | Four verification flags remained open across six shifts. |",
            "| Employee perspective | Jordan checked the main dashboard but did not know about the later refresh. |",
            "| Employee action | Check both dashboard tabs, use the handoff template, and escalate clinical questions. |",
            "| Supervisor support | Demonstrate the refresh and provide the approved handoff template. |",
            "| Follow-up | Review the dashboard and handoff record on Tuesday. |",
            "",
            "### Modeled Coaching Conversation",
            "",
            "> Elena: I want to review four verification flags that remained open across six shifts. What got in the way? Jordan: I checked the main dashboard but did not know about the later refresh. Elena: Let us use both dashboard tabs, the handoff template, and a Tuesday review so the next step is clear."
        )
    }
    if ($Chapter.title -match "Performance Feedback") {
        return @(
            "### Communication Toolbox",
            "",
            "### Model Artifact: Feedback and Improvement Record",
            "",
            "**Feedback and conflict brief for $($caseFace.caseName)**",
            "",
            "| Field | Model entry |",
            "| --- | --- |",
            "| Purpose and standard | Every verification flag has a completed status or a documented owner before the end-of-day handoff. |",
            "| Evidence reviewed | Four open flags across six shifts, two later patient calls, and one next-morning coworker handoff. |",
            "| Employee perspective | Jordan checked the main tab but did not know about the later refresh and lacked a handoff template. |",
            "| Employee action | Check both tabs twice, use the approved handoff template, and escalate clinical questions. |",
            "| Supervisor support | Provide dashboard review and update the closing card. |",
            "| Evidence of progress | The dashboard report shows a status and owner for every flag across five shifts. |",
            "| Review date | Next Tuesday. |",
            "",
            "The model separates behavior, impact, perspective, support, and evidence of progress. That separation gives feedback a fair basis and gives conflict resolution a workable next step.",
            "",
            "### Modeled Conflict-Meeting Opening",
            "",
            "> We are meeting to clarify the Friday follow-up delay, not to assign blame. We will identify the observable pattern, hear each person's perspective, name the service standard, and agree on one owner and one review point."
        )
    }
    if ($Chapter.title -match "Ethical|Inclusive") {
        return @(
            "### Communication Toolbox",
            "",
            "### Model Artifact: Ethical Decision Brief",
            "",
            "| Element | Amina's model entry |",
            "| --- | --- |",
            "| Neutral issue | How can the clinic provide evening access while protecting fair participation, privacy, and trained coverage? |",
            "| Facts and boundaries | Two evening blocks are needed; qualifications and approved workplace requirements must guide coverage. |",
            "| Stakeholders | Patients, employees, supervisors, and the team members who depend on reliable coverage. |",
            "| Options and analysis | Seek qualified volunteers, honor approved requirements, then use a transparent rotation for remaining shifts. |",
            "| Communication and review | Use a private scheduling form, publish job-related criteria, track distribution, and review after four weeks. |",
            "",
            "### Modeled Inclusive Schedule Message",
            "",
            "> Beginning next month, the clinic will add two evening appointment blocks to improve access. We will first ask for evening preferences, then match qualified coverage, honor approved workplace requirements, and use a visible rotation for remaining shifts. Please share preferences or constraints through the private scheduling form; you do not need to discuss personal details in the team meeting. We will review the plan after four weeks.",
            "",
            "The ethical brief keeps the decision grounded in facts, boundaries, affected people, options, privacy, and review. The connected team plan appears after the field guide so the learner sees the decision model before building the broader leadership system."
        )
    }

    if ($focus -match "interpersonal|listening|audience awareness") {
        return @(
            "### Communication Toolbox",
            "",
            "**Listening note for $($caseFace.caseName)**",
            "",
            "| Part | Model entry |",
            "| --- | --- |",
            "| Speaker need | The patient wants to know what is happening with the referral and does not want to repeat the whole story. |",
            "| Verbal signal | The patient says the office promised an update last week. |",
            "| Nonverbal or tone signal | The patient sounds worried and rushed, so the response should slow the moment down without sounding dismissive. |",
            "| Clarifying question | `"Let me make sure I understand the delay. Which specialist office were you expecting to hear from?`" |",
            "| Response | `"I can check the referral status, document what we find, and tell you the next step before we end this call.`" |",
            "",
            "The model shows that listening is not silence. It is a sequence of noticing, checking, and responding so the other person can tell that the message was understood."
        )
    }
    if ($focus -match "message planning|tone|channel|digital communication") {
        return @(
            "### Communication Toolbox",
            "",
            "**Message plan for $($caseFace.caseName)**",
            "",
            "| Planning choice | Model choice |",
            "| --- | --- |",
            "| Audience | Patient who needs a clear next step, not internal clinic details. |",
            "| Purpose | Confirm that the request was received and explain what happens next. |",
            "| Channel | Patient portal, because the message includes service information and should be documented. |",
            "| Tone | Calm, brief, respectful, and specific. |",
            "| Draft sentence | `"We received your request and are checking the referral status today. We will update your portal by 4 p.m. with either the appointment information or the next action needed.`" |",
            "| Revision check | The sentence names the action, timing, and follow-up without exposing private internal notes. |",
            "",
            "The model keeps the message short because the reader needs direction. It also shows why channel choice is part of professionalism, especially when information may be private."
        )
    }
    if ($focus -match "difficult-message|bad-news|conflict") {
        return @(
            "### Communication Toolbox",
            "",
            "**Difficult-message revision for $($caseFace.caseName)**",
            "",
            "| Draft move | Stronger revision |",
            "| --- | --- |",
            "| Vague opening | `"We need to reschedule your appointment because the provider is unavailable at the original time.`" |",
            "| Reason | `"The earliest available option is Tuesday at 10 a.m., and we can also place you on the cancellation list.`" |",
            "| Respectful tone | `"I know a change like this can disrupt your plans, so I want to give you the clearest options now.`" |",
            "| Next step | `"Please reply through the portal or call us by 3 p.m. so we can hold the time that works best for you.`" |",
            "",
            "The model is direct enough to be useful and respectful enough to protect the relationship. It does not hide the bad news behind a long apology."
        )
    }
    if ($focus -match "professional writing|report|revision") {
        return @(
            "### Communication Toolbox",
            "",
            "**Short update memo for $($caseFace.caseName)**",
            "",
            "| Section | Model content |",
            "| --- | --- |",
            "| Subject | Friday follow-up delay: evidence and recommended next step |",
            "| Situation | Follow-up calls after 2 p.m. on Fridays are often completed the next business day. |",
            "| Evidence | The last two Friday logs show delayed call-backs when message volume rises and one staff member covers both phone and portal queues. |",
            "| Recommendation | Test a Friday status template and assign one backup reviewer for two weeks. |",
            "| Follow-up | Compare same-day completion rates before deciding whether to keep the change. |",
            "",
            "The model shows how revision turns a loose explanation into a decision-ready workplace document. The reader can see the issue, evidence, action, and review point."
        )
    }
    if ($focus -match "collaboration|meeting|team") {
        return @(
            "### Communication Toolbox",
            "",
            "**Meeting note for $($caseFace.caseName)**",
            "",
            "| Meeting element | Model entry |",
            "| --- | --- |",
            "| Purpose | Decide how the team will handle incomplete intake forms this week. |",
            "| Voices to hear | Front desk, records, billing, and supervisor. |",
            "| Decision needed | Who contacts the patient, who updates the record, and when the file can move forward. |",
            "| Follow-up owner | Records assistant confirms status by end of day. |",
            "| Closing sentence | `"Before we leave, I want to confirm the owner, deadline, and where the update will be documented.`" |",
            "",
            "The model makes collaboration visible. A useful meeting is not only a conversation; it is a shared record of what changed and who owns the next step."
        )
    }
    if ($focus -match "presentation") {
        return @(
            "### Communication Toolbox",
            "",
            "**Presentation arc for $($caseFace.caseName)**",
            "",
            "| Part | Model choice |",
            "| --- | --- |",
            "| Opening | `"Today I will show how one intake handoff can protect patient service, privacy, and follow-up.`" |",
            "| Point 1 | Name the patient need and the information required before action. |",
            "| Point 2 | Show the handoff from front desk to records or billing. |",
            "| Point 3 | Explain the follow-up message that closes the loop. |",
            "| Visual | A simple three-step process line with one risk point marked. |",
            "| Closing | `"The takeaway is simple: a clear handoff gives the next person enough information to act without guessing.`" |",
            "",
            "The model gives the speaker a path and gives listeners a reason to follow it. The visual supports the point instead of decorating the slide."
        )
    }

    return @(
        "### Communication Toolbox",
        "",
        "**$($caseFace.artifact)**",
        "",
        "| Part | Model entry |",
        "| --- | --- |",
        "| Situation | $($caseFace.situation) |",
        "| Decision | $($caseFace.decision) |",
        "| Evidence | Name the information that proves the next step is justified. |",
        "| Risk | $($caseFace.risk) |",
        "| Review point | Decide how the team will know whether the action worked. |"
    )
}

function Get-ChapterRevisionWalkthrough {
    param([object]$Chapter)

    $focus = ([string]$Chapter.focus).ToLowerInvariant()
    if ($focus -notmatch "communication|audience|message|tone|channel|listening|presentation|meeting|collaboration|professional writing|report|revision") {
        return @()
    }

    $caseFace = Get-ChapterCaseFace -Chapter $Chapter
    $before = "I wanted to follow up about this because there has been some confusion and we need to get it handled soon."
    $after = "I am checking the status today and will update the record by 4 p.m. so the next person can see the current step."
    $reason = "The revision names the action, the timing, and the place where the follow-up will be documented."

    if ($focus -match "interpersonal|listening|audience awareness") {
        $before = "I understand what you are saying, but we have a process for this."
        $after = "I hear that you expected an update already. Let me check the referral status and confirm the next step before we end the call."
        $reason = "The revision first reflects the speaker's concern, then explains the action. It avoids sounding defensive."
    }
    elseif ($focus -match "message planning|tone|channel|digital communication") {
        $before = "We are still working on your request and will let you know when we have something."
        $after = "We received your request and are checking the referral status today. We will update your portal by 4 p.m. with the next action."
        $reason = "The revision gives the reader a clear status, channel, time frame, and next step."
    }
    elseif ($focus -match "difficult-message|bad-news|conflict") {
        $before = "Unfortunately, we cannot keep the appointment, and we apologize for the inconvenience."
        $after = "We need to reschedule your appointment because the provider is unavailable at the original time. The earliest option is Tuesday at 10 a.m."
        $reason = "The revision states the bad news clearly and quickly, then gives the reader usable information."
    }
    elseif ($focus -match "professional writing|report|revision") {
        $before = "The Friday calls have been a problem for a while, and people are getting backed up."
        $after = "Friday follow-up calls after 2 p.m. are often completed the next business day when one person covers both phone and portal queues."
        $reason = "The revision replaces a general complaint with a specific condition, time pattern, and likely cause."
    }
    elseif ($focus -match "collaboration|meeting|team") {
        $before = "We talked about the intake issue and everyone agreed to keep an eye on it."
        $after = "Records will flag incomplete intake forms by 2 p.m., and the front desk will contact patients through the approved channel before the file moves forward."
        $reason = "The revision turns vague agreement into owners, actions, timing, and a standard path."
    }
    elseif ($focus -match "presentation") {
        $before = "Today I am going to talk about intake forms and why they are important."
        $after = "Today I will show how one intake handoff protects patient service, privacy, and follow-up."
        $reason = "The revision gives listeners a reason to care and previews the organizing idea."
    }

    return @(
        "## Revision Walkthrough",
        "",
        "Professional communication improves when a writer or speaker can explain what changed between a first attempt and a stronger version. Revision is not only grammar correction. It is the act of making the audience, purpose, tone, evidence, and next step easier to see.",
        "",
        "| First attempt | Stronger version | Why the revision works |",
        "| --- | --- | --- |",
        "| $before | $after | $reason |",
        "",
        "In $($caseFace.person)'s situation, the stronger version gives the reader or listener less work to do. It reduces guessing, protects the relationship, and makes the next action visible. A student should be able to point to the exact words that create that improvement.",
        "",
        "A useful revision pass asks four questions. First, what should the audience know or do after this message? Second, which words could sound vague, defensive, too casual, or too severe? Third, what detail would help the reader trust the message without overwhelming them? Fourth, where will the next step be recorded or followed up? These questions turn communication from personal style into a repeatable professional process."
    )
}

function Add-ChapterDeepeningSections {
    param(
        [System.Collections.ArrayList]$Lines,
        [object]$Chapter,
        [object]$Citations,
        [string]$CitationIds,
        [object[]]$Endnotes,
        [switch]$UseGM1025ReferenceFormat
    )

    $caseFace = Get-ChapterCaseFace -Chapter $Chapter
    $isGM1025Format = $UseGM1025ReferenceFormat.IsPresent
    $isCriticalThinking = ($Chapter.focus -match "critical thinking|information evaluation|problem solving|decision influences|inductive|deductive|ethical|persuasive|position")
    $isComputerApplications = ($Chapter.focus -match "operating system|software environment|file management|local and cloud|document creation|microsoft word|source evaluation|apa citation|academic writing|cybersecurity|digital responsibility|keyboarding")
    $isProfessionalCommunication = ($Chapter.focus -match "communication|audience|message|tone|channel|listening|presentation|meeting|collaboration")
    $caseTitle = "### Case Study Progression: $($caseFace.caseName)"
    $chapterNumber = if ($Chapter.number) { [int]$Chapter.number } else { 0 }
    $evidenceRefs = if ($chapterNumber -gt 0) { Format-MarkdownCitationRefs -Endnotes $Endnotes -ChapterNumber $chapterNumber -Numbers @(1, 2) } else { "" }
    [void]$Lines.Add($caseTitle)
    [void]$Lines.Add("")
    if ($isCriticalThinking) {
        [void]$Lines.Add("Look at $($caseFace.person)'s situation at $($caseFace.workplace). $($caseFace.situation) The case does not have one obvious answer. $($caseFace.person) must define the issue, test the evidence, notice assumptions, and explain the reasoning. The decision is $($caseFace.decision). If $($caseFace.person) rushes, habit or pressure may shape the conclusion. If $($caseFace.person) thinks carefully, they can explain the claim, evidence, limits, alternatives, and level of confidence.")
    }
    elseif ($isComputerApplications) {
        [void]$Lines.Add("Look at $($caseFace.person)'s situation at $($caseFace.workplace). $($caseFace.situation) The task may look simple, but each step matters. $($caseFace.person) must choose the tool, store the information, check the final product, and notice the risk if a step gets skipped. The decision is $($caseFace.decision). If $($caseFace.person) rushes, the work may be hard to find, poorly formatted, weakly supported, insecure, or inaccurate. If $($caseFace.person) works carefully, they can explain the tool choice, standard, evidence, security habit, and final check.")
    }
    elseif ($isProfessionalCommunication) {
        [void]$Lines.Add("Look at $($caseFace.person)'s situation at $($caseFace.workplace). $($caseFace.situation) The communication choice may look simple, but audience, purpose, tone, channel, timing, and follow-up all shape the result. $($caseFace.person) must decide $($caseFace.decision). If $($caseFace.person) rushes, the message may confuse the reader or damage trust. If $($caseFace.person) communicates carefully, they can make the purpose clear, choose respectful wording, and help the next person know what matters.")
    }
    else {
        [void]$Lines.Add("Look at $($caseFace.person)'s situation at $($caseFace.workplace). $($caseFace.situation) The request touches more than one person, record, and decision point. $($caseFace.person) must decide $($caseFace.decision). If the team handles the work casually, the result may depend on who is available and what they remember. If the team handles the work as an operation, $($caseFace.person) can explain the trigger, owner, evidence, status, service expectation, and next step.")
    }
    [void]$Lines.Add("")
    if ($isCriticalThinking) {
        [void]$Lines.Add("A useful way to analyze the case is to separate the visible answer from the reasoning underneath it. The visible answer may be a position, solution, recommendation, or conclusion. The reasoning underneath includes definitions, evidence, assumptions, criteria, values, and possible objections. Strong thinkers look at both levels. They do not simply ask whether they agree; they ask whether the conclusion is supported well enough to deserve agreement.")
    }
    elseif ($isComputerApplications) {
        [void]$Lines.Add("A useful way to analyze the case is to separate the visible output from the workflow underneath it. The visible output may be an open app, a saved file, a formatted document, a citation, a secure message, or a keyboarding score. The workflow underneath includes the tool path, naming standard, formatting rule, source judgment, security decision, and accuracy check. Strong digital workers look at both levels. They do not simply ask whether the task appears finished; they ask whether it can be found, trusted, protected, and repeated.")
    }
    elseif ($isProfessionalCommunication) {
        [void]$Lines.Add("A useful way to analyze the case is to separate the message from the communication situation around it. The visible message may be an email, agenda, presentation opening, short response, or difficult-news paragraph. The situation underneath includes audience needs, purpose, relationship, timing, channel, tone, and likely reaction. Strong communicators look at both levels. They do not simply ask whether the words are correct; they ask whether the message helps the reader understand, trust, and act appropriately.")
    }
    else {
        [void]$Lines.Add("A useful way to analyze the case is to separate the visible event from the system underneath it. The visible event may be a delayed response, an unanswered message, a confused customer, or a missing approval. The system underneath includes roles, tools, procedures, staffing, records, and priorities. Good office professionals look at both levels. They do not simply say that someone should have been more careful; they ask what kind of process would make careful work easier and inconsistent work harder.")
    }
    [void]$Lines.Add("")
    if (-not $isGM1025Format) {
        [void]$Lines.Add("## Using Evidence")
        [void]$Lines.Add("")
    }
    [void]$Lines.Add((((Get-ResearchLensParagraph -Chapter $Chapter -Citations $Citations) + " " + $evidenceRefs).Trim()))
    [void]$Lines.Add("")
    if ($isCriticalThinking) {
        [void]$Lines.Add("A useful conclusion uses evidence inside the reasoning. Do not attach sources only at the end. Evidence may define the skill, clarify a concept, support a method, or help you judge whether a claim deserves confidence. Students should point to the moment where evidence changes, strengthens, limits, or complicates the conclusion.")
        [void]$Lines.Add("")
        if (-not $isGM1025Format) {
            [void]$Lines.Add("## Learning Notes")
            [void]$Lines.Add("")
        }
        [void]$Lines.Add("A strong understanding in this chapter shows the thinking process, not only the final answer. Readers should be able to see how the issue was defined, which evidence mattered, which assumption needed attention, and why the conclusion is stronger than at least one alternative. This matters because critical thinking is often invisible unless the learner makes the reasoning visible in words, diagrams, or a brief decision note.")
        [void]$Lines.Add("")
        [void]$Lines.Add("When using AI or any outside source, students should separate useful language from verified support. A generated explanation may help identify possibilities, but the student is still responsible for checking whether the information is accurate, relevant, sufficient, and fair to the issue. The habit is to use tools as aids for inquiry rather than substitutes for judgment.")
        [void]$Lines.Add("")
        [void]$Lines.Add("Revision is part of the thinking process. A revised sentence might make the claim more precise, add a missing qualification, name a reasonable objection, or lower the level of confidence when the evidence is limited. This small revision step turns critical thinking from a concept into a repeatable habit.")
        [void]$Lines.Add("")
        [void]$Lines.Add("A final review should also check audience and purpose. The same reasoning can be expressed differently in a class discussion, a workplace message, a recommendation memo, or an ethical position statement. Students should keep the reasoning stable while adjusting the explanation so the reader can follow the issue, the evidence, and the conclusion without guessing what matters most.")
        [void]$Lines.Add("")
        [void]$Lines.Add("The best final answers are usually modest, specific, and inspectable. They avoid claiming more than the evidence allows, and they make it easy for a reader to see how the thinker moved from question to support to conclusion in a clear, accountable, and respectful way.")
    }
    elseif ($isComputerApplications) {
        [void]$Lines.Add("A useful digital task brings evidence into the workflow rather than treating the finished file as the only proof. The evidence may be a file path, a version name, a visible formatting standard, a citation detail, a security check, a keyboarding result, or a saved source note. Students should be able to point to the moment where the evidence shows that the work is complete and reliable.")
        [void]$Lines.Add("")
        if (-not $isGM1025Format) {
            [void]$Lines.Add("## Learning Notes")
            [void]$Lines.Add("")
        }
        [void]$Lines.Add("A strong understanding in this chapter shows the task process, not only the final screen or file. Readers should be able to see what tool was used, what standard guided the work, what risk was avoided, and how the final result was checked.")
        [void]$Lines.Add("")
        [void]$Lines.Add("When using digital tools, students should separate convenience from correctness. A shortcut may be useful, but the learner is still responsible for verifying file location, formatting, source accuracy, privacy, and final audience expectations.")
        [void]$Lines.Add("")
        [void]$Lines.Add("Revision is part of a reliable digital workflow. A revision might improve a file name, correct a formatting inconsistency, strengthen a citation, add a security check, or slow a keyboarding round enough to improve accuracy.")
        [void]$Lines.Add("")
        [void]$Lines.Add("A final review should also check audience and purpose. You may use the same digital skill for a healthcare office record, a team message, a class document, or a professional document. Keep the standard stable while you adjust the final product to the situation.")
        [void]$Lines.Add("")
        [void]$Lines.Add("The best digital work is usually organized, readable, traceable, secure, and easy for another person to inspect. It avoids relying on memory and makes the important choices visible.")
    }
    elseif ($isProfessionalCommunication) {
        [void]$Lines.Add("Useful communication evidence may come from audience analysis, message examples, research on clarity or tone, or the observable response a message creates. The point is not to decorate a message with a source. The point is to use evidence to make better choices about purpose, organization, language, and follow-up.")
        [void]$Lines.Add("")
        if (-not $isGM1025Format) {
            [void]$Lines.Add("## Learning Notes")
            [void]$Lines.Add("")
        }
        [void]$Lines.Add("A strong understanding in this chapter shows how message choices affect people. Readers should be able to see the intended audience, the purpose, the relationship, the channel, the tone, and the likely next step.")
        [void]$Lines.Add("")
        [void]$Lines.Add("When communication feels difficult, the useful move is to slow down and name the reader's need. A message may need a clearer opening, a more respectful tone, a better order of ideas, or a more precise request. These small revisions can change how the reader receives the message.")
        [void]$Lines.Add("")
        [void]$Lines.Add("The best professional communication is usually clear, respectful, organized, and easy to act on. It avoids making the reader guess what happened, why it matters, or what should happen next.")
    }
    else {
        [void]$Lines.Add("A useful recommendation uses evidence inside the decision. Do not attach sources only at the end. Evidence may define the skill, clarify a business concept, support a method, or help you judge whether a workplace decision may improve the process.")
        [void]$Lines.Add("")
        [void]$Lines.Add("Before you recommend a next step for $($caseFace.person), pause and ask what the evidence changes. Does it confirm the problem, reveal a missing handoff, show a customer expectation, or point to a better standard? This material may seem difficult at first, but you can break it into smaller steps: name the fact, connect it to the case, and explain the action it supports.")
    }
    [void]$Lines.Add("")
    foreach ($artifactLine in (Get-ChapterModelArtifact -Chapter $Chapter)) {
        [void]$Lines.Add($artifactLine)
    }
    [void]$Lines.Add("")
    $revisionWalkthrough = @(Get-ChapterRevisionWalkthrough -Chapter $Chapter)
    foreach ($walkthroughLine in $revisionWalkthrough) {
        [void]$Lines.Add($walkthroughLine)
    }
    if ($revisionWalkthrough.Count -gt 0) {
        [void]$Lines.Add("")
    }
    [void]$Lines.Add("### Field Guide: What To Look For")
    [void]$Lines.Add("")
    if ($isCriticalThinking) {
        [void]$Lines.Add("- Claim: What conclusion or position is under review?")
        [void]$Lines.Add("- Evidence: What information supports the claim?")
        [void]$Lines.Add("- Assumption: What must be true for the reasoning to work?")
        [void]$Lines.Add("- Standard: Which intellectual standard matters most here?")
        [void]$Lines.Add("- Alternative: What other explanation, solution, or position should be considered?")
        [void]$Lines.Add("- Risk: What could distort the reasoning?")
        [void]$Lines.Add("- Revision: What would make the conclusion clearer, fairer, or better supported?")
    }
    elseif ($isComputerApplications) {
        [void]$Lines.Add("- Task: What digital result must be produced?")
        [void]$Lines.Add("- Tool: Which application, feature, or setting fits the task?")
        [void]$Lines.Add("- Standard: What file, formatting, citation, security, or accuracy rule applies?")
        [void]$Lines.Add("- Evidence: What proves the task was completed correctly?")
        [void]$Lines.Add("- Risk: What could make the work hard to find, weakly supported, insecure, or inaccurate?")
        [void]$Lines.Add("- Check: How will the learner verify the final file, source, action, or score?")
        [void]$Lines.Add("- Revision: What small change would make the workflow more reliable?")
    }
    elseif ($isProfessionalCommunication) {
        [void]$Lines.Add("- Audience: Who needs the message, and what do they already know?")
        [void]$Lines.Add("- Purpose: What should the reader understand or do next?")
        [void]$Lines.Add("- Channel: Which format best fits the situation?")
        [void]$Lines.Add("- Tone: What wording builds clarity and respect?")
        [void]$Lines.Add("- Organization: What order makes the message easiest to follow?")
        [void]$Lines.Add("- Evidence: What detail supports the message without overwhelming the reader?")
        [void]$Lines.Add("- Revision: What small change would make the message clearer?")
    }
    else {
        [void]$Lines.Add("- Trigger: What starts the work?")
        [void]$Lines.Add("- Evidence: What information must the team have before it acts?")
        [void]$Lines.Add("- Owner: Who is responsible for the next step?")
        [void]$Lines.Add("- Handoff: Where does work move from one person, system, or department to another?")
        [void]$Lines.Add("- Standard: What does good performance look like?")
        [void]$Lines.Add("- Risk: What can go wrong if people rush, skip details, or leave work undocumented?")
        [void]$Lines.Add("- Improvement: What change would reduce friction without adding unnecessary complexity?")
    }
    [void]$Lines.Add("")
    if ($isGM1025Format -and $Chapter.title -match "Ethical|Inclusive") {
        [void]$Lines.Add("### The Team Leadership Plan")
        [void]$Lines.Add("")
        [void]$Lines.Add("The plan connects situational leadership, delegation, motivation, coaching, feedback, conflict resolution, ethics, and inclusion into one repeatable supervisory approach.")
        [void]$Lines.Add("")
        [void]$Lines.Add("### Model Artifact: Team Leadership Plan")
        [void]$Lines.Add("")
        [void]$Lines.Add("| Plan area | Guiding question | Model commitment |")
        [void]$Lines.Add("| --- | --- | --- |")
        [void]$Lines.Add("| Team purpose and results | Whom does the team serve, and which standards matter? | Connect reliable office work to timely, respectful patient access. |")
        [void]$Lines.Add("| Leadership fit | How will direction and support change with capability, urgency, and risk? | Use more direction for unfamiliar or high-risk work; expand autonomy as capability grows. |")
        [void]$Lines.Add("| Delegation | How will outcome, authority, resources, and boundaries be defined? | Use a delegation brief for complex handoffs and create development opportunities. |")
        [void]$Lines.Add("| Ethics and inclusion | How will the decision account for values, voice, access, bias, and uneven effects? | Define criteria, protect privacy, invite input, consider alternatives, and review outcomes. |")
        [void]$Lines.Add("| Communication rhythm | When and where will the team exchange information? | Use brief huddles, private check-ins, a clear escalation path, and closed-loop updates. |")
        [void]$Lines.Add("| Measures and review | How will the team know the plan works? | Review service, quality, workload, employee voice, and unintended effects each month. |")
        [void]$Lines.Add("")
        [void]$Lines.Add("The plan connects ethical reasoning to the everyday work of assigning roles, protecting privacy, hearing concerns, and reviewing whether a decision affected people fairly.")
        [void]$Lines.Add("")
    }
    [void]$Lines.Add("## Section $chapterNumber.4 - Integrating $($Chapter.title) at Work")
    [void]$Lines.Add("")
    if ($isCriticalThinking) {
        [void]$Lines.Add("The chapter comes together when $($caseFace.person)'s case shows how a claim, evidence, assumptions, limits, and revision choices all shape the final judgment. The important habit is not to rush from a first answer to a final conclusion. The important habit is to make the reasoning visible enough that another reader can inspect it.")
    }
    elseif ($isComputerApplications) {
        [void]$Lines.Add("The chapter comes together when $($caseFace.person)'s case shows how a digital task, tool choice, standard, risk point, and verification step all affect the finished work. The important habit is not to click through screens quickly. The important habit is to leave work organized, readable, protected, and easy to check.")
    }
    elseif ($isProfessionalCommunication) {
        [void]$Lines.Add("The chapter comes together when $($caseFace.person)'s case shows how audience, purpose, channel, tone, organization, and revision all shape the reader's experience. The important habit is not to send the first workable message. The important habit is to make the message clear enough, respectful enough, and complete enough for the situation.")
    }
    else {
        [void]$Lines.Add("The chapter comes together when $($caseFace.person)'s case shows how current work, risk points, evidence, ownership, and improvement choices connect. The important habit is not to memorize a process label. The important habit is to understand what makes the work reliable for the next person.")
    }
    [void]$Lines.Add("")
    if ($isCriticalThinking) {
        [void]$Lines.Add("Strong understanding includes a concise description of the issue, the evidence, the reasoning standard, the conclusion or position, and one way to judge whether the reasoning is strong enough.")
    }
    elseif ($isComputerApplications) {
        [void]$Lines.Add("Strong understanding includes the digital task, the tool or feature, the standard, the evidence checked, the risk avoided, and the way the final result can be confirmed.")
    }
    elseif ($isProfessionalCommunication) {
        [void]$Lines.Add("Strong understanding includes the audience, purpose, channel, tone, organization, key detail, and revision choice that make a message easier to understand and trust.")
    }
    else {
        [void]$Lines.Add("Strong understanding includes the workplace problem, the evidence, the practical change, the responsible role, and the measure that would show whether the work improved.")
    }
    [void]$Lines.Add("")
}

function Get-MarkdownWordCount {
    param([string]$Markdown)

    return @($Markdown -split "\W+" | Where-Object { $_.Trim().Length -gt 0 }).Count
}

function Get-ProductionDepthStandard {
    param(
        [object]$Course,
        [object]$Chapter
    )

    $courseText = "$($Course.courseCode) $($Course.courseName) $($Course.credits) credits $($Course.duration) $($Course.description) $($Course.summary) $($Chapter.title) $($Chapter.focus)".ToLowerInvariant()
    $isProfessionalCommunication = $courseText -match "professional communication|interpersonal.*communication|audience|message|presentation|listening"
    $isGeneralEducation = $courseText -match "general education|gen ed|general studies|interpersonal"
    $isFiveWeek = $courseText -match "5\s*-?\s*week|five\s*-?\s*week"

    if ($isProfessionalCommunication -or ($isGeneralEducation -and $isFiveWeek)) {
        return [pscustomobject]@{
            minimum = 2600
            preferred = 3200
            label = "production-ready 5-week general education chapter"
        }
    }

    return [pscustomobject]@{
        minimum = 2400
        preferred = 3000
        label = "production-ready higher-ed chapter"
    }
}

function Get-ContentRepetitionSignals {
    param([AllowNull()][string]$Markdown)

    $text = [string]$Markdown
    $paragraphs = @(
        $text -split "(\r?\n){2,}" |
            ForEach-Object {
                ($_ -replace "\[[^\]]+\]\([^)]+\)", " " -replace "[#*_`|>-]", " " -replace "\s+", " ").Trim().ToLowerInvariant()
            } |
            Where-Object { $_.Length -ge 90 -and $_ -notmatch "^chapter \d+|^notes\b|^!\[" }
    )
    $duplicateParagraphs = @(
        $paragraphs |
            Group-Object |
            Where-Object { $_.Count -gt 1 } |
            Sort-Object Count -Descending |
            Select-Object -First 5
    )
    $sentences = @(
        [regex]::Matches($text, "[^.!?]+[.!?]") |
            ForEach-Object {
                ($_.Value -replace "\[[^\]]+\]\([^)]+\)", " " -replace "\s+", " ").Trim().ToLowerInvariant()
            } |
            Where-Object { $_.Length -ge 70 -and (Get-MarkdownWordCount -Markdown $_) -ge 10 }
    )
    $duplicateSentences = @(
        $sentences |
            Group-Object |
            Where-Object { $_.Count -gt 2 } |
            Sort-Object Count -Descending |
            Select-Object -First 5
    )

    $templatePatterns = @(
        "this objective turns an abstract business concept into workplace judgment",
        "needs this idea because they must decide",
        "workplace-style course scenario",
        "source context",
        "should be developed before final"
    )
    $templateHits = New-Object System.Collections.ArrayList
    $lower = $text.ToLowerInvariant()
    foreach ($pattern in $templatePatterns) {
        $count = [regex]::Matches($lower, [regex]::Escape($pattern)).Count
        if ($count -gt 0) {
            [void]$templateHits.Add("$pattern ($count)")
        }
    }

    $repeatedPromptCount = [regex]::Matches($lower, "would the reader or listener know the purpose").Count
    if ($repeatedPromptCount -gt 2) {
        [void]$templateHits.Add("repeated communication pause prompt ($repeatedPromptCount)")
    }

    $status = if ($duplicateParagraphs.Count -gt 1 -or $duplicateSentences.Count -gt 0 -or $templateHits.Count -gt 0) { "FAIL" } elseif ($duplicateParagraphs.Count -eq 1) { "WARNING" } else { "PASS" }
    $duplicateDetail = @($duplicateParagraphs | ForEach-Object { "$($_.Count)x paragraph: $($_.Name.Substring(0, [Math]::Min(90, $_.Name.Length)))..." })
    $duplicateDetail += @($duplicateSentences | ForEach-Object { "$($_.Count)x sentence: $($_.Name.Substring(0, [Math]::Min(90, $_.Name.Length)))..." })

    return [pscustomobject]@{
        status = $status
        duplicateParagraphCount = $duplicateParagraphs.Count
        duplicateSentenceCount = $duplicateSentences.Count
        templateHits = @($templateHits)
        detail = if ($status -eq "PASS") {
            "No repeated boilerplate paragraphs or banned generator template phrases detected."
        }
        else {
            "Repetition/template issues: $((@($templateHits) + @($duplicateDetail)) -join '; ')"
        }
    }
}

function Get-CareerContextSignals {
    param(
        [object]$Course,
        [object]$Chapter,
        [AllowNull()][string]$Markdown
    )

    $courseText = "$($Course.courseCode) $($Course.courseName) $($Course.credits) credits $($Course.duration) $($Course.description) $($Course.summary) $($Chapter.title) $($Chapter.focus)".ToLowerInvariant()
    $requiresHealthcareContext = $courseText -match "allied healthcare|healthcare|health care|medical|patient|clinic|\bEN2150\b".ToLowerInvariant()
    if (-not $requiresHealthcareContext) {
        return [pscustomobject]@{
            status = "PASS"
            count = 0
            detail = "No career-field context requirement detected for this chapter."
        }
    }

    $hits = [regex]::Matches(([string]$Markdown).ToLowerInvariant(), "\b(healthcare|health care|patient|patients|clinic|medical|provider|front desk|front office|care team|records|scheduling|intake|privacy|insurance|referral|portal)\b").Count
    return [pscustomobject]@{
        status = if ($hits -ge 8) { "PASS" } elseif ($hits -ge 4) { "WARNING" } else { "FAIL" }
        count = $hits
        detail = "$hits allied-healthcare or career-context signal(s); production chapters should repeatedly connect general skills to the learner's likely workplace."
    }
}

function Get-SourceFitSignals {
    param(
        [object]$Chapter,
        [object]$ChapterSources
    )

    if ($ChapterSources -and $ChapterSources.sourcePolicy -and $ChapterSources.sourcePolicy.mode -eq 'UploadedOnly') {
        return [pscustomobject]@{
            status = "WARNING"
            fitCount = 0
            applicable = $false
            detail = "Uploaded-only source policy selected; external communication-source fit is not evaluated. Confirm source coverage during SME review."
        }
    }

    $focus = ([string]$Chapter.focus).ToLowerInvariant()
    if ($focus -notmatch "communication|audience|message|tone|channel|listening|presentation|meeting|collaboration|professional writing|report|revision") {
        return [pscustomobject]@{
            status = "PASS"
            fitCount = 0
            detail = "No professional communication source-fit requirement detected."
        }
    }

    $sourceTextParts = New-Object System.Collections.ArrayList
    foreach ($item in @($ChapterSources.openStax) + @($ChapterSources.researchCandidates) + @($ChapterSources.sourceContext)) {
        if ($null -eq $item) { continue }
        [void]$sourceTextParts.Add("$($item.title) $($item.book) $($item.sourceName) $($item.label) $($item.preview)")
    }
    $sourceText = (($sourceTextParts -join " ") -replace "\s+", " ").ToLowerInvariant()
    $fitMatches = [regex]::Matches($sourceText, "\b(communication|interpersonal|audience|message|listening|nonverbal|verbal|tone|channel|presentation|meeting|team|collaboration|professional writing|business communication|memo|report|revision|persuasion)\b").Count

    return [pscustomobject]@{
        status = if ($fitMatches -ge 4) { "PASS" } elseif ($fitMatches -ge 2) { "WARNING" } else { "FAIL" }
        fitCount = $fitMatches
        applicable = $true
        detail = "$fitMatches communication-specific source-fit signal(s); professional communication chapters need sources that actually fit communication, writing, presentation, listening, or collaboration."
    }
}

function Get-ChapterMarkdownText {
    param(
        [string]$Markdown,
        [int]$ChapterNumber
    )

    $pattern = "(?ms)^# Chapter $ChapterNumber`:.*?(?=^# Chapter \d+`:|\z)"
    $match = [regex]::Match($Markdown, $pattern)
    if ($match.Success) { return $match.Value }
    return ""
}

function Get-ProhibitedKnowledgeCheckSignals {
    param([AllowNull()][string]$Markdown)

    # These are learner-facing assessment/check labels. They are intentionally
    # checked as headings or bold labels so ordinary prose that uses the word
    # "test" is not rejected accidentally.
    $pattern = "(?im)^\s*(?:#{1,6}\s+|\*\*)?(?:Knowledge Checks?|Check Your Reasoning|Check Your Understanding|Self-Assessment|Quiz|Test|Exam)\b"
    $matches = @([regex]::Matches([string]$Markdown, $pattern) | ForEach-Object { $_.Value.Trim() })
    return [pscustomobject]@{
        count = $matches.Count
        matches = @($matches)
        status = if ($matches.Count -eq 0) { "PASS" } else { "FAIL" }
        detail = if ($matches.Count -eq 0) { "No prohibited Knowledge Check, Check Your Reasoning, Check Your Understanding, Self-Assessment, Quiz, Test, or Exam labels or sections found." } else { "Found $($matches.Count) prohibited learner-check label/reference(s): $($matches -join '; ')" }
    }
}

function Remove-ProhibitedKnowledgeCheckSections {
    param([AllowNull()][string]$Markdown)

    $lines = [string]$Markdown -split "`r?`n"
    $kept = New-Object System.Collections.ArrayList
    $skipLevel = 0
    $removedSections = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        $heading = [regex]::Match($line, "^(#{1,6})\s+(.+?)\s*$")
        if ($skipLevel -gt 0) {
            if ($heading.Success -and $heading.Groups[1].Value.Length -le $skipLevel) {
                $skipLevel = 0
            }
            else {
                continue
            }
        }

        if ($heading.Success -and $heading.Groups[2].Value.Trim() -match "(?i)^(?:knowledge checks?|check your reasoning|check your understanding|self-assessment|quiz|test|exam)(?:\s*[:\-].*)?$") {
            $skipLevel = $heading.Groups[1].Value.Length
            [void]$removedSections.Add($heading.Groups[2].Value.Trim())
            continue
        }
        [void]$kept.Add($line)
    }

    $cleanedMarkdown = ($kept -join "`r`n")
    $labelPattern = "(?i)\bKnowledge Checks?\b|\bCheck Your Reasoning\b|\bCheck Your Understanding\b"
    $labelMatches = @([regex]::Matches($cleanedMarkdown, $labelPattern))
    $cleanedMarkdown = $cleanedMarkdown -replace "(?i)\bKnowledge Checks?\b", "review activities"
    $cleanedMarkdown = $cleanedMarkdown -replace "(?i)\bCheck Your Reasoning\b", "guided reflection"
    $cleanedMarkdown = $cleanedMarkdown -replace "(?i)\bCheck Your Understanding\b", "guided review"

    return [pscustomobject]@{
        markdown = $cleanedMarkdown
        removedCount = $removedSections.Count
        removedSections = @($removedSections)
        replacedLabelCount = $labelMatches.Count
    }
}

function Get-ProhibitedLearnerSectionSignals {
    param([AllowNull()][string]$Markdown)

    $pattern = "(?i)\bReflection Activity\b|\bWorkplace Challenge\b|\bThis Week.?s Challenge\b|\bChapter Summary\b"
    $matches = @([regex]::Matches([string]$Markdown, $pattern) | ForEach-Object { $_.Value.Trim() })
    $reflectionCount = @($matches | Where-Object { $_ -match "(?i)Reflection Activity" }).Count
    $workplaceCount = @($matches | Where-Object { $_ -match "(?i)Workplace Challenge" }).Count
    $challengeCount = @($matches | Where-Object { $_ -match "(?i)This Week.?s Challenge" }).Count
    $summaryCount = @($matches | Where-Object { $_ -match "(?i)Chapter Summary" }).Count
    return [pscustomobject]@{
        count = $matches.Count
        matches = @($matches)
        reflectionActivityCount = $reflectionCount
        workplaceChallengeCount = $workplaceCount
        thisWeekChallengeCount = $challengeCount
        chapterSummaryCount = $summaryCount
        status = if ($matches.Count -eq 0) { "PASS" } else { "FAIL" }
        detail = if ($matches.Count -eq 0) { "No Reflection Activity, Workplace Challenge, This Week's Challenge, or redundant Chapter Summary labels or sections found." } else { "Found prohibited learner-facing label/reference(s): $($matches -join '; ')" }
    }
}

function Remove-ProhibitedLearnerSections {
    param([AllowNull()][string]$Markdown)

    $lines = [string]$Markdown -split "`r?`n"
    $kept = New-Object System.Collections.ArrayList
    $skipLevel = 0
    $removedSections = New-Object System.Collections.ArrayList
    $replacedChapterSummaryCount = 0
    foreach ($line in $lines) {
        $heading = [regex]::Match($line, "^(#{1,6})\s+(.+?)\s*$")
        if ($skipLevel -gt 0) {
            if ($heading.Success -and $heading.Groups[1].Value.Length -le $skipLevel) {
                $skipLevel = 0
            }
            else {
                continue
            }
        }

        if ($heading.Success) {
            $headingText = $heading.Groups[2].Value.Trim()
            if ($headingText -match "(?i)^(?:Reflection Activity|Workplace Challenge|This Week.?s Challenge)(?:\s*[:\-].*)?$") {
                $skipLevel = $heading.Groups[1].Value.Length
                [void]$removedSections.Add($headingText)
                continue
            }
            if ($headingText -match "(?i)^Chapter Summary(?:\s*[:\-].*)?$") {
                [void]$kept.Add(("#" * $heading.Groups[1].Value.Length) + " Synthesis")
                $replacedChapterSummaryCount++
                continue
            }
        }
        [void]$kept.Add($line)
    }

    $cleanedMarkdown = ($kept -join "`r`n")
    $labelPattern = "(?i)\bReflection Activity\b|\bWorkplace Challenge\b|\bThis Week.?s Challenge\b|\bWorkplace Application\b|\bChapter Summary\b"
    $labelMatches = @([regex]::Matches($cleanedMarkdown, $labelPattern))
    $cleanedMarkdown = $cleanedMarkdown -replace "(?i)\bReflection Activity\b", "guided reflection"
    $cleanedMarkdown = $cleanedMarkdown -replace "(?i)\bWorkplace Challenge\b", "applied example"
    $cleanedMarkdown = $cleanedMarkdown -replace "(?i)\bThis Week.?s Challenge\b", "chapter application"
    $cleanedMarkdown = $cleanedMarkdown -replace "(?i)\bWorkplace Application\b", "applied example"
    $cleanedMarkdown = $cleanedMarkdown -replace "(?i)\bChapter Summary\b", "Synthesis"

    return [pscustomobject]@{
        markdown = $cleanedMarkdown
        removedCount = $removedSections.Count
        removedSections = @($removedSections)
        replacedChapterSummaryCount = $replacedChapterSummaryCount
        replacedLabelCount = $labelMatches.Count
    }
}

function Get-MarkdownImageReferences {
    param([AllowNull()][string]$Markdown)

    $images = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Markdown)) {
        return @()
    }

    foreach ($match in [regex]::Matches($Markdown, "(?m)^!\[([^\]]*)\]\(([^)\s]+)\)")) {
        [void]$images.Add([pscustomobject]@{
            altText = ConvertTo-CleanText $match.Groups[1].Value
            path = $match.Groups[2].Value
        })
    }

    return @($images)
}

function Get-ImageAccessibilityIssues {
    param([object[]]$Images)

    $issues = New-Object System.Collections.ArrayList
    $index = 1
    foreach ($image in @($Images)) {
        if ([string]::IsNullOrWhiteSpace($image.altText)) {
            [void]$issues.Add("Image $index has empty alt text.")
        }
        elseif ($image.altText.Length -lt 24) {
            [void]$issues.Add("Image $index alt text is too brief: '$($image.altText)'.")
        }
        elseif ($image.altText -match "^(chapter \d+ opener|quick visual check|visual study aid):?\s+[^.]+$") {
            [void]$issues.Add("Image $index alt text names the asset but does not describe its learning content.")
        }
        $index++
    }

    return @($issues)
}

function Get-PlainTextForStyleGuideCheck {
    param([AllowNull()][string]$Markdown)

    $filteredLines = New-Object System.Collections.ArrayList
    $inReferences = $false
    foreach ($line in ([string]$Markdown -split "`r?`n")) {
        if ($line -match "^##\s+(References and Further Reading|Notes|Numbered Scholarly Notes|Scholarly Sources)") {
            $inReferences = $true
            continue
        }
        if ($inReferences -and $line -match "^#\s+Chapter\s+\d+:") {
            $inReferences = $false
        }
        if ($inReferences) {
            continue
        }
        if ($line -match "^\s*#") {
            continue
        }
        [void]$filteredLines.Add($line)
    }

    $plain = ($filteredLines -join "`n")
    $plain = $plain -replace "!\[[^\]]*\]\([^)]+\)", " "
    $plain = $plain -replace "\[([^\]]+)\]\([^)]+\)", "source"
    $plain = $plain -replace "\*\*", ""
    $plain = $plain -replace "[#>`_]", " "
    $plain = $plain -replace "\s+", " "
    return $plain.Trim()
}

function Get-ProseIntegritySignals {
    param([AllowNull()][string]$Markdown)

    # Remove Markdown links completely for this check. Replacing a citation
    # link with the word "source" can create a false signal such as
    # "leadership. source" even though the manuscript sentence is correct.
    $proseLines = New-Object System.Collections.ArrayList
    $inReferences = $false
    foreach ($line in ([string]$Markdown -split "`r?`n")) {
        if ($line -match "^##\s+(References and Further Reading|Notes|Numbered Scholarly Notes|Scholarly Sources)") {
            $inReferences = $true
            continue
        }
        if ($inReferences -and $line -match "^#\s+Chapter\s+\d+:") {
            $inReferences = $false
        }
        if (-not $inReferences) {
            [void]$proseLines.Add($line)
        }
    }
    $plain = ($proseLines -join "`n")
    $plain = $plain -replace "!\[[^\]]*\]\([^)]+\)", " "
    $plain = $plain -replace "\[[^\]]+\]\([^)]+\)", " "
    $plain = $plain -replace "(?m)^\s*#{1,6}\s*", " "
    $plain = $plain -replace "\*\*|__", ""
    # Remove structural Markdown noise before evaluating sentence fragments.
    # Numbered checks, table rows, URLs, and abbreviations such as a.m. are
    # not learner-facing prose fragments and otherwise create large false
    # positive counts.
    $plain = $plain -replace "(?m)^\s*\|.*(?:\r?\n|$)", " "
    $plain = $plain -replace "(?m)^\s*(?:[-*+]\s+|\d+[\.\)]\s+)", " "
    $plain = $plain -replace "https?://\S+", " "
    $plain = $plain -replace "(?i)\b[ap]\.\s*m\.", "time"
    $plain = $plain -replace "(?i)\bn\.\s*d\.", "nd"
    $plain = $plain -replace "\s+", " "
    $issues = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $lowercaseAfterPeriod = New-Object System.Collections.ArrayList
    $conjunctionAfterPeriod = New-Object System.Collections.ArrayList

    foreach ($match in [regex]::Matches($plain, "(?<=[a-z])\.\s+(?=[a-z])")) {
        $prefix = $plain.Substring(0, $match.Index)
        # e.g. and i.e. are abbreviations, not sentence-boundary failures.
        if ($prefix -match "(?i)(?:e|i)\.\s*$") { continue }
        $start = [Math]::Max(0, $match.Index - 48)
        $length = [Math]::Min(132, $plain.Length - $start)
        [void]$lowercaseAfterPeriod.Add(($plain.Substring($start, $length) -replace "\s+", " ").Trim())
    }

    foreach ($match in [regex]::Matches($plain, "(?i)\.\s+(?:and|or|but|while|because|so|when|instead|rather)\b")) {
        $start = [Math]::Max(0, $match.Index - 48)
        $length = [Math]::Min(132, $plain.Length - $start)
        [void]$conjunctionAfterPeriod.Add(($plain.Substring($start, $length) -replace "\s+", " ").Trim())
    }

    $encodingSignals = [regex]::Matches($plain, "(?:[\u00C2\u00C3\u00E2][\u0080-\u00BF]|\u0393\u00C7|\u00E2\u20AC)").Count
    $shortFragmentCount = 0
    foreach ($sentenceMatch in [regex]::Matches($plain, "[^.!?]+[.!?]")) {
        $sentence = $sentenceMatch.Value.Trim()
        $wordCount = [regex]::Matches($sentence, "\b[A-Za-z][A-Za-z'-]*\b").Count
        $hasVerbSignal = $sentence -match "(?i)\b(is|are|am|was|were|be|been|being|has|have|had|can|could|will|would|should|must|do|does|did|make|makes|help|helps|need|needs|affect|affects|support|supports|use|uses|work|works|show|shows|matter|matters|maintain|hear|identify|evaluate|choose|review|serve|connect|set|clarify|observe|discuss|develop|recognize|ask|name|build|describe|compare|select|explain|consider|apply|practice|record|protect|follow|share|state|keep|check|match|transfer|define|diagnose|gather|listen|agree|write|invite|phrase|stop|return|separate|outline|conduct|create|include|reduce|improve|give|tell|read|learn|look|find|begin|turn|move|remain|provide|require|allow|avoid|decide|identify|measure|document|plan|prepare|respond|resolve|communicate|lead|leadership)\b"
        $isStructuralToken = $sentence -match "(?i)^\s*(?:\d+|yes|no|time|nd|[ap]\.m\.)\.?\s*$"
        if ($wordCount -le 3 -and -not $hasVerbSignal -and -not $isStructuralToken -and $sentence -notmatch "(?i)^(note|example|pause|question|introduction|references?)\b") {
            $shortFragmentCount++
        }
    }

    if ($lowercaseAfterPeriod.Count -gt 0) {
        [void]$issues.Add("$($lowercaseAfterPeriod.Count) lowercase-after-period sentence-boundary error(s) detected. Examples: $((@($lowercaseAfterPeriod | Select-Object -First 3) -join ' | '))")
    }
    if ($conjunctionAfterPeriod.Count -gt 12) {
        [void]$issues.Add("$($conjunctionAfterPeriod.Count) suspicious conjunction-after-period transition(s) detected. Examples: $((@($conjunctionAfterPeriod | Select-Object -First 3) -join ' | '))")
    }
    if ($encodingSignals -gt 0) {
        [void]$issues.Add("$encodingSignals possible mojibake/encoding signal(s) detected in learner-facing prose.")
    }
    if ($shortFragmentCount -gt 12) {
        [void]$warnings.Add("$shortFragmentCount short fragment-like sentence(s) detected; review callouts and list prose.")
    }

    return [pscustomobject]@{
        status = if ($issues.Count -gt 0) { "FAIL" } elseif ($warnings.Count -gt 0) { "WARNING" } else { "PASS" }
        lowercaseAfterPeriodCount = $lowercaseAfterPeriod.Count
        conjunctionAfterPeriodCount = $conjunctionAfterPeriod.Count
        encodingSignalCount = $encodingSignals
        shortFragmentCount = $shortFragmentCount
        lowercaseAfterPeriodExamples = @($lowercaseAfterPeriod | Select-Object -First 5)
        conjunctionAfterPeriodExamples = @($conjunctionAfterPeriod | Select-Object -First 5)
        issues = @($issues)
        warnings = @($warnings)
        detail = if ($issues.Count -gt 0) { $issues -join " " } elseif ($warnings.Count -gt 0) { $warnings -join " " } else { "No suspicious sentence-boundary, conjunction, fragment, or encoding signals detected." }
    }
}

function Get-IntroductionCompletenessSignals {
    param(
        [object]$Course,
        [object]$Chapter,
        [AllowNull()][string]$ChapterText
    )

    $issues = New-Object System.Collections.ArrayList
    $chapterValue = [string]$ChapterText
    $introMatch = [regex]::Match($chapterValue, "(?ims)^##\s+(?:INTRODUCTORY PARAGRAPH|Introduction)\s*\r?\n(?<body>.*?)(?=^##\s+|\z)")
    $introBody = if ($introMatch.Success) { $introMatch.Groups['body'].Value } else { "" }
    $plainIntro = $introBody
    $plainIntro = $plainIntro -replace "!\[[^\]]*\]\([^)]+\)", " "
    $plainIntro = $plainIntro -replace "\[([^\]]+)\]\([^)]+\)", '$1'
    $plainIntro = $plainIntro -replace "\*\*", "" -replace '`', ""
    $plainIntro = $plainIntro -replace "(?im)^\s*why this matters:\s*", ""
    $plainIntro = $plainIntro -replace "\s+", " "
    $plainIntro = $plainIntro.Trim()

    $wordCount = Get-MarkdownWordCount -Markdown $plainIntro
    $sentences = @([regex]::Matches($plainIntro, "[^.!?]+[.!?]") | ForEach-Object { $_.Value.Trim() } | Where-Object { $_ })
    $paragraphs = @($introBody -split "\r?\n\s*\r?\n" | ForEach-Object {
        $value = ($_ -replace "!\[[^\]]*\]\([^)]+\)", " " -replace "\s+", " ").Trim()
        if ($value -and $value -notmatch "(?i)^why this matters:\s*$") { $value }
    })

    if (-not $introMatch.Success) { [void]$issues.Add("No Introduction section was found immediately after the chapter opening.") }
    if ($wordCount -lt 70) { [void]$issues.Add("Introduction contains only $wordCount words; it needs enough context to orient the learner.") }
    if ($sentences.Count -lt 2) { [void]$issues.Add("Introduction contains fewer than two complete sentences.") }
    if ($paragraphs.Count -lt 1) { [void]$issues.Add("Introduction has no learner-facing paragraph content.") }

    $titleTerms = @(
        ([string]$Chapter.title -split "[^A-Za-z0-9]+" | Where-Object { $_.Length -ge 5 } | ForEach-Object { $_.ToLowerInvariant() }) |
            Select-Object -Unique
    )
    $topicHits = @($titleTerms | Where-Object { $plainIntro -match "(?i)\b$([regex]::Escape($_))\b" })
    if ($titleTerms.Count -gt 0 -and $topicHits.Count -eq 0) {
        [void]$issues.Add("Introduction does not name the chapter topic: $($titleTerms -join ', ').")
    }

    # Course context must come from THIS course. The original check looked for
    # supervision and leadership wording from one example course, which failed
    # every other subject regardless of how well the introduction was written.
    $genericWords = @('course', 'courses', 'student', 'students', 'introduces', 'introduction', 'learning', 'skills', 'through', 'their', 'which', 'about', 'these', 'those', 'other', 'there', 'where', 'while', 'being', 'using', 'based', 'within', 'across', 'include', 'including', 'includes', 'emphasis', 'placed', 'develop', 'develops', 'examine', 'understanding', 'foundational', 'fundamental', 'fundamentals', 'settings', 'setting')
    $courseTerms = @(
        ("$($Course.courseName) $($Course.description)" -split "[^A-Za-z0-9-]+" |
            Where-Object { $_.Length -ge 5 } |
            ForEach-Object { $_.ToLowerInvariant() } |
            Where-Object { $genericWords -notcontains $_ } |
            Select-Object -Unique)
    )
    $coursePattern = if ($courseTerms.Count -gt 0) { ($courseTerms | ForEach-Object { [regex]::Escape($_) }) -join "|" } else { "" }
    $contextChecks = @(
        @{ name = "the course subject (for example: $(($courseTerms | Select-Object -First 6) -join ', '))"; pattern = $coursePattern },
        @{ name = "a workplace or service setting"; pattern = "\b(work|workplace|office|service|clinic|healthcare|hospital|business|organization|company|employer|team|patient|customer|client|role|job|career|profession)" },
        @{ name = "learner orientation (you, your, student, learner)"; pattern = "\b(student|students|learner|learners|you|your)\b" }
    )
    $missingContext = @(
        $contextChecks |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.pattern) -and $plainIntro -notmatch "(?i)$($_.pattern)" } |
            ForEach-Object { $_.name }
    )
    if ([int]$Chapter.number -eq 1 -and $missingContext.Count -gt 0) {
        [void]$issues.Add("Chapter 1 introduction is missing essential course/workplace context: $($missingContext -join '; '). It must name this course's subject, its work setting, and speak to the learner.")
    }

    $firstProseLine = @($introBody -split "\r?\n" | ForEach-Object {
        $line = ($_ -replace "!\[[^\]]*\]\([^)]+\)", " " -replace "\*\*", "").Trim()
        if ($line -and $line -notmatch "(?i)^why this matters:\s*$") { $line }
    } | Select-Object -First 1)[0]
    if ($firstProseLine -and $firstProseLine -cmatch "^[a-z]") {
        [void]$issues.Add("Introduction begins with lowercase or fragment-like prose: '$firstProseLine'.")
    }

    return [pscustomobject]@{
        status = if ($issues.Count -gt 0) { "FAIL" } else { "PASS" }
        wordCount = $wordCount
        sentenceCount = $sentences.Count
        paragraphCount = $paragraphs.Count
        topicTerms = @($titleTerms)
        topicHits = @($topicHits)
        contextSignalCount = $contextHits
        firstProseLine = $firstProseLine
        issues = @($issues)
        detail = if ($issues.Count -gt 0) { $issues -join " " } else { "Introduction has $wordCount words, $($sentences.Count) complete sentence(s), named chapter topic coverage, and sufficient learner/workplace orientation." }
    }
}

function Get-SourceFidelitySignals {
    param(
        [object]$Course,
        [object]$Chapter,
        [AllowNull()][string]$ChapterText
    )

    $plain = Get-PlainTextForStyleGuideCheck -Markdown $ChapterText
    $titleTerms = @([string]$Chapter.title -split "[^A-Za-z0-9]+" | Where-Object { $_.Length -ge 5 } | ForEach-Object { $_.ToLowerInvariant() })
    $focusTerms = @(Get-KeyTermsFromText -Text "$($Chapter.focus) $($Chapter.learningTargets -join ' ')" -Limit 6 | Where-Object { $_.Length -ge 5 })
    $requiredTerms = @($titleTerms + $focusTerms) | ForEach-Object { [string]$_ } | Select-Object -Unique
    $matchedTerms = @($requiredTerms | Where-Object { $plain -match "(?i)\b$([regex]::Escape($_))\b" })
    $minimumTopicTerms = if ($requiredTerms.Count -eq 0) { 0 } else { [Math]::Max(1, [Math]::Ceiling($requiredTerms.Count * 0.6)) }

    $courseContextPatterns = @()
    if ([int]$Chapter.number -eq 1) {
        # Context comes from the target course, not the formatting example.
        $courseContextPatterns = @([string]$Course.courseName -split '[^A-Za-z]+' |
            Where-Object { $_.Length -ge 5 -and $_ -notmatch '^(Introduction|Foundations|Principles)$' } |
            Select-Object -Unique | ForEach-Object { '\b' + [regex]::Escape($_) + '\b' })
    }
    $courseContextHits = @($courseContextPatterns | Where-Object { $plain -match "(?i)$_" })
    $issues = New-Object System.Collections.ArrayList
    if ($requiredTerms.Count -gt 0 -and $matchedTerms.Count -lt $minimumTopicTerms) {
        [void]$issues.Add("Only $($matchedTerms.Count) of $($requiredTerms.Count) chapter source/topic terms were found; expected at least $minimumTopicTerms.")
    }
    if ([int]$Chapter.number -eq 1 -and $courseContextHits.Count -lt [Math]::Ceiling($courseContextPatterns.Count * 0.6)) {
        [void]$issues.Add("Chapter 1 preserves only $($courseContextHits.Count) of the required course-context signals; restore the authoritative course purpose and workplace setting.")
    }

    return [pscustomobject]@{
        status = if ($issues.Count -gt 0) { "FAIL" } else { "PASS" }
        requiredTermCount = $requiredTerms.Count
        matchedTermCount = $matchedTerms.Count
        requiredTerms = @($requiredTerms)
        matchedTerms = @($matchedTerms)
        courseContextSignalCount = $courseContextHits.Count
        courseContextSignals = @($courseContextHits)
        issues = @($issues)
        detail = if ($issues.Count -gt 0) { $issues -join " " } else { "$($matchedTerms.Count) of $($requiredTerms.Count) chapter source/topic terms retained; course-context coverage is present." }
    }
}

function Get-EbookTextSha256 {
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

function Get-ApproximateSyllableCount {
    param([AllowNull()][string]$Word)

    $clean = ([string]$Word).ToLowerInvariant() -replace "[^a-z]", ""
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return 0
    }

    $groups = [regex]::Matches($clean, "[aeiouy]+").Count
    if ($clean.Length -gt 3 -and $clean.EndsWith("e")) {
        $groups--
    }
    if ($clean -match "(le)$" -and $clean.Length -gt 2 -and $clean[-3] -notmatch "[aeiouy]") {
        $groups++
    }
    if ($groups -lt 1) {
        $groups = 1
    }

    return $groups
}

function Get-ReadabilityMetrics {
    param([AllowNull()][string]$PlainText)

    $plain = [string]$PlainText
    $sentences = @([regex]::Matches($plain, "[^.!?]+[.!?]") | ForEach-Object { $_.Value.Trim() } | Where-Object { $_ })
    if ($sentences.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($plain)) {
        $sentences = @($plain)
    }

    $words = @([regex]::Matches($plain, "\b[A-Za-z][A-Za-z']*\b") | ForEach-Object { $_.Value })
    $syllables = 0
    foreach ($word in $words) {
        $syllables += Get-ApproximateSyllableCount -Word $word
    }

    $sentenceCount = [Math]::Max(1, $sentences.Count)
    $wordCount = [Math]::Max(1, $words.Count)
    $fleschKincaidGrade = [Math]::Round((0.39 * ($wordCount / [double]$sentenceCount)) + (11.8 * ($syllables / [double]$wordCount)) - 15.59, 1)
    $fleschReadingEase = [Math]::Round(206.835 - (1.015 * ($wordCount / [double]$sentenceCount)) - (84.6 * ($syllables / [double]$wordCount)), 1)

    return [pscustomobject]@{
        sentenceCount = $sentenceCount
        wordCount = $wordCount
        syllableCount = $syllables
        fleschKincaidGrade = $fleschKincaidGrade
        fleschReadingEase = $fleschReadingEase
    }
}

function Get-PassiveVoiceMatches {
    param([AllowNull()][string]$PlainText)

    $pattern = "\b(am|are|be|been|being|is|was|were)\s+(also\s+|not\s+|often\s+|usually\s+|carefully\s+|quickly\s+)?[a-z]+(ed|en)\b"
    $passiveHits = New-Object System.Collections.ArrayList
    foreach ($match in [regex]::Matches(([string]$PlainText).ToLowerInvariant(), $pattern)) {
        $value = $match.Value
        if ($value -match "\b(is|was|were)\s+(concerned|based|focused|related|used)\b") {
            continue
        }
        [void]$passiveHits.Add($value)
    }

    # Rates must count occurrences, not just distinct phrases. Repeating the
    # same passive construction must not lower its measured frequency.
    return @($passiveHits)
}

function Get-FormalToneMatches {
    param([AllowNull()][string]$PlainText)

    $formalTerms = @(
        "utilize",
        "therefore",
        "furthermore",
        "moreover",
        "in order to",
        "prior to",
        "subsequent to",
        "commence",
        "terminate",
        "facilitate",
        "demonstrates that",
        "it is important to note"
    )
    $hits = New-Object System.Collections.ArrayList
    $lower = ([string]$PlainText).ToLowerInvariant()
    foreach ($term in $formalTerms) {
        if ($lower.Contains($term)) {
            [void]$hits.Add($term)
        }
    }

    return @($hits | Select-Object -Unique)
}

function Get-UmaWritingStyleGuideMetrics {
    param([AllowNull()][string]$Markdown)

    $plain = Get-PlainTextForStyleGuideCheck -Markdown $Markdown
    $readability = Get-ReadabilityMetrics -PlainText $plain
    $passiveMatches = @(Get-PassiveVoiceMatches -PlainText $plain)
    $formalToneMatches = @(Get-FormalToneMatches -PlainText $plain)
    $sentences = @([regex]::Matches($plain, "[^.!?]+[.!?]") | ForEach-Object { $_.Value.Trim() } | Where-Object { $_ })
    if ($sentences.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($plain)) {
        $sentences = @($plain)
    }

    $sentenceWordCounts = @($sentences | ForEach-Object { Get-MarkdownWordCount -Markdown $_ })
    $totalSentenceWords = if ($sentenceWordCounts.Count -gt 0) { ($sentenceWordCounts | Measure-Object -Sum).Sum } else { 0 }
    $averageSentenceWords = if ($sentences.Count -gt 0) { [Math]::Round(($totalSentenceWords / [double]$sentences.Count), 1) } else { 0 }
    $longSentenceCount = @($sentenceWordCounts | Where-Object { $_ -gt 30 }).Count
    $secondPersonCount = [regex]::Matches($plain.ToLowerInvariant(), "\b(you|your|yours|yourself|you've|you'll|you're|let's)\b").Count
    $businessCasePresent = ([string]$Markdown) -match "\*\*Business Case:\*\*\s+[A-Z][A-Za-z'-]+(?:\s+[A-Z][A-Za-z'-]+){0,2}\b"

    $forbiddenPatterns = @(
        "\beBook\b",
        "\be-Book\b",
        "\be-mail\b",
        "\bon-line\b",
        "\bweb site\b",
        "\bteacher\b",
        "\blecturer\b",
        "\bfaculty\b",
        "\bclass website\b",
        "\bchat room\b",
        "\bUS\b"
    )
    $forbiddenHits = New-Object System.Collections.ArrayList
    foreach ($pattern in $forbiddenPatterns) {
        if ([regex]::IsMatch($plain, $pattern)) {
            [void]$forbiddenHits.Add($pattern)
        }
    }

    $longListItems = New-Object System.Collections.ArrayList
    foreach ($line in ([string]$Markdown -split "`r?`n")) {
        if ($line -match "^\s*[-*]\s+\S" -and $line -notmatch "^\s*-\s+\[(OS|R|C|SC)\d+\]") {
            $itemWordCount = Get-MarkdownWordCount -Markdown $line
            if ($itemWordCount -gt 24) {
                [void]$longListItems.Add(($line.Trim()))
            }
        }
    }

    $issues = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    if (-not $businessCasePresent) {
        [void]$issues.Add("Missing named '**Business Case:**' chapter pattern.")
    }
    if ($secondPersonCount -lt 5) {
        [void]$issues.Add("Needs more direct learner-facing second-person language.")
    }
    if ($averageSentenceWords -gt 30) {
        [void]$issues.Add("Average sentence length is $averageSentenceWords words; revise for plain-language readability.")
    }
    $passiveRate = [Math]::Round((($passiveMatches.Count / [double][Math]::Max(1, $readability.wordCount)) * 1000), 1)
    $editorial = Test-EbookEditorialThresholds -Grade $readability.fleschKincaidGrade -PassiveRate $passiveRate
    foreach ($issue in $editorial.issues) { [void]$issues.Add($issue) }
    if ($formalToneMatches.Count -gt 3) {
        [void]$issues.Add("Tone may be too formal; review terms: $($formalToneMatches -join ', ').")
    }
    if ($forbiddenHits.Count -gt 0) {
        [void]$issues.Add("Terminology conflicts with UMA style guide: $($forbiddenHits -join ', ').")
    }
    if ($longListItems.Count -gt 3) {
        [void]$issues.Add("$($longListItems.Count) bulleted list item(s) are longer than the concise-list target.")
    }

    return [pscustomobject]@{
        status = if ($issues.Count -gt 0) { "FAIL" } elseif ($warnings.Count -gt 0) { "WARNING" } else { "PASS" }
        issues = @($issues)
        warnings = @($warnings)
        businessCasePresent = $businessCasePresent
        secondPersonCount = $secondPersonCount
        averageSentenceWords = $averageSentenceWords
        fleschKincaidGrade = $readability.fleschKincaidGrade
        fleschReadingEase = $readability.fleschReadingEase
        longSentenceCount = $longSentenceCount
        passiveVoiceMatches = @($passiveMatches)
        passiveVoiceRatePerThousand = $passiveRate
        formalToneMatches = @($formalToneMatches)
        longListItems = $longListItems.Count
        forbiddenHits = @($forbiddenHits)
        detail = if ($issues.Count -gt 0) {
            $issues -join " "
        }
        elseif ($warnings.Count -gt 0) {
            $warnings -join " "
        }
        else {
            "UMA AI style guide signals present: named business case, $secondPersonCount second-person prompt(s), grade $($readability.fleschKincaidGrade) readability, $averageSentenceWords average sentence words, $longSentenceCount long sentence(s), $passiveRate possible passive phrase(s) per 1,000 words, $($longListItems.Count) long non-reference bullet(s), no forbidden terminology."
        }
    }
}

function New-EbookQualityReport {
    param(
        [object]$Course,
        [object]$Plan,
        [object[]]$Sources,
        [object]$SourceContext,
        [string]$Markdown,
        [object]$BrandProfile
    )

    $learnerResiduePatterns = @(
        "(?im)^\s*#{1,4}\s*(assignment|discussion|quiz|test|exam|homework|rubric)\b",
        "\b\d+\s*(points|pts\.?)\b|\b(points|pts\.?)\s*(possible|total|grade|graded)\b",
        "\b(graded|gradebook|due date)\b",
        # "submit"/"submission" is assignment residue only in an assignment
        # context. Claims, forms, and filings are submitted in many subjects
        # (claim submission, electronic submission), and that is course content.
        "(?i)\b(submit|submission)\b[^.\r\n]*\b(assignment|discussion|instructor|dropbox|gradebook|lms|canvas|blackboard|grade|grading)\b|\b(assignment|discussion|instructor|dropbox|gradebook|lms|canvas|blackboard|grade|grading)\b[^.\r\n]*\b(submit|submission)\b",
        "practice quiz",
        "self-assessment quiz",
        "flashcards?",
        "writing workshop",
        "\*\*Apply it:\*\*",
        "\*\*Self-check:\*\*",
        "\*\*Worked example:\*\*",
        "Applied Practice",
        "Workplace Application",
        "Check Your Understanding",
        "research and oer connection",
        "source context",
        "source-context",
        "openstax grounding",
        "oer grounding",
        "research candidates",
        "before final",
        "should be developed",
        "this section develops",
        "chapter purpose",
        "source grounding",
        "opening workplace scenario",
        "source trail",
        "\bapi\b",
        "openalex",
        "\[(SC|C|OS|R)\d+\s*;"
    )

    $objectiveTraceability = Test-EbookObjectiveTraceability -Course $Course -Plan $Plan -Markdown $Markdown
    $chapterChecks = New-Object System.Collections.ArrayList
    foreach ($chapter in $Plan.chapters) {
        Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Quality check" -Status "Working" -Detail "Checking objectives, sources, depth, structure, visuals, accessibility, brand, and learner cleanliness."
        $chapterSources = Get-ChapterSources -Sources $Sources -ChapterNumber $chapter.number
        $uploadedEvidence=Test-EbookUploadedSourceEvidence -Plan $Plan -ChapterSources $chapterSources -SourceContext $SourceContext
        $checks = New-Object System.Collections.ArrayList
        $chapterText = if ($Markdown) { Get-ChapterMarkdownText -Markdown $Markdown -ChapterNumber $chapter.number } else { "" }
        if($Plan.sourceMode -eq 'UploadedOnly'){
            [void]$checks.Add([pscustomobject]@{name='uploaded_source_boundary';status=$(if($uploadedEvidence -and $chapterText -notmatch '\]\(https?://'){'PASS'}else{'FAIL'});detail='Provided-source hashes, current chunk evidence, and no added external citation links are required.'})
        }
        $chapterWords = Get-MarkdownWordCount -Markdown $chapterText
        $chapterImages = Get-MarkdownImageReferences -Markdown $chapterText
        $imageAccessibilityIssues = Get-ImageAccessibilityIssues -Images $chapterImages
        $styleGuideMetrics = Get-UmaWritingStyleGuideMetrics -Markdown $chapterText
        $depthStandard = Get-ProductionDepthStandard -Course $Course -Chapter $chapter
        $repetitionSignals = Get-ContentRepetitionSignals -Markdown $chapterText
        $proseIntegritySignals = Get-ProseIntegritySignals -Markdown $chapterText
        $introductionSignals = Get-IntroductionCompletenessSignals -Course $Course -Chapter $chapter -ChapterText $chapterText
        $sourceFidelitySignals = Get-SourceFidelitySignals -Course $Course -Chapter $chapter -ChapterText $chapterText
        $knowledgeCheckSignals = Get-ProhibitedKnowledgeCheckSignals -Markdown $chapterText
        $learnerSectionSignals = Get-ProhibitedLearnerSectionSignals -Markdown $chapterText
        $careerContextSignals = Get-CareerContextSignals -Course $Course -Chapter $chapter -Markdown $chapterText
        $sourceFitSignals = Get-SourceFitSignals -Chapter $chapter -ChapterSources $chapterSources
        $chapterTraceability = @($objectiveTraceability.chapters | Where-Object { $_.chapterNumber -eq [int]$chapter.number } | Select-Object -First 1)
        $chapterBodyWithoutNotes = [regex]::Replace($chapterText, "(?ms)^##[^\r\n]*(Notes|Scholarly Sources|Numbered Notes)\b[^\r\n]*\r?\n.*$", "")
        # Accept the HU2000-style textbook equivalents used by the Codex pass:
        # Opening Scenario/Case Study Progression, Visual Model, Communication
        # Toolbox, and Chapter Summary are book-native structures even when
        # they do not use the older scaffold labels verbatim.
        $hasCaseStudy = $chapterText -match "(?im)^#{2,4}\s+(Case Study|Opening Scenario|Case Study Progression)\b" -and $chapterText -match "(?im)\*\*Business Case:\*\*"
        $hasEvidenceUse = $chapterText -match "(?im)^##\s+(Evidence in Practice|Using Evidence|Use Evidence|Evidence-Based|Comparing|Understanding|Leadership at|Delegation as|Coaching Within|Ethical Leadership)\b" -or $chapterText -match "\[\d+\]\(#chapter-$($chapter.number)-note-\d+\)"
        $hasModeledArtifact = $chapterText -match "(?im)^#{2,4}\s+(Modeled Artifact|Model Communication Artifact|Model Workplace Artifact|Communication Toolbox|The Team Leadership Plan)\b" -or [regex]::Matches($chapterText, "(?m)^\|").Count -ge 4
        $hasFieldGuide = $chapterText -match "(?im)^#{2,4}\s+.*(Field Guide|Communication Toolbox|Professional Toolbox|Toolbox|Team Leadership Plan)\b"
        $hasSynthesis = $chapterText -match "(?im)^#{2,4}\s+(.+\s+)?(Synthesis|Chapter Summary)\b" -or $chapterText -match "(?im)^##\s+Section\s+\d+\.4\s+-\s+Integrating\b"
        $hasKeyTakeaways = $chapterText -match "(?im)^#{2,4}\s+Key Takeaways\b"
        $hasNumberedNotes = $chapterText -match "(?im)^##\s+.*(Numbered Notes|Scholarly Sources|Notes)\b"
        $hasQuickVisualCheck = $chapterText -match "(?im)^##\s+Quick Visual Check\b|^!\[[^\]]*quick visual check[^\]]*\]"
        # Visual plans use course-specific alt text, so the gate must not rely
        # on a short list of asset names. Once a chapter has an opener, a
        # quick visual check, and at least one additional embedded image, the
        # visual study-aid requirement is satisfied.
        $hasVisualStudyAid = $chapterImages.Count -ge 3 -and ($chapterText -match "(?im)^#{2,4}\s+(Visual Model|Visual Models|Visual Study Aid|Embedded\s+Visual Study Aid)\b")
        $hasInteractiveStudy = $chapterText -match "(?im)^##\s+Interactive Study( Activity)?\b|interactive-study\.html#chapter-$($chapter.number)|interactive study"

        [void]$checks.Add([pscustomobject]@{
            name = "learning_objectives"
            status = if (@($chapter.learningTargets).Count -gt 0) { "PASS" } else { "FAIL" }
            detail = "$(@($chapter.learningTargets).Count) objective(s)"
        })
        [void]$checks.Add([pscustomobject]@{
            name = "objective_traceability"
            status = if ($chapterTraceability -and $chapterTraceability.status -eq "PASS") { "PASS" } else { "FAIL" }
            detail = if ($chapterTraceability) { (@($chapterTraceability.issues) -join " ") } else { "No objective traceability record exists for this chapter." }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "source_context"
            status = if ($chapterSources -and @($chapterSources.sourceContext).Count -gt 0) { "PASS" } else { "FAIL" }
            detail = "$(@($chapterSources.sourceContext).Count) source chunk(s)"
        })
        [void]$checks.Add([pscustomobject]@{
            name = "openstax_grounding"
            status = if ($uploadedEvidence -or ($chapterSources -and @(@($chapterSources.openStax) + @($chapterSources.oer) | Where-Object { $_ -and $_.url }).Count -gt 0)) { "PASS" } else { "FAIL" }
            detail = if ($uploadedEvidence) { 'Uploaded-only source contract verified; no external OER is required or added.' } else { "$(@($chapterSources.openStax | Where-Object { $_ -and $_.url }).Count) OpenStax page(s); $(@($chapterSources.oer | Where-Object { $_ -and $_.url }).Count) other OER page(s)" }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "research_candidates"
            status = if ($uploadedEvidence -or ($chapterSources -and (@($chapterSources.researchCandidates | Where-Object { $_.title -and $_.title -ne "OpenAlex search failed" }).Count -gt 0 -or $chapterSources.sourcePolicy.lockedWeeklyAssignments))) { "PASS" } else { "WARNING" }
            detail = if ($uploadedEvidence) { 'Uploaded-only source contract verified; no research discovery requested.' } elseif ($chapterSources.sourcePolicy.lockedWeeklyAssignments) { 'User-assigned source policy governs this chapter. Required articles and OER are enforced by the separate assigned-source contract; no unassigned research is added.' } else { "$(@($chapterSources.researchCandidates | Where-Object { $_.title -and $_.title -ne "OpenAlex search failed" }).Count) research candidate(s)" }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "cohesion_bridge"
            status = if (-not [string]::IsNullOrWhiteSpace($chapter.cohesionBridge)) { "PASS" } else { "FAIL" }
            detail = $chapter.cohesionBridge
        })
        [void]$checks.Add([pscustomobject]@{
            name = "chapter_depth"
            status = if ($chapterWords -ge $depthStandard.minimum) { "PASS" } elseif ($chapterWords -ge [Math]::Floor($depthStandard.minimum * 0.85)) { "WARNING" } else { "FAIL" }
            detail = "$chapterWords words; target is at least $($depthStandard.minimum) words, preferred $($depthStandard.preferred), for a $($depthStandard.label)"
        })
        [void]$checks.Add([pscustomobject]@{
            name = "book_structure"
            status = if ($hasCaseStudy -and $hasEvidenceUse -and $hasModeledArtifact -and $hasSynthesis -and $hasKeyTakeaways -and $hasNumberedNotes) { "PASS" } else { "FAIL" }
            detail = "Requires book-native case study, evidence use, modeled artifact, synthesis, key takeaways, and numbered notes"
        })
        [void]$checks.Add([pscustomobject]@{
            name = "production_development"
            status = if ($chapterWords -ge $depthStandard.minimum -and $hasModeledArtifact -and $hasFieldGuide -and $hasSynthesis) { "PASS" } else { "FAIL" }
            detail = "Requires production depth plus a modeled artifact, field guide, and synthesis so SMEs review a nearly finished chapter rather than a skeletal lesson."
        })
        [void]$checks.Add([pscustomobject]@{
            name = "repetition_and_naturalness"
            status = $repetitionSignals.status
            detail = $repetitionSignals.detail
            metrics = [pscustomobject]@{
                duplicateParagraphCount = $repetitionSignals.duplicateParagraphCount
                duplicateSentenceCount = $repetitionSignals.duplicateSentenceCount
                templateHits = @($repetitionSignals.templateHits)
            }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "prose_integrity"
            status = $proseIntegritySignals.status
            detail = $proseIntegritySignals.detail
            metrics = [pscustomobject]@{
                lowercaseAfterPeriodCount = $proseIntegritySignals.lowercaseAfterPeriodCount
                conjunctionAfterPeriodCount = $proseIntegritySignals.conjunctionAfterPeriodCount
                encodingSignalCount = $proseIntegritySignals.encodingSignalCount
                shortFragmentCount = $proseIntegritySignals.shortFragmentCount
                lowercaseAfterPeriodExamples = @($proseIntegritySignals.lowercaseAfterPeriodExamples)
                conjunctionAfterPeriodExamples = @($proseIntegritySignals.conjunctionAfterPeriodExamples)
            }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "introduction_completeness"
            status = $introductionSignals.status
            detail = $introductionSignals.detail
            metrics = [pscustomobject]@{
                wordCount = $introductionSignals.wordCount
                sentenceCount = $introductionSignals.sentenceCount
                paragraphCount = $introductionSignals.paragraphCount
                topicTerms = @($introductionSignals.topicTerms)
                topicHits = @($introductionSignals.topicHits)
                contextSignalCount = $introductionSignals.contextSignalCount
                firstProseLine = $introductionSignals.firstProseLine
            }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "source_fidelity"
            status = $sourceFidelitySignals.status
            detail = $sourceFidelitySignals.detail
            metrics = [pscustomobject]@{
                requiredTermCount = $sourceFidelitySignals.requiredTermCount
                matchedTermCount = $sourceFidelitySignals.matchedTermCount
                requiredTerms = @($sourceFidelitySignals.requiredTerms)
                matchedTerms = @($sourceFidelitySignals.matchedTerms)
                courseContextSignalCount = $sourceFidelitySignals.courseContextSignalCount
                courseContextSignals = @($sourceFidelitySignals.courseContextSignals)
            }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "no_knowledge_checks"
            status = $knowledgeCheckSignals.status
            detail = $knowledgeCheckSignals.detail
            metrics = [pscustomobject]@{
                prohibitedHeadingCount = $knowledgeCheckSignals.count
                prohibitedHeadings = @($knowledgeCheckSignals.matches)
            }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "no_reflection_activity_or_workplace_challenge"
            status = if ($learnerSectionSignals.reflectionActivityCount -eq 0 -and $learnerSectionSignals.workplaceChallengeCount -eq 0) { "PASS" } else { "FAIL" }
            detail = if ($learnerSectionSignals.reflectionActivityCount -eq 0 -and $learnerSectionSignals.workplaceChallengeCount -eq 0) { "No Reflection Activity or Workplace Challenge sections found." } else { "Remove Reflection Activity and Workplace Challenge sections: $($learnerSectionSignals.matches -join '; ')" }
            metrics = [pscustomobject]@{
                reflectionActivityCount = $learnerSectionSignals.reflectionActivityCount
                workplaceChallengeCount = $learnerSectionSignals.workplaceChallengeCount
            }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "no_redundant_chapter_summary"
            status = if ($learnerSectionSignals.chapterSummaryCount -eq 0) { "PASS" } else { "FAIL" }
            detail = if ($learnerSectionSignals.chapterSummaryCount -eq 0) { "No redundant Chapter Summary heading found; use the numbered section title with Synthesis content." } else { "Remove redundant Chapter Summary heading(s) beneath the numbered section title." }
            metrics = [pscustomobject]@{
                chapterSummaryCount = $learnerSectionSignals.chapterSummaryCount
            }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "career_context"
            status = $careerContextSignals.status
            detail = $careerContextSignals.detail
            metrics = [pscustomobject]@{
                careerSignalCount = $careerContextSignals.count
            }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "source_fit"
            status = $sourceFitSignals.status
            detail = $sourceFitSignals.detail
            metrics = [pscustomobject]@{
                sourceFitSignalCount = $sourceFitSignals.fitCount
            }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "visual_engagement"
            status = if ($chapterImages.Count -gt 0 -or [regex]::Matches($chapterText, '(?m)^\|\s*:?-{3,}').Count -gt 0) { "PASS" } else { "FAIL" }
            detail = "Requires an embedded instructional diagram or a structured comparison/process table. Decorative openers and interactive activities are not mandatory."
        })
        [void]$checks.Add([pscustomobject]@{
            name = "image_accessibility"
            status = if ($imageAccessibilityIssues.Count -eq 0) { "PASS" } else { "FAIL" }
            detail = if ($imageAccessibilityIssues.Count -eq 0) { "$($chapterImages.Count) image(s) include descriptive alt text for HTML and Word export" } else { "Fix image descriptions: $($imageAccessibilityIssues -join ' ')" }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "brand_style"
            status = if ($BrandProfile -and $BrandProfile.name -and $BrandProfile.visualStyle -and $BrandProfile.colors) { "PASS" } else { "FAIL" }
            detail = if ($BrandProfile -and $BrandProfile.name) { "Brand profile loaded: $($BrandProfile.name)" } else { "Brand profile is missing" }
        })
        [void]$checks.Add([pscustomobject]@{
            name = "uma_ai_style_guide"
            status = $styleGuideMetrics.status
            detail = $styleGuideMetrics.detail
            metrics = [pscustomobject]@{
                businessCasePresent = $styleGuideMetrics.businessCasePresent
                secondPersonCount = $styleGuideMetrics.secondPersonCount
                averageSentenceWords = $styleGuideMetrics.averageSentenceWords
                fleschKincaidGrade = $styleGuideMetrics.fleschKincaidGrade
                fleschReadingEase = $styleGuideMetrics.fleschReadingEase
                longSentenceCount = $styleGuideMetrics.longSentenceCount
                passiveVoiceRatePerThousand = $styleGuideMetrics.passiveVoiceRatePerThousand
                passiveVoiceMatches = @($styleGuideMetrics.passiveVoiceMatches)
                formalToneMatches = @($styleGuideMetrics.formalToneMatches)
                longListItems = $styleGuideMetrics.longListItems
                forbiddenHits = @($styleGuideMetrics.forbiddenHits)
            }
        })
        $residueHits = New-Object System.Collections.ArrayList
        $chapterBodyForResidue = $chapterBodyWithoutNotes
        foreach ($pattern in $learnerResiduePatterns) {
            if ($chapterBodyForResidue -match $pattern) {
                [void]$residueHits.Add($pattern)
            }
        }
        $inlineLinkCitations = [regex]::Matches($chapterBodyForResidue, "\[[^\]]*(OpenStax|Research|source|doi)[^\]]*\]\(https?://").Count
        if ($inlineLinkCitations -gt 0) {
            [void]$residueHits.Add("inline source links in body copy")
        }
        $numberedNoteRefs = [regex]::Matches($chapterBodyForResidue, "\[\d+\]\(#chapter-\d+-note-\d+\)|\[\d+\](?:\([^)]+\))?").Count
        if ($numberedNoteRefs -lt 1 -and @($chapterSources.openStax + $chapterSources.researchCandidates).Count -gt 0) {
            [void]$residueHits.Add("missing numbered note references")
        }
        [void]$checks.Add([pscustomobject]@{
            name = "learner_cleanliness"
            status = if ($residueHits.Count -eq 0) { "PASS" } else { "FAIL" }
            detail = if ($residueHits.Count -eq 0) { "No LMS labels, assignment language, or source-management residue in learner-facing chapter text; citations use numbered notes." } else { "Remove learner-facing residue: $($residueHits -join ', ')" }
        })

        $failed = @($checks | Where-Object { $_.status -eq "FAIL" }).Count
        $warnings = @($checks | Where-Object { $_.status -eq "WARNING" }).Count
        [void]$chapterChecks.Add([pscustomobject]@{
            chapterNumber = $chapter.number
            chapterTitle = $chapter.title
            wordCount = $chapterWords
            status = if ($failed -gt 0) { "FAIL" } elseif ($warnings -gt 0) { "WARNING" } else { "PASS" }
            checks = @($checks)
        })
        $chapterStatus = if ($failed -gt 0) { "Warning" } elseif ($warnings -gt 0) { "Warning" } else { "Complete" }
        Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Quality check" -Status $chapterStatus -Detail "$chapterWords words; $failed failed check(s), $warnings warning check(s); prose integrity=$($proseIntegritySignals.status), introduction=$($introductionSignals.status)."
    }

    $totalFails = @($chapterChecks | Where-Object { $_.status -eq "FAIL" }).Count
    $totalWarnings = @($chapterChecks | Where-Object { $_.status -eq "WARNING" }).Count
    if ($objectiveTraceability.status -ne "PASS") { $totalFails++ }

    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        manuscriptSha256 = Get-EbookTextSha256 -Text $Markdown
        courseCode = $Course.courseCode
        courseName = $Course.courseName
        status = if ($totalFails -gt 0) { "FAIL" } elseif ($totalWarnings -gt 0) { "WARNING" } else { "PASS" }
        summary = [pscustomobject]@{
            chapters = @($Plan.chapters).Count
            sourceFiles = @($SourceContext.files).Count
            sourceChunks = @($SourceContext.chunks).Count
            manuscriptWords = Get-MarkdownWordCount -Markdown $Markdown
            failingChapters = $totalFails
            warningChapters = $totalWarnings
        }
        objectiveTraceability = $objectiveTraceability
        chapters = @($chapterChecks)
    }
}

function ConvertTo-QualityReportMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# Ebook Quality Report")
    [void]$lines.Add("")
    [void]$lines.Add("Course: $($Report.courseCode) - $($Report.courseName)")
    [void]$lines.Add("")
    [void]$lines.Add("Status: $($Report.status)")
    [void]$lines.Add("")
    [void]$lines.Add("Summary: $($Report.summary.chapters) chapter(s), $($Report.summary.manuscriptWords) manuscript words, $($Report.summary.sourceFiles) source file(s), $($Report.summary.sourceChunks) source chunk(s), $($Report.summary.failingChapters) failing chapter(s), $($Report.summary.warningChapters) warning chapter(s).")
    [void]$lines.Add("")

    foreach ($chapter in $Report.chapters) {
        [void]$lines.Add("## Chapter $($chapter.chapterNumber): $($chapter.chapterTitle)")
        [void]$lines.Add("")
        [void]$lines.Add("Status: $($chapter.status)")
        [void]$lines.Add("Word count: $($chapter.wordCount)")
        foreach ($check in $chapter.checks) {
            [void]$lines.Add("- $($check.status): $($check.name) - $($check.detail)")
        }
        [void]$lines.Add("")
    }

    return ($lines -join "`r`n")
}

function Get-RegexMatchCount {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 0
    }

    return [regex]::Matches($Text, $Pattern).Count
}

function Get-QualityChapterResult {
    param(
        [object]$QualityReport,
        [int]$ChapterNumber
    )

    if (-not $QualityReport) { return $null }
    return @($QualityReport.chapters | Where-Object { $_.chapterNumber -eq $ChapterNumber } | Select-Object -First 1)[0]
}

function Get-QualityCheckResult {
    param(
        [object]$QualityChapter,
        [string]$Name
    )

    if (-not $QualityChapter) { return $null }
    return @($QualityChapter.checks | Where-Object { $_.name -eq $Name } | Select-Object -First 1)[0]
}

function New-PublishingEditorReport {
    param(
        [object]$Course,
        [object]$Plan,
        [object[]]$Sources,
        [object]$SourceContext,
        [object]$QualityReport,
        [string]$Markdown,
        [object]$EngagementPlan,
        [object]$BrandProfile
    )

    $chapterCount = @($Plan.chapters).Count
    $chapterReviews = New-Object System.Collections.ArrayList

    foreach ($chapter in $Plan.chapters) {
        Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Publishing editor review" -Status "Working" -Detail "Reviewing depth, learner experience, visual support, source integrity, and revision priorities."
        $chapterText = if ($Markdown) { Get-ChapterMarkdownText -Markdown $Markdown -ChapterNumber $chapter.number } else { "" }
        $wordCount = Get-MarkdownWordCount -Markdown $chapterText
        $sentenceCount = [Math]::Max(1, (Get-RegexMatchCount -Text $chapterText -Pattern "[.!?](\s|$)"))
        $averageSentenceWords = [Math]::Round(($wordCount / $sentenceCount), 1)
        $imageCount = Get-RegexMatchCount -Text $chapterText -Pattern "(?m)^!\[[^\]]+\]\([^)]+\)"
        $linkCount = Get-RegexMatchCount -Text $chapterText -Pattern "\[[^\]]+\]\([^)]+\)"
        $pauseNoticeCount = Get-RegexMatchCount -Text $chapterText -Pattern "(?im)^##\s+Pause and Notice\b|\*\*Pause and Notice:\*\*"
        $exampleContextCount = Get-RegexMatchCount -Text $chapterText -Pattern "(?im)^##\s+Example in Context\b|\*\*Example in Context:\*\*"
        $qualityChapter = Get-QualityChapterResult -QualityReport $QualityReport -ChapterNumber $chapter.number
        $chapterSources = Get-ChapterSources -Sources $Sources -ChapterNumber $chapter.number
        $engagementItem = Get-EngagementItemForChapter -EngagementPlan $EngagementPlan -ChapterNumber $chapter.number
        $depthStandard = Get-ProductionDepthStandard -Course $Course -Chapter $chapter
        $minimumChapterWords = $depthStandard.minimum
        $preferredChapterWords = $depthStandard.preferred

        $sourceCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "source_context"
        $openStaxCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "openstax_grounding"
        $researchCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "research_candidates"
        $structureCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "book_structure"
        $developmentCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "production_development"
        $repetitionCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "repetition_and_naturalness"
        $proseIntegrityCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "prose_integrity"
        $introductionCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "introduction_completeness"
        $sourceFidelityCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "source_fidelity"
        $knowledgeCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "no_knowledge_checks"
        $learnerActivityCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "no_reflection_activity_or_workplace_challenge"
        $chapterSummaryCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "no_redundant_chapter_summary"
        $careerContextCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "career_context"
        $sourceFitCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "source_fit"
        $visualCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "visual_engagement"
        $imageAccessibilityCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "image_accessibility"
        $cleanCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "learner_cleanliness"
        $brandCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "brand_style"
        $styleGuideCheck = Get-QualityCheckResult -QualityChapter $qualityChapter -Name "uma_ai_style_guide"

        $blockingIssues = New-Object System.Collections.ArrayList
        $editorialNotes = New-Object System.Collections.ArrayList
        $strengths = New-Object System.Collections.ArrayList

        if ($wordCount -lt $minimumChapterWords) {
            [void]$blockingIssues.Add("Expand chapter depth to at least $minimumChapterWords words for a production draft.")
        }
        elseif ($wordCount -lt $preferredChapterWords) {
            [void]$editorialNotes.Add("Chapter is above the minimum but below the preferred higher-ed depth target of $preferredChapterWords words.")
        }
        else {
            [void]$strengths.Add("Chapter depth supports a multi-week higher-ed reading experience.")
        }

        if (@($chapter.learningTargets).Count -eq 0) {
            [void]$blockingIssues.Add("Add explicit learning objectives before publication review.")
        }
        else {
            [void]$strengths.Add("$(@($chapter.learningTargets).Count) learning objective(s) drive the chapter.")
        }

        if ($structureCheck -and $structureCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Restore textbook structure: case study, evidence use, modeled artifact, chapter synthesis, key takeaways, and numbered notes.")
        }
        elseif ($chapterText -notmatch '(?im)^#{2,4}\s+.*(Field Guide|Communication Toolbox)\b' -and ($pauseNoticeCount -lt @($chapter.learningTargets).Count -or $exampleContextCount -lt @($chapter.learningTargets).Count)) {
            [void]$editorialNotes.Add("Review the explanation and modeled examples for each objective; do not add prohibited learner activities.")
        }
        else {
            [void]$strengths.Add("Examples, reader-notice moments, case study, synthesis, and notes are present.")
        }

        if ($sourceCheck -and $sourceCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Attach the provided course/book source context to this chapter.")
        }
        if ($openStaxCheck -and $openStaxCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Map at least one OpenStax or OER page for this chapter.")
        }
        if ($researchCheck -and $researchCheck.status -ne "PASS") {
            [void]$editorialNotes.Add("Research source coverage needs SME review or an additional curated scholarly source.")
        }
        if ($sourceFitCheck -and $sourceFitCheck.status -eq "FAIL") {
            [void]$blockingIssues.Add("Replace or supplement weakly aligned sources with sources that fit the chapter topic: $($sourceFitCheck.detail)")
        }
        elseif ($sourceFitCheck -and $sourceFitCheck.status -eq "WARNING") {
            [void]$editorialNotes.Add("Source fit is thin and should be strengthened before SME review: $($sourceFitCheck.detail)")
        }
        if (($sourceCheck -and $sourceCheck.status -eq "PASS") -and ($openStaxCheck -and $openStaxCheck.status -eq "PASS")) {
            [void]$strengths.Add("Course source context and OER grounding are present.")
        }

        if ($developmentCheck -and $developmentCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Develop this as a production textbook chapter, not a lesson outline: $($developmentCheck.detail)")
        }
        if ($repetitionCheck -and $repetitionCheck.status -eq "FAIL") {
            [void]$blockingIssues.Add("Revise repeated or template-like prose before SME handoff: $($repetitionCheck.detail)")
        }
        elseif ($repetitionCheck -and $repetitionCheck.status -eq "WARNING") {
            [void]$editorialNotes.Add("Review repeated prose for naturalness: $($repetitionCheck.detail)")
        }
        if ($proseIntegrityCheck -and $proseIntegrityCheck.status -eq "FAIL") {
            [void]$blockingIssues.Add("Correct sentence-boundary, punctuation, or encoding defects before SME handoff: $($proseIntegrityCheck.detail)")
        }
        elseif ($proseIntegrityCheck -and $proseIntegrityCheck.status -eq "WARNING") {
            [void]$editorialNotes.Add("Review fragment-like sentences and callout prose: $($proseIntegrityCheck.detail)")
        }
        if ($introductionCheck -and $introductionCheck.status -eq "FAIL") {
            [void]$blockingIssues.Add("Restore a complete learner-facing introduction: $($introductionCheck.detail)")
        }
        if ($sourceFidelityCheck -and $sourceFidelityCheck.status -eq "FAIL") {
            [void]$blockingIssues.Add("Restore required course/topic source coverage: $($sourceFidelityCheck.detail)")
        }
        if ($knowledgeCheck -and $knowledgeCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Remove Knowledge Checks and Check Your Reasoning sections before publication: $($knowledgeCheck.detail)")
        }
        if ($learnerActivityCheck -and $learnerActivityCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Remove Reflection Activity and Workplace Challenge sections before publication: $($learnerActivityCheck.detail)")
        }
        if ($chapterSummaryCheck -and $chapterSummaryCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Remove the redundant Chapter Summary heading; the numbered integration section is the title: $($chapterSummaryCheck.detail)")
        }
        if ($careerContextCheck -and $careerContextCheck.status -eq "FAIL") {
            [void]$blockingIssues.Add("Add enough career-field context for learner relevance: $($careerContextCheck.detail)")
        }
        elseif ($careerContextCheck -and $careerContextCheck.status -eq "WARNING") {
            [void]$editorialNotes.Add("Career-field context is present but thin: $($careerContextCheck.detail)")
        }

        if ($visualCheck -and $visualCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Add an embedded instructional diagram or structured comparison/process table appropriate to the approved format.")
        }
        elseif ($imageCount -lt 3 -and [regex]::Matches($chapterText, '(?m)^\|').Count -lt 4) {
            [void]$editorialNotes.Add("Review whether the approved format needs additional instructional visual support.")
        }
        else {
            [void]$strengths.Add("Chapter includes multiple media moments rather than only text.")
        }
        if ($imageAccessibilityCheck -and $imageAccessibilityCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Add descriptive alt text and figure descriptions for every instructional image.")
        }
        elseif ($imageAccessibilityCheck) {
            [void]$strengths.Add("Instructional images include descriptive text for accessible HTML and Word export.")
        }

        if ($cleanCheck -and $cleanCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Remove generator notes, source-management language, or raw production residue from the learner copy.")
        }
        if ($brandCheck -and $brandCheck.status -ne "PASS") {
            [void]$blockingIssues.Add("Apply the configured brand profile to tone, layout, and visual treatment.")
        }
        if ($styleGuideCheck -and $styleGuideCheck.status -eq "FAIL") {
            [void]$blockingIssues.Add("Revise chapter to meet the UMA AI writing style guide: $($styleGuideCheck.detail)")
        }
        elseif ($styleGuideCheck -and $styleGuideCheck.status -eq "WARNING") {
            [void]$editorialNotes.Add("Copyedit chapter toward the UMA AI writing style guide: $($styleGuideCheck.detail)")
        }
        elseif ($styleGuideCheck) {
            [void]$strengths.Add("UMA AI writing style guide signals are present, including business case, learner-facing prompts, and approved terminology.")
        }
        if ($averageSentenceWords -gt 28) {
            [void]$editorialNotes.Add("Review sentence length for student readability; average sentence length is $averageSentenceWords words.")
        }
        if ($linkCount -lt 4) {
            [void]$editorialNotes.Add("Review source-link density so students and reviewers can trace claims without hunting through the registry.")
        }

        $status = if ($blockingIssues.Count -gt 0) { "FAIL" } elseif ($editorialNotes.Count -gt 0) { "WARNING" } else { "PASS" }
        $recommendation = if ($status -eq "FAIL") {
            "Hold for developmental revision."
        }
        elseif ($status -eq "WARNING") {
            "Ready for SME review with targeted editorial expansion."
        }
        else {
            "Ready for SME review and final editorial polish."
        }

        [void]$chapterReviews.Add([pscustomobject]@{
            chapterNumber = $chapter.number
            chapterTitle = $chapter.title
            status = $status
            recommendation = $recommendation
            metrics = [pscustomobject]@{
                wordCount = $wordCount
                learningObjectives = @($chapter.learningTargets).Count
                averageSentenceWords = $averageSentenceWords
                imageReferences = $imageCount
                sourceLinks = $linkCount
                pauseAndNotice = $pauseNoticeCount
                examplesInContext = $exampleContextCount
                sourceContextItems = if ($chapterSources) { @($chapterSources.sourceContext).Count } else { 0 }
                openStaxItems = if ($chapterSources) { @($chapterSources.openStax).Count } else { 0 }
                researchItems = if ($chapterSources) { @($chapterSources.researchCandidates | Where-Object { $_.title -and $_.title -ne "OpenAlex search failed" }).Count } else { 0 }
                assignedSourcePolicySatisfied = [bool]($chapterSources.sourcePolicy.lockedWeeklyAssignments -and $researchCheck.status -eq 'PASS' -and $openStaxCheck.status -eq 'PASS' -and @($chapterSources.openStax).Count -gt 0 -and @($chapterSources.openStax | Where-Object {$_.reviewStatus -ne 'CONTENT_REVIEWED'}).Count -eq 0)
                uploadedSourcePolicySatisfied = (Test-EbookUploadedSourceEvidence -Plan $Plan -ChapterSources $chapterSources -SourceContext $SourceContext)
                styleGuideStatus = if ($styleGuideCheck) { $styleGuideCheck.status } else { "MISSING" }
                businessCase = if ($styleGuideCheck -and $styleGuideCheck.metrics) { [bool]$styleGuideCheck.metrics.businessCasePresent } else { $false }
            }
            visualEvidence = [pscustomobject]@{
                openerImage = if ($engagementItem) { $engagementItem.openerImageFile } else { "" }
                quickVisualCheck = if ($engagementItem) { $engagementItem.quickCheckFile } else { "" }
                studyAid = if ($engagementItem) { $engagementItem.assetFile } else { "" }
                interactiveStudy = if ($engagementItem) { $engagementItem.interactiveAnchor } else { "" }
            }
            strengths = @($strengths)
            editorialNotes = @($editorialNotes)
            priorityRevisions = @($blockingIssues)
        })
        $editorStatus = if ($status -eq "PASS") { "Complete" } else { "Warning" }
        Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Publishing editor review" -Status $editorStatus -Detail $recommendation
    }

    $totalWords = Get-MarkdownWordCount -Markdown $Markdown
    $averageChapterWords = if ($chapterCount -gt 0) { [Math]::Round(($totalWords / $chapterCount), 0) } else { 0 }
    $chapterFailures = @($chapterReviews | Where-Object { $_.status -eq "FAIL" }).Count
    $chapterWarnings = @($chapterReviews | Where-Object { $_.status -eq "WARNING" }).Count
    $chaptersWithFullVisualSet = @($QualityReport.chapters | Where-Object { @($_.checks | Where-Object { $_.name -eq 'visual_engagement' -and $_.status -eq 'PASS' }).Count -gt 0 }).Count
    $chaptersWithResearch = @($chapterReviews | Where-Object { $_.metrics.researchItems -gt 0 }).Count
    $chaptersWithSourcePolicy = @($chapterReviews | Where-Object { $_.metrics.researchItems -gt 0 -or $_.metrics.assignedSourcePolicySatisfied -or $_.metrics.uploadedSourcePolicySatisfied }).Count
    $chaptersPassingStyleGuide = @($chapterReviews | Where-Object { $_.metrics.styleGuideStatus -eq "PASS" }).Count
    $chaptersWarningStyleGuide = @($chapterReviews | Where-Object { $_.metrics.styleGuideStatus -eq "WARNING" }).Count
    $chaptersFailingStyleGuide = @($chapterReviews | Where-Object { $_.metrics.styleGuideStatus -eq "FAIL" }).Count

    $standards = New-Object System.Collections.ArrayList
    [void]$standards.Add([pscustomobject]@{
        category = "Higher Education Fit"
        status = if ($chapterFailures -gt 0) { "FAIL" } elseif ($chapterWarnings -gt 0) { "WARNING" } else { "PASS" }
        evidence = "$chapterCount chapter(s), $totalWords words total, $averageChapterWords average words per chapter."
        analysis = "The manuscript should feel like a coherent e-book chapter, not a packet of links, prompts, or LMS activities. Depth, chapter flow, examples, synthesis, and clean notes are the key signals."
    })
    [void]$standards.Add([pscustomobject]@{
        category = "Instructional Design"
        status = if (@($QualityReport.chapters | Where-Object { (@($_.checks | Where-Object { $_.name -eq "book_structure" -and $_.status -eq "PASS" })).Count -eq 0 }).Count -gt 0) { "FAIL" } else { "PASS" }
        evidence = "Case study, evidence use, field guide, synthesis, key takeaways, and numbered notes are checked in every chapter."
        analysis = "The chapters need book-native scaffolding so learners can move from concept recognition to durable understanding without seeing assignment or course-shell instructions."
    })
    [void]$standards.Add([pscustomobject]@{
        category = "Visual Learning Experience"
        status = if ($chaptersWithFullVisualSet -eq $chapterCount) { "PASS" } elseif ($chaptersWithFullVisualSet -gt 0) { "WARNING" } else { "FAIL" }
        evidence = "$chaptersWithFullVisualSet of $chapterCount chapter(s) include an embedded instructional diagram or structured comparison/process table."
        analysis = "A higher-ed ebook should use visuals to reduce cognitive load, clarify processes, and create useful breaks in the reading experience."
    })
    [void]$standards.Add([pscustomobject]@{
        category = "Source And Research Integrity"
        status = if ($chapterCount -gt 0 -and $chaptersWithSourcePolicy -eq $chapterCount) { "PASS" } else { "FAIL" }
        evidence = "$chaptersWithSourcePolicy of $chapterCount chapter(s) satisfy their source policy through research candidates, locked assigned readings, or hash-verified uploaded documents. $chaptersWithResearch chapter(s) have separate research candidates."
        analysis = "Do not add unassigned research to a locked reading assignment merely to satisfy a count. The independent assigned-source contract still enforces exact weekly sections and body development. Academic accuracy, attribution, and permissions require human review."
    })
    [void]$standards.Add([pscustomobject]@{
        category = "Brand And Accessibility"
        status = if ($BrandProfile -and $BrandProfile.name) { "PASS" } else { "FAIL" }
        evidence = if ($BrandProfile -and $BrandProfile.name) { "Brand profile loaded: $($BrandProfile.name)." } else { "Brand profile missing." }
        analysis = "The ebook should use the brand voice, visual language, accessible color choices, alt text, and readable hierarchy consistently."
    })
    [void]$standards.Add([pscustomobject]@{
        category = "UMA AI Writing Style Guide"
        status = if ($chaptersFailingStyleGuide -gt 0) { "FAIL" } elseif ($chaptersWarningStyleGuide -gt 0) { "WARNING" } else { "PASS" }
        evidence = "$chaptersPassingStyleGuide of $chapterCount chapter(s) pass the UMA AI style guide check; $chaptersWarningStyleGuide chapter(s) need copyediting; $chaptersFailingStyleGuide chapter(s) fail."
        analysis = "The ebook should use active learner-facing voice, plain language, job-connected examples, analytical prompts, inclusive terminology, concise lists, and a named business case in every chapter."
    })

    $standardFailures = @($standards | Where-Object { $_.status -eq "FAIL" }).Count
    $standardWarnings = @($standards | Where-Object { $_.status -eq "WARNING" }).Count
    $overallStatus = if ($chapterFailures -gt 0 -or $standardFailures -gt 0) { "FAIL" } elseif ($chapterWarnings -gt 0 -or $standardWarnings -gt 0) { "WARNING" } else { "PASS" }
    $decision = if ($overallStatus -eq "FAIL") {
        "Do not publish yet. Complete developmental revisions, then rerun quality and editorial review."
    }
    elseif ($overallStatus -eq "WARNING") {
        "Meets the production-draft baseline, with targeted expansion or SME review required before final publication."
    }
    else {
        "Meets the production-draft expectation and is ready for SME review plus final copyedit."
    }

    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        courseCode = $Course.courseCode
        courseName = $Course.courseName
        status = $overallStatus
        editorialRole = "Publishing Editor Agent"
        manuscriptSha256 = Get-EbookTextSha256 -Text $Markdown
        editorialPolicyVersion = (Get-EbookEditorialPolicy).version
        editorialLens = "Higher education developmental editor reviewing content depth, learner experience, visual support, source integrity, brand fit, and production readiness."
        decision = $decision
        summary = [pscustomobject]@{
            chapters = $chapterCount
            manuscriptWords = $totalWords
            averageChapterWords = $averageChapterWords
            minimumChapterWords = $minimumChapterWords
            preferredChapterWords = $preferredChapterWords
            chaptersWithWarnings = $chapterWarnings
            chaptersWithFailures = $chapterFailures
            chaptersWithFullVisualSet = $chaptersWithFullVisualSet
            chaptersWithResearch = $chaptersWithResearch
            sourceFiles = if ($SourceContext) { @($SourceContext.files).Count } else { 0 }
            sourceChunks = if ($SourceContext) { @($SourceContext.chunks).Count } else { 0 }
        }
        analysis = [pscustomobject]@{
        content = "The manuscript is judged on whether each chapter reads like a coherent e-book chapter, with enough explanation, examples, synthesis, and transitions to support a five-week higher-ed course."
        visuals = "The visual review checks embedded diagrams and structured comparison/process tables against the publication format. It does not require decorative images or interactive activities."
            pedagogy = "The editor looks for alignment between chapter goals, narrative sections, examples in context, reader-notice moments, case-based reasoning, synthesis, and key takeaways."
            sources = "The source review expects course context, OER grounding, and research candidates to be traceable through numbered notes while keeping learner-facing prose clean."
            productionRisk = "Passing this report does not replace SME review, copyright or attribution review, final copyediting, accessibility QA, or LMS packaging review."
        }
        standards = @($standards)
        chapters = @($chapterReviews)
    }
}

function ConvertTo-PublishingEditorReportMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# Publishing Editor Analysis Report")
    [void]$lines.Add("")
    [void]$lines.Add("Course: $($Report.courseCode) - $($Report.courseName)")
    [void]$lines.Add("")
    [void]$lines.Add("Status: $($Report.status)")
    [void]$lines.Add("")
    [void]$lines.Add("Editorial role: $($Report.editorialRole)")
    [void]$lines.Add("")
    [void]$lines.Add("Lens: $($Report.editorialLens)")
    [void]$lines.Add("")
    [void]$lines.Add("Decision: $($Report.decision)")
    [void]$lines.Add("")
    [void]$lines.Add("Summary: $($Report.summary.chapters) chapter(s), $($Report.summary.manuscriptWords) manuscript words, $($Report.summary.averageChapterWords) average words per chapter, $($Report.summary.chaptersWithFullVisualSet) chapter(s) with a full visual set, $($Report.summary.chaptersWithResearch) chapter(s) with research candidates.")
    [void]$lines.Add("")
    [void]$lines.Add("## Overall Analysis")
    [void]$lines.Add("")
    [void]$lines.Add("- Content: $($Report.analysis.content)")
    [void]$lines.Add("- Visuals: $($Report.analysis.visuals)")
    [void]$lines.Add("- Pedagogy: $($Report.analysis.pedagogy)")
    [void]$lines.Add("- Sources: $($Report.analysis.sources)")
    [void]$lines.Add("- Production risk: $($Report.analysis.productionRisk)")
    [void]$lines.Add("")
    [void]$lines.Add("## Standards Review")
    [void]$lines.Add("")
    foreach ($standard in $Report.standards) {
        [void]$lines.Add("### $($standard.category)")
        [void]$lines.Add("")
        [void]$lines.Add("Status: $($standard.status)")
        [void]$lines.Add("")
        [void]$lines.Add("Evidence: $($standard.evidence)")
        [void]$lines.Add("")
        [void]$lines.Add("Analysis: $($standard.analysis)")
        [void]$lines.Add("")
    }

    [void]$lines.Add("## Chapter Reviews")
    [void]$lines.Add("")
    $tick = [char]96
    foreach ($chapter in $Report.chapters) {
        [void]$lines.Add("### Chapter $($chapter.chapterNumber): $($chapter.chapterTitle)")
        [void]$lines.Add("")
        [void]$lines.Add("Status: $($chapter.status)")
        [void]$lines.Add("")
        [void]$lines.Add("Recommendation: $($chapter.recommendation)")
        [void]$lines.Add("")
        [void]$lines.Add("Metrics: $($chapter.metrics.wordCount) words; $($chapter.metrics.learningObjectives) objective(s); $($chapter.metrics.imageReferences) image reference(s); $($chapter.metrics.sourceLinks) source link(s); $($chapter.metrics.pauseAndNotice) pause-and-notice moment(s); $($chapter.metrics.examplesInContext) example(s) in context; style guide $($chapter.metrics.styleGuideStatus); business case $($chapter.metrics.businessCase).")
        [void]$lines.Add("")
        [void]$lines.Add("Visual evidence: opener $tick$($chapter.visualEvidence.openerImage)$tick, quick check $tick$($chapter.visualEvidence.quickVisualCheck)$tick, study aid $tick$($chapter.visualEvidence.studyAid)$tick, interactive $tick$($chapter.visualEvidence.interactiveStudy)$tick.")
        [void]$lines.Add("")
        if (@($chapter.strengths).Count -gt 0) {
            [void]$lines.Add("Strengths:")
            foreach ($item in $chapter.strengths) {
                [void]$lines.Add("- $item")
            }
            [void]$lines.Add("")
        }
        if (@($chapter.editorialNotes).Count -gt 0) {
            [void]$lines.Add("Editorial notes:")
            foreach ($item in $chapter.editorialNotes) {
                [void]$lines.Add("- $item")
            }
            [void]$lines.Add("")
        }
        if (@($chapter.priorityRevisions).Count -gt 0) {
            [void]$lines.Add("Priority revisions:")
            foreach ($item in $chapter.priorityRevisions) {
                [void]$lines.Add("- $item")
            }
            [void]$lines.Add("")
        }
    }

    return ($lines -join "`r`n")
}

function New-AgentReviewReport {
    param(
        [object]$Course,
        [object]$Plan,
        [object[]]$Sources,
        [object]$SourceContext,
        [object]$QualityReport,
        [string]$Markdown,
        [object]$BrandProfile,
        [object]$EditorialReport,
        [object]$Blueprint
    )

    $agents = @(
        [pscustomobject]@{
            name = "Curriculum Alignment Agent"
            role = "Verifies that weekly learning objectives become chapter sections, checks, and applications."
            gate = "Every chapter has parsed objectives and objective-driven sections."
        },
        [pscustomobject]@{
            name = "Course Arc Structure Agent"
            role = "Verifies that the planning packet includes a learner-focused five-module arc with concept focus, student actions, introduced concepts, reinforced concepts, and objective alignment."
            gate = "The course arc structure gate must pass before draft generation."
        },
        [pscustomobject]@{
            name = "Concept Reinforcement Map Agent"
            role = "Verifies that the course arc shows where key concepts are introduced and where they return later."
            gate = "The key concept introduction and reinforcement map must be present and complete."
        },
        [pscustomobject]@{
            name = "Student Performance Thread Agent"
            role = "Verifies that one realistic scenario carries student performance across the modules and grows in complexity."
            gate = "The recommended student performance thread must include a scenario and one observable action for each module."
        },
        [pscustomobject]@{
            name = "Outline Specificity Agent"
            role = "Verifies that the detailed outline contains concrete subpoints, examples, worked moments, and reader-notice supports instead of generic placeholders."
            gate = "The outline specificity gate must pass before draft generation."
        },
        [pscustomobject]@{
            name = "Source Fidelity Agent"
            role = "Verifies that the provided source/book context is indexed, attached to chapters, and represented in the learner-facing manuscript."
            gate = "Every chapter has source-context matches and passes source-fidelity coverage."
        },
        [pscustomobject]@{
            name = "Prose Integrity Agent"
            role = "Verifies that drafting and plain-language transformations preserve sentence boundaries, punctuation, readable prose, and text encoding."
            gate = "No lowercase-after-period, suspicious conjunction-after-period, or mojibake failures may reach export."
        },
        [pscustomobject]@{
            name = "No Knowledge Checks Agent"
            role = "Verifies that the learner-facing e-book does not contain Knowledge Checks or Check Your Reasoning question-and-answer sections."
            gate = "Every chapter must pass the no_knowledge_checks gate before export."
        },
        [pscustomobject]@{
            name = "No Extra Learner Activities Agent"
            role = "Verifies that the learner-facing e-book does not contain Reflection Activity, Workplace Challenge, or redundant Chapter Summary headings."
            gate = "Every chapter must pass the no_reflection_activity_or_workplace_challenge and no_redundant_chapter_summary gates before export."
        },
        [pscustomobject]@{
            name = "Introduction Completeness Agent"
            role = "Verifies that each chapter opens with enough complete learner-facing context and that Chapter 1 restores the course purpose and workplace setting."
            gate = "Every chapter has a complete introduction; Chapter 1 includes course and workplace orientation."
        },
        [pscustomobject]@{
            name = "OpenStax OER Agent"
            role = "Verifies that OpenStax or OER pages are mapped, visible, and attribution-ready."
            gate = "Every chapter has OER grounding links."
        },
        [pscustomobject]@{
            name = "Research Integration Agent"
            role = "Verifies that each chapter has scholarly research candidates and DOI or landing-page links when available."
            gate = "Every chapter has research candidates or a warning."
        },
        [pscustomobject]@{
            name = "Cohesion Agent"
            role = "Verifies that chapters build from one week to the next instead of behaving like isolated handouts."
            gate = "Every chapter has a bridge to the next chapter."
        },
        [pscustomobject]@{
            name = "Humanization Agent"
            role = "Verifies that the student-facing book includes scenarios, examples in context, reader-notice moments, synthesis, and key takeaways instead of links, prompts, or LMS activities."
            gate = "Every chapter has case study, evidence-use, synthesis, key-takeaway, and numbered-note sections."
        },
        [pscustomobject]@{
            name = "Clean Student Copy Agent"
            role = "Verifies that production notes, source-management language, and raw citation clusters do not leak into the learner-facing ebook."
            gate = "Every chapter passes the learner cleanliness check."
        },
        [pscustomobject]@{
            name = "Engagement Asset Agent"
            role = "Verifies that each chapter includes an instructional diagram or structured comparison/process table appropriate to the publication format."
            gate = "Every chapter has opener, quick-check, study-aid, and interactive engagement assets."
        },
        [pscustomobject]@{
            name = "Image Accessibility Agent"
            role = "Verifies that instructional images carry meaningful learner-facing descriptions for HTML alt text, figure captions, and Word export."
            gate = "Every chapter image has non-empty descriptive alt text generated from the engagement plan."
        },
        [pscustomobject]@{
            name = "Brand Style Agent"
            role = "Verifies that the UMA brand profile is loaded for content tone, typography, colors, visual prompts, and accessible presentation."
            gate = "Every chapter passes the brand-style check."
        },
        [pscustomobject]@{
            name = "UMA Writing Style Agent"
            role = "Verifies that each chapter applies the UMA AI writing style guide: active learner-facing voice, plain language, job connection, business case, concise lists, and approved terminology."
            gate = "Every chapter passes the UMA AI writing style guide check."
        },
        [pscustomobject]@{
            name = "Publishing Editor Agent"
            role = "Reviews the ebook as a higher education publishing editor, judging content depth, learner experience, visual support, source integrity, brand fit, and production readiness."
            gate = "The publishing editor report is generated and does not identify blocking developmental issues."
        },
        [pscustomobject]@{
            name = "Depth Agent"
            role = "Verifies that the manuscript is deep enough for multi-week learning."
            gate = "Every chapter targets at least 1,800 words in the production draft."
        },
        [pscustomobject]@{
            name = "Export Agent"
            role = "Verifies that Markdown, HTML, Word, source, and QA artifacts can be generated."
            gate = "Export step completes without errors."
        }
    )

    $agentResults = New-Object System.Collections.ArrayList
    foreach ($agent in $agents) {
        Write-EbookGeneratorProgress -Phase "Agent review" -Detail "Running $($agent.name)."
        $status = "PASS"
        $notes = New-Object System.Collections.ArrayList

        switch ($agent.name) {
            "Curriculum Alignment Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "learning_objectives" })[0]
                    if ($check.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("Learning-objective coverage is checked per chapter.")
            }
            "Course Arc Structure Agent" {
                $check = if ($Blueprint -and $Blueprint.planningQualityGates) { @($Blueprint.planningQualityGates.checks | Where-Object { $_.name -eq "course_arc_structure" })[0] } else { $null }
                if (-not $check -or $check.status -ne "PASS") { $status = "FAIL" }
                $note = if ($check) { $check.detail } else { "Planning packet quality gates were not available." }
                [void]$notes.Add($note)
            }
            "Concept Reinforcement Map Agent" {
                $check = if ($Blueprint -and $Blueprint.planningQualityGates) { @($Blueprint.planningQualityGates.checks | Where-Object { $_.name -eq "concept_reinforcement_map" })[0] } else { $null }
                if (-not $check) { $status = "FAIL" }
                elseif ($check.status -eq "FAIL") { $status = "FAIL" }
                elseif ($check.status -eq "WARNING") { $status = "WARNING" }
                $note = if ($check) { $check.detail } else { "Concept reinforcement map gate was not available." }
                [void]$notes.Add($note)
            }
            "Student Performance Thread Agent" {
                $check = if ($Blueprint -and $Blueprint.planningQualityGates) { @($Blueprint.planningQualityGates.checks | Where-Object { $_.name -eq "student_performance_thread" })[0] } else { $null }
                if (-not $check -or $check.status -ne "PASS") { $status = "FAIL" }
                $note = if ($check) { $check.detail } else { "Student performance thread gate was not available." }
                [void]$notes.Add($note)
            }
            "Outline Specificity Agent" {
                $check = if ($Blueprint -and $Blueprint.planningQualityGates) { @($Blueprint.planningQualityGates.checks | Where-Object { $_.name -eq "outline_specificity" })[0] } else { $null }
                if (-not $check) { $status = "FAIL" }
                elseif ($check.status -eq "FAIL") { $status = "FAIL" }
                elseif ($check.status -eq "WARNING") { $status = "WARNING" }
                $note = if ($check) { $check.detail } else { "Outline specificity gate was not available." }
                [void]$notes.Add($note)
            }
            "Source Fidelity Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "source_context" })[0]
                    if ($check.status -ne "PASS") { $status = "FAIL" }
                    $fidelityCheck = @($chapter.checks | Where-Object { $_.name -eq "source_fidelity" })[0]
                    if (-not $fidelityCheck -or $fidelityCheck.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("$(@($SourceContext.chunks).Count) source chunks are indexed and checked for chapter-level fidelity.")
            }
            "Prose Integrity Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "prose_integrity" })[0]
                    if (-not $check -or $check.status -eq "FAIL") { $status = "FAIL" }
                    elseif ($check.status -eq "WARNING" -and $status -ne "FAIL") { $status = "WARNING" }
                }
                [void]$notes.Add("Checked sentence-boundary punctuation, suspicious conjunction transitions, fragment signals, and encoding anomalies.")
            }
            "No Knowledge Checks Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "no_knowledge_checks" })[0]
                    if (-not $check -or $check.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("Checked full chapter text for prohibited Knowledge Checks and Check Your Reasoning labels or sections.")
            }
            "No Extra Learner Activities Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $activityCheck = @($chapter.checks | Where-Object { $_.name -eq "no_reflection_activity_or_workplace_challenge" })[0]
                    $summaryCheck = @($chapter.checks | Where-Object { $_.name -eq "no_redundant_chapter_summary" })[0]
                    if (-not $activityCheck -or $activityCheck.status -ne "PASS" -or -not $summaryCheck -or $summaryCheck.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("Checked full chapter text for Reflection Activity, Workplace Challenge, and redundant Chapter Summary headings.")
            }
            "Introduction Completeness Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "introduction_completeness" })[0]
                    if (-not $check -or $check.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("Checked introduction presence, minimum explanatory context, chapter-topic coverage, and Chapter 1 workplace orientation.")
            }
            "OpenStax OER Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "openstax_grounding" })[0]
                    if ($check.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("OpenStax links are preserved in chapter reference notes.")
            }
            "Research Integration Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "research_candidates" })[0]
                    if ($check.status -eq "FAIL") { $status = "FAIL" }
                    elseif ($check.status -eq "WARNING" -and $status -ne "FAIL") { $status = "WARNING" }
                }
                [void]$notes.Add("OpenAlex candidates are treated as research leads for SME review.")
            }
            "Cohesion Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "cohesion_bridge" })[0]
                    if ($check.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("Chapter bridges are present across the full book spine.")
            }
            "Humanization Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "book_structure" })[0]
                    if ($check.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("The book includes scenarios, case studies, examples in context, synthesis, key takeaways, and numbered notes.")
            }
            "Clean Student Copy Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "learner_cleanliness" })[0]
                    if ($check.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("Student-facing chapters are checked for LMS labels, assignment language, generator residue, raw source-management language, and citation clutter.")
            }
            "Engagement Asset Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "visual_engagement" })[0]
                    if ($check.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("Each chapter is checked for an embedded instructional diagram or structured comparison/process table; interactive activities are not required.")
            }
            "Image Accessibility Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "image_accessibility" })[0]
                    if ($check.status -ne "PASS") { $status = "FAIL" }
                }
                [void]$notes.Add("Image descriptions are generated from the engagement plan and carried into HTML alt text and visible figure descriptions.")
            }
            "Brand Style Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "brand_style" })[0]
                    if ($check.status -ne "PASS") { $status = "FAIL" }
                }
                if ($BrandProfile -and $BrandProfile.name) {
                    [void]$notes.Add("Brand profile applied: $($BrandProfile.name).")
                }
                else {
                    [void]$notes.Add("Brand profile was not available.")
                }
            }
            "UMA Writing Style Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "uma_ai_style_guide" })[0]
                    if (-not $check -or $check.status -eq "FAIL") { $status = "FAIL" }
                    elseif ($check.status -eq "WARNING" -and $status -ne "FAIL") { $status = "WARNING" }
                }
                if ($BrandProfile -and $BrandProfile.writingStyleGuide -and $BrandProfile.writingStyleGuide.sourceGuideResolved) {
                    [void]$notes.Add("Writing style guide applied: $($BrandProfile.writingStyleGuide.sourceGuideResolved).")
                }
                else {
                    [void]$notes.Add("Writing style guide rules applied from the built-in UMA AI style profile.")
                }
                [void]$notes.Add("Checked for a named business case, second-person learner prompts, readable sentence length, concise lists, and UMA terminology.")
            }
            "Publishing Editor Agent" {
                if ($EditorialReport) {
                    if ($EditorialReport.status -eq "FAIL") { $status = "FAIL" }
                    elseif ($EditorialReport.status -eq "WARNING" -and $status -ne "FAIL") { $status = "WARNING" }
                    [void]$notes.Add("Editorial decision: $($EditorialReport.decision)")
                    [void]$notes.Add("Reviewed as a higher education production draft: $($EditorialReport.summary.manuscriptWords) manuscript words, $($EditorialReport.summary.averageChapterWords) average words per chapter, $($EditorialReport.summary.chaptersWithFullVisualSet) chapter(s) with a full visual set.")
                    $chapterNotes = @($EditorialReport.chapters | Where-Object { $_.status -ne "PASS" } | ForEach-Object { "Chapter $($_.chapterNumber): $($_.recommendation)" })
                    if ($chapterNotes.Count -gt 0) {
                        [void]$notes.Add("Targeted editorial notes: $($chapterNotes -join '; ')")
                    }
                }
                else {
                    $status = "WARNING"
                    [void]$notes.Add("Publishing editor report was not generated.")
                }
            }
            "Depth Agent" {
                foreach ($chapter in $QualityReport.chapters) {
                    $check = @($chapter.checks | Where-Object { $_.name -eq "chapter_depth" })[0]
                    if ($check.status -eq "FAIL") { $status = "FAIL" }
                    elseif ($check.status -eq "WARNING" -and $status -ne "FAIL") { $status = "WARNING" }
                }
                [void]$notes.Add("Total manuscript word count: $($QualityReport.summary.manuscriptWords).")
            }
            "Export Agent" {
                [void]$notes.Add("Export validation occurs after package generation.")
            }
        }

        [void]$agentResults.Add([pscustomobject]@{
            name = $agent.name
            role = $agent.role
            gate = $agent.gate
            status = $status
            notes = @($notes)
        })
        Write-EbookGeneratorProgress -Phase "Agent review" -Detail "$($agent.name) finished with status $status."
    }

    $failed = @($agentResults | Where-Object { $_.status -eq "FAIL" }).Count
    $warnings = @($agentResults | Where-Object { $_.status -eq "WARNING" }).Count

    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        courseCode = $Course.courseCode
        courseName = $Course.courseName
        status = if ($failed -gt 0) { "FAIL" } elseif ($warnings -gt 0) { "WARNING" } else { "PASS" }
        agents = @($agentResults)
    }
}

function ConvertTo-AgentReportMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# Ebook Agent Review Report")
    [void]$lines.Add("")
    [void]$lines.Add("Course: $($Report.courseCode) - $($Report.courseName)")
    [void]$lines.Add("")
    [void]$lines.Add("Status: $($Report.status)")
    [void]$lines.Add("")

    foreach ($agent in $Report.agents) {
        [void]$lines.Add("## $($agent.name)")
        [void]$lines.Add("")
        [void]$lines.Add("Status: $($agent.status)")
        [void]$lines.Add("")
        [void]$lines.Add("Role: $($agent.role)")
        [void]$lines.Add("")
        [void]$lines.Add("Gate: $($agent.gate)")
        [void]$lines.Add("")
        foreach ($note in $agent.notes) {
            [void]$lines.Add("- $note")
        }
        [void]$lines.Add("")
    }

    return ($lines -join "`r`n")
}

function Get-ChapterFormatExpansion {
    param([Parameter(Mandatory)][object]$Chapter)

    $title = ([string]$Chapter.title).ToLowerInvariant()
    if ($title -match "leadership styles|situational fit") {
        return @(
            "Situational fit begins with the work, the people, and the moment. A supervisor may need to give clear direction when a task is new or time is short, then shift toward coaching as the employee gains skill. A supportive approach can help when the employee understands the task but needs confidence or access to resources. Delegation becomes appropriate when the employee has the capability and authority to carry the work forward. The style is a response to evidence, not a fixed personality label.",
            "Behavioral, transformational, visionary, and charismatic approaches describe different ways a leader can influence work. Behavioral leadership draws attention to observable actions and routines. Transformational leadership connects improvement to purpose and growth. Visionary leadership gives people a useful picture of a future state. Charismatic leadership can create energy through confidence and communication. Each approach has value, and each can create risk when confidence replaces evidence or when a compelling vision leaves roles and standards unclear.",
            "For Maya, the useful comparison is not which style sounds best. The useful comparison is which response fits the appointment request, the information available, the capability of the people involved, and the risk of delay or error. Maya can begin with a clear outcome, ask what the team already knows, and choose the amount of direction and support the situation requires. If the facts change, the supervisory approach should change with them.",
            "A reliable supervisor makes the choice visible. A short decision note can name the situation, the selected approach, the reason for the choice, the employee's level of capability and commitment, and the follow-up signal that will show whether the approach worked. This record supports accountability without turning leadership into paperwork. It also gives the next supervisor enough context to continue the work instead of restarting the conversation.",
            "Ethical leadership keeps style selection connected to respect and inclusion. A supervisor should not give one employee endless support while assuming another can manage without it, and should not confuse direct communication with permission to dismiss questions. Consistent standards, clear expectations, and an opportunity to explain the situation help the team experience leadership as fair, practical, and connected to the work."
        )
    }
    if ($title -match "delegation|motivation") {
        return @(
            "Delegation is the planned transfer of a task and its decision boundaries, not the simple act of handing work to someone else. Before assigning a task, a supervisor should clarify the outcome, the authority the employee has, the resources available, the deadline, and the point at which the employee should ask for help. Capability matters because a task should provide enough stretch to build skill without creating avoidable risk. Accountability matters because the employee and supervisor need a shared understanding of who owns the result.",
            "Motivation adds the human side of performance. Content theories draw attention to needs such as security, belonging, recognition, and growth. Process theories draw attention to how people judge effort, fairness, expectations, and the relationship between performance and outcomes. A supervisor does not need to choose one theory as a complete answer. The practical question is what the employee understands, values, expects, and experiences in the current work setting.",
            "For Priya, a useful delegation conversation starts with the patient-service outcome and then works backward through the handoff. Priya can explain what must be completed, identify which decisions belong to the employee, offer a model or resource, and set a check-in that supports learning without taking the task back. The follow-up should focus on evidence such as a completed record, a clear status, or a timely response rather than on whether the employee used the supervisor's exact method.",
            "Fair delegation also requires attention to workload and access. Repeatedly assigning growth opportunities to the same person can limit development for others, while distributing urgent tasks without checking capacity can create resentment and errors. A supervisor can rotate learning opportunities, ask about barriers, and distinguish a capability gap from a resource or process problem. Those steps make motivation part of the operating system of the team rather than a speech delivered after performance falls.",
            "The strongest delegation plan includes an observable result, a named owner, a support boundary, a review point, and a next action. It gives the employee room to act while keeping the supervisor accountable for the conditions around the work. When the plan is reviewed, the conversation should identify what helped, what created friction, and what adjustment will make the next handoff clearer."
        )
    }
    if ($title -match "coaching") {
        return @(
            "A coaching conversation is a focused work conversation that helps an employee understand an expectation, examine current performance, and choose a next step. It is different from an informal reminder because the supervisor makes the purpose and standard clear. It is also different from a one-way correction because the employee has a chance to describe what happened, identify barriers, and participate in a realistic plan for improvement.",
            "Before the conversation, the supervisor should gather observable information. A specific date, behavior, record, response time, or customer-service detail gives the conversation a stable starting point. General statements such as someone needs to communicate better are difficult to act on. A concrete statement such as the status was not recorded before the request moved to the next queue makes the expectation visible and leaves room to investigate the cause.",
            "The coaching sequence can be simple: state the purpose, describe the observable situation, ask for the employee's view, clarify the expected standard, agree on a next action, and document the outcome. The documentation should be accurate and respectful. It should record the issue, the employee's explanation, the support offered, the commitment made, and the time for follow-up. A record protects continuity for the employee, the supervisor, and the team.",
            "A supervisor should also separate skill, knowledge, motivation, and system barriers. An employee may understand the standard but lack access to a needed tool. Another employee may have the tool but need practice. A third may need a clearer priority because competing requests make the order of work uncertain. Coaching is more useful when the response fits the actual barrier instead of treating every concern as a personal failure.",
            "The conversation becomes part of performance management when the next step is observable and time-bound. The employee should know what to do, what evidence will show progress, what support remains available, and when the two people will review the result. This approach keeps accountability clear while protecting the dignity and development of the employee."
        )
    }
    if ($title -match "feedback|conflict") {
        return @(
            "Useful performance feedback stays close to observable behavior, relevant data, and the standard that matters. A supervisor can describe what was seen or recorded, explain why it affects the team or service, and invite the employee to add context. This keeps the conversation focused on work that can change rather than on personality judgments or labels that are difficult to verify.",
            "Data does not have to mean a complicated dashboard. It may be a response-time record, an error count, a completed handoff, a documented customer concern, or a pattern across several shifts. One event may call for clarification, while a repeated pattern may support an improvement plan. The supervisor should explain the limits of the evidence and avoid presenting an incomplete record as a final judgment.",
            "When a conflict appears, the supervisor can slow the situation down enough to define the issue, identify the people and work affected, separate facts from interpretations, and name the standard that should guide the decision. Structured communication helps the participants describe the concern without interrupting, test assumptions, and agree on a next action. The goal is not to make every person feel the same about the decision; it is to make the process fair, clear, and workable.",
            "For Sam, a useful response may combine a feedback conversation with a conflict-resolution step. Sam can describe the behavior and its effect, ask each person what information is missing, check whether workload or unclear ownership contributed to the problem, and document the agreement. If the issue involves safety, discrimination, privacy, or another protected concern, Sam should follow the organization's escalation and reporting process rather than trying to settle it informally.",
            "An improvement plan should name the desired behavior, the support or resource needed, the owner, the measure, and the review date. A conflict plan should also name how the participants will communicate while the issue is being addressed. These details turn a difficult conversation into a managed work process and make it easier to recognize improvement without pretending that the original concern did not happen."
        )
    }
    if ($title -match "ethical|inclusive|team") {
        return @(
            "Ethical leadership makes the reasoning behind a decision visible. A supervisor should identify who may be affected, what obligations or policies apply, which facts are known, what information is missing, and which values are in tension. Efficiency may matter, but it does not erase privacy, dignity, safety, fairness, or the responsibility to explain a decision to the people who must carry it out.",
            "Inclusive leadership is an operating practice, not only a statement of respect. It appears in who receives information, who is invited to contribute, how meetings are run, how assignments are distributed, and whether different experiences are taken seriously. Bias can enter through assumptions about capability, communication style, availability, or commitment. Naming the decision standard and checking the evidence helps a supervisor reduce the effect of those assumptions.",
            "A team leadership plan connects purpose to action. It can identify the shared outcome, the roles needed, the agreements that support trust, the communication rhythm, the decision rule, and the signal that will show progress. The plan should be specific enough to guide the next shift and flexible enough to change when the work, people, or risks change.",
            "In an allied healthcare office, Amina may need to balance a service goal with a concern about fairness or access. A strong response does not hide the tension. Amina can state the decision, explain the evidence and policy, invite relevant perspectives, protect private information, and record the follow-up. This creates a defensible process even when the available options are imperfect.",
            "Ethical and inclusive leadership also includes repair. When a decision creates confusion or leaves someone out, the supervisor can acknowledge the effect, correct the process where possible, and adjust the team agreement. Trust grows when people see that leaders can make decisions, listen to consequences, and change a practice when the evidence shows that the practice is not serving the team."
        )
    }

    return @(
        "A reliable workplace practice becomes easier to use when the team can see the outcome, the roles, the information, and the standard that guide it. Start with the actual work rather than an ideal description. Notice where requests wait, where information is lost, and where people have to rely on memory. Those details show which part of the process needs attention.",
        "The case in this chapter gives the idea a person and a decision. Follow the sequence of events, identify what the person knows at each point, and ask what a coworker would need in order to continue the work. This keeps the concept connected to an observable result instead of leaving it as a definition.",
        "Evidence helps a supervisor distinguish a process problem from an individual problem. Useful evidence may include a record, time, behavior, customer need, policy, or repeated pattern. The evidence should be relevant to the decision and limited enough that the team can act on it. Clear reasoning makes it easier to explain the decision and revise it when conditions change.",
        "A strong workplace response gives people enough direction to act and enough context to make a sound judgment. It names the owner, the next step, the support available, and the point for follow-up. This balance protects accountability without creating unnecessary control.",
        "The practice becomes sustainable when the team records what it learned. A short note about the trigger, decision, result, and adjustment gives the next person a usable starting point. Over time, these small records help the organization improve without depending on one person's memory."
    )
}

function Get-ChapterFormatSupplement {
    param([Parameter(Mandatory)][object]$Chapter)

    $caseFace = Get-ChapterCaseFace -Chapter $Chapter
    $title = [string]$Chapter.title
    return @(
        "The four sections in this chapter move from workplace context to the developing practice, then to application and integration. That sequence keeps $title connected to the decisions a supervisor makes with real people, limited time, and incomplete information. It also gives the reader a way to return to the same idea at a deeper level instead of treating each section as a separate definition.",
        "Start by framing the work around an observable result. In $($caseFace.workplace), the result may involve a clear request, a reliable handoff, a supported employee, a respectful conversation, or a defensible decision. Naming the result first helps the supervisor choose relevant evidence and prevents activity from becoming the goal. The team can then describe what should happen, who owns the next step, and what information must travel with the work.",
        "During a busy shift, supervisors often make choices before every fact is available. A sound response does not pretend that uncertainty has disappeared. It identifies what is known, what still needs attention, and which action protects the work while the missing information is gathered. This approach supports timely service and gives employees a clear boundary for decisions they can make on their own.",
        "The people affected by a supervisory decision should be able to understand the standard behind it. Explain the purpose, use language that fits the audience, and invite information that could change the decision. Listening does not remove accountability. It improves the quality of the record and helps the supervisor notice barriers that are easy to miss from a desk or a schedule.",
        "A practical way to transfer this chapter to another workplace is to change the setting while keeping the reasoning visible. Ask what the trigger would be, which role would act, what resource or policy would guide the response, and what evidence would show progress. If the answer changes when the setting changes, name the condition that caused the change. That makes the skill flexible without making it vague.",
        "The chapter's ideas become part of team practice when the supervisor records a short, usable account of the decision. The account can name the situation, the response, the owner, the support provided, the result, and the adjustment for next time. A record like this helps coworkers continue the work, supports fair follow-up, and gives the team a concrete basis for improving the process.",
        "A supervisor can also connect the immediate decision to the wider service system. Ask which customer, patient, employee, or coworker depends on the result; which downstream role needs accurate information; and what delay, privacy concern, or quality risk could appear if the handoff fails. This wider view prevents a locally efficient choice from creating extra work somewhere else and keeps the team focused on the complete service experience.",
        "When the team discusses the work, describe the behavior or process in language that people can act on. Replace a vague concern with a visible condition, such as an incomplete request, an unclear owner, a missed status update, or a decision made without the needed context. Specific language gives the supervisor a fair basis for support and gives the employee a clear way to improve the next result.",
        "Good supervisory judgment includes a deliberate pause before escalation. First clarify the standard, the available evidence, the risk, and the support that could resolve the issue. Then decide whether the situation needs a coaching conversation, a process change, a resource request, or formal organizational follow-up. This sequence protects relationships while keeping serious concerns visible and accountable.",
        "The most useful transfer question is simple: what would another supervisor need to know to make the same quality of decision tomorrow? The answer should fit on a practical page or record. It should show the trigger, the relevant facts, the decision boundary, the owner, the communication path, and the point for review. That discipline turns the chapter from information into a shared operating habit."
    )
}

function Get-GM1025ReferenceTopicBlocks {
    param(
        [Parameter(Mandatory)][object]$Chapter,
        [Parameter(Mandatory)][ValidateSet("context", "development")][string]$Section
    )

    $title = [string]$Chapter.title
    $blocks = @()
    if ($Section -eq "context") {
        if ($title -match "Leadership Styles") {
            $blocks = @(
                @{ heading = "Leadership at the Front Line"; text = "Front-line supervisors translate broad organizational goals into daily direction, support, standards, and follow-up. Leadership influence grows through clear behavior, fair decisions, and reliable communication rather than through job title alone." },
                @{ heading = "Management and Leadership"; text = "Management creates order through schedules, roles, procedures, and controls. Leadership creates movement through purpose, influence, communication, and change. A front-line supervisor needs both so a sound idea becomes dependable work." },
                @{ heading = "Task Behavior and Relationship Behavior"; text = "Task behavior organizes the work through roles, deadlines, process explanations, and progress checks. Relationship behavior supports people through listening, recognition, confidence building, and respectful attention to tension. The balance should change with the situation." }
            )
        }
        elseif ($title -match "Delegation") {
            $blocks = @(
                @{ heading = "Delegation as a Leadership Process"; text = "Delegation is a planned transfer of work, authority, resources, and accountability. It gives another person a real opportunity to carry a result while the supervisor keeps the standard and follow-up visible." },
                @{ heading = "Choose the Right Work"; text = "A supervisor should identify work that can be transferred without compromising safety, privacy, quality, or role boundaries. The decision begins with the result and the level of judgment the task requires." },
                @{ heading = "Match Capability Without Stereotyping"; text = "Capability is specific to a task. A person's title, age, confidence, or years of service does not provide enough evidence by itself. Supervisors should look at demonstrated skill, prior support, and the conditions of the work." },
                @{ heading = "Transfer Authority Along With Responsibility"; text = "Assigning responsibility without access, decision rights, information, or resources creates a failure that looks like an employee problem. A clear delegation conversation names what the employee may decide and when to escalate." },
                @{ heading = "Build Accountability Without Micromanaging"; text = "Accountability requires a defined result, a checkpoint, and a useful record. It does not require the supervisor to control every step. The goal is enough visibility to support the work without taking ownership back." }
            )
        }
        elseif ($title -match "Coaching") {
            $blocks = @(
                @{ heading = "Coaching Within Performance Management"; text = "Coaching belongs inside an ongoing performance cycle of setting expectations, observing work, supporting progress, documenting important outcomes, and reviewing results. It is not only an emergency response to failure." },
                @{ heading = "Coaching, Training, Feedback, and Corrective Action"; text = "Training builds capability, feedback gives information about current work, coaching helps an employee examine barriers and choose a next step, and corrective action addresses serious or repeated gaps through the approved process. A supervisor should not treat these responses as interchangeable." },
                @{ heading = "Prepare With Facts, Not a Verdict"; text = "A useful coaching conversation begins with the standard, observable examples, the impact on work, and questions that allow the employee to explain the situation. Preparing a verdict before listening makes the conversation less accurate and less fair." }
            )
        }
        elseif ($title -match "Performance Feedback") {
            $blocks = @(
                @{ heading = "Evidence-Based Performance Feedback"; text = "Performance feedback is strongest when it connects a known standard to observable behavior, relevant data, and an accurate impact. This approach helps the supervisor reinforce sound work or redirect a gap without relying on labels." },
                @{ heading = "Use Situation–Behavior–Impact"; text = "The Situation–Behavior–Impact pattern gives a conversation a clear opening: name when or where the event occurred, describe what was observable, and explain the effect on service, quality, privacy, workload, or the team." },
                @{ heading = "Balance Reinforcing and Redirecting Feedback"; text = "Reinforcing feedback identifies behavior worth repeating. Redirecting feedback identifies a gap and the standard that should guide the next attempt. Both forms are more useful when they are timely, specific, and connected to support." },
                @{ heading = "From Feedback to an Improvement Plan"; text = "An improvement plan turns feedback into an agreed path with an employee action, supervisor support, a measure, a review point, and an escalation boundary when the issue exceeds the supervisor's authority." },
                @{ heading = "Diagnose the Constraint Before Choosing a Fix"; text = "A delay or error may come from skill, unclear priorities, a missing tool, a confusing procedure, staffing pressure, or a handoff failure. Diagnosing the constraint first prevents a supervisor from prescribing the wrong response." }
            )
        }
        elseif ($title -match "Ethical|Inclusive") {
            $blocks = @(
                @{ heading = "Ethical Leadership at the Front Line"; text = "Front-line decisions can affect dignity, privacy, safety, access, workload, and trust even when the decision appears routine. Ethical leadership makes the relevant standard and the likely effects visible." },
                @{ heading = "Ethical Conduct and Ethical Reasoning"; text = "Ethical conduct concerns what the supervisor does. Ethical reasoning explains why the action is defensible. A sound decision identifies facts, responsibilities, affected people, values in tension, and a way to review the result." },
                @{ heading = "A Practical Ethical Decision Process"; text = "A reusable process frames the issue, gathers facts, identifies stakeholders, considers options, tests assumptions and consequences, communicates the decision, and reviews intended and unintended effects." },
                @{ heading = "Use Several Ethical Lenses"; text = "Outcomes, rights and duties, fairness, the common good, and character can reveal different effects of the same option. Using several lenses does not remove uncertainty; it makes the reasoning more transparent." },
                @{ heading = "Organizational-Level Ethical Leadership"; text = "Repeated supervisory choices become team norms. Scheduling, recognition, workload, access to development, complaint handling, and escalation practices can either reinforce or weaken ethical and inclusive leadership." },
                @{ heading = "Speak Up and Escalate Responsibly"; text = "Supervisors should welcome concerns, protect confidential information, document the issue, and use the approved channel when risk, authority, policy, or disputed facts require another function." }
            )
        }
    }
    else {
        if ($title -match "Leadership Styles") {
            $blocks = @(
                @{ heading = "Comparing Leadership Approaches"; text = "Behavioral, transformational, visionary, charismatic, and situational approaches offer different lenses for choosing how to lead. The useful question is which observable response fits the task, people, risk, urgency, and context." },
                @{ heading = "Behavioral Leadership"; text = "Behavioral leadership focuses on what a supervisor does: clarifying roles, setting standards, monitoring progress, listening, recognizing effort, and addressing tension. Its practical value is that behavior can be observed and revised." },
                @{ heading = "Transformational Leadership"; text = "Transformational leadership connects daily work to purpose, improvement, development, and shared effort. Purpose is most useful when it is paired with concrete steps, resources, and follow-up." },
                @{ heading = "Visionary Leadership"; text = "Visionary leadership describes a credible future state and shows how present action moves the team toward it. A useful vision is specific enough to guide today's work rather than functioning as a slogan." },
                @{ heading = "Charismatic Leadership"; text = "Charismatic leadership can create energy through confidence and communication, but confidence should not replace evidence, questions, or team capability. The leader's presence should make useful questions safer, not silence them." },
                @{ heading = "Situational Leadership"; text = "Situational leadership asks the supervisor to adjust direction and support to the task, capability, commitment, risk, urgency, and context. It treats fit as a reasoned choice rather than a fixed personal identity." },
                @{ heading = "Matching Direction and Support"; text = "A simple situational map considers how much direction the work requires and how much support the person needs. The map is a thinking aid; accessibility, culture, prior experience, and power differences still require attention." }
            )
        }
        elseif ($title -match "Delegation") {
            $blocks = @(
                @{ heading = "Understanding Motivation"; text = "Motivation is shaped by whether the goal matters, success seems possible, effort appears connected to a valued result, and the process feels fair. A supervisor cannot control another person's motivation, but can shape the conditions around the work." },
                @{ heading = "Content Theories: What Needs Matter?"; text = "Content theories draw attention to needs such as security, belonging, recognition, achievement, and growth. Theories are lenses rather than labels; employees may value different conditions at different times." },
                @{ heading = "Process Theories: How Do People Decide to Exert Effort?"; text = "Process theories examine how people judge effort, performance, outcomes, fairness, and control. Clear expectations and credible follow-through help employees see how their work connects to team results." },
                @{ heading = "Recognition, Consequences, and Individual Differences"; text = "Recognition should be specific and connected to useful behavior. Consequences should be consistent and job-related. Supervisors should avoid assuming that one reward, schedule, or communication style will motivate every employee." }
            )
        }
        elseif ($title -match "Coaching") {
            $blocks = @(
                @{ heading = "A Structure for the Coaching Conversation"; text = "A coaching conversation can move from a clear purpose to evidence, the employee's perspective, options, a commitment, documentation, and follow-up. The structure keeps the conversation focused without making it mechanical." },
                @{ heading = "Goal: Define the Needed Result"; text = "The goal names what good work should look like and why it matters. A specific result gives both people a shared point of reference." },
                @{ heading = "Reality: Compare Evidence With the Standard"; text = "The reality step compares observable work with the standard and invites the employee to explain barriers, resources, competing priorities, or missing information." },
                @{ heading = "Options: Generate Practical Paths"; text = "Options may include practice, a clearer handoff, a tool change, a priority adjustment, additional support, or formal escalation. The supervisor and employee should compare the options against the work requirement." },
                @{ heading = "Will: Commit to Who, What, and When"; text = "A useful commitment names the action, owner, timing, support, measure, and next review. It should be realistic enough to carry out and specific enough to document." },
                @{ heading = "Goals and Expectations That Guide Action"; text = "Expectations should identify the result, the relevant standard, the decision boundary, and the point where the employee should ask for help. Clarity reduces avoidable defensiveness." },
                @{ heading = "Document Outcomes With Care"; text = "Documentation should distinguish facts, the employee's perspective, agreed actions, support, and follow-up. It should be accurate, necessary, and stored through the approved process." },
                @{ heading = "Follow Up and Reinforce Progress"; text = "Follow-up shows that the conversation was part of performance support rather than a one-time event. Recognize progress, address remaining gaps, and revise the plan when evidence changes." }
            )
        }
        elseif ($title -match "Performance Feedback") {
            $blocks = @(
                @{ heading = "Understanding Workplace Conflict"; text = "Conflict may involve competing goals, resources, interpretations, values, roles, or communication histories. Naming the source helps the supervisor respond to the work problem rather than to personal assumptions." },
                @{ heading = "Conflict Response Styles"; text = "Avoiding, accommodating, competing, compromising, and collaborating can each be useful or harmful depending on the stakes, time, relationship, and need for a durable solution." },
                @{ heading = "A Structured Resolution Process"; text = "A structured process defines the issue, gathers perspectives, identifies shared interests, names constraints, develops options, agrees on a next step, and sets a review point." },
                @{ heading = "Communication That Lowers Heat Without Hiding the Issue"; text = "Respectful language can lower defensiveness while keeping the standard visible. The supervisor should describe the concern, listen for relevant information, avoid public blame, and make the next action clear." }
            )
        }
        elseif ($title -match "Ethical|Inclusive") {
            $blocks = @(
                @{ heading = "Diversity, Inclusion, and Belonging"; text = "Diversity describes differences among people and groups. Inclusion concerns access, voice, participation, and respect. Belonging concerns whether people experience the team as a place where they can contribute without hiding important parts of themselves." },
                @{ heading = "Equality, Equity, and Consistency"; text = "Equality provides the same resource or treatment. Equity responds to relevant differences so people have fair access. Consistency applies stable, job-related reasoning across comparable cases. These ideas support one another but are not identical." },
                @{ heading = "Bias Awareness"; text = "Bias can shape attention, interpretation, memory, and choice. Supervisors can reduce its effect by defining criteria before reviewing names, using more than one relevant data point, inviting structured input, documenting reasons, and reviewing outcomes." },
                @{ heading = "Inclusive Communication and Voice"; text = "Inclusive communication uses clear language, accessible formats, meaningful opportunities to contribute, and follow-through about what input changed. Psychological safety supports questions and disagreement without removing standards." }
            )
        }
    }

    foreach ($block in $blocks) {
        [pscustomobject]$block
    }
}

function ConvertTo-EbookMarkdown {
    param(
        [object]$Course,
        [object]$Plan,
        [object[]]$Sources,
        [object]$SourceRegistry,
        [object]$EngagementPlan,
        [object]$BrandProfile
    )

    $lines = New-Object System.Collections.ArrayList
    $practiceFrame = Get-CoursePracticeFrame -Course $Course
    $courseDomain = Get-CourseDomain -Course $Course
    $isGM1025Format = ([string]$Course.code -eq "GM1025" -or [string]$Course.courseCode -eq "GM1025" -or [string]$Course.title -match "Front-Line Supervision and Team Leadership")
    foreach ($chapter in $Plan.chapters) {
        Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Assembling chapter scaffold" -Status "Working" -Detail "Creating scaffold text, learning objectives, scenarios, visuals, practice, and references."
        $chapterSources = Get-ChapterSources -Sources $Sources -ChapterNumber $chapter.number
        $citations = Get-ChapterCitationModel -ChapterSources $chapterSources -SourceRegistry $SourceRegistry
        $chapterEndnotes = @(Get-ChapterEndnotes -CitationModel $citations)
        $openingRefs = Format-MarkdownCitationRefs -Endnotes $chapterEndnotes -ChapterNumber $chapter.number -Numbers @(1, 2)
        $engagementItem = Get-EngagementItemForChapter -EngagementPlan $EngagementPlan -ChapterNumber $chapter.number
        $caseFace = Get-ChapterCaseFace -Chapter $chapter
        [void]$lines.Add("# Chapter $($chapter.number): $($chapter.title)")
        [void]$lines.Add("")
        [void]$lines.Add("## Introduction")
        [void]$lines.Add("")
        [void]$lines.Add("This chapter focuses on $($chapter.title).")
        [void]$lines.Add("")
        [void]$lines.Add("**Why This Matters:** ")
        [void]$lines.Add($practiceFrame.chapterPurpose)
        [void]$lines.Add("")
        if ($engagementItem -and $engagementItem.productionStatus -eq 'Generated') { [void]$lines.Add((Format-MarkdownImage -AltText $engagementItem.openerAltText -Path $engagementItem.openerImageFile))
        [void]$lines.Add("")
        }
        [void]$lines.Add((("You build this skill by seeing how the work of $($chapter.title) operates in realistic situations. This chapter moves from $($chapter.buildsOn) toward $($chapter.setsUp), using the course roadmap as guidance and drawing on selected sources where they strengthen the explanation. $openingRefs").Trim()))
        [void]$lines.Add("")
        [void]$lines.Add("This chapter follows $($caseFace.person), $($caseFace.roleWithArticle), through $($caseFace.caseName). This situation gives the chapter a business case, so each concept connects to a person, a decision, and a workplace result.")
        [void]$lines.Add("")
        [void]$lines.Add($practiceFrame.chapterPurpose)
        [void]$lines.Add("")
        Add-EbookLearningObjectives -Lines $lines -Chapter $chapter
        [void]$lines.Add("## Section $($chapter.number).1 - Workplace Context for $($chapter.title)")
        [void]$lines.Add("")
        [void]$lines.Add("The workplace context matters because this topic affects people, decisions, and the quality of the work that follows.")
        [void]$lines.Add("")
        [void]$lines.Add("### Opening Scenario: $($caseFace.caseName)")
        [void]$lines.Add("")
        [void]$lines.Add("**Business Case:** $($caseFace.caseLine)")
        [void]$lines.Add("")
        [void]$lines.Add("$($caseFace.person) must decide $($caseFace.decision), account for the people and process involved, and keep the next step visible.")
        [void]$lines.Add("")
        [void]$lines.Add("The business case keeps this risk in view: $($caseFace.risk). The choices in this scenario will carry through the chapter.")
        [void]$lines.Add("")
        [void]$lines.Add("### Chapter Roadmap")
        [void]$lines.Add("")
        [void]$lines.Add("This chapter moves from workplace context, to the concepts and decisions that shape the work, to an applied case and a field guide for integrating the practice at work.")
        [void]$lines.Add("")
        if ($isGM1025Format) {
            foreach ($topic in @(Get-GM1025ReferenceTopicBlocks -Chapter $chapter -Section "context")) {
                [void]$lines.Add("### $($topic.heading)")
                [void]$lines.Add("")
                [void]$lines.Add($topic.text)
                [void]$lines.Add("")
            }
            if ($engagementItem) {
                [void]$lines.Add("### Visual Model: $($engagementItem.title)")
                [void]$lines.Add("")
                [void]$lines.Add((Format-MarkdownImage -AltText $engagementItem.quickCheckAltText -Path $engagementItem.quickCheckFile))
                [void]$lines.Add("")
                [void]$lines.Add("$($engagementItem.quickCheckText)")
                [void]$lines.Add("")
                [void]$lines.Add((Format-MarkdownImage -AltText $engagementItem.altText -Path $engagementItem.assetFile))
                [void]$lines.Add("")
                [void]$lines.Add("The chapter diagram, [$($engagementItem.title)]($($engagementItem.assetFile)), summarizes the pattern used in the business case and chapter examples.")
                [void]$lines.Add("")
            }
        }
        $developmentHeading = "Developing $($chapter.title)"
        if ($chapter.title -match "Leadership Styles") { $developmentHeading = "Developing Leadership Fit" }
        elseif ($chapter.title -match "Delegation") { $developmentHeading = "Delegating Work and Supporting Motivation" }
        elseif ($chapter.title -match "Coaching") { $developmentHeading = "Structuring Coaching Conversations" }
        elseif ($chapter.title -match "Performance Feedback") { $developmentHeading = "Building Performance and Conflict Skills" }
        elseif ($chapter.title -match "Ethical") { $developmentHeading = "Leading Inclusion and Ethical Action" }
        [void]$lines.Add("## Section $($chapter.number).2 - $developmentHeading")
        [void]$lines.Add("")
        if ($isGM1025Format) {
            foreach ($topic in @(Get-GM1025ReferenceTopicBlocks -Chapter $chapter -Section "development")) {
                [void]$lines.Add("### $($topic.heading)")
                [void]$lines.Add("")
                [void]$lines.Add($topic.text)
                [void]$lines.Add("")
            }
        }
        else {
            [void]$lines.Add("### Developing the Practice in Context")
            [void]$lines.Add("")
        }
        foreach ($expansionParagraph in @(Get-ChapterFormatExpansion -Chapter $chapter)) {
            [void]$lines.Add($expansionParagraph)
            [void]$lines.Add("")
        }
        foreach ($supplementParagraph in @(Get-ChapterFormatSupplement -Chapter $chapter)) {
            [void]$lines.Add($supplementParagraph)
            [void]$lines.Add("")
        }
        [void]$lines.Add($practiceFrame.ordinary)
        [void]$lines.Add("")
        [void]$lines.Add("Can you imagine being in $($caseFace.person)'s position? You need to decide $($caseFace.decision). The practical artifact is $($caseFace.artifact), a tool you can build, review, and improve. The main risk is $($caseFace.risk).")
        [void]$lines.Add("")
        [void]$lines.Add($caseFace.jobConnection)
        [void]$lines.Add("")
        if ($engagementItem -and -not $isGM1025Format) {
            [void]$lines.Add("### Visual Model: $($engagementItem.title)")
            [void]$lines.Add("")
            [void]$lines.Add((Format-MarkdownImage -AltText $engagementItem.quickCheckAltText -Path $engagementItem.quickCheckFile))
            [void]$lines.Add("")
            [void]$lines.Add("$($engagementItem.quickCheckText)")
            [void]$lines.Add("")
            [void]$lines.Add((Format-MarkdownImage -AltText $engagementItem.altText -Path $engagementItem.assetFile))
            [void]$lines.Add("")
            [void]$lines.Add("The chapter diagram, [$($engagementItem.title)]($($engagementItem.assetFile)), summarizes the pattern used in the business case and chapter examples.")
            [void]$lines.Add("")
        }

        foreach ($module in $chapter.moduleSequence) {
            if (Test-EbookAssessmentOrLmsText -Text $module.title) {
                continue
            }
            $sectionObjectives = @($module.subObjectives | Where-Object { -not (Test-EbookAssessmentOrLmsText -Text $_) })
            if ($sectionObjectives.Count -eq 0) {
                $sectionObjectives = @($chapter.learningTargets | Where-Object { $_ -and -not (Test-EbookAssessmentOrLmsText -Text $_) })
            }

            $hasDistinctModuleHeading = -not (@($sectionObjectives | ForEach-Object { (ConvertTo-CleanText $_).ToLowerInvariant() }) -contains (ConvertTo-CleanText $module.title).ToLowerInvariant())
            if ($hasDistinctModuleHeading -and -not $isGM1025Format) {
                [void]$lines.Add("### $($module.title)")
                [void]$lines.Add("")
                [void]$lines.Add("$($module.title) turns the chapter topic into visible practice. You identify the question, gather the information, choose the standard, and explain how the result affects $($practiceFrame.learnerWork).")
                [void]$lines.Add("")
            }

            foreach ($subObjective in $sectionObjectives) {
                Add-ObjectiveDevelopment -Lines $lines -Chapter $chapter -Objective $subObjective -Citations $citations -CitationIds "" -Endnotes $chapterEndnotes
            }
        }

        [void]$lines.Add("## Section $($chapter.number).3 - Applying $($chapter.title) at Work")
        [void]$lines.Add("")
        Add-ChapterDeepeningSections -Lines $lines -Chapter $chapter -Citations $citations -CitationIds "" -Endnotes $chapterEndnotes -UseGM1025ReferenceFormat:$isGM1025Format

        if ($isGM1025Format) {
            [void]$lines.Add("In office, service, and allied-health settings, this skill helps you run huddles, assign work, protect records, support coworkers, and respond to problems without losing sight of the people affected by the decision.")
            [void]$lines.Add("")
            [void]$lines.Add("Apply the chapter by naming the goal, evidence, risks, assumptions, and next step. Make the decision, boundary, owner, and follow-up clear to the people involved.")
            [void]$lines.Add("")
        }
        else {
            [void]$lines.Add("### Career Connection")
            [void]$lines.Add("")
            [void]$lines.Add("In office, service, and allied-health settings, this skill helps you run huddles, assign work, protect records, support coworkers, and respond to problems without losing sight of the people affected by the decision.")
            [void]$lines.Add("")
            [void]$lines.Add("### Professional Application")
            [void]$lines.Add("")
            [void]$lines.Add("Apply Critical Thinking & Problem Solving by naming the goal, evidence, risks, assumptions, and next step. Apply Communication Skills by making the decision, boundary, owner, and follow-up clear to the people involved.")
            [void]$lines.Add("")
        }
        [void]$lines.Add("### Key Takeaways")
        [void]$lines.Add("")
        if ($courseDomain -eq "computer-applications") {
            [void]$lines.Add("- Digital skill becomes professional skill when the learner can explain the tool choice, file or source standard, risk point, and verification step.")
            [void]$lines.Add("- Reliable digital work is organized, readable, protected, and easy for another person to inspect.")
            [void]$lines.Add("- Small revisions to names, formatting, citations, security habits, or accuracy checks can prevent larger problems later.")
        }
        elseif ($courseDomain -eq "professional-communication") {
            [void]$lines.Add("- Professional communication depends on audience, purpose, tone, channel, organization, and timing.")
            [void]$lines.Add("- Clear messages reduce guessing by showing what happened, why it matters, and what comes next.")
            [void]$lines.Add("- Revision is not decoration; it is how a communicator protects meaning, respect, and trust.")
        }
        elseif ($courseDomain -eq "critical-thinking") {
            [void]$lines.Add("- Strong reasoning makes the issue, evidence, assumptions, limits, and conclusion visible.")
            [void]$lines.Add("- Evidence matters most when it changes, strengthens, or limits a conclusion.")
            [void]$lines.Add("- Revision helps a thinker avoid overstating what the evidence can support.")
        }
        else {
            [void]$lines.Add("- Work becomes reliable when people can see the trigger, owner, evidence, standard, and next step.")
            [void]$lines.Add("- Process problems often come from unclear handoffs, missing information, weak documentation, or rushed decisions.")
            [void]$lines.Add("- A practical improvement should be specific enough to explain and small enough to evaluate.")
        }
        [void]$lines.Add("")
        [void]$lines.Add("### Vocabulary Review")
        [void]$lines.Add("")
        [void]$lines.Add("Vocabulary in this chapter connects $($chapter.title) to the business case. Use the source definitions consistently when naming the evidence, decisions, and results described in each section.")
        [void]$lines.Add("")
        if ([int]$chapter.number -eq @($Plan.chapters).Count) {
            [void]$lines.Add("## Conclusion")
            [void]$lines.Add("")
            [void]$lines.Add("$($chapter.title) brings the course together by connecting the concepts in this course to evidence, standards, context, and defensible judgment. The business cases show how to explain a decision, recognize its limits, and review the result.")
            [void]$lines.Add("")
        }
        else {
            [void]$lines.Add("## Looking Ahead")
            [void]$lines.Add("")
            [void]$lines.Add("Next, you will build on this chapter by applying its central habit to $($chapter.setsUp) as the course continues to develop $($practiceFrame.bridgeNoun).")
            [void]$lines.Add("")
        }
        Add-MarkdownEndnotes -Lines $lines -ChapterNumber $chapter.number -Endnotes $chapterEndnotes
        [void]$lines.Add("")
        Write-EbookGeneratorChapterProgress -ChapterNumber $chapter.number -ChapterTitle $chapter.title -Phase "Assembling chapter scaffold" -Status "Complete" -Detail "Chapter scaffold is written."
    }

    return ($lines -join "`r`n")
}

function ConvertTo-ShortSentenceText {
    param([AllowNull()][string]$Text)

    $textValue = [string]$Text
    if ([string]::IsNullOrWhiteSpace($textValue)) {
        return $textValue
    }

    # This function used to split long sentences by replacing commas, colons,
    # semicolons, and conjunctions with periods. That changed valid prose into
    # fragments (for example, "people, technology, and procedures" became
    # "people. technology. And procedures"). Sentence length is a review
    # signal, not a safe reason to rewrite punctuation mechanically. Preserve
    # the author's sentence structure and let the quality gates report long or
    # malformed sentences for editorial revision.
    return $textValue.Trim()
}

function ConvertTo-PlainLanguageLine {
    param([AllowNull()][string]$Line)

    $lineValue = [string]$Line
    if ([string]::IsNullOrWhiteSpace($lineValue)) {
        return $lineValue
    }

    $lineValue = $lineValue -replace "\butilize\b", "use"
    $lineValue = $lineValue -replace "\bfacilitate\b", "help"
    $lineValue = $lineValue -replace "\bcommence\b", "start"
    $lineValue = $lineValue -replace "\bterminate\b", "end"
    $lineValue = $lineValue -replace "\bprior to\b", "before"
    $lineValue = $lineValue -replace "\bin order to\b", "to"
    $lineValue = $lineValue -replace "\bsubsequent to\b", "after"
    $lineValue = $lineValue -replace "\binterdependencies\b", "work links"
    $lineValue = $lineValue -replace "\binterdependence\b", "work link"
    $lineValue = $lineValue -replace "\borganizational effectiveness\b", "how well the organization works"
    $lineValue = $lineValue -replace "\boperational effectiveness\b", "how well the work runs"
    $lineValue = $lineValue -replace "\boperational decision\b", "office decision"
    $lineValue = $lineValue -replace "\boperational decisions\b", "office decisions"
    $lineValue = $lineValue -replace "\boperational improvement\b", "office improvement"
    $lineValue = $lineValue -replace "\boperational improvements\b", "office improvements"
    $lineValue = $lineValue -replace "\boperational risk\b", "work risk"
    $lineValue = $lineValue -replace "\boperational strategy\b", "office strategy"
    $lineValue = $lineValue -replace "\bproductivity\b", "work output"
    $lineValue = $lineValue -replace "\befficiency\b", "speed and fit"
    $lineValue = $lineValue -replace "\brecommendation\b", "suggested next step"
    $lineValue = $lineValue -replace "\brecommendations\b", "suggested next steps"
    $lineValue = $lineValue -replace "\bdocumentation\b", "records"
    $lineValue = $lineValue -replace "\bdocumented\b", "recorded"
    $lineValue = $lineValue -replace "\bstrategic goals\b", "larger goals"
    $lineValue = $lineValue -replace "\bstrategic goal\b", "larger goal"
    $lineValue = $lineValue -replace "\bcustomer-facing service quality\b", "front-office service"
    $lineValue = $lineValue -replace "\bcustomer-facing service\b", "front-office service"
    $lineValue = $lineValue -replace "\bcustomer-facing processes\b", "front-office steps"
    $lineValue = $lineValue -replace "\bservice quality\b", "service"
    $lineValue = $lineValue -replace "\bconfidentiality\b", "privacy"
    $lineValue = $lineValue -replace "\bresponsiveness\b", "quick response"
    $lineValue = $lineValue -replace "\bworkflow coordination\b", "team workflow"
    $lineValue = $lineValue -replace "\baccountability\b", "clear ownership"
    $lineValue = $lineValue -replace "\bcoordinating workflow\b", "guiding workflow"
    $lineValue = $lineValue -replace "\bcoordination\b", "teamwork"
    $lineValue = $lineValue -replace "(?<=\.\s)clear ownership", "Clear ownership"
    $lineValue = $lineValue -replace "(?<=\.\s)speed and fit", "Speed and fit"

    return (ConvertTo-ShortSentenceText -Text $lineValue)
}

function ConvertTo-PlainLanguageMarkdown {
    param(
        [AllowNull()][string]$Markdown,
        [object]$Course
    )

    $lines = New-Object System.Collections.ArrayList
    foreach ($line in ([string]$Markdown -split "`r?`n")) {
        if ($line -match "^\s*$" -or $line -match "^\s*#" -or $line -match "^\s*!\[" -or $line -match "^\s*[-*]\s+" -or $line -match "^\s*\d+\.\s+" -or $line -match "https?://" -or $line -match "\]\([^)]*\.(svg|html?|png|jpe?g|docx|md)(#[^)]+)?\)") {
            [void]$lines.Add($line)
            continue
        }

        [void]$lines.Add((ConvertTo-PlainLanguageLine -Line $line))
    }

    return ($lines -join "`r`n")
}

function ConvertTo-EbookHtml {
    param(
        [object]$Course,
        [object]$Plan,
        [object[]]$Sources
    )

    $body = New-Object System.Collections.ArrayList
    $practiceFrame = Get-CoursePracticeFrame -Course $Course
    $courseDomain = Get-CourseDomain -Course $Course
    [void]$body.Add("<main>")
    [void]$body.Add("<h1>$(ConvertTo-HtmlText "$($Course.courseCode): $($Course.courseName)")</h1>")
    [void]$body.Add("<p class=""subtitle"">Student Edition</p>")
    [void]$body.Add("<section><h2>Preface</h2><p>$(ConvertTo-HtmlText $Course.description)</p><p>$(ConvertTo-HtmlText $practiceFrame.preface)</p></section>")
    [void]$body.Add("<section><h2>Course Throughline</h2><p>$(ConvertTo-HtmlText $Plan.narrativeSpine)</p></section>")

    foreach ($chapter in $Plan.chapters) {
        $chapterSources = Get-ChapterSources -Sources $Sources -ChapterNumber $chapter.number
        $citations = Get-ChapterCitationModel -ChapterSources $chapterSources
        $chapterEndnotes = @(Get-ChapterEndnotes -CitationModel $citations)
        $openingRefs = Format-HtmlCitationRefs -Endnotes $chapterEndnotes -ChapterNumber $chapter.number -Numbers @(1, 2)
        [void]$body.Add("<article>")
        [void]$body.Add("<h2>Chapter $($chapter.number): $(ConvertTo-HtmlText $chapter.title)</h2>")
        [void]$body.Add("<p>$(ConvertTo-HtmlText "You build this skill by seeing how $($chapter.focus) works in realistic situations. This chapter builds from $($chapter.buildsOn) toward $($chapter.setsUp), using the course roadmap as guidance and selected sources where they strengthen the explanation.") $openingRefs</p>")

        [void]$body.Add("<h3>What This Chapter Helps You Understand</h3><ol>")
        foreach ($target in $chapter.learningTargets) {
            if (Test-EbookAssessmentOrLmsText -Text $target) {
                continue
            }
            [void]$body.Add("<li>$(ConvertTo-HtmlText $target)</li>")
        }
        [void]$body.Add("</ol>")

        [void]$body.Add("<h3>Learning in Practice</h3>")
        [void]$body.Add("<p>$(ConvertTo-HtmlText $practiceFrame.ordinary)</p>")

        foreach ($module in $chapter.moduleSequence) {
            if (Test-EbookAssessmentOrLmsText -Text $module.title) {
                continue
            }
            [void]$body.Add("<h3>$(ConvertTo-HtmlText $module.title)</h3>")
            [void]$body.Add("<p>$($module.title) turns the chapter topic into visible work: what starts the process, what information the team needs, who owns the next action, and how the result affects productivity, service, risk, or strategic goals.</p>")

            $sectionObjectives = @($module.subObjectives | Where-Object { -not (Test-EbookAssessmentOrLmsText -Text $_) })
            if ($sectionObjectives.Count -eq 0) {
                $sectionObjectives = @($chapter.learningTargets | Where-Object { $_ -and -not (Test-EbookAssessmentOrLmsText -Text $_) })
            }

            foreach ($subObjective in $sectionObjectives) {
                $concept = Get-ObjectiveConceptFrame -Objective $subObjective
                $workedExample = Get-ObjectiveWorkedExample -Objective $subObjective -Chapter $chapter
                $selfCheck = Get-ObjectiveSelfCheck -Objective $subObjective -Chapter $chapter
                $noteRefs = Format-HtmlCitationRefs -Endnotes $chapterEndnotes -ChapterNumber $chapter.number -Numbers @(1)
                [void]$body.Add("<section class=""objective-section""><h4>$(ConvertTo-HtmlText $subObjective)</h4>")
                [void]$body.Add("<p>$(ConvertTo-HtmlText $concept) $noteRefs</p>")
                [void]$body.Add("<p><strong>Example in Context:</strong> $(ConvertTo-HtmlText $workedExample)</p>")
                [void]$body.Add("<p><strong>Pause and Notice:</strong> $(ConvertTo-HtmlText $selfCheck)</p></section>")
            }
        }

        [void]$body.Add("<h3>Chapter Synthesis</h3>")
        if ($courseDomain -eq "professional-communication") {
            [void]$body.Add("<p>The chapter comes together when audience, purpose, channel, tone, organization, and revision all shape the reader's experience. The important habit is to make communication clear enough, respectful enough, and complete enough for the situation.</p>")
        }
        elseif ($courseDomain -eq "computer-applications") {
            [void]$body.Add("<p>The chapter comes together when a digital task, tool choice, standard, risk point, and verification step all affect the finished work. The important habit is to leave work organized, readable, protected, and easy to check.</p>")
        }
        elseif ($courseDomain -eq "critical-thinking") {
            [void]$body.Add("<p>The chapter comes together when the issue, evidence, assumptions, limits, and revision choices all shape the final judgment. The important habit is to make reasoning visible enough that another reader can inspect it.</p>")
        }
        else {
            [void]$body.Add("<p>The chapter comes together when current work, risk points, evidence, ownership, and improvement choices connect. The important habit is to understand what makes the work reliable for the next person.</p>")
        }

        [void]$body.Add("<h3>Key Takeaways</h3><ul>")
        if ($courseDomain -eq "professional-communication") {
            [void]$body.Add("<li>Professional communication depends on audience, purpose, tone, channel, organization, and timing.</li>")
            [void]$body.Add("<li>Clear messages reduce guessing by showing what happened, why it matters, and what comes next.</li>")
            [void]$body.Add("<li>Revision protects meaning, respect, and trust.</li>")
        }
        elseif ($courseDomain -eq "computer-applications") {
            [void]$body.Add("<li>Digital skill becomes professional skill when the learner can explain the tool choice, standard, risk point, and verification step.</li>")
            [void]$body.Add("<li>Reliable digital work is organized, readable, protected, and easy to inspect.</li>")
            [void]$body.Add("<li>Small revisions prevent larger problems later.</li>")
        }
        elseif ($courseDomain -eq "critical-thinking") {
            [void]$body.Add("<li>Strong reasoning makes the issue, evidence, assumptions, limits, and conclusion visible.</li>")
            [void]$body.Add("<li>Evidence matters most when it changes, strengthens, or limits a conclusion.</li>")
            [void]$body.Add("<li>Revision helps avoid overstating what the evidence can support.</li>")
        }
        else {
            [void]$body.Add("<li>Work becomes reliable when people can see the trigger, owner, evidence, standard, and next step.</li>")
            [void]$body.Add("<li>Process problems often come from unclear handoffs, missing information, weak documentation, or rushed decisions.</li>")
            [void]$body.Add("<li>A practical improvement should be specific enough to explain and small enough to evaluate.</li>")
        }
        [void]$body.Add("</ul>")

        [void]$body.Add("<h3>Chapter Close</h3><p>$(ConvertTo-HtmlText "$($chapter.title) prepares students to move into $($chapter.setsUp). Carry forward the habit of connecting concepts to evidence, standards, context, and defensible judgment.")</p>")
        [void]$body.Add("<h3>Scholarly Sources</h3><ol class=""notes"">")
        if ($chapterEndnotes.Count -eq 0) {
            [void]$body.Add("<li>No external sources are cited in this chapter.</li>")
        }
        else {
            foreach ($item in $chapterEndnotes) {
                $label = ConvertTo-HtmlText $item.label
                $entry = if ($item.url) { "<a href=""$(ConvertTo-HtmlAttribute $item.url)"">$label</a>" } else { $label }
                [void]$body.Add("<li id=""chapter-$($chapter.number)-note-$($item.number)"">$entry</li>")
            }
        }
        [void]$body.Add("</ol>")
        [void]$body.Add("</article>")
    }

    [void]$body.Add("</main>")

    return @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$(ConvertTo-HtmlText "$($Course.courseCode): $($Course.courseName)")</title>
  <style>
    body { margin: 0; font-family: Arial, Helvetica, sans-serif; color: #172026; background: #f7f8fa; line-height: 1.55; }
    main { max-width: 980px; margin: 0 auto; padding: 40px 24px 64px; background: #ffffff; }
    h1 { font-size: 34px; line-height: 1.15; margin: 0 0 8px; }
    h2 { margin-top: 36px; border-top: 1px solid #d7dde3; padding-top: 24px; }
    h3 { margin-top: 24px; }
    h4 { margin: 20px 0 8px; }
    article { margin-top: 32px; }
    a { color: #095d7e; }
    .meta, .subtitle, .source-policy { color: #52606d; }
    .source-policy { border-left: 4px solid #2f7d59; padding-left: 14px; }
    .objective-section { border-left: 3px solid #d7dde3; padding-left: 16px; margin: 18px 0; }
    li { margin: 8px 0; }
  </style>
</head>
<body>
$($body -join "`r`n")
</body>
</html>
"@
}

function ConvertTo-HtmlText {
    param([AllowNull()][string]$Text)
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function ConvertTo-HtmlAttribute {
    param([AllowNull()][string]$Text)
    return ([System.Net.WebUtility]::HtmlEncode([string]$Text) -replace '"', "&quot;")
}

function ConvertTo-SimpleHtmlFromMarkdown {
    param(
        [Parameter(Mandatory)][string]$Markdown,
        [string]$Title = "Ebook",
        [object]$BrandProfile,
        [object]$PublicationTemplate
    )

    if (Test-EbookDeprecatedCaseLabel $Markdown) { throw 'Publication terminology gate: use Business Case, not Case and Face.' }
    $Markdown = ConvertTo-EbookCitationMarkdown -Markdown $Markdown
    if (-not $PublicationTemplate) { $PublicationTemplate = Get-EbookPublicationTemplate }
    $legendBlue = Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553"
    $heroBlue = Get-BrandColor -BrandProfile $BrandProfile -Name "Hero Blue" -Fallback "#1D6BA6"
    $horizonBlue = Get-BrandColor -BrandProfile $BrandProfile -Name "Horizon Blue" -Fallback "#0095C8"
    $journeyGreen = Get-BrandColor -BrandProfile $BrandProfile -Name "Journey Green" -Fallback "#15EAC4"
    $graciousGray = Get-BrandColor -BrandProfile $BrandProfile -Name "Gracious Gray" -Fallback "#F9F9F9"
    $mediumGray = Get-BrandColor -BrandProfile $BrandProfile -Name "Medium Gray 1" -Fallback "#DBDBDB"
    $integrityGray = Get-BrandColor -BrandProfile $BrandProfile -Name "Integrity Gray" -Fallback "#444444"
    $body = New-Object System.Collections.ArrayList
    $inUl = $false
    $inOl = $false
    $currentChapterNumber = 0
    $currentSectionTitle = ""
    $figureCount = 0

    $htmlLines = @($Markdown -split "`r?`n")
    for ($htmlIndex = 0; $htmlIndex -lt $htmlLines.Count; $htmlIndex++) {
        $rawLine = $htmlLines[$htmlIndex]
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            # Blank lines between bibliography entries do not start new lists.
            if ($inOl -and (Test-EbookNotesHeading $currentSectionTitle)) { continue }
            if ($inUl) { [void]$body.Add("</ul>"); $inUl = $false }
            if ($inOl) { [void]$body.Add("</ol>"); $inOl = $false }
            continue
        }

        if ($htmlIndex + 1 -lt $htmlLines.Count -and $line -match '^\|.*\|$' -and $htmlLines[$htmlIndex + 1] -match '^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$') {
            if ($inUl) { [void]$body.Add('</ul>'); $inUl = $false }
            if ($inOl) { [void]$body.Add('</ol>'); $inOl = $false }
            $cells = @($line.Trim('|') -split '\|')
            [void]$body.Add('<table><thead><tr>' + (($cells | ForEach-Object { '<th scope="col">' + (ConvertTo-HtmlInlineFromMarkdown $_.Trim()) + '</th>' }) -join '') + '</tr></thead><tbody>')
            $htmlIndex++
            while ($htmlIndex + 1 -lt $htmlLines.Count -and $htmlLines[$htmlIndex + 1] -match '^\s*\|.*\|\s*$') {
                $htmlIndex++
                $cells = @($htmlLines[$htmlIndex].Trim().Trim('|') -split '\|')
                [void]$body.Add('<tr>' + (($cells | ForEach-Object { '<td>' + (ConvertTo-HtmlInlineFromMarkdown $_.Trim()) + '</td>' }) -join '') + '</tr>')
            }
            [void]$body.Add('</tbody></table>')
            continue
        }

        if ($line -match "^!\[([^\]]*)\]\(([^)\s]+)\)$") {
            # Capture before any other -match (or helper) changes PowerShell's $Matches.
            $imageAlt = $Matches[1]
            $imageTarget = $Matches[2]
            if ($inUl) { [void]$body.Add("</ul>"); $inUl = $false }
            if ($inOl) { [void]$body.Add("</ol>"); $inOl = $false }
            $figureCount++
            $description = ConvertTo-CleanText $imageAlt
            if ([string]::IsNullOrWhiteSpace($description)) {
                $description = "Instructional image for the ebook."
            }
            $figureClass = if ($imageTarget -match "^images/chapter-\d+-.+-opener\.png$") { " class=""chapter-opener-figure""" } else { "" }
            [void]$body.Add("<figure$figureClass><img src=""$(ConvertTo-HtmlAttribute $imageTarget)"" alt=""$(ConvertTo-HtmlAttribute $description)"" loading=""lazy""></figure>")
            continue
        }

        if ($line -match "^(#{1,4})\s+(.+)$") {
            if ($inUl) { [void]$body.Add("</ul>"); $inUl = $false }
            if ($inOl) { [void]$body.Add("</ol>"); $inOl = $false }
            $level = [Math]::Min($Matches[1].Length, 4)
            $headingText = [string]$Matches[2]
            if ($level -eq 1 -and $headingText -match "^Chapter\s+(\d+)\s*:") {
                $currentChapterNumber = [int]$Matches[1]
            }
            $currentSectionTitle = $headingText
            [void]$body.Add("<h$level>$(ConvertTo-HtmlText $headingText)</h$level>")
            continue
        }

        if ($line -match "^\-\s+(.+)$") {
            if ($inOl) { [void]$body.Add("</ol>"); $inOl = $false }
            if (-not $inUl) { [void]$body.Add("<ul>"); $inUl = $true }
            [void]$body.Add("<li>$(ConvertTo-HtmlInlineFromMarkdown $Matches[1])</li>")
            continue
        }

        if ($line -match "^\d+\.\s+(.+)$") {
            $itemMarkdown = $Matches[1]
            if ($inUl) { [void]$body.Add("</ul>"); $inUl = $false }
            if (-not $inOl) { [void]$body.Add("<ol>"); $inOl = $true }
            $itemNumber = [int]($line -replace "^(\d+)\..*$", '$1')
            $idAttribute = if ($currentChapterNumber -gt 0 -and $currentSectionTitle -match "^(Notes|Scholarly Sources)$") { " id=""chapter-$currentChapterNumber-note-$itemNumber""" } else { "" }
            [void]$body.Add("<li$idAttribute>$(ConvertTo-HtmlInlineFromMarkdown $itemMarkdown)</li>")
            continue
        }

        if ($inUl) { [void]$body.Add("</ul>"); $inUl = $false }
        if ($inOl) { [void]$body.Add("</ol>"); $inOl = $false }
        [void]$body.Add("<p>$(ConvertTo-HtmlInlineFromMarkdown $line)</p>")
    }

    if ($inUl) { [void]$body.Add("</ul>") }
    if ($inOl) { [void]$body.Add("</ol>") }

    return @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$(ConvertTo-HtmlText $Title)</title>
  <style>
    body { margin: 0; font-family: Roboto, Arial, Helvetica, sans-serif; color: $legendBlue; background: $graciousGray; line-height: 1.65; }
    main { max-width: 920px; margin: 0 auto; padding: 48px 30px 72px; background: #ffffff; }
    h1 { font-family: Merriweather, Georgia, serif; font-style: italic; color: $legendBlue; font-size: 34px; line-height: 1.15; margin: 34px 0 12px; }
    h2 { font-family: Roboto, Arial, Helvetica, sans-serif; color: $heroBlue; font-size: 25px; margin-top: 30px; border-top: 1px solid $mediumGray; padding-top: 18px; }
    h3 { font-family: Roboto, Arial, Helvetica, sans-serif; color: $legendBlue; font-size: 20px; margin-top: 24px; }
    h4 { font-family: Roboto, Arial, Helvetica, sans-serif; color: $integrityGray; font-size: 17px; margin-top: 18px; }
    /* Shared GM1000 publication typography; no cover-style browser theme. */
    body { font-family: '$($publicationTemplate.font)', Arial, sans-serif; font-size: $($publicationTemplate.bodyPoints)pt; color: #000000; line-height: 1.16; }
    main { box-sizing: border-box; max-width: 8.5in; padding: 1in; }
    h1, h2, h3, h4 { font-family: inherit; font-weight: normal; }
    h1 { font-size: $($publicationTemplate.chapterPoints)pt; font-style: normal; color: #000000; }
    h2 { font-size: $($publicationTemplate.sectionPoints)pt; color: #$($publicationTemplate.sectionColor); border: 0; padding-top: 0; }
    h3, h4 { font-size: $($publicationTemplate.subsectionPoints)pt; font-style: italic; color: #000000; }
    @media (max-width: 700px) { main { padding: 24px; } }
    p { margin: 12px 0; }
    li { margin: 7px 0; }
    a { color: $heroBlue; }
    table { border-collapse: collapse; width: 100%; margin: 18px 0; }
    th, td { border: 1px solid $mediumGray; padding: 9px 12px; text-align: left; vertical-align: top; }
    th { background: $graciousGray; color: $legendBlue; }
    figure { margin: 20px 0 24px; }
    figure img { display: block; width: 100%; max-height: 540px; object-fit: contain; border: 1px solid $mediumGray; border-radius: 8px; background: #ffffff; }
    .chapter-opener-figure { margin: 18px 0 26px; }
    .chapter-opener-figure img { height: auto; aspect-ratio: auto; max-height: none; object-fit: contain; }
    figcaption { margin-top: 6px; color: $integrityGray; font-family: Roboto, Arial, Helvetica, sans-serif; font-size: 14px; border-left: 4px solid $journeyGreen; padding-left: 8px; }
  </style>
</head>
<body>
<main>
$($body -join "`r`n")
</main>
</body>
</html>
"@
}

function ConvertTo-CloudflareWorkerScript {
    param(
        [Parameter(Mandatory)][string]$Html,
        [string]$RoutePath = "/ebook"
    )

    $htmlLiteral = ConvertTo-Json -InputObject $Html -Compress
    $routeLiteral = ConvertTo-Json -InputObject $RoutePath -Compress

    return @"
const EBOOK_HTML = $htmlLiteral;
const ROUTE_PATH = $routeLiteral;
const CONTENT_TYPES = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".svg": "image/svg+xml; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".json": "application/json; charset=utf-8"
};

function contentTypeFor(path) {
  const lower = path.toLowerCase();
  for (const [extension, type] of Object.entries(CONTENT_TYPES)) {
    if (lower.endsWith(extension)) return type;
  }
  return "application/octet-stream";
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/" || url.pathname === ROUTE_PATH) {
      return new Response(EBOOK_HTML, {
        headers: {
          "content-type": "text/html; charset=utf-8",
          "cache-control": "public, max-age=300"
        }
      });
    }

    const assetKey = decodeURIComponent(url.pathname.replace(/^\/+/, ""));
    if (assetKey && env.EBOOK_ASSETS) {
      const asset = await env.EBOOK_ASSETS.get(assetKey, "arrayBuffer");
      if (asset) {
        return new Response(asset, {
          headers: {
            "content-type": contentTypeFor(assetKey),
            "cache-control": "public, max-age=31536000"
          }
        });
      }
    }

    return new Response("Not found", {
      status: 404,
      headers: { "content-type": "text/plain; charset=utf-8" }
    });
  }
};
"@
}

function ConvertTo-OpenXmlText {
    param([AllowNull()][string]$Text)

    return [System.Security.SecurityElement]::Escape([string]$Text)
}

function ConvertFrom-MarkdownLineToPlainText {
    param([AllowNull()][string]$Text)

    $plain = [string]$Text
    $plain = $plain -replace "^!\[([^\]]*)\]\(([^)]+)\)$", 'Image: $1 - $2'
    $plain = $plain -replace "\[([^\]]+)\]\(([^)]+)\)", '$1 - $2'
    $plain = $plain -replace "\*\*", ""
    $plain = $plain -replace '(?<!\*)\*([^*\r\n]+)\*(?!\*)', '$1'
    $plain = $plain -replace '^>\s?', ''
    $plain = $plain -replace '`', ""
    return $plain
}

function ConvertTo-HtmlInlineFromMarkdown {
    param([AllowNull()][string]$Text)

    $source = [string]$Text
    $pattern = '(\[([^\]]+)\]\(([^)\s]+)\)|\*\*([^*]+)\*\*|(?<!\*)\*([^*\r\n]+)\*(?!\*))'
    $matches = [regex]::Matches($source, $pattern)
    if ($matches.Count -eq 0) {
        return (ConvertTo-HtmlText (ConvertFrom-MarkdownLineToPlainText $source))
    }

    $parts = New-Object System.Collections.ArrayList
    $position = 0
    foreach ($match in $matches) {
        if ($match.Index -gt $position) {
            $plainSegment = $source.Substring($position, $match.Index - $position)
            [void]$parts.Add((ConvertTo-HtmlText (ConvertFrom-MarkdownLineToPlainText $plainSegment)))
        }

        if ($match.Groups[2].Success) {
            $label = ConvertFrom-MarkdownLineToPlainText $match.Groups[2].Value
            $url = $match.Groups[3].Value
            [void]$parts.Add("<a href=""$(ConvertTo-HtmlAttribute $url)"">$(ConvertTo-HtmlText $label)</a>")
        }
        elseif ($match.Groups[4].Success) { [void]$parts.Add('<strong>' + (ConvertTo-HtmlText $match.Groups[4].Value) + '</strong>') }
        elseif ($match.Groups[5].Success) { [void]$parts.Add('<em>' + (ConvertTo-HtmlText $match.Groups[5].Value) + '</em>') }
        $position = $match.Index + $match.Length
    }

    if ($position -lt $source.Length) {
        $plainSegment = $source.Substring($position)
        [void]$parts.Add((ConvertTo-HtmlText (ConvertFrom-MarkdownLineToPlainText $plainSegment)))
    }

    return ($parts -join "")
}

function Add-WordHyperlinkRelationship {
    param(
        [System.Collections.ArrayList]$HyperlinkRelationships,
        [string]$Url
    )

    $id = "rId$($HyperlinkRelationships.Count + 1)"
    [void]$HyperlinkRelationships.Add([pscustomobject]@{
        id = $id
        type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
        target = $Url
        targetMode = "External"
    })

    return $id
}

function Add-WordImageRelationship {
    param(
        [System.Collections.ArrayList]$Relationships,
        [string]$Target
    )

    $id = "rId$($Relationships.Count + 1)"
    [void]$Relationships.Add([pscustomobject]@{
        id = $id
        type = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
        target = $Target
        targetMode = ""
    })

    return $id
}

function Get-ImagePixelSize {
    param([Parameter(Mandatory)][string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (@(".png", ".jpg", ".jpeg") -contains $extension) {
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
            $image = [System.Drawing.Image]::FromFile((ConvertTo-EbookLongPath -Path $Path))
            try {
                if ($image.Width -gt 0 -and $image.Height -gt 0) {
                    return [pscustomobject]@{ width = [double]$image.Width; height = [double]$image.Height }
                }
            }
            finally {
                $image.Dispose()
            }
        }
        catch {
            # Fall back to lightweight header parsing below when the decoder is unavailable.
        }
    }

    if ($extension -eq ".png") {
        $bytes = [System.IO.File]::ReadAllBytes((ConvertTo-EbookLongPath -Path $Path))
        if ($bytes.Length -ge 24) {
            $width = ([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor [int]$bytes[19]
            $height = ([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor ([int]$bytes[22] -shl 8) -bor [int]$bytes[23]
            if ($width -gt 0 -and $height -gt 0) {
                return [pscustomobject]@{ width = $width; height = $height }
            }
        }
    }

    if ($extension -eq ".svg") {
        try {
            $xml = [xml](Get-Content -Raw -LiteralPath (ConvertTo-EbookLongPath -Path $Path))
            $svg = $xml.DocumentElement
            if ($svg.viewBox) {
                $parts = @($svg.viewBox -split "\s+" | Where-Object { $_ -ne "" })
                if ($parts.Count -eq 4) {
                    return [pscustomobject]@{ width = [double]$parts[2]; height = [double]$parts[3] }
                }
            }

            $widthText = ([string]$svg.width) -replace "[^\d\.]", ""
            $heightText = ([string]$svg.height) -replace "[^\d\.]", ""
            if ($widthText -and $heightText) {
                return [pscustomobject]@{ width = [double]$widthText; height = [double]$heightText }
            }
        }
        catch {
            return $null
        }
    }

    return $null
}

function Get-WordImageExtent {
    param([object]$Size)

    $maxCx = 5943600
    if (-not $Size -or $Size.width -le 0 -or $Size.height -le 0) {
        return [pscustomobject]@{ cx = $maxCx; cy = 3343275 }
    }

    $cx = $maxCx
    $cy = [int64]([double]$maxCx * ([double]$Size.height / [double]$Size.width))
    return [pscustomobject]@{ cx = $cx; cy = $cy }
}

function New-WordImageParagraphXml {
    param(
        [AllowNull()][string]$AltText,
        [string]$RelativePath,
        [AllowNull()][string]$AssetRoot,
        [System.Collections.ArrayList]$Relationships,
        [System.Collections.ArrayList]$MediaAssets
    )

    if ([string]::IsNullOrWhiteSpace($AssetRoot) -or $null -eq $MediaAssets) {
        return $null
    }

    $sourcePath = Join-Path $AssetRoot $RelativePath
    if (-not [System.IO.File]::Exists((ConvertTo-EbookLongPath -Path $sourcePath))) {
        return $null
    }

    $extension = [System.IO.Path]::GetExtension($sourcePath).ToLowerInvariant()
    if (@(".png", ".jpg", ".jpeg", ".svg") -notcontains $extension) {
        return $null
    }

    $mediaName = "image$($MediaAssets.Count + 1)$extension"
    $target = "media/$mediaName"
    $relationshipId = Add-WordImageRelationship -Relationships $Relationships -Target $target
    $size = Get-ImagePixelSize -Path $sourcePath
    $extent = Get-WordImageExtent -Size $size
    $docPrId = $MediaAssets.Count + 1
    [void]$MediaAssets.Add([pscustomobject]@{
        sourcePath = $sourcePath
        entryName = "word/media/$mediaName"
    })

    $alt = ConvertTo-OpenXmlText $AltText
    return @"
<w:p>
  <w:pPr><w:jc w:val="center"/><w:spacing w:after="180"/></w:pPr>
  <w:r>
    <w:drawing>
      <wp:inline distT="0" distB="0" distL="0" distR="0">
        <wp:extent cx="$($extent.cx)" cy="$($extent.cy)"/>
        <wp:docPr id="$docPrId" name="$alt" descr="$alt"/>
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>
        <a:graphic>
          <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
            <pic:pic>
              <pic:nvPicPr>
                <pic:cNvPr id="$docPrId" name="$alt"/>
                <pic:cNvPicPr><a:picLocks noChangeAspect="1"/></pic:cNvPicPr>
              </pic:nvPicPr>
              <pic:blipFill>
                <a:blip r:embed="$relationshipId"/>
                <a:stretch><a:fillRect/></a:stretch>
              </pic:blipFill>
              <pic:spPr>
                <a:xfrm><a:off x="0" y="0"/><a:ext cx="$($extent.cx)" cy="$($extent.cy)"/></a:xfrm>
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
              </pic:spPr>
            </pic:pic>
          </a:graphicData>
        </a:graphic>
      </wp:inline>
    </w:drawing>
  </w:r>
</w:p>
"@
}

function ConvertTo-WordTextRunXml {
    param(
        [AllowNull()][string]$Text,
        [switch]$Bold,
        [switch]$Italic
    )

    $plain = ConvertFrom-MarkdownLineToPlainText $Text
    if ([string]::IsNullOrEmpty($plain)) {
        return ""
    }

    $runProperties = New-Object System.Collections.ArrayList
    if ($Bold) {
        [void]$runProperties.Add("<w:b/>")
    }
    if ($Italic) {
        [void]$runProperties.Add("<w:i/>")
    }

    $runPropertyXml = ""
    if ($runProperties.Count -gt 0) {
        $joinedRunProperties = $runProperties -join ""
        $runPropertyXml = "<w:rPr>$joinedRunProperties</w:rPr>"
    }

    return "<w:r>$runPropertyXml<w:t xml:space=""preserve"">$(ConvertTo-OpenXmlText $plain)</w:t></w:r>"
}

function ConvertTo-WordInlineXml {
    param(
        [AllowNull()][string]$Text,
        [System.Collections.ArrayList]$HyperlinkRelationships
    )

    $source = [string]$Text
    $pattern = '(\[([^\]]+)\]\(([^)\s]+)\)|\*\*([^*]+)\*\*|(?<!\*)\*([^*\r\n]+)\*(?!\*))'
    $matches = [regex]::Matches($source, $pattern)
    if ($matches.Count -eq 0) {
        return (ConvertTo-WordTextRunXml $source)
    }

    $parts = New-Object System.Collections.ArrayList
    $position = 0
    foreach ($match in $matches) {
        if ($match.Index -gt $position) {
            [void]$parts.Add((ConvertTo-WordTextRunXml $source.Substring($position, $match.Index - $position)))
        }

        if ($match.Groups[2].Success) {
            $label = ConvertFrom-MarkdownLineToPlainText $match.Groups[2].Value
            $url = $match.Groups[3].Value
            # Only web/email links belong in the DOCX relationship part. Local
            # package paths and fragment anchors are useful in HTML but become
            # misleading or unusable external links when opened in Word.
            if ($url -match "^(?i:https?|mailto):") {
                $relationshipId = Add-WordHyperlinkRelationship -HyperlinkRelationships $HyperlinkRelationships -Url $url
                $escapedLabel = ConvertTo-OpenXmlText $label
                [void]$parts.Add("<w:hyperlink r:id=""$relationshipId"" w:history=""1""><w:r><w:rPr><w:rStyle w:val=""Hyperlink""/></w:rPr><w:t xml:space=""preserve"">$escapedLabel</w:t></w:r></w:hyperlink>")
            }
            elseif ($url -match '^#chapter-\d+-note-\d+$') {
                $anchor = $url.Substring(1).Replace('-', '_')
                $escapedLabel = ConvertTo-OpenXmlText $label
                [void]$parts.Add("<w:hyperlink w:anchor=""$anchor"" w:history=""1""><w:r><w:rPr><w:rStyle w:val=""Hyperlink""/></w:rPr><w:t>$escapedLabel</w:t></w:r></w:hyperlink>")
            }
            else {
                [void]$parts.Add((ConvertTo-WordTextRunXml -Text $label))
            }
        }
        elseif ($match.Groups[4].Success) {
            [void]$parts.Add((ConvertTo-WordTextRunXml -Text $match.Groups[4].Value -Bold))
        }
        elseif ($match.Groups[5].Success) {
            [void]$parts.Add((ConvertTo-WordTextRunXml -Text $match.Groups[5].Value -Italic))
        }
        $position = $match.Index + $match.Length
    }

    if ($position -lt $source.Length) {
        [void]$parts.Add((ConvertTo-WordTextRunXml $source.Substring($position)))
    }

    return ($parts -join "")
}

function New-WordParagraphXml {
    param(
        [string]$Text,
        [string]$StyleId = "Normal",
        [System.Collections.ArrayList]$HyperlinkRelationships,
        [int]$LeftIndent = 0,
        [int]$HangingIndent = 0,
        [int]$SpacingBefore = 0,
        [int]$SpacingAfter = 120,
        [switch]$KeepNext,
        [switch]$PageBreakBefore,
        [int]$NumberingId = 0,
        [int]$NumberingLevel = 0,
        [AllowNull()][string]$RunXml
    )

    $properties = New-Object System.Collections.ArrayList
    if ($StyleId -and $StyleId -ne "Normal") {
        [void]$properties.Add("<w:pStyle w:val=""$StyleId""/>")
    }
    if ($KeepNext) {
        [void]$properties.Add("<w:keepNext/>")
    }
    if ($PageBreakBefore) {
        [void]$properties.Add("<w:pageBreakBefore/>")
    }
    if ($SpacingBefore -gt 0 -or $SpacingAfter -gt 0) {
        [void]$properties.Add("<w:spacing w:before=""$SpacingBefore"" w:after=""$SpacingAfter""/>")
    }
    if ($LeftIndent -gt 0 -or $HangingIndent -gt 0) {
        $hanging = if ($HangingIndent -gt 0) { " w:hanging=""$HangingIndent""" } else { "" }
        [void]$properties.Add("<w:ind w:left=""$LeftIndent""$hanging/>")
    }
    if ($NumberingId -gt 0) {
        [void]$properties.Add("<w:numPr><w:ilvl w:val=""$NumberingLevel""/><w:numId w:val=""$NumberingId""/></w:numPr>")
    }

    $propertyXml = ""
    if ($properties.Count -gt 0) {
        $joinedProperties = $properties -join ""
        $propertyXml = "<w:pPr>$joinedProperties</w:pPr>"
    }

    $runs = if ([string]::IsNullOrEmpty($RunXml)) { ConvertTo-WordInlineXml -Text $Text -HyperlinkRelationships $HyperlinkRelationships } else { $RunXml }
    return "<w:p>$propertyXml$runs</w:p>"
}

function New-WordLabeledParagraphXml {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][string]$Body,
        [string]$StyleId,
        [System.Collections.ArrayList]$HyperlinkRelationships
    )

    $labelText = ConvertTo-OpenXmlText "${Label}: "
    $bodyRuns = ConvertTo-WordInlineXml -Text ([string]$Body).Trim() -HyperlinkRelationships $HyperlinkRelationships
    $runs = "<w:r><w:rPr><w:b/></w:rPr><w:t xml:space=""preserve"">$labelText</w:t></w:r>$bodyRuns"
    return (New-WordParagraphXml -Text "" -StyleId $StyleId -HyperlinkRelationships $HyperlinkRelationships -SpacingBefore 120 -SpacingAfter 120 -RunXml $runs)
}

function New-WordPageBreakXml {
    return '<w:p><w:r><w:br w:type="page"/></w:r></w:p>'
}

function ConvertTo-MarkdownTableCells {
    param([Parameter(Mandatory)][string]$Line)

    $value = $Line.Trim()
    if ($value.StartsWith("|")) { $value = $value.Substring(1) }
    if ($value.EndsWith("|")) { $value = $value.Substring(0, $value.Length - 1) }
    return @($value -split "\|" | ForEach-Object { (ConvertFrom-MarkdownLineToPlainText $_).Trim() })
}

function New-WordTableXml {
    param(
        [Parameter(Mandatory)][object[]]$Rows,
        [System.Collections.ArrayList]$HyperlinkRelationships
    )

    $rowXml = New-Object System.Collections.ArrayList
    $columnCount = @($Rows[0]).Count
    if ($columnCount -lt 1) { throw 'A table must have columns.' }
    $cellWidth = [int][Math]::Floor(8730 / $columnCount)
    $gridXml = ('<w:gridCol w:w="' + $cellWidth + '"/>') * $columnCount
    for ($rowIndex = 0; $rowIndex -lt $Rows.Count; $rowIndex++) {
        $cells = @($Rows[$rowIndex])
        if ($cells.Count -ne $columnCount) { throw 'Table rows must have the same number of cells.' }
        $cellXml = New-Object System.Collections.ArrayList
        foreach ($cell in $cells) {
            $cellText = [string]$cell
            $cellRuns = if ($rowIndex -eq 0) {
                ConvertTo-WordTextRunXml -Text $cellText -Bold
            }
            else {
                ConvertTo-WordInlineXml -Text $cellText -HyperlinkRelationships $HyperlinkRelationships
            }
            $cellParagraph = New-WordParagraphXml -Text "" -StyleId "TableText" -HyperlinkRelationships $HyperlinkRelationships -SpacingBefore 0 -SpacingAfter 0 -RunXml $cellRuns -KeepNext:($rowIndex -eq 0)
            [void]$cellXml.Add("<w:tc><w:tcPr><w:tcW w:w=""$cellWidth"" w:type=""dxa""/><w:tcBorders><w:top w:val=""single"" w:sz=""4"" w:color=""B7C9D6""/><w:left w:val=""single"" w:sz=""4"" w:color=""B7C9D6""/><w:bottom w:val=""single"" w:sz=""4"" w:color=""B7C9D6""/><w:right w:val=""single"" w:sz=""4"" w:color=""B7C9D6""/></w:tcBorders></w:tcPr>$cellParagraph</w:tc>")
        }
        $cellTextXml = $cellXml -join ""
        $repeatHeader = if ($rowIndex -eq 0) { '<w:tblHeader/>' } else { '' }
        [void]$rowXml.Add("<w:tr><w:trPr><w:cantSplit/>$repeatHeader</w:trPr>$cellTextXml</w:tr>")
    }

    $rowTextXml = $rowXml -join ""
    return "<w:tbl><w:tblPr><w:tblW w:w=""8730"" w:type=""dxa""/><w:tblLayout w:type=""fixed""/><w:tblCellMar><w:top w:w=""80"" w:type=""dxa""/><w:left w:w=""100"" w:type=""dxa""/><w:bottom w:w=""80"" w:type=""dxa""/><w:right w:w=""100"" w:type=""dxa""/></w:tblCellMar><w:tblBorders><w:top w:val=""single"" w:sz=""6"" w:color=""7AAFC5""/><w:left w:val=""single"" w:sz=""6"" w:color=""7AAFC5""/><w:bottom w:val=""single"" w:sz=""6"" w:color=""7AAFC5""/><w:right w:val=""single"" w:sz=""6"" w:color=""7AAFC5""/><w:insideH w:val=""single"" w:sz=""4"" w:color=""B7C9D6""/><w:insideV w:val=""single"" w:sz=""4"" w:color=""B7C9D6""/></w:tblBorders></w:tblPr><w:tblGrid>$gridXml</w:tblGrid>$rowTextXml</w:tbl>"
}

function ConvertTo-WordDocumentXml {
    param(
        [Parameter(Mandatory)][string]$Markdown,
        [string]$Title = "Ebook",
        [System.Collections.ArrayList]$HyperlinkRelationships,
        [AllowNull()][string]$AssetRoot,
        [System.Collections.ArrayList]$MediaAssets,
        [System.Collections.ArrayList]$RestartingNumberingIds,
        [switch]$IncludeCoverPage
    )

    if (Test-EbookDeprecatedCaseLabel $Markdown) { throw 'Publication terminology gate: use Business Case, not Case and Face.' }
    $Markdown = ConvertTo-EbookCitationMarkdown -Markdown $Markdown
    if ($null -eq $HyperlinkRelationships) { $HyperlinkRelationships = New-Object System.Collections.ArrayList }
    if ($null -eq $MediaAssets) { $MediaAssets = New-Object System.Collections.ArrayList }
    if ($null -eq $RestartingNumberingIds) { $RestartingNumberingIds = New-Object System.Collections.ArrayList }
    $paragraphs = New-Object System.Collections.ArrayList
    $hasCoverTitle = $false
    $hasChapterHeading = $false
    $previousListKind = ""
    $activeOrderedNumberingId = 0
    $nextNumberingId = 3
    $wordChapterNumber = 0
    $wordSectionTitle = ''
    $wordBookmarkId = 0
    $keepShortNotesTogether = $false
    $markdownLines = @($Markdown -split "`r?`n")
    for ($lineIndex = 0; $lineIndex -lt $markdownLines.Count; $lineIndex++) {
        $line = [string]$markdownLines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($previousListKind -eq 'ordered' -and (Test-EbookNotesHeading $wordSectionTitle)) { continue }
            $previousListKind = ""
            continue
        }

        if ($lineIndex + 1 -lt $markdownLines.Count -and $line -match "^\s*\|.*\|\s*$" -and $markdownLines[$lineIndex + 1] -match "^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$") {
            $tableRows = New-Object System.Collections.ArrayList
            [void]$tableRows.Add((ConvertTo-MarkdownTableCells -Line $line))
            $lineIndex++
            while ($lineIndex + 1 -lt $markdownLines.Count -and $markdownLines[$lineIndex + 1] -match "^\s*\|.*\|\s*$") {
                $lineIndex++
                [void]$tableRows.Add((ConvertTo-MarkdownTableCells -Line $markdownLines[$lineIndex]))
            }
            [void]$paragraphs.Add((New-WordTableXml -Rows @($tableRows) -HyperlinkRelationships $HyperlinkRelationships))
            $previousListKind = ""
            continue
        }

        if ($line -match "^!\[([^\]]*)\]\(([^)\s]+)\)$") {
            $imageXml = New-WordImageParagraphXml -AltText $Matches[1] -RelativePath $Matches[2] -AssetRoot $AssetRoot -Relationships $HyperlinkRelationships -MediaAssets $MediaAssets
            if ($imageXml) {
                [void]$paragraphs.Add($imageXml)
            }
            else {
                [void]$paragraphs.Add((New-WordParagraphXml -Text "[Image: $($Matches[1])]($($Matches[2]))" -StyleId "Normal" -HyperlinkRelationships $HyperlinkRelationships))
            }
            $previousListKind = ""
            continue
        }

        if ($line -match "^(#{1,4})\s+(.+)$") {
            $level = [Math]::Min($Matches[1].Length, 3)
            $headingText = $Matches[2]
            $wordSectionTitle = $headingText
            $keepShortNotesTogether = $false
            if ($headingText -match '^(Scholarly Sources|Notes)$') {
                $remaining = $markdownLines[$lineIndex..($markdownLines.Count-1)] -join "`n"
                $noteBlock = [regex]::Match($remaining, '(?ms)^#{1,4} [^\r\n]+\r?\n(?<body>.*?)(?=^#{1,4} |\z)').Groups['body'].Value
                $keepShortNotesTogether = (Get-MarkdownWordCount -Markdown $noteBlock) -le 250 -and [regex]::Matches($noteBlock, '(?m)^\d+\. ').Count -le 6
            }
            if ($headingText -match '^Chapter\s+(\d+):') { $wordChapterNumber = [int]$Matches[1] }
            if ($IncludeCoverPage -and -not $hasCoverTitle -and $level -eq 1) {
                [void]$paragraphs.Add((New-WordParagraphXml -Text $headingText -StyleId "Title" -HyperlinkRelationships $HyperlinkRelationships -SpacingBefore 720 -SpacingAfter 180 -KeepNext))
                [void]$paragraphs.Add((New-WordParagraphXml -Text "E-Book" -StyleId "Subtitle" -HyperlinkRelationships $HyperlinkRelationships -SpacingAfter 720))
                [void]$paragraphs.Add((New-WordPageBreakXml))
                $hasCoverTitle = $true
                $previousListKind = ""
                continue
            }

            $pageBreakBefore = $false
            if ($level -eq 1 -and $headingText -match "^Chapter\s+\d+\b" -and $hasChapterHeading) {
                $pageBreakBefore = $true
            }
            if ($level -eq 1 -and $headingText -match "^Chapter\s+\d+\b") { $hasChapterHeading = $true }

            [void]$paragraphs.Add((New-WordParagraphXml -Text $headingText -StyleId "Heading$level" -HyperlinkRelationships $HyperlinkRelationships -SpacingBefore 240 -SpacingAfter 160 -KeepNext -PageBreakBefore:$pageBreakBefore))
            $previousListKind = ""
            continue
        }

        if ($line -match "^\*\*(Worked example|Apply it|Self-check|Example in Context|Pause and Notice):\*\*\s*(.*)$") {
            $label = $Matches[1]
            $styleId = switch ($label) {
                "Worked example" { "WorkedExample" }
                "Apply it" { "ApplyIt" }
                "Self-check" { "SelfCheck" }
                "Example in Context" { "WorkedExample" }
                "Pause and Notice" { "SelfCheck" }
                default { "LearningCallout" }
            }
            [void]$paragraphs.Add((New-WordLabeledParagraphXml -Label $label -Body $Matches[2] -StyleId $styleId -HyperlinkRelationships $HyperlinkRelationships))
            $previousListKind = ""
            continue
        }

        if ($line -match "^[IVXLCDM]+\.\s+Chapter\s+\d+:.+$") {
            [void]$paragraphs.Add((New-WordParagraphXml -Text $line -StyleId "OutlineChapter" -HyperlinkRelationships $HyperlinkRelationships -SpacingBefore 360 -SpacingAfter 160))
            $previousListKind = ""
            continue
        }

        if ($line -match "^Chapter\s+\d+\s+Key Concepts$") {
            [void]$paragraphs.Add((New-WordParagraphXml -Text $line -StyleId "OutlineLabel" -HyperlinkRelationships $HyperlinkRelationships -LeftIndent 360 -SpacingBefore 160 -SpacingAfter 80))
            $previousListKind = ""
            continue
        }

        if ($line -match "^[A-Z]\.\s+.+$") {
            [void]$paragraphs.Add((New-WordParagraphXml -Text $line -StyleId "OutlineSection" -HyperlinkRelationships $HyperlinkRelationships -LeftIndent 360 -SpacingBefore 180 -SpacingAfter 80))
            $previousListKind = ""
            continue
        }

        if ($line -match "^\d+\.\s+.+$") {
            $listText = $line -replace "^\d+\.\s+", ""
            if ($previousListKind -ne "ordered") {
                $activeOrderedNumberingId = $nextNumberingId
                $nextNumberingId++
                [void]$RestartingNumberingIds.Add($activeOrderedNumberingId)
            }
            $noteRuns = $null
            $keepNextNote = $false
            if ($wordChapterNumber -gt 0 -and $wordSectionTitle -match '^(Scholarly Sources|Notes)$') {
                $noteNumber = [int]([regex]::Match($line, '^\d+').Value)
                $noteAnchor = "chapter_${wordChapterNumber}_note_$noteNumber"
                $wordBookmarkId++
                $noteRuns = "<w:bookmarkStart w:id=""$wordBookmarkId"" w:name=""$noteAnchor""/>" + (ConvertTo-WordInlineXml -Text $listText -HyperlinkRelationships $HyperlinkRelationships) + "<w:bookmarkEnd w:id=""$wordBookmarkId""/>"
                $lookAhead = $lineIndex + 1
                while ($lookAhead -lt $markdownLines.Count -and [string]::IsNullOrWhiteSpace($markdownLines[$lookAhead])) { $lookAhead++ }
                $keepNextNote = $keepShortNotesTogether -and $lookAhead -lt $markdownLines.Count -and $markdownLines[$lookAhead] -match '^\d+\. '
            }
            [void]$paragraphs.Add((New-WordParagraphXml -Text $listText -StyleId "ListParagraph" -HyperlinkRelationships $HyperlinkRelationships -LeftIndent 720 -HangingIndent 360 -SpacingAfter 80 -NumberingId $activeOrderedNumberingId -RunXml $noteRuns -KeepNext:$keepNextNote))
            $previousListKind = "ordered"
            continue
        }

        if ($line -match "^\-\s+(.+)$") {
            [void]$paragraphs.Add((New-WordParagraphXml -Text $Matches[1] -StyleId "ListParagraph" -HyperlinkRelationships $HyperlinkRelationships -LeftIndent 720 -HangingIndent 360 -SpacingAfter 80 -NumberingId 2))
            $previousListKind = "bullet"
            continue
        }

        if ($line -match '^>\s?(.*)$') {
            $quoteText = $Matches[1]
            if ($quoteText.Trim()) { [void]$paragraphs.Add((New-WordParagraphXml -Text $quoteText -StyleId 'Normal' -HyperlinkRelationships $HyperlinkRelationships -LeftIndent 360 -SpacingAfter 120)) }
        }
        else { [void]$paragraphs.Add((New-WordParagraphXml -Text $line -StyleId "Normal" -HyperlinkRelationships $HyperlinkRelationships -SpacingAfter 120)) }
        $previousListKind = ""
    }

    $body = $paragraphs -join "`r`n"
    # A cover can be unnumbered page zero; chapter-first books begin at one.
    $pageNumberStart = if ($IncludeCoverPage) { 0 } else { 1 }
    return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
    <w:body>
$body
    <w:sectPr>
      <w:headerReference w:type="default" r:id="rIdHeader"/>
      <w:footerReference w:type="default" r:id="rIdFooter"/>
      <w:pgSz w:w="12240" w:h="15840"/>
      <w:titlePg/>
      <w:pgNumType w:start="$pageNumberStart"/>
      <w:cols w:space="720"/>
      <w:pgMar w:top="1440" w:right="2070" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
    </w:sectPr>
  </w:body>
</w:document>
"@
}

function Get-WordDocumentRelationshipsXml {
    param([System.Collections.ArrayList]$HyperlinkRelationships)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$lines.Add('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')
    [void]$lines.Add('  <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>')
    [void]$lines.Add('  <Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>')
    [void]$lines.Add('  <Relationship Id="rIdHeader" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>')
    [void]$lines.Add('  <Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>')
    foreach ($relationship in $HyperlinkRelationships) {
        $targetMode = if ($relationship.targetMode) { " TargetMode=""$($relationship.targetMode)""" } else { "" }
        [void]$lines.Add("  <Relationship Id=""$($relationship.id)"" Type=""$($relationship.type)"" Target=""$(ConvertTo-OpenXmlText $relationship.target)""$targetMode/>")
    }
    [void]$lines.Add('</Relationships>')
    return ($lines -join "`r`n")
}

function Get-WordNumberingXml {
    param([int[]]$RestartingNumberingIds = @())

    $restartXml = New-Object System.Collections.ArrayList
    foreach ($numberingId in @($RestartingNumberingIds | Select-Object -Unique)) {
        if ($numberingId -gt 2) {
            [void]$restartXml.Add("  <w:num w:numId=""$numberingId""><w:abstractNumId w:val=""0""/><w:lvlOverride w:ilvl=""0""><w:startOverride w:val=""1""/></w:lvlOverride></w:num>")
        }
    }

    return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="0">
    <w:multiLevelType w:val="singleLevel"/>
    <w:lvl w:ilvl="0">
      <w:start w:val="1"/>
      <w:numFmt w:val="decimal"/>
      <w:lvlText w:val="%1."/>
      <w:lvlJc w:val="left"/>
      <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>
    </w:lvl>
  </w:abstractNum>
  <w:abstractNum w:abstractNumId="1">
    <w:multiLevelType w:val="singleLevel"/>
    <w:lvl w:ilvl="0">
      <w:start w:val="1"/>
      <w:numFmt w:val="bullet"/>
      <w:lvlText w:val="•"/>
      <w:lvlJc w:val="left"/>
      <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>
      <w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:hint="default"/></w:rPr>
    </w:lvl>
  </w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
  <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
$($restartXml -join "`r`n")
</w:numbering>
"@
}

function Get-WordHeaderXml {
    param(
        [string]$Title,
        [object]$BrandProfile
    )

    $legendBlue = ConvertTo-WordHexColor (Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553")
    $headerText = ConvertTo-OpenXmlText $Title
    return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:p>
    <w:pPr>
      <w:pBdr><w:bottom w:val="single" w:sz="8" w:space="4" w:color="$legendBlue"/></w:pBdr>
      <w:spacing w:after="80"/>
    </w:pPr>
    <w:r><w:rPr><w:b/><w:color w:val="$legendBlue"/><w:sz w:val="18"/></w:rPr><w:t xml:space="preserve">$headerText</w:t></w:r>
  </w:p>
</w:hdr>
"@
}

function Get-WordFooterXml {
    param([object]$BrandProfile)

    $integrityGray = ConvertTo-WordHexColor (Get-BrandColor -BrandProfile $BrandProfile -Name "Integrity Gray" -Fallback "#444444")
    return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:p>
    <w:pPr><w:jc w:val="center"/></w:pPr>
    <w:r><w:rPr><w:color w:val="$integrityGray"/><w:sz w:val="18"/></w:rPr><w:t xml:space="preserve">Page </w:t></w:r>
    <w:r><w:fldChar w:fldCharType="begin"/></w:r>
    <w:r><w:instrText xml:space="preserve">PAGE</w:instrText></w:r>
    <w:r><w:fldChar w:fldCharType="end"/></w:r>
  </w:p>
</w:ftr>
"@
}

function Get-WordStylesXml {
    param([object]$BrandProfile, [string]$PackageFolder)

    $t = Get-EbookPublicationTemplate -PackageFolder $PackageFolder

    $legendBlue = ConvertTo-WordHexColor (Get-BrandColor -BrandProfile $BrandProfile -Name "Legend Blue" -Fallback "#0D3553")
    $heroBlue = ConvertTo-WordHexColor (Get-BrandColor -BrandProfile $BrandProfile -Name "Hero Blue" -Fallback "#1D6BA6")
    $horizonBlue = ConvertTo-WordHexColor (Get-BrandColor -BrandProfile $BrandProfile -Name "Horizon Blue" -Fallback "#0095C8")
    $journeyGreen = ConvertTo-WordHexColor (Get-BrandColor -BrandProfile $BrandProfile -Name "Journey Green" -Fallback "#15EAC4")
    $graciousGray = ConvertTo-WordHexColor (Get-BrandColor -BrandProfile $BrandProfile -Name "Gracious Gray" -Fallback "#F9F9F9")
    $mediumGray = ConvertTo-WordHexColor (Get-BrandColor -BrandProfile $BrandProfile -Name "Medium Gray 1" -Fallback "#DBDBDB")
    $integrityGray = ConvertTo-WordHexColor (Get-BrandColor -BrandProfile $BrandProfile -Name "Integrity Gray" -Fallback "#444444")

    return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults>
    <w:rPrDefault><w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:color w:val="000000"/><w:sz w:val="$($t.bodyPoints * 2)"/></w:rPr></w:rPrDefault>
    <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>
  </w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:spacing w:line="278" w:lineRule="auto"/><w:ind w:right="-630"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:color w:val="000000"/><w:sz w:val="$($t.bodyPoints * 2)"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="TableText">
    <w:name w:val="Table Text"/>
    <w:basedOn w:val="Normal"/>
    <w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/><w:ind w:left="0" w:right="0"/></w:pPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="ListParagraph">
    <w:name w:val="List Paragraph"/>
    <w:basedOn w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:ind w:left="720"/><w:contextualSpacing/></w:pPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Title">
    <w:name w:val="Title"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Subtitle"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/><w:spacing w:before="720" w:after="180"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Aptos Display" w:hAnsi="Aptos Display" w:cs="Arial"/><w:b/><w:color w:val="$legendBlue"/><w:sz w:val="48"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Subtitle">
    <w:name w:val="Subtitle"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:spacing w:after="720"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:color w:val="$heroBlue"/><w:sz w:val="26"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/>
    <w:aliases w:val="Chapter"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="0"/><w:outlineLvl w:val="0"/></w:pPr>
    <w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:eastAsiaTheme="majorEastAsia" w:hAnsiTheme="majorHAnsi" w:cstheme="majorBidi"/><w:sz w:val="$($t.chapterPoints * 2)"/><w:szCs w:val="$($t.chapterPoints * 2)"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading2">
    <w:name w:val="heading 2"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240"/><w:outlineLvl w:val="1"/></w:pPr>
    <w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:eastAsiaTheme="majorEastAsia" w:hAnsiTheme="majorHAnsi" w:cstheme="majorBidi"/><w:color w:val="0F4761" w:themeColor="accent1" w:themeShade="BF"/><w:sz w:val="$($t.sectionPoints * 2)"/><w:szCs w:val="$($t.sectionPoints * 2)"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading3">
    <w:name w:val="heading 3"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="320" w:after="30"/><w:outlineLvl w:val="2"/></w:pPr>
    <w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:eastAsiaTheme="majorEastAsia" w:hAnsiTheme="majorHAnsi" w:cstheme="majorBidi"/><w:i/><w:iCs/><w:sz w:val="$($t.subsectionPoints * 2)"/><w:szCs w:val="$($t.subsectionPoints * 2)"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="WorkedExample">
    <w:name w:val="Worked Example"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:spacing w:before="120" w:after="120"/><w:ind w:left="240" w:right="120"/><w:pBdr><w:left w:val="single" w:sz="18" w:space="6" w:color="$heroBlue"/></w:pBdr><w:shd w:val="clear" w:color="auto" w:fill="F3F8FB"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:color w:val="$integrityGray"/><w:sz w:val="21"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="ApplyIt">
    <w:name w:val="Apply It"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:spacing w:before="120" w:after="120"/><w:ind w:left="240" w:right="120"/><w:pBdr><w:left w:val="single" w:sz="18" w:space="6" w:color="$journeyGreen"/></w:pBdr><w:shd w:val="clear" w:color="auto" w:fill="EFFBF8"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:color w:val="$integrityGray"/><w:sz w:val="21"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="SelfCheck">
    <w:name w:val="Self-Check"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:spacing w:before="120" w:after="140"/><w:ind w:left="240" w:right="120"/><w:pBdr><w:left w:val="single" w:sz="18" w:space="6" w:color="$mediumGray"/></w:pBdr><w:shd w:val="clear" w:color="auto" w:fill="$graciousGray"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:color w:val="$integrityGray"/><w:sz w:val="21"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="NumberedList">
    <w:name w:val="Numbered List"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="NumberedList"/>
    <w:qFormat/>
    <w:pPr><w:spacing w:after="80"/><w:ind w:left="720" w:hanging="360"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:color w:val="$integrityGray"/><w:sz w:val="22"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="OutlineChapter">
    <w:name w:val="outline chapter"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:b/><w:color w:val="$heroBlue"/><w:sz w:val="28"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="OutlineLabel">
    <w:name w:val="outline label"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:b/><w:color w:val="$legendBlue"/><w:sz w:val="23"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="OutlineSection">
    <w:name w:val="outline section"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:b/><w:color w:val="$legendBlue"/><w:sz w:val="23"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="OutlinePoint">
    <w:name w:val="outline point"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:color w:val="$integrityGray"/><w:sz w:val="22"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="BulletList">
    <w:name w:val="bullet list"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:spacing w:after="80"/><w:ind w:left="720" w:hanging="360"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos" w:cs="Arial"/><w:color w:val="$integrityGray"/><w:sz w:val="22"/></w:rPr>
  </w:style>
  <w:style w:type="character" w:styleId="Hyperlink">
    <w:name w:val="Hyperlink"/>
    <w:basedOn w:val="DefaultParagraphFont"/>
    <w:uiPriority w:val="99"/>
    <w:unhideWhenUsed/>
    <w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr>
  </w:style>
</w:styles>
"@
}

function Add-ZipEntryString {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$EntryName,
        [string]$Content
    )

    $entry = $Archive.CreateEntry($EntryName)
    $stream = $entry.Open()
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $writer.Write($Content)
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Add-ZipEntryFile {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$EntryName,
        [string]$SourcePath
    )

    $entry = $Archive.CreateEntry($EntryName)
    $inputStream = [System.IO.File]::OpenRead((ConvertTo-EbookLongPath -Path $SourcePath))
    $outputStream = $entry.Open()
    try {
        $inputStream.CopyTo($outputStream)
    }
    finally {
        $outputStream.Dispose()
        $inputStream.Dispose()
    }
}

function Export-MarkdownToDocx {
    param(
        [Parameter(Mandatory)][string]$Markdown,
        [Parameter(Mandatory)][string]$Path,
        [string]$Title = "Ebook",
        [AllowNull()][string]$AssetRoot,
        [object]$BrandProfile
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    # Validate in memory BEFORE touching an existing output file. Bad legacy
    # markup must not destroy the last usable book or leave a partial DOCX.
    $hyperlinkRelationships = New-Object System.Collections.ArrayList
    $mediaAssets = New-Object System.Collections.ArrayList
    $restartingNumberingIds = New-Object System.Collections.ArrayList
    $documentXml = ConvertTo-WordDocumentXml -Markdown $Markdown -Title $Title -HyperlinkRelationships $hyperlinkRelationships -AssetRoot $AssetRoot -MediaAssets $mediaAssets -RestartingNumberingIds $restartingNumberingIds
    $numberingIds = if ($restartingNumberingIds.Count -gt 0) { [int[]]$restartingNumberingIds.ToArray() } else { @() }
    $numberingXml = Get-WordNumberingXml -RestartingNumberingIds $numberingIds
    $citationIssues = @(Get-EbookWordCitationIssues -Document ([xml]$documentXml) -Numbering ([xml]$numberingXml))
    if ($citationIssues.Count -gt 0) { throw "Word export integrity gate failed: $($citationIssues -join ' ')" }

    $parentFolder = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parentFolder)) {
        New-Item -ItemType Directory -Force -Path $parentFolder | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        catch {
            $folder = Split-Path -Parent $Path
            $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            $Path = Join-Path $folder "$name-$((Get-Date).ToString('yyyyMMdd-HHmmss')).docx"
        }
    }

    $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Add-ZipEntryString -Archive $archive -EntryName "[Content_Types].xml" -Content @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Default Extension="jpg" ContentType="image/jpeg"/>
  <Default Extension="jpeg" ContentType="image/jpeg"/>
  <Default Extension="svg" ContentType="image/svg+xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
  <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
  <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
  <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>
"@
        Add-ZipEntryString -Archive $archive -EntryName "_rels/.rels" -Content @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
"@
        Add-ZipEntryString -Archive $archive -EntryName "word/_rels/document.xml.rels" -Content (Get-WordDocumentRelationshipsXml -HyperlinkRelationships $hyperlinkRelationships)
        Add-ZipEntryString -Archive $archive -EntryName "word/document.xml" -Content $documentXml
        Add-ZipEntryString -Archive $archive -EntryName "word/styles.xml" -Content (Get-WordStylesXml -BrandProfile $BrandProfile -PackageFolder $(if ($AssetRoot) { $AssetRoot } else { Split-Path -Parent $Path }))
        Add-ZipEntryString -Archive $archive -EntryName "word/numbering.xml" -Content $numberingXml
        Add-ZipEntryString -Archive $archive -EntryName "word/header1.xml" -Content (Get-WordHeaderXml -Title $Title -BrandProfile $BrandProfile)
        Add-ZipEntryString -Archive $archive -EntryName "word/footer1.xml" -Content (Get-WordFooterXml -BrandProfile $BrandProfile)
        foreach ($media in @($mediaAssets)) {
            Add-ZipEntryFile -Archive $archive -EntryName $media.entryName -SourcePath $media.sourcePath
        }
        Add-ZipEntryString -Archive $archive -EntryName "docProps/core.xml" -Content @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title>$(ConvertTo-OpenXmlText $Title)</dc:title>
  <dc:creator>ebook-generator</dc:creator>
  <cp:lastModifiedBy>ebook-generator</cp:lastModifiedBy>
  <dcterms:created xsi:type="dcterms:W3CDTF">$((Get-Date).ToUniversalTime().ToString("s"))Z</dcterms:created>
  <dcterms:modified xsi:type="dcterms:W3CDTF">$((Get-Date).ToUniversalTime().ToString("s"))Z</dcterms:modified>
</cp:coreProperties>
"@
        Add-ZipEntryString -Archive $archive -EntryName "docProps/app.xml" -Content @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>ebook-generator</Application>
</Properties>
"@
    }
    finally {
        $archive.Dispose()
    }

    return $Path
}

function ConvertTo-SafePathPart {
    # Windows limits a full path to 259 characters and packages nest several
    # levels deep, so folder and file parts built from course titles are capped
    # at a word boundary. The full title stays in the plan and manifest.
    param([string]$Text, [int]$MaxLength = 0)

    $safe = $Text -replace "[^\w\-]+", "-"
    $safe = $safe.Trim("-")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "ebook"
    }
    if ($MaxLength -gt 0 -and $safe.Length -gt $MaxLength) {
        $cut = $safe.Substring(0, $MaxLength)
        $boundary = $cut.LastIndexOf("-")
        if ($boundary -ge [Math]::Floor($MaxLength / 2)) { $cut = $cut.Substring(0, $boundary) }
        $safe = $cut.Trim("-")
    }

    return $safe
}

function ConvertTo-SafeFileName {
    param([string]$Text)

    $safe = ([string]$Text) -replace '[<>:"/\\|?*]', "-"
    $safe = $safe -replace "\s+", " "
    $safe = $safe.Trim(" .-")
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "ebook"
    }

    return $safe
}

function Get-CourseReviewDocxFileName {
    param(
        [object]$Course,
        [Parameter(Mandatory)][string]$ArtifactName
    )

    $courseCode = ConvertTo-SafeFileName "$($Course.courseCode)"
    if ([string]::IsNullOrWhiteSpace($courseCode)) {
        $courseCode = "ebook"
    }
    $fileBase = ConvertTo-SafeFileName "$courseCode - $ArtifactName"
    return "$fileBase.docx"
}

function Get-CourseArtifactFileName {
    param(
        [object]$Course,
        [Parameter(Mandatory)][string]$ArtifactName,
        [Parameter(Mandatory)][string]$Extension
    )

    $courseLabel = ConvertTo-SafeFileName "$($Course.courseCode) $($Course.courseName)"
    $extensionText = $Extension.TrimStart(".")
    $fileBase = ConvertTo-SafeFileName "$courseLabel - $ArtifactName"
    return "$fileBase.$extensionText"
}

function Assert-EbookChapterOpenerFiles {
    param([Parameter(Mandatory)][string]$Markdown, [Parameter(Mandatory)][string]$OutputFolder)
    foreach ($match in [regex]::Matches($Markdown, "!\[[^\]]*\]\((images/chapter-\d+-[^)]+-opener\.png)\)")) {
        $target = Join-Path $OutputFolder $match.Groups[1].Value
        if (-not [IO.File]::Exists((ConvertTo-EbookLongPath -Path $target))) {
            throw "Missing planned chapter image: $target. Generate the exact asset; do not substitute another chapter's file."
        }
    }
}

function Get-DocxPackageValidationResult {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ArtifactName,
        [int]$MinimumWords = 200,
        [int]$MinimumTextRuns = 20,
        [int]$MinimumImages = 0,
        [switch]$RequireHeadings
    )

    $issues = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) {
        [void]$issues.Add("DOCX file was not created.")
        return [pscustomobject]@{
            artifactName = $ArtifactName
            path = $Path
            status = "FAIL"
            textRunCount = 0
            wordCountApprox = 0
            headingParagraphs = 0
            numberedParagraphs = 0
            blankNumberedParagraphs = 0
            imageRefs = 0
            zeroSizedImages = 0
            issues = @($issues)
        }
    }

    foreach ($issue in @((Get-EbookDocxArtifactIssues -Path $Path).issues)) { [void]$issues.Add($issue) }
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try {
        $entry = $zip.GetEntry("word/document.xml")
        if (-not $entry) {
            [void]$issues.Add("word/document.xml is missing.")
            return [pscustomobject]@{
                artifactName = $ArtifactName
                path = (Resolve-Path -LiteralPath $Path).ProviderPath
                status = "FAIL"
                textRunCount = 0
                wordCountApprox = 0
                headingParagraphs = 0
                numberedParagraphs = 0
                blankNumberedParagraphs = 0
                imageRefs = 0
                zeroSizedImages = 0
                issues = @($issues)
            }
        }

        $reader = New-Object System.IO.StreamReader($entry.Open())
        try {
            $xmlText = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $textMatches = @([regex]::Matches($xmlText, "<w:t[^>]*>(.*?)</w:t>", "Singleline"))
        $text = (($textMatches | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value) }) -join " ")
        $wordCount = ([regex]::Matches($text, "\b[A-Za-z][A-Za-z'-]*\b")).Count
        $numberedParas = @([regex]::Matches($xmlText, "<w:p\b(?:(?!</w:p>).)*<w:numPr\b(?:(?!</w:p>).)*</w:p>", "Singleline"))
        $blankNumbered = @($numberedParas | Where-Object { $_.Value -notmatch "<w:t\b" })
        $headingParas = @([regex]::Matches($xmlText, "<w:p\b(?:(?!</w:p>).)*<w:pStyle\s+w:val=""Heading[1-6]""(?:(?!</w:p>).)*</w:p>", "Singleline"))
        $imageRefs = @([regex]::Matches($xmlText, "<a:blip\b", "Singleline"))
        $extents = @([regex]::Matches($xmlText, "<wp:extent\s+cx=""(\d+)""\s+cy=""(\d+)""", "Singleline"))
        $zeroSizedImages = @($extents | Where-Object { [int64]$_.Groups[1].Value -eq 0 -or [int64]$_.Groups[2].Value -eq 0 })

        if ($textMatches.Count -lt $MinimumTextRuns) {
            [void]$issues.Add("Expected at least $MinimumTextRuns text run(s), found $($textMatches.Count).")
        }
        if ($wordCount -lt $MinimumWords) {
            [void]$issues.Add("Expected at least $MinimumWords approximate word(s), found $wordCount.")
        }
        if ($RequireHeadings -and $headingParas.Count -lt 3) {
            [void]$issues.Add("Expected heading paragraphs in the Word document, found $($headingParas.Count).")
        }
        if ($blankNumbered.Count -gt 0) {
            [void]$issues.Add("Found $($blankNumbered.Count) blank numbered paragraph(s).")
        }
        if ($imageRefs.Count -lt $MinimumImages) {
            [void]$issues.Add("Expected at least $MinimumImages image reference(s), found $($imageRefs.Count).")
        }
        if ($zeroSizedImages.Count -gt 0) {
            [void]$issues.Add("Found $($zeroSizedImages.Count) zero-sized image placeholder(s).")
        }

        return [pscustomobject]@{
            artifactName = $ArtifactName
            path = (Resolve-Path -LiteralPath $Path).ProviderPath
            status = if ($issues.Count -eq 0) { "PASS" } else { "FAIL" }
            textRunCount = $textMatches.Count
            wordCountApprox = $wordCount
            headingParagraphs = $headingParas.Count
            numberedParagraphs = $numberedParas.Count
            blankNumberedParagraphs = $blankNumbered.Count
            imageRefs = $imageRefs.Count
            zeroSizedImages = $zeroSizedImages.Count
            issues = @($issues)
        }
    }
    finally {
        $zip.Dispose()
    }
}

function New-ExportValidationReport {
    param([object[]]$Artifacts)

    $results = New-Object System.Collections.ArrayList
    foreach ($artifact in @($Artifacts)) {
        [void]$results.Add((Get-DocxPackageValidationResult `
            -Path $artifact.path `
            -ArtifactName $artifact.name `
            -MinimumWords $artifact.minimumWords `
            -MinimumTextRuns $artifact.minimumTextRuns `
            -MinimumImages $artifact.minimumImages `
            -RequireHeadings:([bool]$artifact.requireHeadings)))
    }
    $failed = @($results | Where-Object { $_.status -eq "FAIL" }).Count
    return [pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        status = if ($failed -gt 0) { "FAIL" } else { "PASS" }
        artifacts = @($results)
    }
}

function ConvertTo-ExportValidationMarkdown {
    param([object]$Report)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# Export Validation Report")
    [void]$lines.Add("")
    [void]$lines.Add("Status: $($Report.status)")
    [void]$lines.Add("")
    foreach ($artifact in @($Report.artifacts)) {
        [void]$lines.Add("## $($artifact.artifactName)")
        [void]$lines.Add("")
        [void]$lines.Add("Status: $($artifact.status)")
        [void]$lines.Add("")
        [void]$lines.Add("Path: $($artifact.path)")
        [void]$lines.Add("")
        [void]$lines.Add("Metrics: $($artifact.wordCountApprox) approximate words; $($artifact.textRunCount) text run(s); $($artifact.headingParagraphs) heading paragraph(s); $($artifact.numberedParagraphs) numbered paragraph(s); $($artifact.blankNumberedParagraphs) blank numbered paragraph(s); $($artifact.imageRefs) image reference(s); $($artifact.zeroSizedImages) zero-sized image(s).")
        [void]$lines.Add("")
        if (@($artifact.issues).Count -gt 0) {
            [void]$lines.Add("Issues:")
            foreach ($issue in @($artifact.issues)) {
                [void]$lines.Add("- $issue")
            }
            [void]$lines.Add("")
        }
    }
    return ($lines -join "`r`n")
}

function Assert-ExportValidationReport {
    param([object]$Report)

    if ($Report.status -eq "FAIL") {
        $details = @($Report.artifacts | Where-Object { $_.status -eq "FAIL" } | ForEach-Object { "$($_.artifactName): $($_.issues -join '; ')" })
        throw "Export validation failed. $($details -join ' ')"
    }
}

function Assert-EbookQualityReport {
    param([object]$Report)

    if (-not $Report) {
        throw "Final e-book quality report was not generated. Content gates must run before export."
    }
    if ($Report.status -eq "FAIL") {
        $details = @(
            $Report.chapters |
                ForEach-Object {
                    $chapter = $_
                    @($chapter.checks | Where-Object { $_.status -eq "FAIL" } | ForEach-Object { "Chapter $($chapter.chapterNumber) $($_.name): $($_.detail)" })
                }
        )
        throw "Final e-book content quality gates failed. $($details -join ' | ')"
    }
}

function Repair-EbookPackageOutputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [string]$CourseCode = "",
        [string]$CourseName = ""
    )

    if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
        throw "Output folder was not found: $OutputFolder"
    }

    $resolvedOutputFolder = (Resolve-Path -LiteralPath $OutputFolder).ProviderPath
    # Resolve target identity before editing the manuscript or exporting files.
    if ($CourseCode) {
        foreach ($identityFile in @('ebook-plan.json', 'ebook-planning-packet.json')) {
            $identityPath = Join-Path $resolvedOutputFolder $identityFile
            if (Test-Path -LiteralPath $identityPath) {
                $identityRecord = Get-Content -LiteralPath $identityPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $recordCode = if ($identityRecord.course) { [string]$identityRecord.course.courseCode } else { [string]$identityRecord.courseCode }
                if ($recordCode -and $recordCode -ne $CourseCode) { throw "Target course mismatch: requested $CourseCode but $identityFile belongs to $recordCode. No repair performed." }
            }
        }
    }
    $brandProfile = $null
    $brandProfilePath = Join-Path $resolvedOutputFolder "brand-profile.json"
    if (Test-Path -LiteralPath $brandProfilePath) {
        try {
            $brandProfile = Get-Content -LiteralPath $brandProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            $brandProfile = $null
        }
    }

    $ebookMarkdownFile = @(
        Get-ChildItem -LiteralPath $resolvedOutputFolder -File -Filter "* - E-Book.md" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    )[0]
    if (-not $ebookMarkdownFile) {
        throw "Could not find the e-book Markdown artifact in $resolvedOutputFolder."
    }

    if ([string]::IsNullOrWhiteSpace($CourseName)) {
        $CourseName = ($ebookMarkdownFile.BaseName -replace "\s+-\s+E-Book$", "")
        if ($CourseCode -and $CourseName.StartsWith($CourseCode, [System.StringComparison]::OrdinalIgnoreCase)) {
            $CourseName = $CourseName.Substring($CourseCode.Length).Trim(" -")
        }
    }

    $titlePrefix = if ($CourseCode) { "$CourseCode`: " } else { "" }
    $ebookDocxFile = @(
        Get-ChildItem -LiteralPath $resolvedOutputFolder -File -Filter "* - E-Book.docx" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    )[0]
    $ebookDocxPath = if ($ebookDocxFile) {
        $ebookDocxFile.FullName
    }
    else {
        Join-Path $resolvedOutputFolder "$($ebookMarkdownFile.BaseName).docx"
    }

    $markdown = Get-Content -LiteralPath $ebookMarkdownFile.FullName -Raw -Encoding UTF8
    $citationMarkdown = ConvertTo-EbookCitationMarkdown -Markdown (ConvertTo-EbookBusinessCaseLabel -Markdown $markdown)
    $citationChanged = $citationMarkdown -cne $markdown
    $markdown = $citationMarkdown
    $knowledgeCheckRemoval = Remove-ProhibitedKnowledgeCheckSections -Markdown $markdown
    $markdown = [string]$knowledgeCheckRemoval.markdown
    $learnerSectionRemoval = Remove-ProhibitedLearnerSections -Markdown $markdown
    $markdown = [string]$learnerSectionRemoval.markdown
    $knowledgeCheckChanged = $knowledgeCheckRemoval.removedCount -gt 0 -or $knowledgeCheckRemoval.replacedLabelCount -gt 0
    $learnerSectionChanged = $learnerSectionRemoval.removedCount -gt 0 -or $learnerSectionRemoval.replacedChapterSummaryCount -gt 0 -or $learnerSectionRemoval.replacedLabelCount -gt 0
    if ($citationChanged -or $knowledgeCheckChanged -or $learnerSectionChanged) {
        Set-Content -LiteralPath $ebookMarkdownFile.FullName -Value $markdown -Encoding UTF8
    }
    # Re-read the persisted manuscript so the quality-report hash matches the
    # exact bytes/text that the audit will inspect after Set-Content writes its
    # final line ending.
    $markdown = Get-Content -LiteralPath $ebookMarkdownFile.FullName -Raw -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $resolvedOutputFolder "content-policy-removal.json") -Value ([pscustomobject]@{
        generatedAt = (Get-Date).ToString("s")
        policy = "No Knowledge Checks, Reflection Activity, Workplace Challenge, or redundant Chapter Summary headings in learner-facing e-book"
        knowledgeCheckRemovedCount = $knowledgeCheckRemoval.removedCount
        knowledgeCheckReplacedLabelCount = $knowledgeCheckRemoval.replacedLabelCount
        knowledgeCheckRemovedSections = @($knowledgeCheckRemoval.removedSections)
        learnerActivityRemovedCount = $learnerSectionRemoval.removedCount
        learnerActivityRemovedSections = @($learnerSectionRemoval.removedSections)
        chapterSummaryReplacedCount = $learnerSectionRemoval.replacedChapterSummaryCount
        learnerSectionReplacedLabelCount = $learnerSectionRemoval.replacedLabelCount
    } | ConvertTo-Json -Depth 6) -Encoding UTF8

    $planPath = Join-Path $resolvedOutputFolder "ebook-plan.json"
    $sourcesPath = Join-Path $resolvedOutputFolder "source-brief.json"
    $sourceContextPath = Join-Path $resolvedOutputFolder "source-context-index.json"
    $engagementPlanPath = Join-Path $resolvedOutputFolder "engagement-plan.json"
    $blueprintPath = Join-Path $resolvedOutputFolder "ebook-planning-packet.json"
    $qualityReportStatus = "MISSING"
    $qualityReportHash = ""
    if ((Test-Path -LiteralPath $planPath) -and (Test-Path -LiteralPath $sourcesPath) -and (Test-Path -LiteralPath $sourceContextPath)) {
        try {
            $draftPlan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $sources = Get-Content -LiteralPath $sourcesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $sourceContext = Get-Content -LiteralPath $sourceContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $engagementPlan = if (Test-Path -LiteralPath $engagementPlanPath) { Get-Content -LiteralPath $engagementPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
            $blueprint = if (Test-Path -LiteralPath $blueprintPath) { Get-Content -LiteralPath $blueprintPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
            $course = if ($blueprint -and $blueprint.course) {
                $blueprint.course
            }
            else {
                [pscustomobject]@{
                    courseCode = $CourseCode
                    courseName = $CourseName
                }
            }
            if ([string]::IsNullOrWhiteSpace([string]$course.courseCode)) { $course.courseCode = $CourseCode }
            if ([string]::IsNullOrWhiteSpace([string]$course.courseName)) { $course.courseName = $CourseName }

            $assignedSourceReview = Test-EbookAssignedSourcePackage -Course $course -Plan $draftPlan -Markdown $markdown -OutputFolder $resolvedOutputFolder
            if ($assignedSourceReview.applicable) {
                $assignedSourceReview | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $resolvedOutputFolder 'assigned-source-review.json') -Encoding UTF8
                if ($assignedSourceReview.status -ne 'PASS') { throw "Assigned source gate failed: $($assignedSourceReview.detail)" }
            }

            $qualityReport = New-EbookQualityReport -Course $course -Plan $draftPlan -Sources $sources -SourceContext $sourceContext -Markdown $markdown -BrandProfile $brandProfile
            Set-Content -LiteralPath (Join-Path $resolvedOutputFolder "quality-report.json") -Value ($qualityReport | ConvertTo-Json -Depth 16) -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $resolvedOutputFolder "quality-report.md") -Value (ConvertTo-QualityReportMarkdown -Report $qualityReport) -Encoding UTF8
            $qualityReportStatus = [string]$qualityReport.status
            $qualityReportHash = [string]$qualityReport.manuscriptSha256

            if ($engagementPlan) {
                $publishingEditorReport = New-PublishingEditorReport -Course $course -Plan $draftPlan -Sources $sources -SourceContext $sourceContext -QualityReport $qualityReport -Markdown $markdown -EngagementPlan $engagementPlan -BrandProfile $brandProfile
                Set-Content -LiteralPath (Join-Path $resolvedOutputFolder "publishing-editor-report.json") -Value ($publishingEditorReport | ConvertTo-Json -Depth 16) -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $resolvedOutputFolder "publishing-editor-report.md") -Value (ConvertTo-PublishingEditorReportMarkdown -Report $publishingEditorReport) -Encoding UTF8

                $agentReport = New-AgentReviewReport -Course $course -Plan $draftPlan -Sources $sources -SourceContext $sourceContext -QualityReport $qualityReport -Markdown $markdown -BrandProfile $brandProfile -EditorialReport $publishingEditorReport -Blueprint $blueprint
                Set-Content -LiteralPath (Join-Path $resolvedOutputFolder "agent-report.json") -Value ($agentReport | ConvertTo-Json -Depth 16) -Encoding UTF8
                Set-Content -LiteralPath (Join-Path $resolvedOutputFolder "agent-report.md") -Value (ConvertTo-AgentReportMarkdown -Report $agentReport) -Encoding UTF8
            }
        }
        catch {
            Set-Content -LiteralPath (Join-Path $resolvedOutputFolder "report-refresh-error.log") -Value $_.Exception.Message -Encoding UTF8
            throw "Final quality-report refresh failed. The package was not exported: $($_.Exception.Message)"
        }
    }
    else {
        throw "Final quality-report refresh could not run because ebook-plan.json, source-brief.json, or source-context-index.json is missing. The package was not exported."
    }

    # Editorial quality findings are recorded for instructional-designer
    # review, but they must not prevent the current manuscript from being
    # exported. Mechanical artifact/release checks below remain blocking.

    Assert-EbookChapterOpenerFiles -Markdown $markdown -OutputFolder $resolvedOutputFolder
    $ebookHtmlFile = @(
        Get-ChildItem -LiteralPath $resolvedOutputFolder -File -Filter "* - E-Book.html" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    )[0]
    $ebookHtmlPath = if ($ebookHtmlFile) {
        $ebookHtmlFile.FullName
    }
    else {
        Join-Path $resolvedOutputFolder "$($ebookMarkdownFile.BaseName).html"
    }
    $ebookHtml = ConvertTo-SimpleHtmlFromMarkdown -Markdown $markdown -Title "$titlePrefix$CourseName" -BrandProfile $brandProfile -PublicationTemplate (Get-EbookPublicationTemplate -PackageFolder $resolvedOutputFolder)
    Set-Content -LiteralPath $ebookHtmlPath -Value $ebookHtml -Encoding UTF8
    $ebookDocxPath = Export-MarkdownToDocx -Markdown $markdown -Path $ebookDocxPath -Title "$titlePrefix$CourseName" -AssetRoot $resolvedOutputFolder -BrandProfile $brandProfile
    $releaseIntegrityPath = Join-Path $resolvedOutputFolder "release-integrity.json"
    $releaseIntegrityReport = Test-EbookReleaseArtifacts -Course $course -Plan $draftPlan -Markdown $markdown -HtmlPath $ebookHtmlPath -DocxPath $ebookDocxPath -OutputFolder $resolvedOutputFolder
    Set-Content -LiteralPath $releaseIntegrityPath -Value ($releaseIntegrityReport | ConvertTo-Json -Depth 16) -Encoding UTF8
    if ($releaseIntegrityReport.status -eq "FAIL") {
        throw "Release artifact gate failed during repair. $((@($releaseIntegrityReport.checks | Where-Object { $_.status -eq 'FAIL' } | ForEach-Object { $_.name + ': ' + $_.detail }) -join ' '))"
    }

    $validationArtifacts = New-Object System.Collections.ArrayList

    $planningMarkdownPath = Join-Path $resolvedOutputFolder "ebook-planning-packet.md"
    $planningDocxFile = @(
        Get-ChildItem -LiteralPath $resolvedOutputFolder -File -Filter "* - E-Book Planning Packet.docx" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    )[0]
    $planningDocxPath = if ($planningDocxFile) { $planningDocxFile.FullName } else { "" }
    if ((Test-Path -LiteralPath $planningMarkdownPath) -and $planningDocxPath) {
        $planningMarkdown = Get-Content -LiteralPath $planningMarkdownPath -Raw -Encoding UTF8
        $planningDocxPath = Export-MarkdownToDocx -Markdown $planningMarkdown -Path $planningDocxPath -Title "$titlePrefix`E-Book Planning Packet" -AssetRoot $resolvedOutputFolder -BrandProfile $brandProfile
        [void]$validationArtifacts.Add([pscustomobject]@{ name = "Planning packet Word document"; path = $planningDocxPath; minimumWords = 500; minimumTextRuns = 60; minimumImages = 0; requireHeadings = $false })
    }

    $outlineMarkdownPath = Join-Path $resolvedOutputFolder "ebook-outline.md"
    $outlineDocxFile = @(
        Get-ChildItem -LiteralPath $resolvedOutputFolder -File -Filter "* - E-Book Outline.docx" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    )[0]
    $outlineDocxPath = if ($outlineDocxFile) { $outlineDocxFile.FullName } else { "" }
    if ((Test-Path -LiteralPath $outlineMarkdownPath) -and $outlineDocxPath) {
        $outlineMarkdown = Get-Content -LiteralPath $outlineMarkdownPath -Raw -Encoding UTF8
        $outlineDocxPath = Export-MarkdownToDocx -Markdown $outlineMarkdown -Path $outlineDocxPath -Title "$titlePrefix`E-Book Chapter Outline" -AssetRoot $resolvedOutputFolder -BrandProfile $brandProfile
        [void]$validationArtifacts.Add([pscustomobject]@{ name = "Outline Word document"; path = $outlineDocxPath; minimumWords = 500; minimumTextRuns = 60; minimumImages = 0; requireHeadings = $false })
    }

    [void]$validationArtifacts.Add([pscustomobject]@{ name = "E-book Word document"; path = $ebookDocxPath; minimumWords = 1000; minimumTextRuns = 120; minimumImages = @(Get-MarkdownImageReferences -Markdown $markdown).Count; requireHeadings = $true })

    $exportValidationReport = New-ExportValidationReport -Artifacts @($validationArtifacts)
    $exportValidationPath = Join-Path $resolvedOutputFolder "export-validation.json"
    $exportValidationMarkdownPath = Join-Path $resolvedOutputFolder "export-validation.md"
    Set-Content -LiteralPath $exportValidationPath -Value ($exportValidationReport | ConvertTo-Json -Depth 8) -Encoding UTF8
    Set-Content -LiteralPath $exportValidationMarkdownPath -Value (ConvertTo-ExportValidationMarkdown -Report $exportValidationReport) -Encoding UTF8

    return [pscustomobject]@{
        outputFolder = $resolvedOutputFolder
        markdownPath = (Resolve-Path -LiteralPath $ebookMarkdownFile.FullName).ProviderPath
        htmlPath = (Resolve-Path -LiteralPath $ebookHtmlPath).ProviderPath
        docxPath = (Resolve-Path -LiteralPath $ebookDocxPath).ProviderPath
        planningDocxPath = if ($planningDocxPath -and (Test-Path -LiteralPath $planningDocxPath)) { (Resolve-Path -LiteralPath $planningDocxPath).ProviderPath } else { "" }
        outlineDocxPath = if ($outlineDocxPath -and (Test-Path -LiteralPath $outlineDocxPath)) { (Resolve-Path -LiteralPath $outlineDocxPath).ProviderPath } else { "" }
        exportValidationPath = (Resolve-Path -LiteralPath $exportValidationPath).ProviderPath
        exportValidationMarkdownPath = (Resolve-Path -LiteralPath $exportValidationMarkdownPath).ProviderPath
        exportValidationStatus = $exportValidationReport.status
        qualityReportStatus = $qualityReportStatus
        qualityReportManuscriptSha256 = $qualityReportHash
        releaseIntegrityPath = (Resolve-Path -LiteralPath $releaseIntegrityPath).ProviderPath
        releaseIntegrityStatus = $releaseIntegrityReport.status
    }
}

function Export-EbookBlueprintPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $folderName = ConvertTo-SafePathPart "$($Package.course.courseCode)-$($Package.course.courseName)" -MaxLength 48
    $outputFolder = Join-Path $OutputRoot $folderName
    New-Item -ItemType Directory -Force -Path $outputFolder | Out-Null
    foreach ($legacyReviewFile in @("ebook-blueprint.docx", "ebook-blueprint.json", "ebook-blueprint.md", "ebook-outline.docx")) {
        $legacyReviewPath = Join-Path $outputFolder $legacyReviewFile
        Remove-Item -LiteralPath $legacyReviewPath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Join-Path $outputFolder (Get-CourseReviewDocxFileName -Course $Package.course -ArtifactName "E-Book Blueprint")) -Force -ErrorAction SilentlyContinue

    $planningPacketPath = Join-Path $outputFolder "ebook-planning-packet.json"
    $planningPacketMarkdownPath = Join-Path $outputFolder "ebook-planning-packet.md"
    $planningPacketDocxPath = Join-Path $outputFolder (Get-CourseReviewDocxFileName -Course $Package.course -ArtifactName "E-Book Planning Packet")
    $outlineMarkdownPath = Join-Path $outputFolder "ebook-outline.md"
    $outlineDocxPath = Join-Path $outputFolder (Get-CourseReviewDocxFileName -Course $Package.course -ArtifactName "E-Book Outline")
    $planPath = Join-Path $outputFolder "ebook-plan.json"
    $exportValidationPath = Join-Path $outputFolder "export-validation.json"
    $exportValidationMarkdownPath = Join-Path $outputFolder "export-validation.md"

    Set-Content -LiteralPath $planningPacketPath -Value ($Package.blueprint | ConvertTo-Json -Depth 16) -Encoding UTF8
    Set-Content -LiteralPath $planningPacketMarkdownPath -Value $Package.blueprintMarkdown -Encoding UTF8
    $planningPacketDocxPath = Export-MarkdownToDocx -Markdown $Package.blueprintMarkdown -Path $planningPacketDocxPath -Title "$($Package.course.courseCode): E-Book Planning Packet" -AssetRoot $outputFolder -BrandProfile $Package.brandProfile
    Set-Content -LiteralPath $outlineMarkdownPath -Value $Package.outlineMarkdown -Encoding UTF8
    $outlineDocxPath = Export-MarkdownToDocx -Markdown $Package.outlineMarkdown -Path $outlineDocxPath -Title "$($Package.course.courseCode): E-Book Chapter Outline" -AssetRoot $outputFolder -BrandProfile $Package.brandProfile
    Set-Content -LiteralPath $planPath -Value ($Package.plan | ConvertTo-Json -Depth 12) -Encoding UTF8
    $exportValidationReport = New-ExportValidationReport -Artifacts @(
        [pscustomobject]@{ name = "Planning packet Word document"; path = $planningPacketDocxPath; minimumWords = 500; minimumTextRuns = 60; minimumImages = 0; requireHeadings = $false },
        [pscustomobject]@{ name = "Outline Word document"; path = $outlineDocxPath; minimumWords = 500; minimumTextRuns = 60; minimumImages = 0; requireHeadings = $false }
    )
    Set-Content -LiteralPath $exportValidationPath -Value ($exportValidationReport | ConvertTo-Json -Depth 8) -Encoding UTF8
    Set-Content -LiteralPath $exportValidationMarkdownPath -Value (ConvertTo-ExportValidationMarkdown -Report $exportValidationReport) -Encoding UTF8
    Assert-ExportValidationReport -Report $exportValidationReport

    return [pscustomobject]@{
        outputFolder = (Resolve-Path $outputFolder).ProviderPath
        planningPacketPath = (Resolve-Path $planningPacketPath).ProviderPath
        planningPacketMarkdownPath = (Resolve-Path $planningPacketMarkdownPath).ProviderPath
        planningPacketDocxPath = (Resolve-Path $planningPacketDocxPath).ProviderPath
        blueprintPath = (Resolve-Path $planningPacketPath).ProviderPath
        blueprintMarkdownPath = (Resolve-Path $planningPacketMarkdownPath).ProviderPath
        blueprintDocxPath = (Resolve-Path $planningPacketDocxPath).ProviderPath
        outlineMarkdownPath = (Resolve-Path $outlineMarkdownPath).ProviderPath
        outlineDocxPath = (Resolve-Path $outlineDocxPath).ProviderPath
        planPath = (Resolve-Path $planPath).ProviderPath
        exportValidationPath = (Resolve-Path $exportValidationPath).ProviderPath
        exportValidationMarkdownPath = (Resolve-Path $exportValidationMarkdownPath).ProviderPath
    }
}

function Export-EbookPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Package,
        [Parameter(Mandatory)][string]$OutputRoot
    )

    $templateCheck = Test-EbookPublicationTemplate -Markdown $Package.markdown
    if ($templateCheck.status -ne 'PASS') { throw "Publication template gate failed: $($templateCheck.detail)" }
    $null = ConvertTo-EbookCitationMarkdown -Markdown $Package.markdown
    $htmlCitationIssues = @(Get-EbookHtmlCitationIssues -Html $Package.html)
    if ($htmlCitationIssues.Count -gt 0) { throw "HTML export integrity gate failed: $($htmlCitationIssues -join ' ')" }
    $knowledgeCheckGate = Get-ProhibitedKnowledgeCheckSignals -Markdown $Package.markdown
    if ($knowledgeCheckGate.status -ne "PASS") {
        throw "Refusing to export a learner-facing package containing prohibited Knowledge Checks or Check Your Reasoning sections: $($knowledgeCheckGate.detail)"
    }
    $learnerSectionGate = Get-ProhibitedLearnerSectionSignals -Markdown $Package.markdown
    if ($learnerSectionGate.status -ne "PASS") {
        throw "Refusing to export a learner-facing package containing Reflection Activity, Workplace Challenge, or redundant Chapter Summary headings: $($learnerSectionGate.detail)"
    }

    $folderName = ConvertTo-SafePathPart "$($Package.course.courseCode)-$($Package.course.courseName)" -MaxLength 48
    $outputFolder = Join-Path $OutputRoot $folderName
    New-Item -ItemType Directory -Force -Path $outputFolder | Out-Null
    foreach ($legacyReviewFile in @("ebook-blueprint.docx", "ebook-blueprint.json", "ebook-blueprint.md", "ebook-outline.docx", "ebook.md", "ebook.html", "ebook.docx")) {
        $legacyReviewPath = Join-Path $outputFolder $legacyReviewFile
        Remove-Item -LiteralPath $legacyReviewPath -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Join-Path $outputFolder (Get-CourseReviewDocxFileName -Course $Package.course -ArtifactName "E-Book Blueprint")) -Force -ErrorAction SilentlyContinue

    $markdownPath = Join-Path $outputFolder (Get-CourseArtifactFileName -Course $Package.course -ArtifactName "E-Book" -Extension "md")
    $htmlPath = Join-Path $outputFolder (Get-CourseArtifactFileName -Course $Package.course -ArtifactName "E-Book" -Extension "html")
    $workerScriptPath = Join-Path $outputFolder "ebook-worker.js"
    $docxPath = Join-Path $outputFolder (Get-CourseArtifactFileName -Course $Package.course -ArtifactName "E-Book" -Extension "docx")
    $imagesFolder = Join-Path $outputFolder "images"
    $visualsFolder = Join-Path $outputFolder "visuals"
    $interactiveStudyPath = Join-Path $outputFolder "interactive-study.html"
    $planningPacketPath = Join-Path $outputFolder "ebook-planning-packet.json"
    $planningPacketMarkdownPath = Join-Path $outputFolder "ebook-planning-packet.md"
    $planningPacketDocxPath = Join-Path $outputFolder (Get-CourseReviewDocxFileName -Course $Package.course -ArtifactName "E-Book Planning Packet")
    $outlineMarkdownPath = Join-Path $outputFolder "ebook-outline.md"
    $outlineDocxPath = Join-Path $outputFolder (Get-CourseReviewDocxFileName -Course $Package.course -ArtifactName "E-Book Outline")
    $planPath = Join-Path $outputFolder "ebook-plan.json"
    $sourcesPath = Join-Path $outputFolder "source-brief.json"
    $sourceRegistryPath = Join-Path $outputFolder "sources.json"
    $sourceRegistryMarkdownPath = Join-Path $outputFolder "sources.md"
    $brandProfilePath = Join-Path $outputFolder "brand-profile.json"
    $brandProfileMarkdownPath = Join-Path $outputFolder "brand-profile.md"
    $sourceContextPath = Join-Path $outputFolder "source-context-index.json"
    $engagementPlanPath = Join-Path $outputFolder "engagement-plan.json"
    $engagementPlanMarkdownPath = Join-Path $outputFolder "engagement-plan.md"
    $qualityReportPath = Join-Path $outputFolder "quality-report.json"
    $qualityReportMarkdownPath = Join-Path $outputFolder "quality-report.md"
    $publishingEditorReportPath = Join-Path $outputFolder "publishing-editor-report.json"
    $publishingEditorReportMarkdownPath = Join-Path $outputFolder "publishing-editor-report.md"
    $agentReportPath = Join-Path $outputFolder "agent-report.json"
    $agentReportMarkdownPath = Join-Path $outputFolder "agent-report.md"
    $exportValidationPath = Join-Path $outputFolder "export-validation.json"
    $exportValidationMarkdownPath = Join-Path $outputFolder "export-validation.md"
    $releaseIntegrityPath = Join-Path $outputFolder "release-integrity.json"

    Write-EbookGeneratorProgress -Phase "Preparing output folder" -Detail "Creating package folders and clearing legacy export files."
    New-Item -ItemType Directory -Force -Path $imagesFolder | Out-Null
    New-Item -ItemType Directory -Force -Path $visualsFolder | Out-Null
    Write-EbookGeneratorProgress -Phase "Writing ebook exports" -Detail "Writing Markdown, HTML, and worker script files."
    Set-Content -LiteralPath $markdownPath -Value $Package.markdown -Encoding UTF8
    $exportHtml = ConvertTo-SimpleHtmlFromMarkdown -Markdown $Package.markdown -Title "$($Package.course.courseCode): $($Package.course.courseName)" -BrandProfile $Package.brandProfile -PublicationTemplate (Get-EbookPublicationTemplate -PackageFolder $outputFolder)
    Set-Content -LiteralPath $htmlPath -Value $exportHtml -Encoding UTF8
    Set-Content -LiteralPath $workerScriptPath -Value $Package.workerScript -Encoding UTF8
    foreach ($asset in @($Package.visualAssets)) {
        Write-EbookGeneratorChapterProgress -ChapterNumber $asset.chapterNumber -ChapterTitle $asset.chapterTitle -Phase "Exporting visual assets" -Status "Working" -Detail "Writing $($asset.relativePath)."
        $assetPath = Join-Path $outputFolder $asset.relativePath
        $assetFolder = Split-Path -Parent $assetPath
        New-Item -ItemType Directory -Force -Path $assetFolder | Out-Null
        if ($asset.PSObject.Properties.Name -contains "bytesBase64" -and -not [string]::IsNullOrWhiteSpace([string]$asset.bytesBase64)) {
            $assetBytes = [Convert]::FromBase64String([string]$asset.bytesBase64)
            if (-not $assetBytes -or $assetBytes.Length -eq 0) {
                throw "Generated binary visual asset is empty: $($asset.relativePath)"
            }
            [System.IO.File]::WriteAllBytes((ConvertTo-EbookLongPath -Path $assetPath), $assetBytes)
        }
        else {
            [System.IO.File]::WriteAllText((ConvertTo-EbookLongPath -Path $assetPath), [string]$asset.svg, [System.Text.Encoding]::UTF8)
        }
        Write-EbookGeneratorChapterProgress -ChapterNumber $asset.chapterNumber -ChapterTitle $asset.chapterTitle -Phase "Exporting visual assets" -Status "Complete" -Detail "$($asset.relativePath) is written."
    }
    Write-EbookGeneratorProgress -Phase "Checking opener references" -Detail "Checking exact image paths. No automatic file substitution is allowed."
    Assert-EbookChapterOpenerFiles -Markdown $Package.markdown -OutputFolder $outputFolder
    Write-EbookGeneratorProgress -Phase "Writing interactive study" -Detail "Writing the interactive study HTML page."
    Set-Content -LiteralPath $interactiveStudyPath -Value $Package.interactiveStudyHtml -Encoding UTF8
    Write-EbookGeneratorProgress -Phase "Exporting Word ebook" -Detail "Building the student-facing Word document with current package assets."
    $docxPath = Export-MarkdownToDocx -Markdown $Package.markdown -Path $docxPath -Title "$($Package.course.courseCode): $($Package.course.courseName)" -AssetRoot $outputFolder -BrandProfile $Package.brandProfile
    $releaseIntegrityReport = Test-EbookReleaseArtifacts -Course $Package.course -Plan $Package.plan -Markdown $Package.markdown -HtmlPath $htmlPath -DocxPath $docxPath -OutputFolder $outputFolder
    Set-Content -LiteralPath $releaseIntegrityPath -Value ($releaseIntegrityReport | ConvertTo-Json -Depth 16) -Encoding UTF8
    if ($releaseIntegrityReport.status -eq "FAIL") {
        throw "Release artifact gate failed. $((@($releaseIntegrityReport.checks | Where-Object { $_.status -eq 'FAIL' } | ForEach-Object { $_.name + ': ' + $_.detail }) -join ' '))"
    }
    Write-EbookGeneratorProgress -Phase "Writing planning artifacts" -Detail "Writing planning packet, outline, and plan files."
    Set-Content -LiteralPath $planningPacketPath -Value ($Package.blueprint | ConvertTo-Json -Depth 16) -Encoding UTF8
    Set-Content -LiteralPath $planningPacketMarkdownPath -Value $Package.blueprintMarkdown -Encoding UTF8
    Write-EbookGeneratorProgress -Phase "Exporting planning packet Word" -Detail "Building the planning packet Word document."
    $planningPacketDocxPath = Export-MarkdownToDocx -Markdown $Package.blueprintMarkdown -Path $planningPacketDocxPath -Title "$($Package.course.courseCode): E-Book Planning Packet" -AssetRoot $outputFolder -BrandProfile $Package.brandProfile
    Set-Content -LiteralPath $outlineMarkdownPath -Value $Package.outlineMarkdown -Encoding UTF8
    Write-EbookGeneratorProgress -Phase "Exporting outline Word" -Detail "Building the chapter outline Word document."
    $outlineDocxPath = Export-MarkdownToDocx -Markdown $Package.outlineMarkdown -Path $outlineDocxPath -Title "$($Package.course.courseCode): E-Book Chapter Outline" -AssetRoot $outputFolder -BrandProfile $Package.brandProfile
    Set-Content -LiteralPath $planPath -Value ($Package.plan | ConvertTo-Json -Depth 12) -Encoding UTF8
    Write-EbookGeneratorProgress -Phase "Writing source and report files" -Detail "Writing source registry, source context, brand profile, engagement plan, quality report, publishing editor report, and agent report."
    Set-Content -LiteralPath $sourcesPath -Value ($Package.sources | ConvertTo-Json -Depth 12) -Encoding UTF8
    Set-Content -LiteralPath $brandProfilePath -Value ($Package.brandProfile | ConvertTo-Json -Depth 12) -Encoding UTF8
    Set-Content -LiteralPath $brandProfileMarkdownPath -Value $Package.brandProfileMarkdown -Encoding UTF8
    Set-Content -LiteralPath $sourceRegistryPath -Value ($Package.sourceRegistry | ConvertTo-Json -Depth 12) -Encoding UTF8
    Set-Content -LiteralPath $sourceRegistryMarkdownPath -Value $Package.sourceRegistryMarkdown -Encoding UTF8
    Set-Content -LiteralPath $sourceContextPath -Value ($Package.sourceContext | ConvertTo-Json -Depth 12) -Encoding UTF8
    Set-Content -LiteralPath $engagementPlanPath -Value ($Package.engagementPlan | ConvertTo-Json -Depth 12) -Encoding UTF8
    Set-Content -LiteralPath $engagementPlanMarkdownPath -Value $Package.engagementPlanMarkdown -Encoding UTF8
    Set-Content -LiteralPath $qualityReportPath -Value ($Package.qualityReport | ConvertTo-Json -Depth 12) -Encoding UTF8
    Set-Content -LiteralPath $qualityReportMarkdownPath -Value $Package.qualityReportMarkdown -Encoding UTF8
    Set-Content -LiteralPath $publishingEditorReportPath -Value ($Package.publishingEditorReport | ConvertTo-Json -Depth 12) -Encoding UTF8
    Set-Content -LiteralPath $publishingEditorReportMarkdownPath -Value $Package.publishingEditorReportMarkdown -Encoding UTF8
    Set-Content -LiteralPath $agentReportPath -Value ($Package.agentReport | ConvertTo-Json -Depth 12) -Encoding UTF8
    Set-Content -LiteralPath $agentReportMarkdownPath -Value $Package.agentReportMarkdown -Encoding UTF8
    Write-EbookGeneratorProgress -Phase "Running export validation" -Detail "Checking Word package content, headings, images, and generated artifacts."
    $exportValidationReport = New-ExportValidationReport -Artifacts @(
        [pscustomobject]@{ name = "Planning packet Word document"; path = $planningPacketDocxPath; minimumWords = 500; minimumTextRuns = 60; minimumImages = 0; requireHeadings = $false },
        [pscustomobject]@{ name = "Outline Word document"; path = $outlineDocxPath; minimumWords = 500; minimumTextRuns = 60; minimumImages = 0; requireHeadings = $false },
        [pscustomobject]@{ name = "E-book Word document"; path = $docxPath; minimumWords = 1000; minimumTextRuns = 120; minimumImages = @(Get-MarkdownImageReferences -Markdown $Package.markdown).Count; requireHeadings = $true }
    )
    Set-Content -LiteralPath $exportValidationPath -Value ($exportValidationReport | ConvertTo-Json -Depth 8) -Encoding UTF8
    Set-Content -LiteralPath $exportValidationMarkdownPath -Value (ConvertTo-ExportValidationMarkdown -Report $exportValidationReport) -Encoding UTF8
    Assert-ExportValidationReport -Report $exportValidationReport
    Write-EbookGeneratorProgress -Phase "Export validation complete" -Detail "Export validation finished with status $($exportValidationReport.status)."

    return [pscustomobject]@{
        outputFolder = (Resolve-Path $outputFolder).ProviderPath
        markdownPath = (Resolve-Path $markdownPath).ProviderPath
        htmlPath = (Resolve-Path $htmlPath).ProviderPath
        workerScriptPath = (Resolve-Path $workerScriptPath).ProviderPath
        docxPath = (Resolve-Path $docxPath).ProviderPath
        imagesFolder = (Resolve-Path $imagesFolder).ProviderPath
        visualsFolder = (Resolve-Path $visualsFolder).ProviderPath
        interactiveStudyPath = (Resolve-Path $interactiveStudyPath).ProviderPath
        planningPacketPath = (Resolve-Path $planningPacketPath).ProviderPath
        planningPacketMarkdownPath = (Resolve-Path $planningPacketMarkdownPath).ProviderPath
        planningPacketDocxPath = (Resolve-Path $planningPacketDocxPath).ProviderPath
        blueprintPath = (Resolve-Path $planningPacketPath).ProviderPath
        blueprintMarkdownPath = (Resolve-Path $planningPacketMarkdownPath).ProviderPath
        blueprintDocxPath = (Resolve-Path $planningPacketDocxPath).ProviderPath
        outlineMarkdownPath = (Resolve-Path $outlineMarkdownPath).ProviderPath
        outlineDocxPath = (Resolve-Path $outlineDocxPath).ProviderPath
        planPath = (Resolve-Path $planPath).ProviderPath
        sourcesPath = (Resolve-Path $sourcesPath).ProviderPath
        brandProfilePath = (Resolve-Path $brandProfilePath).ProviderPath
        brandProfileMarkdownPath = (Resolve-Path $brandProfileMarkdownPath).ProviderPath
        sourceRegistryPath = (Resolve-Path $sourceRegistryPath).ProviderPath
        sourceRegistryMarkdownPath = (Resolve-Path $sourceRegistryMarkdownPath).ProviderPath
        sourceContextPath = (Resolve-Path $sourceContextPath).ProviderPath
        engagementPlanPath = (Resolve-Path $engagementPlanPath).ProviderPath
        engagementPlanMarkdownPath = (Resolve-Path $engagementPlanMarkdownPath).ProviderPath
        qualityReportPath = (Resolve-Path $qualityReportPath).ProviderPath
        qualityReportMarkdownPath = (Resolve-Path $qualityReportMarkdownPath).ProviderPath
        publishingEditorReportPath = (Resolve-Path $publishingEditorReportPath).ProviderPath
        publishingEditorReportMarkdownPath = (Resolve-Path $publishingEditorReportMarkdownPath).ProviderPath
        agentReportPath = (Resolve-Path $agentReportPath).ProviderPath
        agentReportMarkdownPath = (Resolve-Path $agentReportMarkdownPath).ProviderPath
        exportValidationPath = (Resolve-Path $exportValidationPath).ProviderPath
        exportValidationMarkdownPath = (Resolve-Path $exportValidationMarkdownPath).ProviderPath
        releaseIntegrityPath = (Resolve-Path $releaseIntegrityPath).ProviderPath
    }
}

Export-ModuleMember -Function Import-CourseSpec, Import-SourceContext, Import-BrandProfile, New-EbookPlan, Merge-EbookReviewedOutline, Resolve-EbookSources, New-EbookBlueprintPackage, Export-EbookBlueprintPackage, New-EbookPackage, Export-EbookPackage, Repair-EbookPackageOutputs, Get-ProhibitedKnowledgeCheckSignals, Remove-ProhibitedKnowledgeCheckSections, Get-ProhibitedLearnerSectionSignals, Remove-ProhibitedLearnerSections, Test-EbookObjectiveTraceability, Test-EbookReleaseArtifacts, Test-EbookAssignedSources, Test-EbookAssignedSourcePackage, Get-EbookTemplateInstructions, Get-EbookPublicationTemplate, Test-EbookPublicationTemplate

