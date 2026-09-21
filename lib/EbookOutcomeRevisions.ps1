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

function Resolve-EbookOutcomeAssignments {
    # One rule for turning a CO/LO catalog plus per-chapter ID lists into the
    # records each chapter teaches. Two callers share it: the analysis of a
    # curriculum draft before the book is planned, and the outcome replacement
    # after the format preview exists. They must agree, or a book approved in
    # one place is refused in the other.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Chapters,
        [AllowEmptyCollection()][AllowNull()][object[]]$Assignments
    )
    $byId=@{}; foreach($record in $Catalog){$byId[([string]$record.objectiveId).ToUpperInvariant()]=$record}
    # COs with child LOs are grouping labels, not duplicate learner outcomes.
    $targets=@(foreach($record in $Catalog){ if($record.objectiveId -like 'LO*' -or -not @($Catalog | Where-Object objectiveId -like ($record.objectiveId.Replace('CO','LO')+'.*')).Count){$record} })
    if (@($Assignments).Count -ne @($Chapters).Count) { throw "Provide an outcome assignment for every chapter. This book has $(@($Chapters).Count) chapter(s) and $(@($Assignments).Count) assignment(s) were supplied." }
    $used=@{}
    $resolved=@(foreach($chapter in $Chapters){
        # Not named $assignments: PowerShell variable names are case-insensitive,
        # so that would overwrite the $Assignments parameter after chapter one.
        $forChapter=@($Assignments | Where-Object number -eq $chapter.number)
        if($forChapter.Count -ne 1){throw "Missing or duplicate Chapter $($chapter.number)."}
        $selected=[Collections.Generic.List[object]]::new();$seen=@{}
        foreach($id in (([string]$forChapter[0].ids).ToUpperInvariant() -split '[,;\s]+' | Where-Object {$_})) {
            if(-not $byId.ContainsKey($id)){throw "Unknown outcome $id in Chapter $($chapter.number)."}
            $expanded=@($targets | Where-Object { $_.objectiveId -eq $id -or ($id -like 'CO*' -and $_.objectiveId -like ($id.Replace('CO','LO')+'.*')) })
            foreach($record in $expanded){if(-not $seen.ContainsKey($record.objectiveId)){$selected.Add($record);$seen[$record.objectiveId]=$true;$used[$record.objectiveId]=$true}}
        }
        if(-not $selected.Count){throw "Assign outcomes to Chapter $($chapter.number). Use CO1 for its lessons, or specific IDs such as LO1.1."}
        [pscustomobject]@{number=[int]$chapter.number;title=[string]$chapter.title;records=$selected.ToArray()}
    })
    $missing=@($targets | Where-Object {-not $used.ContainsKey($_.objectiveId)})
    if($missing.Count){throw "Assign every outcome before applying. Unassigned: $($missing.objectiveId -join ', ')."}
    return [pscustomobject]@{chapters=@($resolved);targets=@($targets);uniqueOutcomes=@($targets).Count;newCount=@($resolved | ForEach-Object {$_.records}).Count}
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
