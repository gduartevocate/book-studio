function ConvertTo-EbookAssignedReadingMarkdown {
    param([object]$Course, [object]$Plan, [object]$Manifest, [string]$Markdown)
    if ($Manifest.courseCode -ne $Course.courseCode -or $Plan.courseCode -ne $Course.courseCode) { throw 'Assigned manuscript target course mismatch.' }
    $chapters = @([regex]::Matches($Markdown, '(?ms)^# Chapter (?<n>\d+): (?<title>[^\r\n]+)\r?\n.*?(?=^# Chapter |\z)'))
    if ($chapters.Count -ne @($Course.weeks).Count) { throw 'Assigned manuscript chapter count differs from the curriculum.' }
    $result = @(); $seen = @()
    foreach ($chapter in $chapters) {
        $n = [int]$chapter.Groups['n'].Value
        if ($n -in $seen -or $n -ne $seen.Count+1) { throw 'Assigned manuscript chapters must occur exactly once in curriculum order.' }
        $seen += $n
        $week = @($Course.weeks | Where-Object number -eq $n)
        $assignment = @($Manifest.weeks | Where-Object number -eq $n)
        if ($week.Count -ne 1 -or $assignment.Count -ne 1 -or $chapter.Groups['title'].Value.Trim() -ne $week[0].title) { throw "Chapter ${n}: title or assignment does not match curriculum." }
        $body = $chapter.Value.Trim()
        $token = "[objectives:$n]"
        if ([regex]::Matches($body,[regex]::Escape($token)).Count -ne 1) { throw "Chapter ${n}: one objective insertion point is required." }
        $objectives = @(); $j=0
        foreach ($objective in $week[0].modules) {
            if (-not $objective.objectiveId -or -not $objective.objective) { throw 'Source objective identity/text is missing.' }
            $j++; $objectives += "$j. $($objective.objective)"
        }
        $body = $body.Replace($token,($objectives -join "`n"))
        if ($body -match '(?m)^## Scholarly Sources' -or $body -match '\]\(https?://') { throw 'Authoring manuscript must use assigned source IDs; do not carry a legacy bibliography or external links.' }
        $ids = [Collections.Generic.List[string]]::new()
        foreach ($cite in [regex]::Matches($body,'\[cite:([a-z0-9-]+)\]')) {
            $id=$cite.Groups[1].Value
            if ($id -notin $assignment[0].sectionIds) { throw "Chapter ${n}: unassigned source ID $id." }
            if (-not $ids.Contains($id)) { $ids.Add($id) }
        }
        if ((@($ids | Sort-Object) -join '|') -ne (@($assignment[0].sectionIds | Sort-Object) -join '|')) { throw "Chapter ${n}: a required reading is missing from the teaching." }
        $body = [regex]::Replace($body,'\[cite:([a-z0-9-]+)\]',[Text.RegularExpressions.MatchEvaluator]{param($m)
            $index=$ids.IndexOf($m.Groups[1].Value)+1
            return "[$index](#chapter-$n-note-$index)"
        })
        $notes=@(); $books=@()
        for ($i=0;$i -lt $ids.Count;$i++) {
            $section=@($Manifest.sections | Where-Object id -eq $ids[$i])
            if ($section.Count -ne 1 -or $section[0].reviewStatus -ne 'CONTENT_REVIEWED') { throw 'Source is unresolved, duplicated, or not content-reviewed.' }
            $section=$section[0]; $resource=@($Manifest.resources | Where-Object id -eq $section.resourceId)
            if ($resource.Count -ne 1 -or $resource[0].id -notin $assignment[0].resourceIds) { throw 'Assigned source book identity is invalid.' }
            $resource=$resource[0]
            $line="$($i+1). $($resource.authors) ($($resource.year)). [$($section.title)]($($section.url)). $($resource.title). $($resource.publisher)."
            if ($resource.id -notin $books) { $line += " [Book information]($($resource.url))."; $books += $resource.id }
            $notes += $line
        }
        if ($body -match '\[(?:cite|objectives):|<span|&lt;span') { throw 'Unresolved authoring marker or legacy citation markup.' }
        $result += $body + "`n`n## Scholarly Sources`n`n" + ($notes -join "`n")
    }
    $rendered = ($result -join "`n`n") + "`n"
    $trace = Test-EbookObjectiveTraceability -Course $Course -Plan $Plan -Markdown $rendered
    if ($trace.status -ne 'PASS') { throw $trace.detail }
    $sources = Test-EbookAssignedSources -Course $Course -Plan $Plan -Markdown $rendered -Manifest $Manifest
    if ($sources.status -ne 'PASS') { throw $sources.detail }
    return $rendered
}

