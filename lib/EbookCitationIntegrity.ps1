# Shared by all courses and by both renderers; never silently discard a source.
function Test-EbookNotesHeading {
    param([string]$Text)
    return $Text.Trim() -match '^(Scholarly Sources(?:\s*/\s*Numbered Notes)?|Notes|Numbered Scholarly Notes|Numbered Notes)$'
}

function Test-EbookVisibleCitationMarkup {
    param([AllowNull()][string]$Text)
    $decoded = [string]$Text
    # Also catch escaped and double-escaped tags, including tags split over Word runs.
    for ($i = 0; $i -lt 3; $i++) { $decoded = [Net.WebUtility]::HtmlDecode($decoded) }
    return $decoded -match '(?is)</?span\b|<a\b[^>]*(?:id|name)\s*=\s*["'']?chapter[-_]\d+[-_]note'
}

function ConvertTo-EbookCitationMarkdown {
    param([Parameter(Mandatory)][string]$Markdown)
    $lines = @($Markdown -split '\r?\n')
    $output = New-Object Collections.Generic.List[string]
    $targets = @{}
    $links = New-Object Collections.Generic.List[string]
    $chapter = 0; $inNotes = $false; $noteNumber = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ($line -match '^(#{1,4})\s+(.+?)\s*$') {
            $level = $Matches[1]; $title = $Matches[2]
            if ($title -match '^Chapter\s+(\d+)\s*:') { $chapter = [int]$Matches[1] }
            $inNotes = Test-EbookNotesHeading $title
            if ($inNotes) { $noteNumber = 0; $line = "$level Scholarly Sources" }
        }
        # Codex sometimes places the legacy HTML target inline with a
        # numbered source note. It is safe to normalize only the exact
        # chapter/note target that belongs to that note; all other HTML
        # citation markup remains rejected below.
        if ($inNotes -and $chapter -gt 0 -and $line -match '^\s*(\d+)\.\s*<a\s+id\s*=\s*(["''])(chapter-(\d+)-note-(\d+))\2\s*>\s*</a>\s*(\S.*)$') {
            $inlineNumber = [int]$Matches[1]
            $inlineAnchor = $Matches[3]
            $inlineChapter = [int]$Matches[4]
            $inlineNote = [int]$Matches[5]
            if ($inlineChapter -ne $chapter -or $inlineNote -ne $inlineNumber -or $inlineNumber -ne ($noteNumber + 1)) {
                throw "Citation preflight: misplaced or mismatched inline legacy anchor '$inlineAnchor'."
            }
            $line = "$inlineNumber. $($Matches[6])"
        }
        if ($line -match '^\s*<span\s+id\s*=\s*(["''])(chapter-(\d+)-note-(\d+))\1\s*>\s*</span>\s*$') {
            $anchor = $Matches[2]; $anchorChapter = [int]$Matches[3]; $anchorNote = [int]$Matches[4]
            $next = $i + 1
            while ($next -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$next])) { $next++ }
            if (-not $inNotes -or $chapter -le 0 -or $anchorChapter -ne $chapter -or
                $anchorNote -ne ($noteNumber + 1) -or $next -ge $lines.Count -or
                $lines[$next] -notmatch ('^\s*' + $anchorNote + '\.\s+\S')) {
                throw "Citation preflight: misplaced or mismatched legacy anchor '$anchor'."
            }
            # The renderers create a native bookmark/list ID from this numbered note.
            continue
        }
        if (Test-EbookVisibleCitationMarkup $line) {
            throw "Citation preflight: unsupported or escaped citation markup at line $($i + 1)."
        }
        if ($inNotes -and $chapter -gt 0 -and $line -match '^\s*(\d+)\.\s+(.+)$') {
            $number = [int]$Matches[1]; $body = $Matches[2]
            if ($number -ne ($noteNumber + 1)) {
                throw "Citation preflight: Chapter $chapter sources must run 1, 2, 3...; expected $($noteNumber + 1), found $number."
            }
            $noteNumber = $number
            $id = "chapter-$chapter-note-$number"
            if ($targets.ContainsKey($id)) { throw "Citation preflight: duplicate note '$id'." }
            $targets[$id] = $true
            $line = "$number. $body"
        }
        foreach ($link in [regex]::Matches($line, '\]\(#(chapter[-_]\d+[-_]note[-_]\d+)\)')) {
            $links.Add($link.Groups[1].Value.Replace('_', '-'))
        }
        $line = [regex]::Replace($line, '\]\(#(chapter[-_]\d+[-_]note[-_]\d+)\)', {
            param($match)
            return '](#' + $match.Groups[1].Value.Replace('_', '-') + ')'
        })
        $output.Add($line)
    }
    foreach ($link in $links) {
        if (-not $targets.ContainsKey($link)) { throw "Citation preflight: unresolved note link '#$link'." }
    }
    return ($output -join "`n")
}

