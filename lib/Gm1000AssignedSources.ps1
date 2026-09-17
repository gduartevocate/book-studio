# Explicit editorial reconstruction, never a blanket citation replacement.
function Update-Gm1000AssignedSourceChapters {
    param([string[]]$Chapters, [object]$Manifest, [string]$AdditionsPath)
    $text = Get-Content -LiteralPath $AdditionsPath -Raw -Encoding UTF8
    $blocks = @{}
    foreach ($match in [regex]::Matches($text, '(?ms)^# (?<key>[a-z0-9-]+)\r?\n(?<body>.*?)(?=^# |\z)')) { $blocks[$match.Groups['key'].Value] = $match.Groups['body'].Value.Trim() }
    $insertions = @(
        @{chapter=1;before='### Comparing the Same Request Across Three Structures';key='insert-1-authority'},
        @{chapter=1;before='## Section 1.3';key='insert-1-environment'},
        @{chapter=2;before='### Finance: Resources, Controls, and Timing';key='insert-2-functions'},
        @{chapter=2;before='### Creating a Simple Process Map';key='insert-2-design'},
        @{chapter=3;before='### Risk Points and Controls';key='insert-3-capacity'},
        @{chapter=3;before='## Section 3.3';key='insert-3-quality'},
        @{chapter=4;before='## Section 4.2';key='insert-4-value'},
        @{chapter=4;before='## Section 4.3';key='insert-4-gaps'},
        @{chapter=5;before='### Identifying the Problem: Symptom Versus Cause';key='insert-5-study'},
        @{chapter=5;before='### Recommending One Practical Change';key='insert-5-decisions'}
    )
    $result = New-Object System.Collections.ArrayList
    $usedBlocks = New-Object System.Collections.ArrayList
    for ($i=0; $i -lt $Chapters.Count; $i++) {
        $n = $i+1
        $body = [regex]::Replace($Chapters[$i], '(?ms)^## Scholarly Sources\r?\n.*\z', '').Trim()
        $paragraphs = @($body -split '\r?\n\s*\r?\n')
        for ($p=0; $p -lt $paragraphs.Count; $p++) {
            $citation = [regex]::Match($paragraphs[$p], '\[\d+\]\(#chapter-(?<chapter>\d+)-note-(?<note>\d+)\)')
            if (-not $citation.Success) { continue }
            $key = "replace-$n-$($citation.Groups['note'].Value)"
            if (-not $blocks.ContainsKey($key) -or $key -in $usedBlocks) { throw "Missing or ambiguous source rewrite: $key" }
            $paragraphs[$p] = $blocks[$key]
            [void]$usedBlocks.Add($key)
        }
        $body = $paragraphs -join "`n`n"
        foreach ($insertion in @($insertions | Where-Object chapter -eq $n)) {
            $found = [regex]::Matches($body, '(?m)^' + [regex]::Escape($insertion.before))
            if ($found.Count -ne 1 -or -not $blocks.ContainsKey($insertion.key)) { throw "Cannot place source development: $($insertion.key)" }
            $body = $body.Insert($found[0].Index, $blocks[$insertion.key] + "`n`n")
            [void]$usedBlocks.Add($insertion.key)
        }
        # ASCII script literals avoid Windows PowerShell's ANSI decoding of a
        # UTF-8 script without a BOM. Preserve all unrelated punctuation.
        $body = [regex]::Replace($body, '4:00 PM\.\u201D is evidence', ('4:00 PM' + [char]0x201D + ' is evidence'))
        $body = $body.Replace('Priya Shah', 'Priya Nair')
        if ($n -eq 2) {
            $body = $body.Replace('She can describe the request', 'Jordan can describe the request').Replace('She provides the expected volume', 'Jordan provides the expected volume').Replace('It helps her communicate', 'It helps Jordan communicate')
            $body = $body.Replace('Human resources, sometimes called human relations in course materials, focuses', 'Human resources focuses')
        }
        if ($n -eq 3) {
            $body = $body.Replace('Maya uses the clinic', 'As Chapter 1 showed, Maya uses the clinic')
        }
        if ($n -eq 4) {
            $body = [regex]::Replace($body, 'The patient\u2019s experience improves immediately because the office communicates clearly\..*?Customer service and operations are connected\.', 'The patient now has a documented update and a named contact. The team still needs evidence that its new routine reduces missed commitments over time. Clear communication helps the immediate response; a sustained improvement must be demonstrated in later service records.')
        }
        $vocabularyKey = "vocabulary-$n"
        $vocabularyPattern = '(?ms)^### Vocabulary Review\r?\n.*?(?=^## |\z)'
        if ([regex]::Matches($body, $vocabularyPattern).Count -ne 1 -or -not $blocks.ContainsKey($vocabularyKey)) { throw "Missing chapter $n vocabulary mapping." }
        $body = [regex]::Replace($body, $vocabularyPattern, [Text.RegularExpressions.MatchEvaluator]{param($m) $blocks[$vocabularyKey] + "`n`n" })
        [void]$usedBlocks.Add($vocabularyKey)
        if ($body -match '\[\d+\]\(#chapter-') { throw 'A legacy citation survived source reconstruction.' }
        $sourceIds = New-Object System.Collections.ArrayList
        foreach ($cite in [regex]::Matches($body, '\[cite:([a-z0-9-]+)\]')) { if ($cite.Groups[1].Value -notin $sourceIds) { [void]$sourceIds.Add($cite.Groups[1].Value) } }
        $week = @($Manifest.weeks | Where-Object number -eq $n)[0]
        if (@($sourceIds | Where-Object { $_ -notin $week.sectionIds }).Count) { throw "An unassigned source was used in chapter $n." }
        $body = [regex]::Replace($body, '\[cite:([a-z0-9-]+)\]', [Text.RegularExpressions.MatchEvaluator]{param($cite)
            $index = $sourceIds.IndexOf($cite.Groups[1].Value) + 1
            return "[$index](#chapter-$n-note-$index)"
        })
        $notes = @(); $linkedResources = @()
        for ($s=0; $s -lt $sourceIds.Count; $s++) {
            $section = @($Manifest.sections | Where-Object id -eq $sourceIds[$s])[0]
            $resource = @($Manifest.resources | Where-Object id -eq $section.resourceId)[0]
            if (-not $section -or -not $resource) { throw 'Source manifest contains an unresolved reference.' }
            $container = if ($resource.sourceType -eq 'Research') { $resource.publisher } else { "$($resource.title). $($resource.publisher)" }
            $line = "$($s+1). $($resource.authors) ($($resource.year)). [$($section.title)]($($section.url)). $container."
            if ($resource.id -notin $linkedResources) {
                if ($section.url -ne $resource.url) { $line += " [Assigned book]($($resource.url))." }
                $linkedResources += $resource.id
            }
            if ($section.fullTextUrl) { $line += " [Full article PDF]($($section.fullTextUrl))." }
            $notes += $line
        }
        $body += "`n`n## Scholarly Sources`n`n" + ($notes -join "`n")
        [void]$result.Add($body)
    }
    if (@($blocks.Keys | Where-Object { $_ -notin $usedBlocks }).Count) { throw 'Unused source revision blocks: editorial mapping is incomplete.' }
    return @($result)
}