function New-EbookAssignedSourceBrief {
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
            sourceContext=@([pscustomobject]@{chunkId="authoritative-week-$($week.number)";sourceName=[IO.Path]::GetFileName($CurriculumPath);sourceFile=$CurriculumPath;score=1000;text=($curriculumWeek.modules.objective -join ' ')})
            openStax=@($records | Where-Object sourceType -eq 'OpenStax');oer=@($records | Where-Object sourceType -eq 'OER')
            researchCandidates=@($records | Where-Object sourceType -eq 'Research');assignedSources=$records
        }
    }
}

function Test-EbookAssignedSources {
    param([object]$Course, [object]$Plan, [string]$Markdown, [object]$Manifest)
    $issues = New-Object System.Collections.ArrayList
    $chapters = @([regex]::Matches($Markdown, '(?ms)^# Chapter (?<n>\d+):.*?(?=^# Chapter |\z)'))
    if (-not $Manifest -or $Manifest.schemaVersion -ne 1 -or $Manifest.courseCode -ne $Course.courseCode -or $Manifest.courseCode -ne $Plan.courseCode) { [void]$issues.Add('Assigned reading-list schema or target course mismatch.') }
    if (@($Manifest.weeks).Count -ne @($Course.weeks).Count -or $chapters.Count -ne @($Manifest.weeks).Count) { [void]$issues.Add('Assigned weeks, curriculum weeks, and manuscript chapters do not agree.') }
    foreach ($field in @('resources','sections')) {
        $ids = @($Manifest.$field | ForEach-Object id)
        if ($ids.Count -eq 0 -or @($ids | Select-Object -Unique).Count -ne $ids.Count) { [void]$issues.Add("Missing or duplicate $field IDs.") }
    }
    if (@($Manifest.weeks.number | Select-Object -Unique).Count -ne @($Manifest.weeks).Count) { [void]$issues.Add('Duplicate assigned week numbers.') }
    foreach ($week in $Manifest.weeks) {
        $n = [int]$week.number
        $courseWeek = @($Course.weeks | Where-Object number -eq $n)
        if ($courseWeek.Count -ne 1 -or (($courseWeek.modules.objectiveId -join ',') -ne ($week.objectiveIds -join ','))) { [void]$issues.Add("Week ${n}: objective IDs do not match the authoritative curriculum.") }
        $chapterMatches = @($chapters | Where-Object { [int]$_.Groups['n'].Value -eq $n })
        if ($chapterMatches.Count -ne 1) { [void]$issues.Add("Week ${n}: missing or duplicate manuscript chapter."); continue }
        $chapter = $chapterMatches[0].Value
        $split = [regex]::Split($chapter, '(?m)^#{2,3} Scholarly Sources\s*\r?\n', 2)
        $body = $split[0]
        $notes = if ($split.Count -eq 2) { $split[1] } else { '' }
        $noteMap = @{}
        foreach ($note in [regex]::Matches($notes, '(?m)^(\d+)\. ([^\r\n]+)')) { $noteMap[$note.Groups[1].Value] = $note.Groups[2].Value }
        $allowed = @(); $resolvedSections = @{}
        foreach ($id in $week.sectionIds) {
            $section = @($Manifest.sections | Where-Object id -eq $id)
            if ($section.Count -ne 1 -or $section[0].resourceId -notin $week.resourceIds -or $section[0].reviewStatus -ne 'CONTENT_REVIEWED') { [void]$issues.Add("Week ${n}: missing, unreviewed, or unassigned section $id."); continue }
            $section = $section[0]
            $allowed += $section.url
            if ($section.fullTextUrl) { $allowed += $section.fullTextUrl }
            $resolved = @($noteMap.Keys | Where-Object { $noteMap[$_].Contains("]($($section.url))") })
            if ($resolved.Count -ne 1) { [void]$issues.Add("Week ${n}: required source $id has no unique numbered note."); continue }
            $resolvedSections[$id] = [string]$resolved[0]
            if (-not $body.Contains("[$($resolved[0])](#chapter-$n-note-$($resolved[0]))")) { [void]$issues.Add("Week ${n}: $id is listed but never cited in the chapter body.") }
        }
        foreach ($resourceId in $week.resourceIds) {
            $resource = @($Manifest.resources | Where-Object id -eq $resourceId)
            if ($resource.Count -ne 1) { [void]$issues.Add("Week ${n}: unresolved resource $resourceId."); continue }
            $allowed += $resource[0].url
            if (-not $notes.Contains("]($($resource[0].url))")) { [void]$issues.Add("Week ${n}: the exact assigned resource URL is missing for $resourceId.") }
        }
        foreach ($urlMatch in [regex]::Matches($chapter, '\]\((https?://[^)]+)\)')) { if ($urlMatch.Groups[1].Value -notin $allowed) { [void]$issues.Add("Week ${n}: unassigned URL $($urlMatch.Groups[1].Value).") } }
        foreach ($cite in [regex]::Matches($body, '\[(\d+)\]\(#chapter-(\d+)-note-(\d+)\)')) {
            if ([int]$cite.Groups[2].Value -ne $n -or $cite.Groups[1].Value -ne $cite.Groups[3].Value -or -not $noteMap.ContainsKey($cite.Groups[3].Value)) { [void]$issues.Add("Week ${n}: malformed or dangling citation.") }
        }
        foreach ($number in $noteMap.Keys) { if (-not $body.Contains("[$number](#chapter-$n-note-$number)")) { [void]$issues.Add("Week ${n}: orphan bibliography note $number.") } }
        foreach ($evidence in $week.evidence) {
            $pattern = '(?ms)^### ' + [regex]::Escape($evidence.heading) + '\r?\n(?<body>.*?)(?=^#{2,4} |\z)'
            $passage = [regex]::Match($body, $pattern).Groups['body'].Value
            $prose = [regex]::Replace($passage, '(?m)^\|[^\r\n]*', '')
            if ([regex]::Matches($prose, '\b[\p{L}]+\b').Count -lt 100) { [void]$issues.Add("Week ${n}: missing substantive development under $($evidence.heading).") }
            foreach ($concept in $evidence.concepts) { if ($passage.IndexOf($concept, [StringComparison]::OrdinalIgnoreCase) -lt 0) { [void]$issues.Add("Week ${n}: $($evidence.heading) lacks expected concept $concept.") } }
            foreach ($id in $evidence.sourceIds) {
                $number = $resolvedSections[$id]
                if (-not $number -or -not $passage.Contains("[$number](#chapter-$n-note-$number)")) { [void]$issues.Add("Week ${n}: development under $($evidence.heading) is not linked to $id.") }
            }
        }
    }
    return [pscustomobject]@{
        status=$(if($issues.Count){'FAIL'}else{'PASS'});issues=@($issues)
        detail=$(if($issues.Count){$issues -join ' '}else{'Exact weekly resources, editions, body citations, and mapped source-development sections agree.'})
        limitation='Mechanical traceability and content-presence checks do not establish claim accuracy, pedagogical adequacy, copyright clearance, or future URL availability.'
    }
}

