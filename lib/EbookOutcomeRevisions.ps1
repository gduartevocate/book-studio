# An explicit designer-reviewed amendment, never an implicit chat mutation.
function ConvertFrom-EbookOutcomeCatalog {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 60000) { throw 'Paste a CO/LO list of at most 60,000 characters.' }
    $records=[Collections.Generic.List[object]]::new(); $ids=@{}; $current=$null
    foreach ($raw in ($Text -split '\r?\n')) {
        $line=$raw.Trim()
        if (-not $line) { continue }
        if ($line -match '^(CO\d+|LO\d+\.\d+)\s*[:.]\s+(.+)$') {
            $id=$Matches[1].ToUpperInvariant(); $wording=$Matches[2].Trim()
            if ($ids.ContainsKey($id)) { throw "Duplicate outcome ID: $id." }
            $current=[pscustomobject]@{objectiveId=$id;objective=$wording}
            $records.Add($current); $ids[$id]=$true
        } elseif ($line -match '^(CO|LO)\d') { throw "Use CO1: wording or LO1.1: wording. Unrecognized line: $line" }
        elseif ($current) { $current.objective += ' ' + $line }
        # A question before the first CO is not part of the outcome catalog.
    }
    if (-not $records.Count -or $records.Count -gt 250) { throw 'Supply between 1 and 250 CO/LO records.' }
    foreach ($record in $records) {
        if ($record.objective.Length -gt 3000) { throw "Outcome $($record.objectiveId) exceeds 3,000 characters." }
        if ($record.objectiveId -match '^LO(\d+)\.') {
            if (-not $ids.ContainsKey("CO$($Matches[1])")) { throw "$($record.objectiveId) has no parent CO$($Matches[1])." }
        }
    }
    return $records.ToArray()
}

function Set-EbookCourseOutcomeRevision {
    param([object]$Course,[object]$Revision)
    if ($Revision.schemaVersion -ne 1 -or -not $Revision.reviewedBy -or -not $Revision.confirmedAt -or
        $Revision.baseSourceSha256 -ne (Get-FileHash -LiteralPath $Course.sourcePath).Hash) {
        throw 'The reviewed outcome amendment is invalid or its original blueprint changed. Review the outcome replacement again.'
    }
    $weeks=@($Course.weeks | Sort-Object number)
    if ($weeks.Count -ne @($Revision.chapters).Count) { throw 'The outcome amendment no longer matches the course chapter count.' }
    $seen=@{}
    foreach ($week in $weeks) {
        $matches=@($Revision.chapters | Where-Object number -eq $week.number)
        if ($matches.Count -ne 1 -or -not @($matches[0].records).Count) { throw "The outcome amendment is missing Chapter $($week.number)." }
        $chapterIds=@{}
        $modules=@(foreach ($record in $matches[0].records) {
            $id=[string]$record.objectiveId; $text=[string]$record.objective
            if ($id -notmatch '^(CO\d+|LO\d+\.\d+)$' -or -not $text.Trim() -or $chapterIds.ContainsKey($id)) { throw 'Invalid or duplicate amended objective.' }
            if ($seen.ContainsKey($id) -and $seen[$id] -cne $text) { throw "Shared outcome $id has conflicting wording." }
            $seen[$id]=$text; $chapterIds[$id]=$true
            [pscustomobject]@{objectiveId=$id;title=$text;objective=$text;subObjectives=@()}
        })
        $week.modules=$modules
        $week | Add-Member -NotePropertyName courseObjectiveIds -NotePropertyValue @($modules | ForEach-Object { if($_.objectiveId -match '^LO(\d+)\.'){"CO$($Matches[1])"}else{$_.objectiveId} } | Select-Object -Unique) -Force
    }
    $Course.weeks=$weeks
    $Course | Add-Member -NotePropertyName courseObjectives -NotePropertyValue @($Revision.catalog | Where-Object objectiveId -like 'CO*') -Force
    $Course | Add-Member -NotePropertyName outcomeRevision -NotePropertyValue $Revision -Force
    return $Course
}