function New-Gm1000AssignedSourceBrief {
    param([object]$Manifest, [object]$Course, [string]$CurriculumPath)
    foreach ($week in $Manifest.weeks) {
        $records = @(foreach ($id in $week.sectionIds) {
            $section = @($Manifest.sections | Where-Object id -eq $id)[0]
            $resource = @($Manifest.resources | Where-Object id -eq $section.resourceId)[0]
            [pscustomobject]@{
                id=$id;resourceId=$resource.id;title=$section.title;book=$resource.title;publisher=$resource.publisher
                authors=@($resource.authors);year=$resource.year;url=$section.url;sourceType=$resource.sourceType
                licenseNote=$resource.licenseNote;preview=$section.concepts;reviewStatus=$section.reviewStatus
                matchedRule="User-assigned week $($week.number)"
            }
        })
        $curriculumWeek = @($Course.weeks | Where-Object number -eq $week.number)[0]
        [pscustomobject]@{
            chapterNumber=$week.number;chapterTitle=$curriculumWeek.title
            sourcePolicy=[pscustomobject]@{summary=$Manifest.authority;openStaxAttributionNote=$Manifest.rightsStatus;lockedWeeklyAssignments=$true}
            sourceContext=@([pscustomobject]@{chunkId="authoritative-week-$($week.number)";sourceName=[IO.Path]::GetFileName($CurriculumPath);sourceFile=$CurriculumPath;score=1000;text=($curriculumWeek.modules | ForEach-Object { $_.objective + ' ' + ($_.subObjectives -join ' ') }) -join "`n"})
            openStax=@($records | Where-Object sourceType -eq 'OpenStax')
            oer=@($records | Where-Object sourceType -eq 'OER')
            researchCandidates=@($records | Where-Object sourceType -eq 'Research')
            assignedSources=$records
        }
    }
}