function Test-EbookAssignedSourcePackage {
    param([object]$Course, [object]$Plan, [string]$Markdown, [string]$OutputFolder)
    if ($Plan.sourceMode -eq 'Assigned') { return Get-EbookRequiredSourceReview -Plan $Plan -OutputFolder $OutputFolder -Markdown $Markdown }
    if (-not $OutputFolder) {
        return [pscustomobject]@{status=$(if($Plan.assignedReadingListRequired){'FAIL'}else{'PASS'});detail='No package folder supplied for assigned-source verification.';applicable=[bool]$Plan.assignedReadingListRequired}
    }
    $path = Join-Path $OutputFolder 'assigned-reading-list.json'
    $required = $Plan.assignedReadingListRequired -or (Test-Path -LiteralPath $path)
    if (-not $required) { return [pscustomobject]@{status='PASS';detail='No locked reading list was supplied for this package.';applicable=$false} }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{status='FAIL';detail='Required assigned reading list is missing.';applicable=$true} }
    if (-not $Plan.assignedReadingListSha256 -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Plan.assignedReadingListSha256) { return [pscustomobject]@{status='FAIL';detail='Assigned reading list hash differs from the locked plan.';applicable=$true} }
    try {
        $manifest = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $report = Test-EbookAssignedSources -Course $Course -Plan $Plan -Markdown $Markdown -Manifest $manifest
        $report | Add-Member NoteProperty applicable $true
        return $report
    }
    catch { return [pscustomobject]@{status='FAIL';detail="Invalid assigned reading list: $($_.Exception.Message)";applicable=$true} }
}