function Get-EbookWordCitationIssues {
    param([Parameter(Mandatory)][xml]$Document, [Parameter(Mandatory)][xml]$Numbering)
    $issues = New-Object Collections.Generic.List[string]
    $uri = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
    $ns = New-Object Xml.XmlNamespaceManager($Document.NameTable); $ns.AddNamespace('w', $uri)
    $numNs = New-Object Xml.XmlNamespaceManager($Numbering.NameTable); $numNs.AddNamespace('w', $uri)
    $text = ($Document.SelectNodes('//w:p', $ns) | ForEach-Object {
        ($_.SelectNodes('.//w:t', $ns) | ForEach-Object InnerText) -join ''
    }) -join "`n"
    if (Test-EbookVisibleCitationMarkup $text) { $issues.Add('DOCX prints internal citation markup as visible text.') }
    if (Test-EbookDeprecatedCaseLabel $text) { $issues.Add('DOCX contains deprecated Case and Face wording; use Business Case.') }
    $bookmarks = @{}
    foreach ($node in $Document.SelectNodes('//w:bookmarkStart', $ns)) {
        $name = $node.GetAttribute('name', $uri)
        if ($bookmarks.ContainsKey($name)) { $issues.Add("DOCX contains duplicate bookmark '$name'.") }
        $bookmarks[$name] = $true
    }
    foreach ($link in $Document.SelectNodes('//w:hyperlink[@w:anchor]', $ns)) {
        $name = $link.GetAttribute('anchor', $uri)
        if (-not $bookmarks.ContainsKey($name)) { $issues.Add("DOCX internal link '$name' has no bookmark.") }
    }
    $definitions = @{}
    foreach ($num in $Numbering.SelectNodes('//w:num', $numNs)) {
        $id = $num.GetAttribute('numId', $uri)
        $abstractId = $num.SelectSingleNode('./w:abstractNumId/@w:val', $numNs).Value
        $level = $Numbering.SelectSingleNode("//w:abstractNum[@w:abstractNumId='$abstractId']/w:lvl[@w:ilvl='0']", $numNs)
        if (-not $level) { $issues.Add("DOCX numbering ID $id has no valid level-0 definition."); continue }
        $format = $level.SelectSingleNode('./w:numFmt/@w:val', $numNs).Value
        $start = $num.SelectSingleNode('./w:lvlOverride[@w:ilvl="0"]/w:startOverride/@w:val', $numNs)
        if (-not $start) { $start = $level.SelectSingleNode('./w:start/@w:val', $numNs) }
        $definitions[$id] = @{format=$format; start=$(if($start){[int]$start.Value}else{0})}
    }
    $used = @{}; $counts = @{}; $previousId = ''; $inNotes = $false; $chapter = 0; $expectedNote = 0
    foreach ($node in $Document.SelectNodes('//w:body/*', $ns)) {
        if ($node.LocalName -ne 'p') { $previousId = ''; continue }
        $paragraphText = ($node.SelectNodes('.//w:t', $ns) | ForEach-Object InnerText) -join ''
        $style = $node.SelectSingleNode('./w:pPr/w:pStyle/@w:val', $ns).Value
        if ($style -match '^Heading[1-6]$') {
            if ($paragraphText -match '^Chapter\s+(\d+)\s*:') { $chapter = [int]$Matches[1] }
            $inNotes = Test-EbookNotesHeading $paragraphText
            $expectedNote = 0
        }
        $idNode = $node.SelectSingleNode('./w:pPr/w:numPr/w:numId/@w:val', $ns)
        $id = if ($idNode) { $idNode.Value } else { '' }
        if (-not $id -or -not $definitions.ContainsKey($id) -or $definitions[$id].format -ne 'decimal') {
            $previousId = ''; continue
        }
        if ($id -ne $previousId) {
            if ($used.ContainsKey($id)) { $issues.Add("DOCX reuses ordered-list numbering ID $id across separate blocks.") }
            $used[$id] = $true
            if ($definitions[$id].start -ne 1) { $issues.Add("DOCX ordered-list numbering ID $id starts at $($definitions[$id].start), not 1.") }
        }
        if (-not $counts.ContainsKey($id)) { $counts[$id] = $definitions[$id].start - 1 }
        $counts[$id]++
        if ($inNotes -and $chapter -gt 0) {
            $expectedNote++
            $expectedName = "chapter_${chapter}_note_$expectedNote"
            if (-not $node.SelectSingleNode("./w:bookmarkStart[@w:name='$expectedName']", $ns)) {
                $issues.Add("DOCX source $expectedName lacks its native bookmark.")
            }
            if ($counts[$id] -ne $expectedNote) { $issues.Add("DOCX source $expectedName displays $($counts[$id]), not $expectedNote.") }
        }
        $previousId = $id
    }
    return $issues.ToArray()
}

function Get-EbookHtmlCitationIssues {
    param([AllowNull()][string]$Html)
    $issues = New-Object Collections.Generic.List[string]
    # Strip real elements BEFORE decoding, so escaped tags remain detectable.
    $visible = [regex]::Replace([string]$Html, '<[^>]+>', '')
    if (Test-EbookVisibleCitationMarkup $visible) { $issues.Add('HTML prints internal citation markup as visible text.') }
    if (Test-EbookDeprecatedCaseLabel ([Net.WebUtility]::HtmlDecode($visible))) { $issues.Add('HTML contains deprecated Case and Face wording; use Business Case.') }
    $targets = @{}
    foreach ($match in [regex]::Matches([string]$Html, '\bid=["''](chapter-\d+-note-\d+)["'']')) {
        $id = $match.Groups[1].Value
        if ($targets.ContainsKey($id)) { $issues.Add("HTML contains duplicate note target '$id'.") }
        $targets[$id] = $true
    }
    foreach ($match in [regex]::Matches([string]$Html, 'href=["'']#(chapter-\d+-note-\d+)["'']')) {
        if (-not $targets.ContainsKey($match.Groups[1].Value)) { $issues.Add("HTML note link '$($match.Groups[1].Value)' has no target.") }
    }
    foreach ($list in [regex]::Matches([string]$Html, '(?is)<ol\b(?<attrs>[^>]*)>(?<body>.*?)</ol>')) {
        $display = 0
        if ($list.Groups['attrs'].Value -match '\bstart\s*=\s*["'']?(\d+)') { $display = [int]$Matches[1] - 1 }
        if ($display -ne 0) { $issues.Add('HTML ordered list does not restart at 1.') }
        foreach ($item in [regex]::Matches($list.Groups['body'].Value, '(?is)<li\b([^>]*)>')) {
            $display++
            if ($item.Groups[1].Value -match '\bvalue\s*=\s*["'']?(\d+)') { $display = [int]$Matches[1] }
            if ($item.Groups[1].Value -match '\bid=["'']chapter-\d+-note-(\d+)["'']' -and $display -ne [int]$Matches[1]) {
                $issues.Add("HTML source note number disagrees with its displayed list number $display.")
            }
        }
    }
    return $issues.ToArray()
}
